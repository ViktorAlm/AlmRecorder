import Foundation

/// Resumable, non-destructive acoustic-evidence backfill for historical local speaker clusters.
///
/// Fresh FluidAudio diarization is matched to immutable legacy timelines. Only a missing embedding
/// is filled, and only when one new voice dominates the old cluster's speech span. Names, manual or
/// gold assignments, pair labels, UUID projections, transcript text, and undo history are untouched.
@MainActor
final class SpeakerBackfillService: ObservableObject {
    static let shared = SpeakerBackfillService()

    @Published private(set) var isRunning = false
    @Published private(set) var processed = 0
    @Published private(set) var total = 0
    @Published private(set) var statusText = ""
    @Published private(set) var lastSummary: String?

    private let recordingRepo = GRDBRecordingRepository()
    private let utteranceRepo = GRDBUtteranceRepository()
    private var runTask: Task<Void, Never>?
    private var runGeneration: UUID?
    private var shouldResumeAfterPreemption = false

    /// Fill missing evidence recording-by-recording. Completed rows are the durable checkpoint, so
    /// relaunching or preempting the operation naturally resumes at the first remaining recording.
    func run() async {
        guard runTask == nil else { return }
        let generation = UUID()
        runGeneration = generation
        isRunning = true
        processed = 0
        lastSummary = nil
        statusText = "Finding local voices without acoustic evidence…"
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performRun()
        }
        runTask = task
        await task.value
        guard runGeneration == generation else { return }
        runTask = nil
        runGeneration = nil
        isRunning = false
    }

    /// Build the same duration-weighted identity evidence used by live transcription, including
    /// each local cluster's actual speech spans for the overlap cannot-link guard.
    static func averageClusters(from turns: [DiarizationTurn]) -> [SpeakerIdentityCluster] {
        SpeakerAlignment.identityClusters(from: turns, policy: .durationWeighted)
    }

    func stopProcessingForPreemption() {
        guard runTask != nil else { return }
        shouldResumeAfterPreemption = true
        statusText = "Yielding speaker evidence backfill to foreground work…"
        runTask?.cancel()
    }

    func resumeAfterPreemption() {
        guard shouldResumeAfterPreemption else { return }
        shouldResumeAfterPreemption = false
        Task { await run() }
    }

    private func performRun() async {
        let acquired = await GPUResourceManager.shared.acquire(.speakerEvidenceBackfill)
        guard acquired, !Task.isCancelled else {
            statusText = "Speaker evidence backfill paused safely."
            return
        }
        defer { GPUResourceManager.shared.release(.speakerEvidenceBackfill) }

        let missingRecordingIDs: [Int64]
        do {
            missingRecordingIDs = try GRDBDatabaseManager.shared.read { db in
                try Int64.fetchAll(
                    db,
                    sql: """
                        SELECT DISTINCT recording_id
                        FROM speaker_local_clusters
                        WHERE embedding IS NULL
                        ORDER BY recording_id
                    """
                )
            }
        } catch {
            statusText = "Could not inspect speaker evidence: \(error.localizedDescription)"
            return
        }
        let missingSet = Set(missingRecordingIDs)
        let recordings = ((try? recordingRepo.getAll(limit: 100_000)) ?? [])
            .filter { $0.id.map(missingSet.contains) == true }
            .sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        total = recordings.count
        guard !recordings.isEmpty else {
            statusText = "Every local voice already has acoustic evidence."
            lastSummary = statusText
            return
        }

        let configuration = SpeakerPipelineSettings.shared.activeConfiguration
        let service: FluidAudioEmbeddingService
        do {
            service = try await FluidAudioEmbeddingService(configuration: configuration)
        } catch {
            statusText = "FluidAudio unavailable: \(error.localizedDescription)"
            return
        }

        var filled = 0
        var skipped = 0
        for (index, recording) in recordings.enumerated() {
            do {
                try Task.checkCancellation()
            } catch {
                statusText = "Speaker evidence backfill paused safely after \(processed) calls."
                return
            }
            guard let recordingID = recording.id,
                  let path = recording.filePath,
                  FileManager.default.fileExists(atPath: path) else {
                skipped += 1
                processed = index + 1
                continue
            }
            statusText = "Recovering voice evidence for \(recording.title) "
                + "(\(index + 1)/\(recordings.count))…"
            do {
                let audioURL = URL(fileURLWithPath: path)
                var run = try await service.diarizeDetailed(
                    audioURL,
                    configuration: configuration
                )
                if configuration.diarizationBackend == .offlineVBxTargetedSortformer {
                    let utterances = (try? utteranceRepo.getByRecordingId(
                        recordingID,
                        includeHidden: true
                    )) ?? []
                    let timedWords = utterances.flatMap {
                        SpeakerAlignment.approximateWordSegments(
                            text: $0.text,
                            start: $0.startTime,
                            end: $0.endTime
                        )
                    }
                    run = try await service.repairWithTargetedSortformer(
                        audioURL,
                        baseline: run,
                        targetSegments: timedWords,
                        configuration: configuration
                    )
                }
                let evidence = SpeakerAlignment.identityClusters(
                    from: run.turns,
                    policy: configuration.centroidPolicy
                )
                filled += try GRDBDatabaseManager.shared.write { db in
                    try GlobalSpeakerIdentityStore.backfillAcousticEvidence(
                        db,
                        recordingId: recordingID,
                        evidence: evidence
                    )
                }
            } catch is CancellationError {
                statusText = "Speaker evidence backfill paused safely after \(processed) calls."
                return
            } catch {
                skipped += 1
                statusText = "Skipped \(recording.title): \(error.localizedDescription)"
            }
            processed = index + 1
        }

        let remaining = (try? GRDBDatabaseManager.shared.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM speaker_local_clusters WHERE embedding IS NULL"
            ) ?? 0
        }) ?? 0
        if SpeakerPipelineSettings.shared.continuousReconciliationEnabled {
            _ = try? GlobalSpeakerLibraryReconciliation.applyLatestIfSafe()
        }
        let summary = "Added acoustic evidence to \(filled) local voices across "
            + "\(recordings.count - skipped) recordings; \(remaining) remain for review."
        lastSummary = summary
        statusText = summary
    }

    func cancel() {
        shouldResumeAfterPreemption = false
        runTask?.cancel()
    }
}
