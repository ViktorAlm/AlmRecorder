import Foundation
import GRDB

final class GRDBRecordingCommentRepository {
    enum RepositoryError: LocalizedError {
        case recordingNotFound
        case commentNotFound
        case invalidBody
        case invalidAnchor
        case idempotencyConflict
        case authorizationRevoked
        case conflict(currentUpdatedAt: Date)

        var errorDescription: String? {
            switch self {
            case .recordingNotFound: return "Recording not found."
            case .commentNotFound: return "Comment not found."
            case .invalidBody: return "Comment body must contain 1–20,000 characters."
            case .invalidAnchor: return "Comment time anchors are invalid."
            case .idempotencyConflict:
                return "The idempotency key was already used for a different comment intent."
            case .authorizationRevoked: return "MCP authorization was revoked."
            case .conflict: return "The comment changed since it was read."
            }
        }
    }

    private let db = GRDBDatabaseManager.shared

    func list(
        recordingExternalId: String,
        status: RecordingComment.Status? = nil,
        authorizeRecording: ((Database, Int64) throws -> Bool)? = nil
    ) throws -> [RecordingComment] {
        try db.read { db in
            guard let recordingId = try Self.recordingId(db, externalId: recordingExternalId) else {
                throw RepositoryError.recordingNotFound
            }
            guard try authorizeRecording?(db, recordingId) ?? true else {
                throw RepositoryError.recordingNotFound
            }
            var sql = "SELECT * FROM recording_comments WHERE recording_id = ?"
            var arguments: [DatabaseValueConvertible?] = [recordingId]
            if let status {
                sql += " AND status = ?"
                arguments.append(status.rawValue)
            }
            sql += " ORDER BY created_at"
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                .compactMap(Self.comment)
        }
    }

    func create(
        recordingExternalId: String,
        body: String,
        anchorStart: TimeInterval? = nil,
        anchorEnd: TimeInterval? = nil,
        sourceUtteranceId: Int64? = nil,
        createdBy: String,
        idempotencyKey: String? = nil,
        authorize: (() -> Bool)? = nil,
        authorizeRecording: ((Database, Int64) throws -> Bool)? = nil
    ) throws -> RecordingComment {
        try Self.validate(body: body, anchorStart: anchorStart, anchorEnd: anchorEnd)
        return try db.write { db in
            guard authorize?() ?? true else { throw RepositoryError.authorizationRevoked }
            guard let recordingRow = try Row.fetchOne(
                db,
                sql: "SELECT id, duration FROM recordings WHERE external_id = ?",
                arguments: [recordingExternalId]
            ) else {
                throw RepositoryError.recordingNotFound
            }
            let recordingId: Int64 = recordingRow["id"]
            let duration: Double? = recordingRow["duration"]
            guard try authorizeRecording?(db, recordingId) ?? true else {
                throw RepositoryError.recordingNotFound
            }
            if let duration,
               (anchorStart.map { $0 > duration + 0.5 } ?? false
                || anchorEnd.map { $0 > duration + 0.5 } ?? false) {
                throw RepositoryError.invalidAnchor
            }
            if let sourceUtteranceId {
                let sourceRecordingId = try Int64.fetchOne(
                    db,
                    sql: "SELECT recording_id FROM utterances WHERE id = ? AND is_hidden = 0",
                    arguments: [sourceUtteranceId]
                )
                guard sourceRecordingId == recordingId else {
                    throw RepositoryError.invalidAnchor
                }
            }
            if let idempotencyKey,
               let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM recording_comments
                        WHERE created_by = ? AND idempotency_key = ?
                    """,
                    arguments: [createdBy, idempotencyKey]
               ),
               let existing = Self.comment(row) {
                let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
                guard existing.recordingId == recordingId,
                      existing.body == normalizedBody,
                      existing.anchorStart == anchorStart,
                      existing.anchorEnd == anchorEnd,
                      existing.sourceUtteranceId == sourceUtteranceId else {
                    throw RepositoryError.idempotencyConflict
                }
                return existing
            }

            let now = Date()
            let comment = RecordingComment(
                id: "cmt_\(UUID().uuidString.lowercased())",
                recordingId: recordingId,
                body: body.trimmingCharacters(in: .whitespacesAndNewlines),
                anchorStart: anchorStart,
                anchorEnd: anchorEnd,
                sourceUtteranceId: sourceUtteranceId,
                status: .open,
                createdBy: createdBy,
                idempotencyKey: idempotencyKey,
                createdAt: now,
                updatedAt: now,
                resolvedAt: nil
            )
            try db.execute(
                sql: """
                    INSERT INTO recording_comments (
                        id, recording_id, body, anchor_start, anchor_end,
                        source_utterance_id, status, created_by, idempotency_key,
                        created_at, updated_at, resolved_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    comment.id, comment.recordingId, comment.body,
                    comment.anchorStart, comment.anchorEnd, comment.sourceUtteranceId,
                    comment.status.rawValue, comment.createdBy, comment.idempotencyKey,
                    comment.createdAt, comment.updatedAt, comment.resolvedAt
                ]
            )
            try Self.touchRecording(db, id: recordingId, at: now)
            return comment
        }
    }

    func update(
        id: String,
        body: String?,
        anchorStart: FieldPatch<TimeInterval?>,
        anchorEnd: FieldPatch<TimeInterval?>,
        ifUpdatedAt: Date? = nil,
        authorize: (() -> Bool)? = nil,
        authorizeRecording: ((Database, Int64) throws -> Bool)? = nil
    ) throws -> RecordingComment {
        try db.write { db in
            guard authorize?() ?? true else { throw RepositoryError.authorizationRevoked }
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM recording_comments WHERE id = ?",
                arguments: [id]
            ), var comment = Self.comment(row) else {
                throw RepositoryError.commentNotFound
            }
            guard try authorizeRecording?(db, comment.recordingId) ?? true else {
                throw RepositoryError.commentNotFound
            }
            if let ifUpdatedAt,
               abs(comment.updatedAt.timeIntervalSince(ifUpdatedAt)) > 0.002 {
                throw RepositoryError.conflict(currentUpdatedAt: comment.updatedAt)
            }
            if let body { comment.body = body.trimmingCharacters(in: .whitespacesAndNewlines) }
            if case .set(let value) = anchorStart { comment.anchorStart = value }
            if case .set(let value) = anchorEnd { comment.anchorEnd = value }
            try Self.validate(
                body: comment.body,
                anchorStart: comment.anchorStart,
                anchorEnd: comment.anchorEnd
            )
            let duration = try Double.fetchOne(
                db,
                sql: "SELECT duration FROM recordings WHERE id = ?",
                arguments: [comment.recordingId]
            )
            if let duration,
               (comment.anchorStart.map { $0 > duration + 0.5 } ?? false
                || comment.anchorEnd.map { $0 > duration + 0.5 } ?? false) {
                throw RepositoryError.invalidAnchor
            }
            comment.updatedAt = Date()
            try db.execute(
                sql: """
                    UPDATE recording_comments
                    SET body = ?, anchor_start = ?, anchor_end = ?, updated_at = ?
                    WHERE id = ?
                """,
                arguments: [
                    comment.body, comment.anchorStart, comment.anchorEnd,
                    comment.updatedAt, comment.id
                ]
            )
            try Self.touchRecording(db, id: comment.recordingId, at: comment.updatedAt)
            return comment
        }
    }

    enum FieldPatch<Value> {
        case unchanged
        case set(Value)
    }

    func setStatus(
        id: String,
        status: RecordingComment.Status,
        ifUpdatedAt: Date? = nil,
        authorize: (() -> Bool)? = nil,
        authorizeRecording: ((Database, Int64) throws -> Bool)? = nil
    ) throws -> RecordingComment {
        try db.write { db in
            guard authorize?() ?? true else { throw RepositoryError.authorizationRevoked }
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM recording_comments WHERE id = ?",
                arguments: [id]
            ), var comment = Self.comment(row) else {
                throw RepositoryError.commentNotFound
            }
            guard try authorizeRecording?(db, comment.recordingId) ?? true else {
                throw RepositoryError.commentNotFound
            }
            if let ifUpdatedAt,
               abs(comment.updatedAt.timeIntervalSince(ifUpdatedAt)) > 0.002 {
                throw RepositoryError.conflict(currentUpdatedAt: comment.updatedAt)
            }
            if comment.status == status {
                return comment
            }
            let now = Date()
            comment.status = status
            comment.updatedAt = now
            comment.resolvedAt = status == .resolved ? now : nil
            try db.execute(
                sql: """
                    UPDATE recording_comments
                    SET status = ?, updated_at = ?, resolved_at = ?
                    WHERE id = ?
                """,
                arguments: [status.rawValue, now, comment.resolvedAt, id]
            )
            try Self.touchRecording(db, id: comment.recordingId, at: now)
            return comment
        }
    }

    private static func recordingId(_ db: Database, externalId: String) throws -> Int64? {
        try Int64.fetchOne(
            db,
            sql: "SELECT id FROM recordings WHERE external_id = ?",
            arguments: [externalId]
        )
    }

    private static func validate(
        body: String,
        anchorStart: TimeInterval?,
        anchorEnd: TimeInterval?
    ) throws {
        let count = body.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard count > 0, count <= 20_000 else { throw RepositoryError.invalidBody }
        guard anchorStart.map({ $0 >= 0 }) ?? true,
              anchorEnd.map({ $0 >= 0 }) ?? true,
              anchorEnd == nil || anchorStart != nil,
              anchorStart == nil || anchorEnd == nil || anchorStart! <= anchorEnd!
        else {
            throw RepositoryError.invalidAnchor
        }
    }

    private static func touchRecording(_ db: Database, id: Int64, at date: Date) throws {
        try db.execute(
            sql: "UPDATE recordings SET updated_at = ? WHERE id = ?",
            arguments: [date, id]
        )
    }

    private static func comment(_ row: Row) -> RecordingComment? {
        let id: String? = row["id"]
        let recordingId: Int64? = row["recording_id"]
        let body: String? = row["body"]
        let statusRaw: String? = row["status"]
        let createdBy: String? = row["created_by"]
        let createdAt: Date? = row["created_at"]
        let updatedAt: Date? = row["updated_at"]
        guard let id, let recordingId, let body, let statusRaw,
              let status = RecordingComment.Status(rawValue: statusRaw),
              let createdBy, let createdAt, let updatedAt
        else { return nil }
        return RecordingComment(
            id: id,
            recordingId: recordingId,
            body: body,
            anchorStart: row["anchor_start"],
            anchorEnd: row["anchor_end"],
            sourceUtteranceId: row["source_utterance_id"],
            status: status,
            createdBy: createdBy,
            idempotencyKey: row["idempotency_key"],
            createdAt: createdAt,
            updatedAt: updatedAt,
            resolvedAt: row["resolved_at"]
        )
    }
}
