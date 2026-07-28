import Foundation
import GRDB

/// The single privacy boundary for recording data exposed through MCP.
///
/// A recording is available only when its own switch is enabled and none of its
/// assigned tags is configured to hide recordings from MCP. Denials always win.
enum MCPRecordingPrivacyPolicy {
    static let visibleRecordingsRelation = "mcp_visible_recordings"

    static func installView(in db: Database) throws {
        try db.execute(sql: "DROP VIEW IF EXISTS \(visibleRecordingsRelation)")
        try db.execute(sql: """
            CREATE VIEW \(visibleRecordingsRelation) AS
            SELECT r.*
            FROM recordings r
            WHERE \(visibilityPredicate(recordingAlias: "r"))
        """)
    }

    static func visibilityPredicate(recordingAlias: String) -> String {
        """
        \(recordingAlias).mcp_access_enabled = 1
        AND NOT EXISTS (
            SELECT 1
            FROM recording_tags mcp_privacy_rt
            JOIN tags mcp_privacy_t ON mcp_privacy_t.id = mcp_privacy_rt.tag_id
            WHERE mcp_privacy_rt.recording_id = \(recordingAlias).id
              AND mcp_privacy_t.mcp_hidden = 1
        )
        """
    }

    static func isRecordingVisible(_ db: Database, id: Int64) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM \(visibleRecordingsRelation) WHERE id = ?
                )
            """,
            arguments: [id]
        ) ?? false
    }

    static func visibleRecordingId(
        _ db: Database,
        externalId: String
    ) throws -> Int64? {
        try Int64.fetchOne(
            db,
            sql: """
                SELECT id
                FROM \(visibleRecordingsRelation)
                WHERE external_id = ?
            """,
            arguments: [externalId]
        )
    }

    /// Meeting notes are hidden when any active recording link points at an
    /// MCP-hidden recording. This prevents the notes from becoming an indirect
    /// route to data associated with a private recording.
    static func isMeetingVisible(
        _ db: Database,
        calendarEventId: String
    ) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1
                    FROM meetings m
                    WHERE m.calendar_event_id = ?
                      AND NOT EXISTS (
                          SELECT 1
                          FROM recording_meetings privacy_rm
                          JOIN recordings privacy_r ON privacy_r.id = privacy_rm.recording_id
                          WHERE privacy_rm.meeting_id = m.id
                            AND privacy_rm.is_dismissed = 0
                            AND NOT (
                                \(visibilityPredicate(recordingAlias: "privacy_r"))
                            )
                      )
                )
            """,
            arguments: [calendarEventId]
        ) ?? false
    }
}

struct MCPRecordingPrivacyStatus {
    let recordingAllowsAccess: Bool
    let blockingTags: [Tag]

    var isAvailableToMCP: Bool {
        recordingAllowsAccess && blockingTags.isEmpty
    }
}

extension Notification.Name {
    static let mcpRecordingPrivacyDidChange = Notification.Name(
        "com.almrecorder.mcp-recording-privacy-did-change"
    )
}

/// Privacy changes revoke the snapshot held by every active MCP invocation.
/// The socket server also observes the notification and cancels expensive work.
final class MCPPrivacyRevisionStore: @unchecked Sendable {
    static let shared = MCPPrivacyRevisionStore()

    private let lock = NSLock()
    private var revision = UUID().uuidString

    private init() {}

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return revision
    }

    func invalidate() {
        lock.lock()
        revision = UUID().uuidString
        lock.unlock()
        NotificationCenter.default.post(name: .mcpRecordingPrivacyDidChange, object: nil)
    }
}
