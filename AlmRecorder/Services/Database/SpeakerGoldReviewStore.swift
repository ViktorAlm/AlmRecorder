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
        }
        try setStatus(db, recordingId: recordingId, status: .gold, reviewedAt: reviewedAt)
    }

    static func markNeedsCorrection(
        _ db: Database,
        recordingId: Int64,
        reviewedAt: Date = Date()
    ) throws {
        try setStatus(db, recordingId: recordingId, status: .needsCorrection, reviewedAt: reviewedAt)
    }

    static func markInProgress(
        _ db: Database,
        recordingId: Int64,
        reviewedAt: Date = Date()
    ) throws {
        try setStatus(db, recordingId: recordingId, status: .inProgress, reviewedAt: reviewedAt)
    }

    /// Visibility-only transcript changes should invalidate an existing review without creating a
    /// speaker-review task on every recording touched by automatic transcript cleanup.
    static func invalidateIfReviewed(
        _ db: Database,
        recordingId: Int64,
        reviewedAt: Date = Date()
    ) throws {
        try db.execute(
            sql: """
                UPDATE recordings SET speaker_review_status = ?, speaker_reviewed_at = ?
                WHERE id = ? AND speaker_review_status IS NOT NULL
            """,
            arguments: [RecordingSpeakerReviewStatus.inProgress.rawValue, reviewedAt, recordingId]
        )
    }

    static func clear(_ db: Database, recordingId: Int64) throws {
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
}
