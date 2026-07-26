import Foundation

/// Backfills a per-utterance VOICE embedding (256-dim WeSpeaker) for already-transcribed recordings,
/// WITHOUT changing speaker assignments. Re-diarizes each recording once, attaches the best-overlapping
/// turn's embedding to each existing utterance, then recomputes every speaker's mean from those vectors.
/// This is what powers the "needs review" / reassign cleanup in the People profile for existing data;
/// new recordings get their vectors at transcription time.
@MainActor
final class VoiceEmbeddingBackfillService: ObservableObject {
    static let shared = VoiceEmbeddingBackfillService()

    @Published private(set) var isRunning = false
    @Published private(set) var processed = 0
    @Published private(set) var total = 0
    @Published private(set) var embedded = 0
    @Published private(set) var statusText = ""
    @Published private(set) var lastSummary: String?

    private let recordingRepo = GRDBRecordingRepository()
    private let utteranceRepo = GRDBUtteranceRepository()
    private let speakerRepo = GRDBSpeakerRepository()

    /// Re-diarize every recording with audio and store a voice vector per utterance. Speaker
    /// assignments are preserved. Refuses to run while transcription is active (both want FluidAudio).
    func run() async {
        guard !isRunning else { return }
        if TranscriptionQueueManager.shared.isProcessing {
            statusText = "Queue is busy — run this when transcription is idle."
            return
        }

        isRunning = true
        processed = 0; total = 0; embedded = 0; lastSummary = nil
        statusText = "Preparing…"
        defer { isRunning = false }

        let recordings = (try? recordingRepo.getAll(limit: 100_000)) ?? []
        total = recordings.count
        guard !recordings.isEmpty else { statusText = "No recordings to process."; return }

        // Load FluidAudio once and reuse across the whole batch.
        let service: FluidAudioEmbeddingService
        do {
            service = try await FluidAudioEmbeddingService()
        } catch {
            statusText = "FluidAudio unavailable: \(error.localizedDescription)"
            return
        }

        for (idx, rec) in recordings.enumerated() {
            processed = idx
            if Task.isCancelled { break }
            guard let recId = rec.id,
                  let path = rec.filePath,
                  FileManager.default.fileExists(atPath: path) else { continue }

            statusText = "Fingerprinting \(rec.title) (\(idx + 1)/\(recordings.count))…"
            do {
                let turns = try await service.diarize(URL(fileURLWithPath: path))
                guard !turns.isEmpty else { continue }

                let utterances = (try? utteranceRepo.getByRecordingId(recId, includeHidden: true)) ?? []
                var pairs: [(utteranceId: Int64, embedding: [Float])] = []
                for u in utterances {
                    guard let uid = u.id else { continue }
                    let (_, emb) = SpeakerAlignment.speakerAndEmbedding(
                        forUtteranceStart: u.startTime, end: u.endTime, turns: turns)
                    if let emb, emb.count == VoiceEmbeddingStore.dimensions {
                        pairs.append((uid, emb))
                    }
                }
                if !pairs.isEmpty {
                    try? utteranceRepo.storeVoiceEmbeddingsBatch(pairs)
                    embedded += pairs.count
                }
            } catch {
                statusText = "Skipped \(rec.title): \(error.localizedDescription)"
            }
        }

        // Recompute every speaker's mean from the freshly stored utterance vectors.
        statusText = "Updating speaker fingerprints…"
        let speakers = (try? speakerRepo.getAll()) ?? []
        for s in speakers { try? speakerRepo.recomputeMean(uuid: s.uuid) }

        processed = recordings.count
        let summary = "Stored \(embedded) voice fingerprints; updated \(speakers.count) speaker means."
        lastSummary = summary
        statusText = summary
    }
}
