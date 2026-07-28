import XCTest
import GRDB
@testable import AlmRecorder

final class MCPRecordingPrivacyPolicyTests: XCTestCase {
    func testExplicitDenialAndBlockingTagsBothRemoveRecordingFromMCPView() throws {
        let queue = try makeQueue()

        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO recordings(id, mcp_access_enabled)
                    VALUES (1, 1), (2, 0), (3, 1), (4, 0)
                """
            )
            try db.execute(
                sql: """
                    INSERT INTO tags(id, mcp_hidden)
                    VALUES (1, 1), (2, 0)
                """
            )
            try db.execute(
                sql: """
                    INSERT INTO recording_tags(recording_id, tag_id)
                    VALUES (3, 1), (4, 2)
                """
            )
        }

        XCTAssertEqual(try visibleIds(queue), [1])
        XCTAssertTrue(try queue.read {
            try MCPRecordingPrivacyPolicy.isRecordingVisible($0, id: 1)
        })
        XCTAssertFalse(try queue.read {
            try MCPRecordingPrivacyPolicy.isRecordingVisible($0, id: 2)
        })
        XCTAssertFalse(try queue.read {
            try MCPRecordingPrivacyPolicy.isRecordingVisible($0, id: 3)
        })

        try queue.write { db in
            try db.execute(
                sql: "DELETE FROM recording_tags WHERE recording_id = 3 AND tag_id = 1"
            )
        }
        XCTAssertEqual(try visibleIds(queue), [1, 3])
    }

    func testAnyHiddenLinkedRecordingHidesMeetingNotes() throws {
        let queue = try makeQueue()
        let eventId = UUID().uuidString

        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO recordings(id, mcp_access_enabled)
                    VALUES (1, 1), (2, 0)
                """
            )
            try db.execute(
                sql: "INSERT INTO meetings(id, calendar_event_id) VALUES (1, ?)",
                arguments: [eventId]
            )
            try db.execute(
                sql: """
                    INSERT INTO recording_meetings(
                        recording_id, meeting_id, is_dismissed
                    ) VALUES (1, 1, 0)
                """
            )
        }

        XCTAssertTrue(try queue.read {
            try MCPRecordingPrivacyPolicy.isMeetingVisible(
                $0,
                calendarEventId: eventId
            )
        })

        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO recording_meetings(
                        recording_id, meeting_id, is_dismissed
                    ) VALUES (2, 1, 0)
                """
            )
        }
        XCTAssertFalse(try queue.read {
            try MCPRecordingPrivacyPolicy.isMeetingVisible(
                $0,
                calendarEventId: eventId
            )
        })

        try queue.write { db in
            try db.execute(
                sql: """
                    UPDATE recording_meetings
                    SET is_dismissed = 1
                    WHERE recording_id = 2
                """
            )
        }
        XCTAssertTrue(try queue.read {
            try MCPRecordingPrivacyPolicy.isMeetingVisible(
                $0,
                calendarEventId: eventId
            )
        })
    }

    private func makeQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE recordings (
                    id INTEGER PRIMARY KEY,
                    mcp_access_enabled INTEGER NOT NULL DEFAULT 1
                );
                CREATE TABLE tags (
                    id INTEGER PRIMARY KEY,
                    mcp_hidden INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE recording_tags (
                    recording_id INTEGER NOT NULL,
                    tag_id INTEGER NOT NULL,
                    PRIMARY KEY(recording_id, tag_id)
                );
                CREATE TABLE meetings (
                    id INTEGER PRIMARY KEY,
                    calendar_event_id TEXT NOT NULL UNIQUE
                );
                CREATE TABLE recording_meetings (
                    recording_id INTEGER NOT NULL,
                    meeting_id INTEGER NOT NULL,
                    is_dismissed INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY(recording_id, meeting_id)
                );
            """)
            try MCPRecordingPrivacyPolicy.installView(in: db)
        }
        return queue
    }

    private func visibleIds(_ queue: DatabaseQueue) throws -> [Int64] {
        try queue.read { db in
            try Int64.fetchAll(
                db,
                sql: """
                    SELECT id
                    FROM \(MCPRecordingPrivacyPolicy.visibleRecordingsRelation)
                    ORDER BY id
                """
            )
        }
    }
}
