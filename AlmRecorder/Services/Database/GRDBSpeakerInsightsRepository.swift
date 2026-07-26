import Foundation
import GRDB

/// Persists the AI "About this person" summary + topics per speaker, keyed by speaker uuid.
/// `version` lets `SpeakerInsightsService` skip regeneration when insights are already current.
final class GRDBSpeakerInsightsRepository {
    private let db = GRDBDatabaseManager.shared
    private let logger = VoxtralLogger.shared

    struct SpeakerInsights: Equatable {
        var summary: String
        var topics: [String]
        var version: String
        var updatedAt: Date
    }

    /// Stored insights for a speaker, or nil if none exist.
    func get(uuid: String) -> SpeakerInsights? {
        let result: SpeakerInsights?? = try? db.read { db -> SpeakerInsights? in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT summary, topics, version, updated_at FROM speaker_insights WHERE speaker_uuid = ?",
                arguments: [uuid]
            ) else { return nil }
            let summary: String = row["summary"] ?? ""
            let topicsJSON: String = row["topics"] ?? "[]"
            let version: String = row["version"] ?? "1"
            let updatedAt: Date = row["updated_at"] ?? Date()
            return SpeakerInsights(
                summary: summary,
                topics: Self.decodeTopics(topicsJSON),
                version: version,
                updatedAt: updatedAt
            )
        }
        return result ?? nil
    }

    /// Insert or replace the insights row for a speaker.
    func save(uuid: String, summary: String, topics: [String], version: String) {
        let topicsJSON = Self.encodeTopics(topics)
        do {
            try db.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO speaker_insights (speaker_uuid, summary, topics, version, updated_at)
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(speaker_uuid) DO UPDATE SET
                            summary = excluded.summary,
                            topics = excluded.topics,
                            version = excluded.version,
                            updated_at = excluded.updated_at
                    """,
                    arguments: [uuid, summary, topicsJSON, version, Date()]
                )
            }
        } catch {
            logger.error("[GRDBSpeakerInsightsRepository] save failed: \(error)")
        }
    }

    // MARK: - Topics JSON (pure)

    static func encodeTopics(_ topics: [String]) -> String {
        guard let data = try? JSONEncoder().encode(topics),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    static func decodeTopics(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }
}
