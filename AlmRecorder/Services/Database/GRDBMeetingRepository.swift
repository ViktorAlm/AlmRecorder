import Foundation
import GRDB

/// A meeting matched to a recording with a tiered confidence level
struct TieredMeetingMatch {
    let meeting: Meeting
    let confidence: RecordingMeeting.MatchConfidence
}

/// Repository for managing Meeting entities and recording-meeting associations
class GRDBMeetingRepository {
    private let logger = VoxtralLogger.shared
    private let db = GRDBDatabaseManager.shared

    // MARK: - Meeting CRUD

    /// Upsert a meeting (insert or update by calendar_event_id)
    @discardableResult
    func upsert(_ meeting: Meeting) throws -> Int64 {
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meetings (
                        calendar_event_id, title, start_date, end_date,
                        calendar_name, calendar_color, location, notes,
                        attendees, is_recurring, last_synced_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(calendar_event_id) DO UPDATE SET
                        title = excluded.title,
                        start_date = excluded.start_date,
                        end_date = excluded.end_date,
                        calendar_name = excluded.calendar_name,
                        calendar_color = excluded.calendar_color,
                        location = excluded.location,
                        notes = excluded.notes,
                        attendees = excluded.attendees,
                        is_recurring = excluded.is_recurring,
                        last_synced_at = excluded.last_synced_at
                """,
                arguments: [
                    meeting.calendarEventId,
                    meeting.title,
                    meeting.startDate,
                    meeting.endDate,
                    meeting.calendarName,
                    meeting.calendarColor,
                    meeting.location,
                    meeting.notes,
                    meeting.attendees,
                    meeting.isRecurring,
                    meeting.lastSyncedAt
                ]
            )
            return db.lastInsertedRowID
        }
    }

    /// Get all meetings ordered by start date descending
    func getAll(limit: Int = 200) throws -> [Meeting] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM meetings ORDER BY start_date DESC LIMIT ?",
                arguments: [limit]
            )
            return rows.compactMap { Meeting(row: $0) }
        }
    }

    /// Get meetings within a date range
    func getMeetings(from startDate: Date, to endDate: Date) throws -> [Meeting] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM meetings
                    WHERE start_date >= ? AND start_date <= ?
                    ORDER BY start_date DESC
                """,
                arguments: [startDate, endDate]
            )
            return rows.compactMap { Meeting(row: $0) }
        }
    }

    /// Meetings starting within a window (ascending) — used by MeetingMonitor to find meetings about
    /// to begin.
    func getUpcomingMeetings(startingBetween start: Date, and end: Date) throws -> [Meeting] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM meetings WHERE start_date >= ? AND start_date <= ? ORDER BY start_date ASC",
                arguments: [start, end]
            )
            return rows.compactMap { Meeting(row: $0) }
        }
    }

    /// Get a meeting by its calendar event ID
    func getByCalendarEventId(_ eventId: String) throws -> Meeting? {
        try db.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM meetings WHERE calendar_event_id = ?",
                arguments: [eventId]
            )
            return row.flatMap { Meeting(row: $0) }
        }
    }

    /// Get a meeting by database ID
    func getById(_ id: Int64) throws -> Meeting? {
        try db.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM meetings WHERE id = ?",
                arguments: [id]
            )
            return row.flatMap { Meeting(row: $0) }
        }
    }

    /// Delete meetings whose calendar_event_id is NOT in the given set (stale cleanup)
    func deleteStaleEvents(keepingEventIds eventIds: Set<String>) throws {
        guard !eventIds.isEmpty else { return }
        try db.write { db in
            let placeholders = eventIds.map { _ in "?" }.joined(separator: ", ")
            try db.execute(
                sql: "DELETE FROM meetings WHERE calendar_event_id NOT IN (\(placeholders))",
                arguments: StatementArguments(eventIds.map { $0 })
            )
        }
    }

    /// Delete all meetings
    func deleteAll() throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM meetings")
        }
    }

    // MARK: - Recording-Meeting Links

    /// Link a recording to a meeting
    func linkRecording(
        recordingId: Int64,
        meetingId: Int64,
        linkType: RecordingMeeting.LinkType = .auto,
        matchConfidence: RecordingMeeting.MatchConfidence = .matched
    ) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO recording_meetings (recording_id, meeting_id, link_type, match_confidence)
                    VALUES (?, ?, ?, ?)
                """,
                arguments: [recordingId, meetingId, linkType.rawValue, matchConfidence.rawValue]
            )
        }
    }

    /// Unlink a recording from a meeting
    func unlinkRecording(recordingId: Int64, meetingId: Int64) throws {
        try db.write { db in
            try db.execute(
                sql: "DELETE FROM recording_meetings WHERE recording_id = ? AND meeting_id = ?",
                arguments: [recordingId, meetingId]
            )
        }
    }

    /// Get all meetings linked to a recording
    func getMeetingsForRecording(recordingId: Int64) throws -> [Meeting] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT m.* FROM meetings m
                    JOIN recording_meetings rm ON m.id = rm.meeting_id
                    WHERE rm.recording_id = ?
                    ORDER BY m.start_date DESC
                """,
                arguments: [recordingId]
            )
            return rows.compactMap { Meeting(row: $0) }
        }
    }

    /// Get all recordings linked to a meeting
    func getRecordingsForMeeting(meetingId: Int64) throws -> [Recording] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT r.* FROM recordings r
                    JOIN recording_meetings rm ON r.id = rm.recording_id
                    WHERE rm.meeting_id = ?
                    ORDER BY r.created_at DESC
                """,
                arguments: [meetingId]
            )
            return rows.compactMap { Recording(row: $0) }
        }
    }

    /// Get meetings with their linked recording counts
    func getMeetingsWithRecordingCounts(from startDate: Date, to endDate: Date) throws -> [(meeting: Meeting, recordingCount: Int)] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT m.*, COUNT(rm.recording_id) as recording_count
                    FROM meetings m
                    LEFT JOIN recording_meetings rm ON m.id = rm.meeting_id AND rm.is_dismissed = 0
                    WHERE m.start_date >= ? AND m.start_date <= ?
                    GROUP BY m.id
                    ORDER BY m.start_date DESC
                """,
                arguments: [startDate, endDate]
            )
            return rows.compactMap { row -> (meeting: Meeting, recordingCount: Int)? in
                guard let meeting = Meeting(row: row) else { return nil }
                let count: Int? = row["recording_count"]
                return (meeting: meeting, recordingCount: count ?? 0)
            }
        }
    }

    /// Find meetings overlapping with a recording's time window (for auto-matching)
    /// Uses a 5-minute buffer on both sides
    func findOverlappingMeetings(recordingCreatedAt: Date, recordingDuration: TimeInterval?) throws -> [Meeting] {
        let buffer: TimeInterval = 5 * 60 // 5 minutes
        let recordingStart = recordingCreatedAt
        let recordingEnd = recordingCreatedAt.addingTimeInterval(recordingDuration ?? 0)

        return try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM meetings
                    WHERE start_date <= ? AND end_date >= ?
                    ORDER BY start_date ASC
                """,
                arguments: [
                    recordingEnd.addingTimeInterval(buffer),
                    recordingStart.addingTimeInterval(-buffer)
                ]
            )
            return rows.compactMap { Meeting(row: $0) }
        }
    }

    /// Auto-link a recording to all overlapping meetings
    func autoLinkRecording(_ recording: Recording) throws {
        guard let recordingId = recording.id else { return }
        let tiered = findTieredMeetings(
            recordingCreatedAt: recording.createdAt,
            recordingDuration: recording.duration
        )
        for match in tiered {
            guard let meetingId = match.meeting.id else { continue }
            try linkRecording(
                recordingId: recordingId,
                meetingId: meetingId,
                linkType: .auto,
                matchConfidence: match.confidence
            )
        }
    }

    // MARK: - Tiered Meeting Matching

    /// Find meetings within a 12-hour window and classify them by overlap confidence.
    ///
    /// Classification tiers (applied in-memory after fetching the broad window):
    /// - `.matched`  — recording overlaps meeting with a 5-minute buffer
    /// - `.suggested` — recording overlaps meeting with a 45-minute buffer
    /// - `.possible`  — within the 12-hour fetch window but outside the 45-min buffer
    func findTieredMeetings(recordingCreatedAt: Date, recordingDuration: TimeInterval?) -> [TieredMeetingMatch] {
        let recordingStart = recordingCreatedAt
        let recordingEnd = recordingCreatedAt.addingTimeInterval(recordingDuration ?? 0)

        let windowBuffer: TimeInterval = 12 * 60 * 60 // 12 hours
        let matchedBuffer: TimeInterval = 5 * 60      // 5 minutes
        let suggestedBuffer: TimeInterval = 45 * 60    // 45 minutes

        // Fetch all meetings in the wide 12-hour window via SQL
        let meetings: [Meeting]
        do {
            meetings = try db.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM meetings
                        WHERE start_date <= ? AND end_date >= ?
                        ORDER BY start_date ASC
                    """,
                    arguments: [
                        recordingEnd.addingTimeInterval(windowBuffer),
                        recordingStart.addingTimeInterval(-windowBuffer)
                    ]
                )
                return rows.compactMap { Meeting(row: $0) }
            }
        } catch {
            logger.error("[GRDBMeetingRepository] Error fetching tiered meetings: \(error)")
            return []
        }

        // Classify each meeting in-memory
        return meetings.compactMap { meeting in
            let meetingStart = meeting.startDate
            let meetingEnd = meeting.endDate

            // Check 5-min buffer overlap (matched)
            let matchedOverlap =
                meetingStart <= recordingEnd.addingTimeInterval(matchedBuffer) &&
                meetingEnd >= recordingStart.addingTimeInterval(-matchedBuffer)

            if matchedOverlap {
                return TieredMeetingMatch(meeting: meeting, confidence: .matched)
            }

            // Check 45-min buffer overlap (suggested)
            let suggestedOverlap =
                meetingStart <= recordingEnd.addingTimeInterval(suggestedBuffer) &&
                meetingEnd >= recordingStart.addingTimeInterval(-suggestedBuffer)

            if suggestedOverlap {
                return TieredMeetingMatch(meeting: meeting, confidence: .suggested)
            }

            // Everything else in the 12-hour window is possible
            return TieredMeetingMatch(meeting: meeting, confidence: .possible)
        }
    }

    // MARK: - Match Management

    /// Confirm a suggested/possible match by upgrading it to matched with manual link type
    func confirmMatch(recordingId: Int64, meetingId: Int64) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE recording_meetings
                    SET match_confidence = 'matched', link_type = 'manual'
                    WHERE recording_id = ? AND meeting_id = ?
                """,
                arguments: [recordingId, meetingId]
            )
        }
    }

    /// Dismiss a match so it no longer appears in suggestions
    func dismissMatch(recordingId: Int64, meetingId: Int64) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE recording_meetings
                    SET is_dismissed = 1
                    WHERE recording_id = ? AND meeting_id = ?
                """,
                arguments: [recordingId, meetingId]
            )
        }
    }

    /// Get recordings linked to a meeting with their confidence levels, excluding dismissed links
    func getRecordingsForMeetingWithConfidence(meetingId: Int64) throws -> [(recording: Recording, confidence: RecordingMeeting.MatchConfidence)] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT r.*, rm.match_confidence
                    FROM recordings r
                    JOIN recording_meetings rm ON r.id = rm.recording_id
                    WHERE rm.meeting_id = ? AND rm.is_dismissed = 0
                    ORDER BY
                        CASE rm.match_confidence
                            WHEN 'matched' THEN 0
                            WHEN 'suggested' THEN 1
                            WHEN 'possible' THEN 2
                        END,
                        r.created_at DESC
                """,
                arguments: [meetingId]
            )
            return rows.compactMap { row -> (recording: Recording, confidence: RecordingMeeting.MatchConfidence)? in
                guard let recording = Recording(row: row) else { return nil }
                let confidenceRaw: String? = row["match_confidence"]
                let confidence = confidenceRaw.flatMap { RecordingMeeting.MatchConfidence(rawValue: $0) } ?? .matched
                return (recording: recording, confidence: confidence)
            }
        }
    }

    /// Get only meetings that have at least one non-dismissed recording link.
    /// Returns counts split by confidence tier.
    /// - `recordingCount` — number of links with `matched` confidence
    /// - `suggestionCount` — number of non-dismissed links with `suggested` or `possible` confidence
    func getMeetingsWithSuggestionCounts(from startDate: Date, to endDate: Date) throws -> [(meeting: Meeting, recordingCount: Int, suggestionCount: Int)] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT m.*,
                        COUNT(CASE WHEN rm.match_confidence = 'matched' AND rm.is_dismissed = 0 THEN 1 END) as recording_count,
                        COUNT(CASE WHEN rm.match_confidence IN ('suggested', 'possible') AND rm.is_dismissed = 0 THEN 1 END) as suggestion_count
                    FROM meetings m
                    JOIN recording_meetings rm ON m.id = rm.meeting_id
                    WHERE m.start_date >= ? AND m.start_date <= ?
                    GROUP BY m.id
                    HAVING COUNT(CASE WHEN rm.is_dismissed = 0 THEN 1 END) > 0
                    ORDER BY m.start_date DESC
                """,
                arguments: [startDate, endDate]
            )
            return rows.compactMap { row -> (meeting: Meeting, recordingCount: Int, suggestionCount: Int)? in
                guard let meeting = Meeting(row: row) else { return nil }
                let recordingCount: Int? = row["recording_count"]
                let suggestionCount: Int? = row["suggestion_count"]
                return (meeting: meeting, recordingCount: recordingCount ?? 0, suggestionCount: suggestionCount ?? 0)
            }
        }
    }
    /// Get all recordings that have at least one meeting link (any confidence, non-dismissed).
    /// Returns each recording with its linked meetings and their confidence levels.
    func getRecordingsWithMeetings() throws -> [RecordingWithMeetings] {
        try db.read { db in
            // Get all recording IDs that have at least one non-dismissed meeting link
            let recordingRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT r.*
                    FROM recordings r
                    JOIN recording_meetings rm ON r.id = rm.recording_id
                    WHERE rm.is_dismissed = 0
                    ORDER BY r.created_at DESC
                """
            )

            var results: [RecordingWithMeetings] = []
            for row in recordingRows {
                guard let recording = Recording(row: row), let recordingId = recording.id else { continue }

                let meetingRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT m.*, rm.match_confidence
                        FROM meetings m
                        JOIN recording_meetings rm ON m.id = rm.meeting_id
                        WHERE rm.recording_id = ? AND rm.is_dismissed = 0
                        ORDER BY
                            CASE rm.match_confidence
                                WHEN 'matched' THEN 0
                                WHEN 'suggested' THEN 1
                                WHEN 'possible' THEN 2
                            END,
                            m.start_date DESC
                    """,
                    arguments: [recordingId]
                )

                let meetings: [(meeting: Meeting, confidence: RecordingMeeting.MatchConfidence)] = meetingRows.compactMap { mRow in
                    guard let meeting = Meeting(row: mRow) else { return nil }
                    let raw: String? = mRow["match_confidence"]
                    let confidence = raw.flatMap { RecordingMeeting.MatchConfidence(rawValue: $0) } ?? .matched
                    return (meeting: meeting, confidence: confidence)
                }

                if !meetings.isEmpty {
                    results.append(RecordingWithMeetings(recording: recording, meetings: meetings))
                }
            }
            return results
        }
    }
}

/// A recording paired with all its linked meetings and confidence levels
struct RecordingWithMeetings {
    let recording: Recording
    let meetings: [(meeting: Meeting, confidence: RecordingMeeting.MatchConfidence)]

    var matchedMeetings: [Meeting] {
        meetings.filter { $0.confidence == .matched }.map(\.meeting)
    }

    var suggestedMeetings: [Meeting] {
        meetings.filter { $0.confidence == .suggested }.map(\.meeting)
    }

    var possibleMeetings: [Meeting] {
        meetings.filter { $0.confidence == .possible }.map(\.meeting)
    }
}

// MARK: - Meeting GRDB Row Init

extension Meeting {
    init?(row: Row) {
        let id: Int64? = row["id"]
        let calendarEventId: String? = row["calendar_event_id"]
        let title: String? = row["title"]
        let startDate: Date? = row["start_date"]
        let endDate: Date? = row["end_date"]
        let lastSyncedAt: Date? = row["last_synced_at"]

        guard let id, let calendarEventId, let title, let startDate, let endDate, let lastSyncedAt else {
            return nil
        }

        self.id = id
        self.calendarEventId = calendarEventId
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.lastSyncedAt = lastSyncedAt

        let calendarName: String? = row["calendar_name"]
        self.calendarName = calendarName
        let calendarColor: String? = row["calendar_color"]
        self.calendarColor = calendarColor
        let location: String? = row["location"]
        self.location = location
        let notes: String? = row["notes"]
        self.notes = notes
        let attendees: String? = row["attendees"]
        self.attendees = attendees
        let isRecurring: Bool? = row["is_recurring"]
        self.isRecurring = isRecurring ?? false
    }
}
