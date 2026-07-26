import Foundation
import GRDB

/// Preserves user decisions across re-transcription.
///
/// Re-transcribing re-splits the audio on silence/speakers and re-runs the engine, which deletes
/// and recreates every utterance — without this, the user's hides, fixes, and keeps would be
/// silently destroyed. At queue time the decisions are snapshotted (durable table — the job may
/// run much later or after a restart); after the new utterances are created they are re-applied
/// by normalized-text match + nearest time, tolerating the boundary shifts a re-split causes.
///
/// Corrections match against the OLD ORIGINAL ASR text (the junk whisper produced last time),
/// because that is what a re-transcription reproduces — the user's fixed text is what gets
/// re-applied on top. Decisions whisper doesn't reproduce are dropped (and logged), never
/// guessed.
enum RetranscribeCarryover {

    enum Action: String {
        case hide       // user_hidden
        case correct    // user_corrected (re-apply correctedText, preserve new original)
        case keep       // user_kept (prevents the detector/sweep from re-flagging)
    }

    struct Decision: Equatable {
        let action: Action
        /// Normalized text to find in the NEW transcription (for corrections: the old original).
        let matchedText: String
        let correctedText: String?
        let startTime: Double
        let endTime: Double
    }

    struct NewUtterance {
        let id: Int64
        let text: String
        let startTime: Double
        let endTime: Double
    }

    /// How far (seconds, by interval distance) a re-split may move a line and still be "the
    /// same place". Generous — VAD boundaries shift, but 20 minutes away is a different occurrence.
    static let maxTimeDistance: Double = 60

    // MARK: - Pure matching

    /// Greedy 1:1 pairing: every decision claims the time-nearest unclaimed utterance whose
    /// normalized text equals its matched text (within the time tolerance).
    static func match(decisions: [Decision],
                      utterances: [NewUtterance]) -> [(utteranceId: Int64, decision: Decision)] {
        var byText: [String: [(index: Int, utterance: NewUtterance)]] = [:]
        for (index, utterance) in utterances.enumerated() {
            byText[TranscriptSuspicionScorer.normalizedText(utterance.text), default: []].append((index, utterance))
        }

        var claimed: Set<Int> = []
        var matches: [(utteranceId: Int64, decision: Decision)] = []

        for decision in decisions {
            guard let candidates = byText[decision.matchedText] else { continue }
            let best = candidates
                .filter { !claimed.contains($0.index) }
                .map { (entry: $0, distance: intervalDistance(decision: decision, utterance: $0.utterance)) }
                .filter { $0.distance <= maxTimeDistance }
                .min { $0.distance < $1.distance }
            guard let best else { continue }
            claimed.insert(best.entry.index)
            matches.append((best.entry.utterance.id, decision))
        }
        return matches
    }

    /// 0 when the intervals overlap; otherwise the gap between them.
    private static func intervalDistance(decision: Decision, utterance: NewUtterance) -> Double {
        if utterance.endTime >= decision.startTime && utterance.startTime <= decision.endTime {
            return 0
        }
        return max(decision.startTime - utterance.endTime, utterance.startTime - decision.endTime)
    }

    // MARK: - Persistence (snapshot survives restarts; the job may run much later)

    static let tableName = "retranscribe_carryover"

    /// Body of migration v26_retranscribe_carryover.
    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS \(tableName) (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                recording_id INTEGER NOT NULL,
                action TEXT NOT NULL,
                matched_text TEXT NOT NULL,
                corrected_text TEXT,
                start_time DOUBLE NOT NULL,
                end_time DOUBLE NOT NULL,
                created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
        """)
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_carryover_recording ON \(tableName)(recording_id)")
    }

    /// Snapshot every user decision on a recording — call BEFORE deleting its utterances.
    static func snapshot(_ db: Database, recordingId: Int64) throws -> Int {
        guard try db.tableExists(tableName) else { return 0 }
        // Replace any stale snapshot from a previous re-transcription of the same recording.
        try db.execute(sql: "DELETE FROM \(tableName) WHERE recording_id = ?", arguments: [recordingId])

        let rows = try Row.fetchAll(db, sql: """
            SELECT text, original_text, review_status, start_time, end_time FROM utterances
            WHERE recording_id = ? AND review_status IN (?, ?, ?)
        """, arguments: [recordingId,
                         UtteranceReviewStatus.userHidden.rawValue,
                         UtteranceReviewStatus.userCorrected.rawValue,
                         UtteranceReviewStatus.userKept.rawValue])

        var saved = 0
        for row in rows {
            let status: String = row["review_status"]
            let text: String = row["text"]
            let originalText: String? = row["original_text"]

            let action: Action
            let matched: String
            var corrected: String?
            switch status {
            case UtteranceReviewStatus.userHidden.rawValue:
                action = .hide
                matched = TranscriptSuspicionScorer.normalizedText(text)
            case UtteranceReviewStatus.userCorrected.rawValue:
                action = .correct
                matched = TranscriptSuspicionScorer.normalizedText(originalText ?? text)
                corrected = text
            default:
                action = .keep
                matched = TranscriptSuspicionScorer.normalizedText(text)
            }
            guard !matched.isEmpty else { continue }

            try db.execute(sql: """
                INSERT INTO \(tableName) (recording_id, action, matched_text, corrected_text, start_time, end_time)
                VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [recordingId, action.rawValue, matched, corrected,
                             row["start_time"] as Double, row["end_time"] as Double])
            saved += 1
        }
        return saved
    }

    static func pendingDecisions(_ db: Database, recordingId: Int64) throws -> [Decision] {
        guard try db.tableExists(tableName) else { return [] }
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(tableName) WHERE recording_id = ?",
                                    arguments: [recordingId])
        return rows.compactMap { row in
            guard let action = Action(rawValue: row["action"]) else { return nil }
            return Decision(action: action,
                            matchedText: row["matched_text"],
                            correctedText: row["corrected_text"],
                            startTime: row["start_time"],
                            endTime: row["end_time"])
        }
    }

    static func clear(_ db: Database, recordingId: Int64) throws {
        guard try db.tableExists(tableName) else { return }
        try db.execute(sql: "DELETE FROM \(tableName) WHERE recording_id = ?", arguments: [recordingId])
    }

    /// Match the saved decisions against the freshly created utterances and re-apply them.
    /// Consumes the snapshot. Returns the touched utterance ids (callers must exclude them from
    /// embedding generation: hidden lines shouldn't embed, corrected ones re-embed with the
    /// FIXED text via maintenance).
    @discardableResult
    static func reapply(_ db: Database, recordingId: Int64,
                        newUtterances: [NewUtterance]) throws -> Set<Int64> {
        let decisions = try pendingDecisions(db, recordingId: recordingId)
        guard !decisions.isEmpty else { return [] }

        var touched: Set<Int64> = []
        for (utteranceId, decision) in match(decisions: decisions, utterances: newUtterances) {
            switch decision.action {
            case .hide:
                try UtteranceReviewStore.hide(db, utteranceId: utteranceId, status: .userHidden)
            case .correct:
                if let corrected = decision.correctedText {
                    try UtteranceReviewStore.applyCorrection(db, utteranceId: utteranceId, newText: corrected,
                                                             source: .user, status: .userCorrected)
                }
            case .keep:
                try UtteranceReviewStore.setReviewStatus(db, utteranceId: utteranceId, status: .userKept)
            }
            touched.insert(utteranceId)
        }
        try clear(db, recordingId: recordingId)
        return touched
    }
}
