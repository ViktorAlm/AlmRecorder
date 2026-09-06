import Foundation
import GRDB

/// Orchestrates the transcript cleanup pass for one recording:
/// re-score every visible utterance (text + token + cross-utterance + embedding signals) →
/// auto-hide hard-evidence junk → route uncertain lines to human review → rebuild the stored
/// transcript → stamp the recording. Gemma audio verification is deferred.
///
/// The tier rules (`apply`) are pure and unit-tested. Every failure path degrades to
/// `pending_review` — the cleanup pass never destroys data and never applies a guess.
final class TranscriptCleanupService {

    static let shared = TranscriptCleanupService()

    private let utteranceRepo = GRDBUtteranceRepository()
    private let recordingRepo = GRDBRecordingRepository()
    private let logger = VoxtralLogger.shared

    private init() {}

    /// Voice-print mismatch is implemented and unit-tested, but the live-library eval
    /// (2026-06-10) showed NO class separation on real data (confirmed-bad mean voiceMatch 0.813
    /// vs everything-else 0.790) while co-flagging fluent speech — so it stays off until labeled
    /// data proves it out. The live eval keeps reporting both distributions per run.
    static let voiceSignalEnabled = false

    // MARK: - Outcome

    struct Outcome {
        var hidden = 0
        var corrected = 0
        var verifiedOk = 0
        var pendingReview = 0
        var skippedNoAudio = 0

        var summary: String {
            var parts: [String] = []
            if hidden > 0 { parts.append("\(hidden) hidden") }
            if corrected > 0 { parts.append("\(corrected) corrected") }
            if verifiedOk > 0 { parts.append("\(verifiedOk) verified") }
            if pendingReview > 0 { parts.append("\(pendingReview) for review") }
            if skippedNoAudio > 0 { parts.append("\(skippedNoAudio) without audio") }
            return parts.isEmpty ? "transcript clean" : parts.joined(separator: ", ")
        }
    }

    // MARK: - Tier rules (pure)

    enum AppliedAction: Equatable {
        case hide
        case correct(String)
        case verifiedOk
        case pendingReview
        case skip
    }

    /// The locked tier contract: only HIGH-confidence verdicts act automatically; "wrong"
    /// additionally needs a sane rewrite; a clamped (partially-heard) span caps confidence at
    /// medium; user decisions are terminal; everything else goes to human review.
    static func apply(verdict: TranscriptVerificationService.LineVerdict,
                      to utterance: Utterance,
                      spanClamped: Bool) -> AppliedAction {
        if let status = utterance.reviewStatus, status.hasPrefix("user_") {
            return .skip
        }
        let effectiveConfidence: TranscriptVerificationService.VerdictConfidence =
            spanClamped && verdict.confidence == .high ? .medium : verdict.confidence
        guard effectiveConfidence == .high else { return .pendingReview }

        switch verdict.verdict {
        case .correct:
            return .verifiedOk
        case .notSpoken:
            return .hide
        case .wrong:
            return isSaneHeard(verdict.heard, original: utterance.text)
                ? .correct(verdict.heard)
                : .pendingReview
        }
    }

    /// The verifier can hallucinate too: a rewrite is only trusted when it is non-empty, in the
    /// same length ballpark as the original (0.3–3×), and free of JSON braces.
    static func isSaneHeard(_ heard: String, original: String) -> Bool {
        let trimmed = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("{"), !trimmed.contains("}") else { return false }
        let originalLength = max(original.trimmingCharacters(in: .whitespacesAndNewlines).count, 1)
        let ratio = Double(trimmed.count) / Double(originalLength)
        return ratio >= 0.3 && ratio <= 3.0
    }

    // MARK: - Orchestration

    /// Run the full cleanup pass. `force` re-verifies lines a previous pass already settled
    /// (verified_ok / auto_corrected / pending_review); user decisions are never touched.
    func cleanRecording(recordingId: Int64, force: Bool,
                        statusHandler: ((String) -> Void)? = nil) async throws -> Outcome {
        var outcome = Outcome()

        guard try recordingRepo.getById(recordingId) != nil else {
            throw TranscriptionError.processFailed("Recording \(recordingId) not found")
        }
        let utterances = try utteranceRepo.getByRecording(id: recordingId, includeHidden: false)
        guard !utterances.isEmpty else {
            try markCleaned(recordingId)
            return outcome
        }

        // 1. Re-score with the full signal set — embedding neighbor-cosines, learned-exemplar
        //    affinity (found hallucinations finding more), and voice-print mismatch — none of
        //    which exist at creation time.
        statusHandler?("Scoring \(utterances.count) lines…")
        let cosines = try neighborCosines(for: utterances)
        let exemplarAffinity = await exemplarAffinities(for: utterances)
        let voiceMatches = Self.voiceSignalEnabled
            ? voiceMatchSignals(for: utterances)
            : Array(repeating: nil as Double?, count: utterances.count)
        let verdicts = TranscriptSuspicionScorer.score(utterances.enumerated().map { index, u in
            var input = TranscriptSuspicionScorer.Input(
                text: u.text, startTime: u.startTime, endTime: u.endTime,
                speaker: u.speaker, meanP: u.confidence,
                minP: u.asrMinP, lowFrac: u.asrLowFrac)
            input.exemplarExact = exemplarAffinity.exact[index]
            input.exemplarTextCosine = exemplarAffinity.cosine[index]
            input.exemplarNgramJaccard = exemplarAffinity.jaccard[index]
            input.voiceMatch = voiceMatches[index]
            return input
        }, neighborCosines: cosines)

        try utteranceRepo.updateDetection(zip(utterances, verdicts).compactMap { u, v in
            guard let id = u.id else { return nil }
            return UtteranceReviewStore.DetectionUpdate(
                utteranceId: id, suspicion: v.score,
                reasonsJSON: TranscriptSuspicionScorer.reasonsJSON(v.reasons))
        })

        // 2. Hide junk; collect the verify tier.
        var toVerify: [Utterance] = []
        for (utterance, verdict) in zip(utterances, verdicts) {
            guard let id = utterance.id else { continue }
            if let status = utterance.reviewStatus, status.hasPrefix("user_") { continue }

            switch verdict.tier {
            case .junk:
                try utteranceRepo.hideUtterance(id, status: .autoHidden)
                outcome.hidden += 1
            case .verify:
                if isEligibleForVerification(utterance, force: force) {
                    toVerify.append(utterance)
                }
            case .ok:
                break
            }
        }

        // 3. Audio-model verification is deferred. Probabilistic findings are never auto-applied:
        //    park them in the human review inbox with explicit provenance.
        if !toVerify.isEmpty {
            for utterance in toVerify {
                guard let id = utterance.id else { continue }
                try utteranceRepo.setReviewStatus(
                    utteranceId: id,
                    status: .pendingReview,
                    verifierResultJSON: verifierUnavailableJSON()
                )
            }
            outcome.pendingReview += toVerify.count
        }

        // 4. Make the stored transcript match the visible lines, stamp the recording.
        try utteranceRepo.rebuildFullTranscript(recordingId: recordingId)
        try markCleaned(recordingId)

        logger.info("[TranscriptCleanup] Recording \(recordingId): \(outcome.summary)")
        return outcome
    }

    // MARK: - Private

    #if false
    // DEFERRED: historical Gemma audio-verification application path.
    private func verifySpan(_ span: TranscriptVerificationService.VerificationSpan,
                            audioPath: String, language: String?,
                            utteranceById: [Int64: Utterance],
                            outcome: inout Outcome) async throws {
        let lineVerdicts: [TranscriptVerificationService.LineVerdict]
        do {
            lineVerdicts = try await verifier.verify(span: span, audioFilePath: audioPath, language: language)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A Metal OOM is a queue-level resource failure, not an ordinary bad verdict. Abort
            // this recording immediately so the queue releases the GPU and observes its backoff
            // before another full Gemma model load. Swallowing it here previously allowed all 12
            // spans to OOM in seconds and stretched the global cooldown to its maximum.
            if Self.shouldAbortVerification(after: error) {
                throw error
            }
            // Verification failure is never data loss — every line goes to the human.
            logger.warning("[TranscriptCleanup] Span verification failed: \(error.localizedDescription)")
            for line in span.lines {
                try utteranceRepo.setReviewStatus(utteranceId: line.utteranceId, status: .pendingReview,
                                                  verifierResultJSON: verdictErrorJSON(error))
                outcome.pendingReview += 1
            }
            return
        }

        for (line, verdict) in zip(span.lines, lineVerdicts) {
            guard let utterance = utteranceById[line.utteranceId] else { continue }
            let json = verdictJSON(verdict, span: span)
            switch Self.apply(verdict: verdict, to: utterance, spanClamped: span.clamped) {
            case .hide:
                try utteranceRepo.hideUtterance(line.utteranceId, status: .autoHidden, verifierResultJSON: json)
                outcome.hidden += 1
            case .correct(let heard):
                try utteranceRepo.applyCorrection(utteranceId: line.utteranceId, newText: heard,
                                                  source: .verifier, status: .autoCorrected,
                                                  verifierResultJSON: json)
                outcome.corrected += 1
            case .verifiedOk:
                try utteranceRepo.setReviewStatus(utteranceId: line.utteranceId, status: .verifiedOk,
                                                  verifierResultJSON: json)
                outcome.verifiedOk += 1
            case .pendingReview:
                try utteranceRepo.setReviewStatus(utteranceId: line.utteranceId, status: .pendingReview,
                                                  verifierResultJSON: json)
                outcome.pendingReview += 1
            case .skip:
                break
            }
        }
    }
    #endif

    static func shouldAbortVerification(after error: Error) -> Bool {
        guard let transcriptionError = error as? TranscriptionError else { return false }
        if case .gpuOutOfMemory = transcriptionError { return true }
        return false
    }

    private func isEligibleForVerification(_ utterance: Utterance, force: Bool) -> Bool {
        Self.needsVerification(reviewStatus: utterance.reviewStatus,
                               verifierResult: utterance.verifierResult, force: force)
    }

    /// Pure eligibility rule. The key distinction lives in pending_review: lines Gemma actually
    /// LISTENED to (a real verdict, uncertain → human's queue) are not re-listened — the sampler
    /// is deterministic and would repeat itself. Lines that are pending WITHOUT a verdict (sweep
    /// flags, environmental failures like missing audio or a dead projector) have never been
    /// heard and SHOULD be — that's the "double-check everything with the LLM" path.
    static func needsVerification(reviewStatus: String?, verifierResult: String?, force: Bool) -> Bool {
        if let status = reviewStatus, status.hasPrefix("user_") { return false }
        guard let status = reviewStatus else { return true }
        if force { return true }

        switch status {
        case UtteranceReviewStatus.pendingReview.rawValue:
            guard let json = verifierResult, let data = json.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return true
            }
            return payload["verdict"] == nil
        case UtteranceReviewStatus.verifiedOk.rawValue, UtteranceReviewStatus.autoCorrected.rawValue:
            return false
        default:
            return true
        }
    }

    /// cosine(embedding[i], embedding[i-1]) per utterance, nil when either side has no
    /// durable embedding (junk, fresh rows, embedding still queued).
    private func neighborCosines(for utterances: [Utterance]) throws -> [Double?] {
        let ids = utterances.compactMap(\.id)
        guard ids.count > 1 else { return Array(repeating: nil, count: utterances.count) }

        let blobs: [Int64: Data] = try GRDBDatabaseManager.shared.read { db in
            let questionMarks = ids.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT utterance_id, embedding FROM utterance_embeddings WHERE utterance_id IN (\(questionMarks))",
                arguments: StatementArguments(ids))
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["utterance_id"] as Int64, $0["embedding"] as Data) })
        }

        var vectors: [Int64: [Float]] = [:]
        for (id, blob) in blobs { vectors[id] = blobToFloats(blob) }

        return utterances.enumerated().map { index, utterance in
            guard index > 0,
                  let id = utterance.id, let previousId = utterances[index - 1].id,
                  let a = vectors[id], let b = vectors[previousId], a.count == b.count, !a.isEmpty else {
                return nil
            }
            return cosine(a, b)
        }
    }

    // MARK: - Retroactive exemplar sweep

    private static let sweepHighWaterMarkKey = "exemplarSweep.highWaterMark"

    struct SweepOutcome {
        var flagged = 0
        /// Recordings that received new flags — the caller enqueues these so Gemma double-checks
        /// every flagged line against the audio.
        var recordingIds: Set<Int64> = []
    }

    /// The sweep tuning currently selected on the Review page — the four individual thresholds
    /// (master slider = preset applied to them; Advanced sliders override individually).
    static var currentSweepTuning: ExemplarSweepStore.Tuning {
        GlobalModelSettings.shared.sweepTuning
    }

    /// Re-match the whole library against exemplars learned since the last sweep: exact + trigram
    /// in one pass (ExemplarSweepStore), plus an embedding leg that uses the live vectorlite index
    /// as a candidate generator and re-verifies with true cosine. Flags only (`pending_review`) —
    /// cheap (no audio, no Gemma), idempotent, safe on every maintenance tick.
    @discardableResult
    func runExemplarSweep() async -> SweepOutcome {
        let settingsRepo = GRDBSettingsRepository.shared
        let since = Int64(settingsRepo.getString(forKey: Self.sweepHighWaterMarkKey) ?? "") ?? 0
        let tuning = Self.currentSweepTuning
        var outcome = SweepOutcome()

        do {
            // Text leg (exact + trigram) in one write transaction.
            var highWaterMark = since
            try GRDBDatabaseManager.shared.write { db in
                let result = try ExemplarSweepStore.textMatches(db, exemplarsNewerThan: since, tuning: tuning)
                highWaterMark = result.maxExemplarId
                let applied = try ExemplarSweepStore.apply(db, hits: result.hits)
                outcome.flagged += applied.applied
                outcome.recordingIds.formUnion(applied.recordingIds)
            }
            guard highWaterMark > since else { return outcome }   // nothing new since last sweep

            // Embedding leg: make sure new exemplars have vectors, then KNN-candidate + reverify.
            let newExemplars = await embeddedExemplars(newerThan: since)
            var embeddingHits: [ExemplarSweepStore.Hit] = []
            for exemplar in newExemplars {
                guard let blob = exemplar.embedding else { continue }
                let exemplarVector = blobToFloats(blob)
                let candidates = (try? utteranceRepo.searchSimilar(embedding: blob, limit: 30)) ?? []
                let candidateVectors = textEmbeddings(for: candidates.compactMap(\.utterance.id))
                for candidate in candidates {
                    guard let id = candidate.utterance.id, let vector = candidateVectors[id],
                          cosine(exemplarVector, vector) >= tuning.cosineFloor else { continue }
                    // Same corroboration gate as the text legs: a short exemplar's semantic
                    // twin ("Thank you.") is also real speech unless the audio is near-silent.
                    let normalized = TranscriptSuspicionScorer.normalizedText(candidate.utterance.text)
                    guard ExemplarSweepStore.passesGate(exemplarText: exemplar.normalizedText,
                                                        normalizedLength: normalized.count,
                                                        duration: candidate.utterance.duration,
                                                        tuning: tuning) else { continue }
                    embeddingHits.append(ExemplarSweepStore.Hit(
                        utteranceId: id, recordingId: candidate.utterance.recordingId,
                        exemplarText: exemplar.normalizedText, kind: .embedding))
                }
            }
            if !embeddingHits.isEmpty {
                try GRDBDatabaseManager.shared.write { db in
                    let applied = try ExemplarSweepStore.apply(db, hits: embeddingHits)
                    outcome.flagged += applied.applied
                    outcome.recordingIds.formUnion(applied.recordingIds)
                }
            }

            settingsRepo.setString(String(highWaterMark), forKey: Self.sweepHighWaterMarkKey)
            if outcome.flagged > 0 {
                logger.info("[TranscriptCleanup] Exemplar sweep flagged \(outcome.flagged) lookalike line(s) for review")
            }
            return outcome
        } catch {
            logger.error("[TranscriptCleanup] Exemplar sweep failed: \(error.localizedDescription)")
            return outcome
        }
    }

    /// Clear every unactioned sweep flag, reset the high-water mark, and sweep again with the
    /// current sensitivity — the "Sweep again" button after moving the slider.
    func resweepFromScratch() async -> SweepOutcome {
        do {
            try GRDBDatabaseManager.shared.write { db in
                try db.execute(sql: """
                    UPDATE utterances SET review_status = NULL, verifier_result = NULL, reviewed_at = NULL
                    WHERE review_status = ? AND verifier_result LIKE '%exemplar_sweep%'
                """, arguments: [UtteranceReviewStatus.pendingReview.rawValue])
            }
        } catch {
            logger.error("[TranscriptCleanup] Resweep reset failed: \(error.localizedDescription)")
        }
        GRDBSettingsRepository.shared.removeObject(forKey: Self.sweepHighWaterMarkKey)
        return await runExemplarSweep()
    }

    /// New exemplars with embeddings attached, lazily embedding the ones that lack a vector.
    private func embeddedExemplars(newerThan sinceId: Int64) async -> [HallucinationExemplarStore.Exemplar] {
        var exemplars = (try? GRDBDatabaseManager.shared.read { db in
            try HallucinationExemplarStore.exemplars(db)
        })?.filter { $0.id > sinceId } ?? []

        let missing = exemplars.filter { $0.embedding == nil }
        if !missing.isEmpty, EmbeddingModelManager.shared.isModelLoaded,
           let embeddings = try? await EmbeddingService.shared.generateEmbeddings(for: missing.map(\.normalizedText)) {
            try? GRDBDatabaseManager.shared.write { db in
                for (exemplar, embedding) in zip(missing, embeddings) {
                    guard let embedding else { continue }
                    try HallucinationExemplarStore.setEmbedding(db, id: exemplar.id, embedding: embedding)
                }
            }
            exemplars = (try? GRDBDatabaseManager.shared.read { db in
                try HallucinationExemplarStore.exemplars(db)
            })?.filter { $0.id > sinceId } ?? exemplars
        }
        return exemplars
    }

    // MARK: - Learned-exemplar affinity ("reuse found hallucinations to find more")

    struct ExemplarAffinity {
        let exact: [Bool]
        let cosine: [Double?]
        let jaccard: [Double?]

        static func none(count: Int) -> ExemplarAffinity {
            ExemplarAffinity(exact: Array(repeating: false, count: count),
                             cosine: Array(repeating: nil, count: count),
                             jaccard: Array(repeating: nil, count: count))
        }
    }

    /// Match every utterance against the bad-exemplar memory three ways: exact normalized text,
    /// char-trigram Jaccard (language-agnostic, works for CJK), and text-embedding cosine.
    /// Exemplars missing an embedding are embedded lazily (capped per run) so the memory's
    /// semantic reach grows as the embedding model is available.
    private func exemplarAffinities(for utterances: [Utterance]) async -> ExemplarAffinity {
        var exemplars = (try? GRDBDatabaseManager.shared.read { db in
            try HallucinationExemplarStore.exemplars(db)
        }) ?? []
        guard !exemplars.isEmpty else { return .none(count: utterances.count) }

        // Lazily embed exemplars that don't have a vector yet.
        let missing = exemplars.filter { $0.embedding == nil }.prefix(50)
        if !missing.isEmpty, EmbeddingModelManager.shared.isModelLoaded,
           let embeddings = try? await EmbeddingService.shared.generateEmbeddings(for: missing.map(\.normalizedText)) {
            try? GRDBDatabaseManager.shared.write { db in
                for (exemplar, embedding) in zip(missing, embeddings) {
                    guard let embedding else { continue }
                    try HallucinationExemplarStore.setEmbedding(db, id: exemplar.id, embedding: embedding)
                }
            }
            exemplars = (try? GRDBDatabaseManager.shared.read { db in
                try HallucinationExemplarStore.exemplars(db)
            }) ?? exemplars
        }

        let exactSet = Set(exemplars.map(\.normalizedText))
        let exemplarTrigrams = exemplars.map { charTrigrams($0.normalizedText) }
        let exemplarVectors = exemplars.compactMap { $0.embedding.map(blobToFloats) }
        let utteranceVectors = textEmbeddings(for: utterances.compactMap(\.id))

        var exact: [Bool] = []
        var cosines: [Double?] = []
        var jaccards: [Double?] = []
        for utterance in utterances {
            let normalized = TranscriptSuspicionScorer.normalizedText(utterance.text)
            exact.append(exactSet.contains(normalized))

            let trigrams = charTrigrams(normalized)
            jaccards.append(trigrams.count < ExemplarSweepStore.minTrigramsForOverlap ? nil
                            : exemplarTrigrams.map { ExemplarSweepStore.similarity(trigrams, $0) }.max())

            if let id = utterance.id, let vector = utteranceVectors[id], !exemplarVectors.isEmpty {
                cosines.append(exemplarVectors.map { cosine(vector, $0) }.max())
            } else {
                cosines.append(nil)
            }
        }
        return ExemplarAffinity(exact: exact, cosine: cosines, jaccard: jaccards)
    }

    /// Voice-print match: cosine of each line's 256-dim voice embedding against its assigned
    /// speaker's centroid within this recording. Hallucinated segments (whisper inventing text
    /// over silence/noise) carry garbage voice prints far from any real speaker. nil when the
    /// line has no voice embedding or the speaker has too few samples for a stable centroid.
    private func voiceMatchSignals(for utterances: [Utterance]) -> [Double?] {
        let ids = utterances.compactMap(\.id)
        guard !ids.isEmpty else { return Array(repeating: nil, count: utterances.count) }

        let voiceVectors: [Int64: [Float]] = (try? GRDBDatabaseManager.shared.read { db in
            let questionMarks = ids.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT utterance_id, embedding FROM utterance_voice_embeddings WHERE utterance_id IN (\(questionMarks))",
                arguments: StatementArguments(ids))
            return Dictionary(uniqueKeysWithValues: rows.map {
                ($0["utterance_id"] as Int64, VoiceEmbeddingStore.dataToFloats($0["embedding"] as Data))
            })
        }) ?? [:]
        guard !voiceVectors.isEmpty else { return Array(repeating: nil, count: utterances.count) }

        func speakerKey(_ utterance: Utterance) -> String {
            utterance.speakerUuid ?? utterance.speaker ?? "?"
        }

        var samplesBySpeaker: [String: [[Float]]] = [:]
        for utterance in utterances {
            guard let id = utterance.id, let vector = voiceVectors[id] else { continue }
            samplesBySpeaker[speakerKey(utterance), default: []].append(vector)
        }
        let centroids = samplesBySpeaker.compactMapValues { samples in
            samples.count >= 3 ? VoiceMath.meanNormalized(samples) : nil
        }

        return utterances.map { utterance in
            guard let id = utterance.id, let vector = voiceVectors[id],
                  let centroid = centroids[speakerKey(utterance)] else { return nil }
            return cosine(vector, centroid)
        }
    }

    private func textEmbeddings(for ids: [Int64]) -> [Int64: [Float]] {
        guard !ids.isEmpty else { return [:] }
        let blobs: [Int64: Data] = (try? GRDBDatabaseManager.shared.read { db in
            let questionMarks = ids.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT utterance_id, embedding FROM utterance_embeddings WHERE utterance_id IN (\(questionMarks))",
                arguments: StatementArguments(ids))
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["utterance_id"] as Int64, $0["embedding"] as Data) })
        }) ?? [:]
        return blobs.mapValues(blobToFloats)
    }

    /// Shared with the retroactive sweep so live matching and sweeping agree on the metric.
    private func charTrigrams(_ text: String) -> Set<String> {
        ExemplarSweepStore.charTrigrams(text)
    }

    private func blobToFloats(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        var floats = [Float](repeating: 0, count: count)
        _ = floats.withUnsafeMutableBufferPointer { data.copyBytes(to: $0) }
        return floats
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Double {
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denominator = (normA.squareRoot() * normB.squareRoot())
        guard denominator > 0 else { return 0 }
        return Double(dot / denominator)
    }

    private func verdictJSON(_ verdict: TranscriptVerificationService.LineVerdict,
                             span: TranscriptVerificationService.VerificationSpan) -> String {
        let payload: [String: Any] = [
            "verdict": verdict.verdict.rawValue,
            "heard": verdict.heard,
            "confidence": verdict.confidence.rawValue,
            "model": GlobalModelSettings.shared.selectedTextLLMModel,
            "spanStart": (span.audioStart * 10).rounded() / 10,
            "spanEnd": (span.audioEnd * 10).rounded() / 10,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// Explicit provenance for suggestions intentionally routed to a human.
    private func verifierUnavailableJSON() -> String {
        #"{"error":"audio_verification_deferred"}"#
    }

    private func verdictErrorJSON(_ error: Error) -> String {
        let payload = ["error": String(error.localizedDescription.prefix(200))]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return #"{"error":"verification_failed"}"# }
        return json
    }

    private func markCleaned(_ recordingId: Int64) throws {
        try GRDBDatabaseManager.shared.write { db in
            try db.execute(sql: "UPDATE recordings SET transcript_cleaned_at = ? WHERE id = ?",
                           arguments: [Date(), recordingId])
        }
    }
}
