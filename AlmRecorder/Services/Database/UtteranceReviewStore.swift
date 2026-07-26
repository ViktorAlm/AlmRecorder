import Foundation
import GRDB

/// How an utterance's current `text` came to be.
enum UtteranceTextSource: String {
    case asr        // straight from the transcription engine
    case verifier   // rewritten by the Gemma audio-verification pass
    case user       // manually edited
}

/// Lifecycle of a flagged utterance through detection → verification → review.
/// `user*` statuses are terminal: the detector and verifier never overwrite a user decision.
enum UtteranceReviewStatus: String {
    case autoHidden = "auto_hidden"          // detector junk tier or verifier "not spoken" — soft-hidden
    case pendingReview = "pending_review"    // needs a human in the review inbox
    case verifiedOk = "verified_ok"          // verifier confirmed the line; skip in future runs
    case autoCorrected = "auto_corrected"    // verifier rewrote the text (original preserved)
    case userKept = "user_kept"
    case userCorrected = "user_corrected"
    case userHidden = "user_hidden"
}

/// Persistence primitives for transcript cleanup. Static and `Database`-scoped (same testable
/// shape as EmbeddingPersistence); GRDBUtteranceRepository wraps these with queue access.
///
/// Invariants:
/// - hide/unhide never touch `text` — soft delete only, always reversible.
/// - `original_text` is written exactly once (first correction wins); revert restores it and
///   returns the row to pristine ASR state.
/// - any text change purges the durable embedding + live vector and clears `has_embedding`,
///   so embedding maintenance re-embeds the new text instead of trusting a stale vector.
enum UtteranceReviewStore {

    /// Body of migration v24_transcript_cleanup (exposed so tests can run it on a bare schema).
    static func migrate(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE utterances ADD COLUMN original_text TEXT")
        try db.execute(sql: "ALTER TABLE utterances ADD COLUMN text_source TEXT NOT NULL DEFAULT 'asr'")
        try db.execute(sql: "ALTER TABLE utterances ADD COLUMN is_hidden INTEGER NOT NULL DEFAULT 0")
        try db.execute(sql: "ALTER TABLE utterances ADD COLUMN asr_min_p REAL")
        try db.execute(sql: "ALTER TABLE utterances ADD COLUMN asr_low_frac REAL")
        try db.execute(sql: "ALTER TABLE utterances ADD COLUMN suspicion REAL")
        try db.execute(sql: "ALTER TABLE utterances ADD COLUMN suspicion_reasons TEXT")
        try db.execute(sql: "ALTER TABLE utterances ADD COLUMN review_status TEXT")
        try db.execute(sql: "ALTER TABLE utterances ADD COLUMN verifier_result TEXT")
        try db.execute(sql: "ALTER TABLE utterances ADD COLUMN reviewed_at DATETIME")
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_utterances_review_status
            ON utterances(review_status) WHERE review_status IS NOT NULL
        """)
        try db.execute(sql: "ALTER TABLE recordings ADD COLUMN transcript_cleaned_at DATETIME")
    }

    // MARK: - Detection results

    struct DetectionUpdate {
        let utteranceId: Int64
        let suspicion: Double
        let reasonsJSON: String
    }

    static func updateDetection(_ db: Database, _ updates: [DetectionUpdate]) throws {
        for update in updates {
            try db.execute(
                sql: "UPDATE utterances SET suspicion = ?, suspicion_reasons = ? WHERE id = ?",
                arguments: [update.suspicion, update.reasonsJSON, update.utteranceId]
            )
        }
    }

    // MARK: - Hide / unhide (soft delete)

    static func hide(_ db: Database, utteranceId: Int64, status: UtteranceReviewStatus,
                     verifierResultJSON: String? = nil) throws {
        try db.execute(sql: """
            UPDATE utterances SET
                is_hidden = 1,
                review_status = ?,
                verifier_result = COALESCE(?, verifier_result),
                reviewed_at = ?
            WHERE id = ?
        """, arguments: [status.rawValue, verifierResultJSON, Date(), utteranceId])
        try invalidateSpeakerGoldIfPresent(db, utteranceId: utteranceId)
        try removeFromLiveIndex(db, utteranceId: utteranceId)

        // A confirmed hallucination teaches the bad-exemplar memory, so the cleanup pass can
        // find more lines like it (exact / n-gram / embedding similarity).
        if let text = try String.fetchOne(db, sql: "SELECT text FROM utterances WHERE id = ?",
                                          arguments: [utteranceId]) {
            let source: HallucinationExemplarStore.Source =
                status == .userHidden ? .user : (verifierResultJSON != nil ? .verifier : .detector)
            try HallucinationExemplarStore.recordBad(db, text: text, source: source)
        }
    }

    static func unhide(_ db: Database, utteranceId: Int64) throws {
        try db.execute(sql: """
            UPDATE utterances SET is_hidden = 0, review_status = ?, reviewed_at = ?
            WHERE id = ?
        """, arguments: [UtteranceReviewStatus.userKept.rawValue, Date(), utteranceId])
        try invalidateSpeakerGoldIfPresent(db, utteranceId: utteranceId)
        // Restore searchability from the durable copy, if one exists.
        if try db.tableExists("utterance_vectors"),
           let row = try Row.fetchOne(db, sql: "SELECT embedding FROM utterance_embeddings WHERE utterance_id = ?",
                                      arguments: [utteranceId]) {
            try EmbeddingPersistence.insertIntoIndex(db, utteranceId: utteranceId, embedding: row["embedding"])
        }
        // Undoing a hide must remove what that hide taught (negative feedback).
        if let text = try String.fetchOne(db, sql: "SELECT text FROM utterances WHERE id = ?",
                                          arguments: [utteranceId]) {
            try HallucinationExemplarStore.recordGood(db, text: text)
        }
    }

    private static func invalidateSpeakerGoldIfPresent(
        _ db: Database,
        utteranceId: Int64
    ) throws {
        guard try db.tableExists("recordings"),
              try db.columns(in: "recordings").contains(where: { $0.name == "speaker_review_status" }),
              let recordingId = try Int64.fetchOne(
                  db,
                  sql: "SELECT recording_id FROM utterances WHERE id = ?",
                  arguments: [utteranceId]
              ) else { return }
        try SpeakerGoldReviewStore.invalidateIfReviewed(db, recordingId: recordingId)
    }

    // MARK: - Corrections

    static func applyCorrection(_ db: Database, utteranceId: Int64, newText: String,
                                source: UtteranceTextSource, status: UtteranceReviewStatus,
                                verifierResultJSON: String? = nil) throws {
        try db.execute(sql: """
            UPDATE utterances SET
                original_text = COALESCE(original_text, text),
                text = ?,
                text_source = ?,
                review_status = ?,
                verifier_result = COALESCE(?, verifier_result),
                reviewed_at = ?,
                has_embedding = 0
            WHERE id = ?
        """, arguments: [newText, source.rawValue, status.rawValue, verifierResultJSON, Date(), utteranceId])
        try purgeEmbedding(db, utteranceId: utteranceId)
    }

    /// Restore the original ASR text. No-op when the row was never corrected.
    static func revertText(_ db: Database, utteranceId: Int64) throws {
        let changed = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM utterances WHERE id = ? AND original_text IS NOT NULL",
                                       arguments: [utteranceId]) ?? 0
        guard changed > 0 else { return }
        try db.execute(sql: """
            UPDATE utterances SET
                text = original_text,
                original_text = NULL,
                text_source = ?,
                review_status = ?,
                reviewed_at = ?,
                has_embedding = 0
            WHERE id = ?
        """, arguments: [UtteranceTextSource.asr.rawValue, UtteranceReviewStatus.userKept.rawValue, Date(), utteranceId])
        try purgeEmbedding(db, utteranceId: utteranceId)
    }

    // MARK: - Review status

    static func setReviewStatus(_ db: Database, utteranceId: Int64, status: UtteranceReviewStatus?,
                                verifierResultJSON: String? = nil) throws {
        try db.execute(sql: """
            UPDATE utterances SET
                review_status = ?,
                verifier_result = COALESCE(?, verifier_result),
                reviewed_at = ?
            WHERE id = ?
        """, arguments: [status?.rawValue, verifierResultJSON, Date(), utteranceId])

        // Keeping a line is the user saying "this text is real speech" — un-teach it.
        if status == .userKept,
           let text = try String.fetchOne(db, sql: "SELECT text FROM utterances WHERE id = ?",
                                          arguments: [utteranceId]) {
            try HallucinationExemplarStore.recordGood(db, text: text)
        }
    }

    // MARK: - Queries

    static func fetchUtterances(_ db: Database, recordingId: Int64, includeHidden: Bool) throws -> [Utterance] {
        let hiddenClause = includeHidden ? "" : "AND is_hidden = 0"
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM utterances
            WHERE recording_id = ? \(hiddenClause)
            ORDER BY utterance_index
        """, arguments: [recordingId])
        return rows.compactMap { Utterance(row: $0) }
    }

    static func countPendingReview(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM utterances WHERE review_status = ?",
                         arguments: [UtteranceReviewStatus.pendingReview.rawValue]) ?? 0
    }

    /// Regenerate `recordings.full_transcript` from the VISIBLE utterances (current text, so
    /// corrections win and hidden junk disappears). Call after any hide/correct/revert batch.
    static func rebuildFullTranscript(_ db: Database, recordingId: Int64) throws {
        let texts = try String.fetchAll(db, sql: """
            SELECT text FROM utterances
            WHERE recording_id = ? AND is_hidden = 0
            ORDER BY utterance_index
        """, arguments: [recordingId])
        let transcript = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        try db.execute(sql: "UPDATE recordings SET full_transcript = ? WHERE id = ?",
                       arguments: [transcript, recordingId])
    }

    // MARK: - Embedding consistency

    /// Text changed → the stored vector describes the OLD text. Purge both copies; embedding
    /// maintenance (generateMissingEmbeddings) re-embeds from has_embedding = 0.
    private static func purgeEmbedding(_ db: Database, utteranceId: Int64) throws {
        try db.execute(sql: "DELETE FROM utterance_embeddings WHERE utterance_id = ?", arguments: [utteranceId])
        try removeFromLiveIndex(db, utteranceId: utteranceId)
    }

    /// The live vectorlite table only exists when the extension loaded; degrade gracefully.
    private static func removeFromLiveIndex(_ db: Database, utteranceId: Int64) throws {
        guard try db.tableExists("utterance_vectors") else { return }
        try db.execute(sql: "DELETE FROM utterance_vectors WHERE rowid = ?", arguments: [utteranceId])
    }
}
