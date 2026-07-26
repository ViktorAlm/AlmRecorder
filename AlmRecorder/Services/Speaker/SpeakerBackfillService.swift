import Foundation

/// One-time rebuild of speaker identity for already-transcribed recordings, without re-transcribing.
///
/// FluidAudio became the standard diarizer after most of the library was transcribed by the legacy
/// DBSCAN path, so the DB holds a mixed/incoherent speaker set. This service clears that set and
/// rebuilds it from scratch: re-diarize each recording's audio with FluidAudio, unify voices across
/// files into stable speakers (same matcher as the live path), and stamp `speaker_uuid` onto each
/// utterance by time-overlap. Transcript text is never touched.
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
    private let speakerService = SpeakerIdentificationService()

    /// Rebuild the entire speaker set from audio. Refuses to run while the transcription queue is
    /// active (both want FluidAudio + the DB) — run it when the queue is idle.
    func run() async {
        guard !isRunning else { return }
        if TranscriptionQueueManager.shared.isProcessing {
            statusText = "Queue is busy — run this when transcription is idle."
            return
        }

        isRunning = true
        processed = 0
        total = 0
        lastSummary = nil
        statusText = "Preparing…"
        defer { isRunning = false }

        let recordings = (try? recordingRepo.getAll(limit: 100_000)) ?? []
        total = recordings.count
        guard !recordings.isEmpty else {
            statusText = "No recordings to process."
            return
        }

        // Load FluidAudio once and reuse across the whole batch.
        let service: FluidAudioEmbeddingService
        do {
            service = try await FluidAudioEmbeddingService()
        } catch {
            statusText = "FluidAudio unavailable: \(error.localizedDescription)"
            return
        }

        // 1) Wipe the legacy/mixed speaker set so the rebuild is coherent.
        clearSpeakerState()

        // 2) Rebuild an accumulating speaker set, recording by recording.
        var assignedUtterances = 0
        for (idx, rec) in recordings.enumerated() {
            processed = idx
            guard let recId = rec.id,
                  let path = rec.filePath,
                  FileManager.default.fileExists(atPath: path) else {
                continue
            }

            statusText = "Diarizing \(rec.title) (\(idx + 1)/\(recordings.count))…"
            do {
                let turns = try await service.diarize(URL(fileURLWithPath: path))
                guard !turns.isEmpty else { continue }

                let clusters = Self.averageClusters(from: turns)
                guard !clusters.isEmpty else { continue }

                let labelToUUID = speakerService.resolveClusters(clusters, recordingId: Int(recId))
                guard !labelToUUID.isEmpty else { continue }

                // Stamp speaker_uuid (+ a tidy display label) onto each utterance by time-overlap.
                let utterances = (try? utteranceRepo.getByRecordingId(recId, includeHidden: true)) ?? []
                var updates: [(id: Int64, label: String, uuid: String)] = []
                for u in utterances {
                    guard let uid = u.id,
                          let raw = SpeakerAlignment.speaker(
                              forUtteranceStart: u.startTime, end: u.endTime, turns: turns),
                          let uuid = labelToUUID[raw] else { continue }
                    updates.append((id: uid, label: "Speaker \(raw)", uuid: uuid))
                }
                applyUtteranceUpdates(updates)
                assignedUtterances += updates.count
            } catch {
                statusText = "Skipped \(rec.title): \(error.localizedDescription)"
            }
        }

        processed = recordings.count
        let speakerCount = (try? speakerService.loadKnownSpeakers().count) ?? 0
        let summary = "Rebuilt \(speakerCount) speakers across \(recordings.count) recordings; \(assignedUtterances) utterances labeled."
        lastSummary = summary
        statusText = summary
    }

    /// Build the same duration-weighted identity evidence used by live transcription, including
    /// each local cluster's actual speech spans for the overlap cannot-link guard.
    static func averageClusters(from turns: [DiarizationTurn]) -> [SpeakerIdentityCluster] {
        SpeakerAlignment.identityClusters(from: turns, policy: .durationWeighted)
    }

    private func clearSpeakerState() {
        statusText = "Clearing legacy speakers…"
        try? GRDBDatabaseManager.shared.write { db in
            try db.execute(
                sql: """
                    UPDATE utterances SET
                        speaker_uuid = NULL,
                        speaker_assignment_source = ?,
                        speaker_reviewed_at = NULL
                """,
                arguments: [SpeakerAssignmentSource.model.rawValue]
            )
            try db.execute(
                sql: "UPDATE recordings SET speaker_review_status = NULL, speaker_reviewed_at = NULL"
            )
            try db.execute(sql: "DELETE FROM speakers")
            // Old UUIDs are gone — drop everything that referenced them.
            try? db.execute(sql: "DELETE FROM speaker_attendee_mappings")
            try? db.execute(sql: "DELETE FROM speaker_embedding_history")
            try? db.execute(sql: "DELETE FROM speaker_merge_history")
        }
    }

    private func applyUtteranceUpdates(_ updates: [(id: Int64, label: String, uuid: String)]) {
        guard !updates.isEmpty else { return }
        try? GRDBDatabaseManager.shared.write { db in
            for u in updates {
                try db.execute(
                    sql: "UPDATE utterances SET speaker_uuid = ?, speaker = ? WHERE id = ?",
                    arguments: [u.uuid, u.label, u.id]
                )
            }
        }
    }
}
