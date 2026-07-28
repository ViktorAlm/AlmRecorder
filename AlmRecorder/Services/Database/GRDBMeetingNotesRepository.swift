import Foundation
import GRDB

/// Persists user-editable agenda + notes per calendar meeting. Keyed by `calendar_event_id` so the
/// notes survive the `meetings` cache being fully rewritten on every calendar sync.
final class GRDBMeetingNotesRepository {
    private let db = GRDBDatabaseManager.shared
    private let logger = VoxtralLogger.shared

    struct MeetingNotes: Equatable {
        var agenda: String
        var notes: String
        var updatedAt: Date?
        static let empty = MeetingNotes(agenda: "", notes: "", updatedAt: nil)
    }

    func get(eventId: String) -> MeetingNotes {
        (try? getThrowing(eventId: eventId)) ?? .empty
    }

    func getThrowing(eventId: String) throws -> MeetingNotes {
        try db.read { db -> MeetingNotes in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT agenda, notes, updated_at FROM meeting_notes WHERE calendar_event_id = ?",
                arguments: [eventId]
            ) else { return .empty }
            return MeetingNotes(
                agenda: row["agenda"] ?? "",
                notes: row["notes"] ?? "",
                updatedAt: row["updated_at"]
            )
        }
    }

    func save(eventId: String, agenda: String, notes: String) {
        do {
            _ = try upsert(eventId: eventId, agenda: agenda, notes: notes)
        } catch {
            logger.error("[GRDBMeetingNotesRepository] save failed: \(error)")
        }
    }

    @discardableResult
    func upsert(
        eventId: String,
        agenda: String,
        notes: String,
        ifUpdatedAt: Date? = nil,
        authorize: (() -> Bool)? = nil,
        authorizeEvent: ((Database, String) throws -> Bool)? = nil
    ) throws -> MeetingNotes {
        guard agenda.count <= 100_000, notes.count <= 500_000 else {
            throw MeetingNotesError.contentTooLarge
        }
        let updatedAt = Date()
        return try db.write { db in
            guard authorize?() ?? true else {
                throw MeetingNotesError.authorizationRevoked
            }
            guard try authorizeEvent?(db, eventId) ?? true else {
                throw MeetingNotesError.eventNotFound
            }
            let current: Date? = try Date.fetchOne(
                db,
                sql: "SELECT updated_at FROM meeting_notes WHERE calendar_event_id = ?",
                arguments: [eventId]
            )
            if let ifUpdatedAt,
               current.map({ abs($0.timeIntervalSince(ifUpdatedAt)) > 0.002 }) ?? true {
                throw MeetingNotesError.conflict(currentUpdatedAt: current)
            }
            try db.execute(
                sql: """
                    INSERT INTO meeting_notes (calendar_event_id, agenda, notes, updated_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(calendar_event_id) DO UPDATE SET
                        agenda = excluded.agenda,
                        notes = excluded.notes,
                        updated_at = excluded.updated_at
                """,
                arguments: [eventId, agenda, notes, updatedAt]
            )
            return MeetingNotes(agenda: agenda, notes: notes, updatedAt: updatedAt)
        }
    }

    enum MeetingNotesError: LocalizedError {
        case contentTooLarge
        case authorizationRevoked
        case eventNotFound
        case conflict(currentUpdatedAt: Date?)

        var errorDescription: String? {
            switch self {
            case .contentTooLarge:
                return "Meeting notes are too large."
            case .authorizationRevoked:
                return "MCP authorization was revoked."
            case .eventNotFound:
                return "Meeting not found."
            case .conflict:
                return "Meeting notes changed since they were read."
            }
        }
    }
}
