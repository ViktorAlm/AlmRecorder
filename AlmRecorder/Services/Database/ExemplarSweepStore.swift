import Foundation
import GRDB

/// Retroactive lookalike finder: when NEW trash is learned (HallucinationExemplarStore grows),
/// re-match the whole library against it so confirmed hallucinations find their siblings in
/// already-transcribed recordings — without waiting for those recordings to be cleaned again.
///
/// Matching here is text-only (exact normalized + char-trigram Jaccard) and therefore cheap and
/// fully testable; the embedding leg is candidate-generated at runtime via the live vectorlite
/// index and re-verified with true cosine before being fed into `apply` as `.embedding` hits.
///
/// The sweep only ever FLAGS (`pending_review` + `knownHallucination` reason): hiding requires
/// the human or the audio check, and settled lines (user decisions, verified, already flagged,
/// hidden) are never touched — so the sweep is idempotent and safe to run on every tick.
enum ExemplarSweepStore {

    struct Hit: Equatable {
        let utteranceId: Int64
        let recordingId: Int64
        let exemplarText: String
        let kind: Kind

        enum Kind: String {
            case exact, trigram, embedding
        }
    }

    /// User-tunable sensitivity for all four match thresholds (the Review page's slider).
    /// strict = fewer, surgical flags; eager = cast a wide net and let Gemma/the human sort it.
    struct Tuning: Equatable {
        /// Text-embedding cosine floor for the embedding leg.
        let cosineFloor: Double
        /// Overlap coefficient (|∩| / |smaller|) floor — containment-tolerant, not Jaccard:
        /// hallucination variants usually CONTAIN or EXTEND a known exemplar.
        let overlapFloor: Double
        /// A trigram hit must also EXPLAIN the utterance: cover at least this share of the
        /// utterance's own trigrams. Containment alone is worthless — a long real meeting line
        /// that merely says "thank you" shares all of a short exemplar's trigrams.
        let coverageFloor: Double
        /// Exact/embedding hits from SHORT exemplars only flag near-silent lines (normalized
        /// chars/sec below this), because short phrases are also real speech.
        let sparseCharsPerSecond: Double

        static let strict = Tuning(cosineFloor: 0.95, overlapFloor: 0.85, coverageFloor: 0.65, sparseCharsPerSecond: 1.0)
        static let balanced = Tuning(cosineFloor: 0.92, overlapFloor: 0.75, coverageFloor: 0.5, sparseCharsPerSecond: 1.5)
        static let eager = Tuning(cosineFloor: 0.87, overlapFloor: 0.65, coverageFloor: 0.35, sparseCharsPerSecond: 3.0)

        /// Slider value (0 strict / 1 balanced / 2 eager) → preset.
        static func forSensitivity(_ sensitivity: Double) -> Tuning {
            if sensitivity < 0.5 { return .strict }
            if sensitivity < 1.5 { return .balanced }
            return .eager
        }
    }

    /// EITHER side shorter than this many trigrams (~10 chars) can't overlap-match: a tiny
    /// exemplar like "you" is contained in half of all speech (coefficient 1.0 against
    /// anything), and a tiny utterance contained in a long exemplar means just as little.
    /// Exact matching still covers short texts. Enforced inside `similarity`.
    static let minTrigramsForOverlap = 8
    static let sweepSuspicion = 0.5

    /// Exemplars at least this long are distinctive (subtitle credits) — exact/embedding
    /// matches flag unconditionally, regardless of audio shape.
    static let distinctiveExemplarLength = 15

    /// Match exemplars with id > `sinceId` against every visible, unsettled utterance.
    /// Returns the hits plus the new high-water mark (max exemplar id seen).
    static func textMatches(_ db: Database,
                            exemplarsNewerThan sinceId: Int64,
                            tuning: Tuning = .balanced) throws -> (hits: [Hit], maxExemplarId: Int64) {
        guard try db.tableExists(HallucinationExemplarStore.tableName) else { return ([], sinceId) }
        let exemplarRows = try Row.fetchAll(db, sql: """
            SELECT id, normalized_text FROM \(HallucinationExemplarStore.tableName)
            WHERE id > ? ORDER BY id
        """, arguments: [sinceId])
        guard !exemplarRows.isEmpty else { return ([], sinceId) }

        let maxExemplarId = exemplarRows.map { $0["id"] as Int64 }.max() ?? sinceId
        let exemplarTexts = exemplarRows.map { $0["normalized_text"] as String }
        let exactSet = Set(exemplarTexts)
        let exemplarTrigrams = exemplarTexts.map { (text: $0, trigrams: charTrigrams($0)) }

        let candidates = try Row.fetchAll(db, sql: """
            SELECT id, recording_id, text, start_time, end_time FROM utterances
            WHERE is_hidden = 0 AND review_status IS NULL
        """)

        var hits: [Hit] = []
        for row in candidates {
            let utteranceId: Int64 = row["id"]
            let recordingId: Int64 = row["recording_id"]
            let duration = (row["end_time"] as Double) - (row["start_time"] as Double)
            let normalized = TranscriptSuspicionScorer.normalizedText(row["text"] as String)
            guard !normalized.isEmpty else { continue }

            if exactSet.contains(normalized),
               passesGate(exemplarText: normalized, normalizedLength: normalized.count,
                          duration: duration, tuning: tuning) {
                hits.append(Hit(utteranceId: utteranceId, recordingId: recordingId,
                                exemplarText: normalized, kind: .exact))
                continue
            }
            let trigrams = charTrigrams(normalized)
            if let match = exemplarTrigrams.first(where: {
                similarity(trigrams, $0.trigrams) >= tuning.overlapFloor
                    && utteranceCoverage(trigrams, exemplar: $0.trigrams) >= tuning.coverageFloor
            }) {
                hits.append(Hit(utteranceId: utteranceId, recordingId: recordingId,
                                exemplarText: match.text, kind: .trigram))
            }
        }
        return (hits, maxExemplarId)
    }

    struct ApplyOutcome: Equatable {
        let applied: Int
        /// Recordings that received new flags — callers enqueue these for the audio double-check.
        let recordingIds: Set<Int64>
    }

    /// Flag the hits for human review. Re-checks eligibility per row (visible + unsettled), so
    /// applying is idempotent and embedding-leg hits computed outside can be passed in safely.
    @discardableResult
    static func apply(_ db: Database, hits: [Hit]) throws -> ApplyOutcome {
        var applied = 0
        var touchedRecordings: Set<Int64> = []

        for hit in hits {
            guard let row = try Row.fetchOne(db, sql: """
                SELECT suspicion, suspicion_reasons FROM utterances
                WHERE id = ? AND is_hidden = 0 AND review_status IS NULL
            """, arguments: [hit.utteranceId]) else { continue }

            var reasons = decodeReasons(row["suspicion_reasons"] as String?)
            if !reasons.contains(TranscriptSuspicionScorer.Reason.knownHallucination.rawValue) {
                reasons.append(TranscriptSuspicionScorer.Reason.knownHallucination.rawValue)
            }
            let suspicion = max(row["suspicion"] as Double? ?? 0, sweepSuspicion)
            let resultJSON = sweepResultJSON(hit)

            try db.execute(sql: """
                UPDATE utterances SET
                    suspicion = ?, suspicion_reasons = ?,
                    review_status = ?, verifier_result = ?, reviewed_at = ?
                WHERE id = ?
            """, arguments: [suspicion, encodeReasons(reasons),
                             UtteranceReviewStatus.pendingReview.rawValue, resultJSON, Date(),
                             hit.utteranceId])
            applied += 1
            touchedRecordings.insert(hit.recordingId)
        }
        return ApplyOutcome(applied: applied, recordingIds: touchedRecordings)
    }

    // MARK: - Helpers

    private static func sweepResultJSON(_ hit: Hit) -> String {
        let payload: [String: Any] = [
            "source": "exemplar_sweep",
            "match": hit.kind.rawValue,
            "exemplar": String(hit.exemplarText.prefix(80)),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"source":"exemplar_sweep"}"#
        }
        return json
    }

    private static func decodeReasons(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let reasons = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return reasons
    }

    private static func encodeReasons(_ reasons: [String]) -> String {
        guard let data = try? JSONEncoder().encode(reasons),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    static func charTrigrams(_ text: String) -> Set<String> {
        let characters = Array(text)
        guard characters.count >= 3 else { return [] }
        return Set((0...(characters.count - 3)).map { String(characters[$0..<($0 + 3)]) })
    }

    /// Overlap coefficient: |a ∩ b| / min(|a|, |b|). Returns 0 when EITHER side is below the
    /// minimum-size guard — tiny sets make containment meaningless (single enforcement point
    /// for both the sweep and the live per-recording matching).
    static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard a.count >= minTrigramsForOverlap, b.count >= minTrigramsForOverlap else { return 0 }
        let intersection = a.intersection(b).count
        return Double(intersection) / Double(min(a.count, b.count))
    }

    /// Whether an exact/embedding match against this exemplar may flag a line of the given
    /// shape: distinctive (long) exemplars always may; short ones only on near-silent audio,
    /// measured on the NORMALIZED text (dot-filler padding must not count as spoken content).
    static func passesGate(exemplarText: String, normalizedLength: Int, duration: Double,
                           tuning: Tuning = .balanced) -> Bool {
        if exemplarText.count >= distinctiveExemplarLength { return true }
        guard duration >= 1 else { return false }
        return Double(normalizedLength) / duration < tuning.sparseCharsPerSecond
    }

    /// Share of the utterance's trigrams explained by the exemplar match.
    static func utteranceCoverage(_ utteranceTrigrams: Set<String>, exemplar: Set<String>) -> Double {
        guard !utteranceTrigrams.isEmpty else { return 0 }
        return Double(utteranceTrigrams.intersection(exemplar).count) / Double(utteranceTrigrams.count)
    }
}
