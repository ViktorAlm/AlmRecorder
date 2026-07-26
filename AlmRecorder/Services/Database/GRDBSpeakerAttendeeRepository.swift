import Foundation
import GRDB

/// Resolution result for matching attendees to speakers in a meeting context
struct MeetingResolution {
    let matched: [(attendeeName: String, speakerUuid: String)]
    let unmatchedAttendees: [String]
    let unmatchedSpeakers: [String]
}

/// Repository for managing speaker-to-attendee mappings
class GRDBSpeakerAttendeeRepository {
    private let logger = VoxtralLogger.shared
    private let db = GRDBDatabaseManager.shared

    // MARK: - Upsert / Remove

    /// Upsert a mapping (insert or update by speaker_uuid + attendee_name)
    func setMapping(
        speakerUuid: String,
        attendeeName: String,
        attendeeEmail: String? = nil,
        source: SpeakerAttendeeMapping.MappingSource = .manual
    ) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO speaker_attendee_mappings (
                        speaker_uuid, attendee_name, attendee_email, source
                    ) VALUES (?, ?, ?, ?)
                    ON CONFLICT(speaker_uuid, attendee_name) DO UPDATE SET
                        attendee_email = excluded.attendee_email,
                        source = excluded.source
                """,
                arguments: [speakerUuid, attendeeName, attendeeEmail, source.rawValue]
            )
        }
    }

    /// Remove a specific mapping
    func removeMapping(speakerUuid: String, attendeeName: String) throws {
        try db.write { db in
            try db.execute(
                sql: "DELETE FROM speaker_attendee_mappings WHERE speaker_uuid = ? AND attendee_name = ?",
                arguments: [speakerUuid, attendeeName]
            )
        }
    }

    /// Remove all mappings for a speaker
    func removeMappingsForSpeaker(uuid: String) throws {
        try db.write { db in
            try db.execute(
                sql: "DELETE FROM speaker_attendee_mappings WHERE speaker_uuid = ?",
                arguments: [uuid]
            )
        }
    }

    // MARK: - Lookups

    /// Get the attendee name mapped to a speaker
    func getAttendeeForSpeaker(uuid: String) -> SpeakerAttendeeMapping? {
        do {
            return try db.read { db in
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM speaker_attendee_mappings WHERE speaker_uuid = ? LIMIT 1",
                    arguments: [uuid]
                )
                return row.flatMap { SpeakerAttendeeMapping(row: $0) }
            }
        } catch {
            logger.error("[GRDBSpeakerAttendeeRepository] Error fetching attendee for speaker \(uuid): \(error)")
            return nil
        }
    }

    /// Get the speaker UUID mapped to an attendee name
    func getSpeakerForAttendee(name: String) -> SpeakerAttendeeMapping? {
        do {
            return try db.read { db in
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM speaker_attendee_mappings WHERE attendee_name = ? LIMIT 1",
                    arguments: [name]
                )
                return row.flatMap { SpeakerAttendeeMapping(row: $0) }
            }
        } catch {
            logger.error("[GRDBSpeakerAttendeeRepository] Error fetching speaker for attendee \(name): \(error)")
            return nil
        }
    }

    /// Get all mappings
    func getAllMappings() throws -> [SpeakerAttendeeMapping] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM speaker_attendee_mappings ORDER BY created_at DESC"
            )
            return rows.compactMap { SpeakerAttendeeMapping(row: $0) }
        }
    }

    // MARK: - Meeting Resolution

    /// Resolve mappings for a meeting context.
    /// Given a list of attendee names and speaker UUIDs, returns:
    /// - matched: pairs where a mapping exists
    /// - unmatchedAttendees: attendee names with no speaker mapping
    /// - unmatchedSpeakers: speaker UUIDs with no attendee mapping
    func resolveForMeeting(attendeeNames: [String], speakerUuids: [String]) -> MeetingResolution {
        guard !attendeeNames.isEmpty || !speakerUuids.isEmpty else {
            return MeetingResolution(matched: [], unmatchedAttendees: [], unmatchedSpeakers: [])
        }

        let mappings: [SpeakerAttendeeMapping]
        do {
            mappings = try db.read { db in
                // Build a query that fetches mappings matching any of the given speakers or attendees
                var conditions: [String] = []
                var arguments: [DatabaseValueConvertible?] = []

                if !speakerUuids.isEmpty {
                    let placeholders = speakerUuids.map { _ in "?" }.joined(separator: ", ")
                    conditions.append("speaker_uuid IN (\(placeholders))")
                    arguments.append(contentsOf: speakerUuids)
                }

                if !attendeeNames.isEmpty {
                    let placeholders = attendeeNames.map { _ in "?" }.joined(separator: ", ")
                    conditions.append("attendee_name IN (\(placeholders))")
                    arguments.append(contentsOf: attendeeNames)
                }

                let whereClause = conditions.joined(separator: " OR ")
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM speaker_attendee_mappings WHERE \(whereClause)",
                    arguments: StatementArguments(arguments)
                )
                return rows.compactMap { SpeakerAttendeeMapping(row: $0) }
            }
        } catch {
            logger.error("[GRDBSpeakerAttendeeRepository] Error resolving meeting mappings: \(error)")
            return MeetingResolution(
                matched: [],
                unmatchedAttendees: attendeeNames,
                unmatchedSpeakers: speakerUuids
            )
        }

        // Classify in-memory
        let speakerSet = Set(speakerUuids)
        let attendeeSet = Set(attendeeNames)

        var matched: [(attendeeName: String, speakerUuid: String)] = []
        var matchedSpeakers = Set<String>()
        var matchedAttendees = Set<String>()

        for mapping in mappings {
            // Only count as matched if both sides are present in the meeting context
            if speakerSet.contains(mapping.speakerUuid) && attendeeSet.contains(mapping.attendeeName) {
                matched.append((attendeeName: mapping.attendeeName, speakerUuid: mapping.speakerUuid))
                matchedSpeakers.insert(mapping.speakerUuid)
                matchedAttendees.insert(mapping.attendeeName)
            }
        }

        let unmatchedAttendees = attendeeNames.filter { !matchedAttendees.contains($0) }
        let unmatchedSpeakers = speakerUuids.filter { !matchedSpeakers.contains($0) }

        return MeetingResolution(
            matched: matched,
            unmatchedAttendees: unmatchedAttendees,
            unmatchedSpeakers: unmatchedSpeakers
        )
    }
}

// MARK: - SpeakerAttendeeMapping GRDB Row Init

extension SpeakerAttendeeMapping {
    /// Initialize from GRDB Row using typed subscripts
    init?(row: Row) {
        let id: Int64? = row["id"]
        let speakerUuid: String? = row["speaker_uuid"]
        let attendeeName: String? = row["attendee_name"]
        let sourceRaw: String? = row["source"]
        let createdAt: Date? = row["created_at"]

        guard let id, let speakerUuid, let attendeeName, let sourceRaw, let createdAt else {
            return nil
        }

        guard let source = MappingSource(rawValue: sourceRaw) else { return nil }

        let attendeeEmail: String? = row["attendee_email"]

        self.init(
            id: id,
            speakerUuid: speakerUuid,
            attendeeName: attendeeName,
            attendeeEmail: attendeeEmail,
            source: source,
            createdAt: createdAt
        )
    }
}
