import Foundation
import GRDB

/// Read-only query cores that assemble the speaker-identity inference engine's pure inputs from the
/// recordings / utterances / meetings tables. Static-over-`Database` so they unit-test against an
/// in-memory queue (mirrors `EmbeddingPersistence` / the `GRDBSpeakerRepository` query cores).
enum GRDBIdentityInferenceQueries {

    /// Per-voice recording statistics for owner detection.
    static func voiceStats(_ db: Database) throws -> [VoiceStats] {
        // rec_info: per recording, how many distinct speakers it has and its source. A "solo memo" is a
        // single-speaker recording the user captured themselves (not an imported file).
        let rows = try Row.fetchAll(db, sql: """
            WITH rec_info AS (
                SELECT u.recording_id AS rid,
                       COUNT(DISTINCT u.speaker_uuid) AS n,
                       r.source AS source
                FROM utterances u
                JOIN recordings r ON r.id = u.recording_id
                WHERE u.speaker_uuid IS NOT NULL
                GROUP BY u.recording_id
            )
            SELECT s.speaker_uuid AS uuid,
                   COUNT(DISTINCT s.recording_id) AS rec_count,
                   SUM(CASE WHEN ri.n = 1 AND ri.source IN ('voiceMemos', 'recording') THEN 1 ELSE 0 END) AS solo_count
            FROM (SELECT DISTINCT recording_id, speaker_uuid FROM utterances WHERE speaker_uuid IS NOT NULL) s
            JOIN rec_info ri ON ri.rid = s.recording_id
            GROUP BY s.speaker_uuid
        """)
        return rows.compactMap { row in
            guard let uuid: String = row["uuid"] else { return nil }
            return VoiceStats(
                speakerUuid: uuid,
                recordingCount: row["rec_count"] ?? 0,
                soloMemoCount: row["solo_count"] ?? 0
            )
        }
    }

    /// One `MeetingContext` per meeting that has at least one transcribed, non-dismissed linked recording:
    /// its attendees, the distinct voices recorded in it, and its strongest link confidence.
    static func meetingContexts(_ db: Database) throws -> [MeetingContext] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.id AS id,
                   m.attendees AS attendees,
                   MAX(CASE rm.match_confidence WHEN 'matched' THEN 2 WHEN 'suggested' THEN 1 ELSE 0 END) AS conf_rank,
                   GROUP_CONCAT(DISTINCT u.speaker_uuid) AS voices
            FROM meetings m
            JOIN recording_meetings rm ON rm.meeting_id = m.id AND rm.is_dismissed = 0
            JOIN utterances u ON u.recording_id = rm.recording_id AND u.speaker_uuid IS NOT NULL
            GROUP BY m.id
            ORDER BY m.start_date DESC
        """)
        return rows.compactMap { row in
            guard let id: Int64 = row["id"] else { return nil }
            let voicesCSV: String = row["voices"] ?? ""
            let voiceUuids = voicesCSV.split(separator: ",").map(String.init).filter { !$0.isEmpty }
            guard !voiceUuids.isEmpty else { return nil }
            let rank: Int = row["conf_rank"] ?? 2
            let confidence: RecordingMeeting.MatchConfidence = rank >= 2 ? .matched : (rank == 1 ? .suggested : .possible)
            let attendees = Self.parseAttendees(row["attendees"])
            return MeetingContext(meetingId: id, confidence: confidence, attendees: attendees, voiceUuids: voiceUuids)
        }
    }

    /// Tolerant decode of the `meetings.attendees` JSON — the new `[{name,email}]` shape or legacy `["name"]`.
    /// Mirrors `Meeting.parsedParticipants` so the engine sees attendees the same way the rest of the app does.
    private static func parseAttendees(_ json: String?) -> [MeetingAttendee] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        if let list = try? JSONDecoder().decode([MeetingAttendee].self, from: data) { return list }
        if let names = try? JSONDecoder().decode([String].self, from: data) {
            return names.map { MeetingAttendee(name: $0, email: nil) }
        }
        return []
    }
}
