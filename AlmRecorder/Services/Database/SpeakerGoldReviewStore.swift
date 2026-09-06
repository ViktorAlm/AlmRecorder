import Foundation
import GRDB

enum SpeakerGoldReviewError: LocalizedError {
    case noVisibleUtterances
    case unassignedVisibleUtterances(Int)

    var errorDescription: String? {
        switch self {
        case .noVisibleUtterances:
            return "This recording has no visible transcript lines to review."
        case .unassignedVisibleUtterances(let count):
            return "Assign a speaker to all visible lines first (\(count) still unassigned)."
        }
    }
}

/// Durable conversation-level speaker-gold verdicts. The speaker wizard only reviews detected
/// clusters; this store is used after the user checks every visible line in the transcript.
enum SpeakerGoldReviewStore {
    /// Rebuilds derived pair constraints from conversations that were already confirmed before
    /// edit-to-gold capture existed. This is intentionally idempotent: each conversation owns one
    /// action ID, and explicit pair-review labels are never overwritten.
    static func backfillDerivedGold(_ db: Database) throws {
        guard try db.tableExists("speaker_pair_gold_labels"),
              try db.tableExists("speaker_global_assignments"),
              try db.tableExists("recordings") else { return }
        let recordingColumns = Set(try db.columns(in: "recordings").map(\.name))
        guard recordingColumns.contains("speaker_review_status") else { return }

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, speaker_reviewed_at
                FROM recordings
                WHERE speaker_review_status = ?
                ORDER BY id
            """,
            arguments: [RecordingSpeakerReviewStatus.gold.rawValue]
        )
        for row in rows {
            guard let recordingID: Int64 = row["id"] else { continue }
            let reviewedAt: Date = row["speaker_reviewed_at"] ?? Date()
            try SpeakerPairGoldStore.recordConversationGold(
                db,
                recordingID: recordingID,
                now: reviewedAt
            )
        }
    }

    static func confirmGold(
        _ db: Database,
        recordingId: Int64,
        reviewedAt: Date = Date()
    ) throws {
        let visibleCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM utterances WHERE recording_id = ? AND COALESCE(is_hidden, 0) = 0",
            arguments: [recordingId]
        ) ?? 0
        guard visibleCount > 0 else { throw SpeakerGoldReviewError.noVisibleUtterances }

        let unassigned = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM utterances
                WHERE recording_id = ?
                  AND COALESCE(is_hidden, 0) = 0
                  AND speaker_uuid IS NULL
                  AND TRIM(COALESCE(speaker, '')) = ''
            """,
            arguments: [recordingId]
        ) ?? 0
        guard unassigned == 0 else {
            throw SpeakerGoldReviewError.unassignedVisibleUtterances(unassigned)
        }

        // The whole visible speaker transcript was explicitly checked. Stamp each reference row,
        // not just the recording, so extraction can reject stale/partially modified gold safely.
        try db.execute(
            sql: """
                UPDATE utterances SET
                    speaker_assignment_source = ?,
                    speaker_reviewed_at = ?
                WHERE recording_id = ? AND COALESCE(is_hidden, 0) = 0
            """,
            arguments: [SpeakerAssignmentSource.manual.rawValue, reviewedAt, recordingId]
        )
        if try db.tableExists("speaker_global_assignments") {
            try db.execute(
                sql: """
                    UPDATE speaker_global_assignments SET
                        state = ?, source = ?, confidence = 1,
                        matcher = 'user-conversation-gold',
                        operation_id = NULL, updated_at = ?
                    WHERE local_cluster_id IN (
                        SELECT id FROM speaker_local_clusters WHERE recording_id = ?
                    )
                """,
                arguments: [
                    GlobalSpeakerAssignmentState.gold.rawValue,
                    SpeakerAssignmentSource.globalManual.rawValue,
                    reviewedAt,
                    recordingId
                ]
            )
            if try db.tableExists("speaker_pair_gold_labels") {
                try SpeakerPairGoldStore.recordConversationGold(
                    db,
                    recordingID: recordingId,
                    now: reviewedAt
                )
            }
        }
        try setStatus(db, recordingId: recordingId, status: .gold, reviewedAt: reviewedAt)
    }

    static func markNeedsCorrection(
        _ db: Database,
        recordingId: Int64,
        reviewedAt: Date = Date()
    ) throws {
        try removeDerivedGold(db, recordingId: recordingId)
        try setStatus(db, recordingId: recordingId, status: .needsCorrection, reviewedAt: reviewedAt)
    }

    static func markInProgress(
        _ db: Database,
        recordingId: Int64,
        reviewedAt: Date = Date()
    ) throws {
        try removeDerivedGold(db, recordingId: recordingId)
        try setStatus(db, recordingId: recordingId, status: .inProgress, reviewedAt: reviewedAt)
    }

    /// Visibility-only transcript changes should invalidate an existing review without creating a
    /// speaker-review task on every recording touched by automatic transcript cleanup.
    static func invalidateIfReviewed(
        _ db: Database,
        recordingId: Int64,
        reviewedAt: Date = Date()
    ) throws {
        try removeDerivedGold(db, recordingId: recordingId)
        try db.execute(
            sql: """
                UPDATE recordings SET speaker_review_status = ?, speaker_reviewed_at = ?
                WHERE id = ? AND speaker_review_status IS NOT NULL
            """,
            arguments: [RecordingSpeakerReviewStatus.inProgress.rawValue, reviewedAt, recordingId]
        )
    }

    static func clear(_ db: Database, recordingId: Int64) throws {
        try removeDerivedGold(db, recordingId: recordingId)
        try db.execute(
            sql: "UPDATE recordings SET speaker_review_status = NULL, speaker_reviewed_at = NULL WHERE id = ?",
            arguments: [recordingId]
        )
    }

    private static func setStatus(
        _ db: Database,
        recordingId: Int64,
        status: RecordingSpeakerReviewStatus,
        reviewedAt: Date
    ) throws {
        try db.execute(
            sql: "UPDATE recordings SET speaker_review_status = ?, speaker_reviewed_at = ? WHERE id = ?",
            arguments: [status.rawValue, reviewedAt, recordingId]
        )
    }

    private static func removeDerivedGold(
        _ db: Database,
        recordingId: Int64
    ) throws {
        if try db.tableExists("speaker_pair_gold_labels") {
            try SpeakerPairGoldStore.deleteDerivedLabels(
                db,
                actionID: "conversation-gold:\(recordingId)"
            )
        }
        // Gold is trusted enrollment. If the conversation is reopened, remove only the trust that
        // came from that confirmation. A later explicit assignment has another matcher and stays
        // manual/gold.
        if try db.tableExists("speaker_global_assignments") {
            try db.execute(
                sql: """
                    UPDATE speaker_global_assignments SET
                        state = ?, source = ?, confidence = MIN(confidence, 0.8),
                        matcher = 'conversation-gold-invalidated',
                        operation_id = NULL, updated_at = ?
                    WHERE matcher = 'user-conversation-gold'
                      AND local_cluster_id IN (
                          SELECT id FROM speaker_local_clusters WHERE recording_id = ?
                      )
                """,
                arguments: [
                    GlobalSpeakerAssignmentState.legacy.rawValue,
                    SpeakerAssignmentSource.reviewCarryover.rawValue,
                    Date(),
                    recordingId
                ]
            )
        }
    }
}
