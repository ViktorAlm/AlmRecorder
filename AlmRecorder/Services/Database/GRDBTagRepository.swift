import Foundation
import GRDB

/// Repository for managing Tag entities and recording-tag associations
class GRDBTagRepository {
    private let logger = VoxtralLogger.shared
    private let db = GRDBDatabaseManager.shared

    // MARK: - Tag CRUD

    /// Create a new tag
    @discardableResult
    func createTag(name: String, color: String? = nil, description: String? = nil) throws -> Int64 {
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO tags (name, color, description, external_id, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [name, color, description, "tag_\(UUID().uuidString.lowercased())", Date()]
            )
            return db.lastInsertedRowID
        }
    }

    /// Get all tags ordered by name
    func getAllTags() throws -> [Tag] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM tags ORDER BY name")
            return rows.compactMap { Tag(row: $0) }
        }
    }

    /// Update a tag's name and/or color
    func updateTag(id: Int64, name: String, color: String?) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE tags SET name = ?, color = ?, updated_at = ? WHERE id = ?",
                arguments: [name, color, Date(), id]
            )
        }
    }

    /// Update just a tag's description.
    func updateTagDescription(id: Int64, description: String?) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE tags SET description = ?, updated_at = ? WHERE id = ?",
                arguments: [description, Date(), id]
            )
        }
    }

    /// Delete a tag (cascade removes recording_tags entries)
    func deleteTag(id: Int64) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM tags WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Recording-Tag Associations

    /// Add a tag to a recording
    func addTagToRecording(recordingId: Int64, tagId: Int64) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO recording_tags (recording_id, tag_id) VALUES (?, ?)",
                arguments: [recordingId, tagId]
            )
            try db.execute(
                sql: "UPDATE recordings SET updated_at = ? WHERE id = ?",
                arguments: [Date(), recordingId]
            )
        }
    }

    /// Remove a tag from a recording
    func removeTagFromRecording(recordingId: Int64, tagId: Int64) throws {
        try db.write { db in
            try db.execute(
                sql: "DELETE FROM recording_tags WHERE recording_id = ? AND tag_id = ?",
                arguments: [recordingId, tagId]
            )
            if db.changesCount > 0 {
                try db.execute(
                    sql: "UPDATE recordings SET updated_at = ? WHERE id = ?",
                    arguments: [Date(), recordingId]
                )
            }
        }
    }

    /// Get all tags for a specific recording
    func getTagsForRecording(recordingId: Int64) throws -> [Tag] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT t.* FROM tags t
                    JOIN recording_tags rt ON t.id = rt.tag_id
                    WHERE rt.recording_id = ?
                    ORDER BY t.name
                """,
                arguments: [recordingId]
            )
            return rows.compactMap { Tag(row: $0) }
        }
    }

    /// Get all recordings for a specific tag
    func getRecordingsForTag(tagId: Int64) throws -> [Recording] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT r.* FROM recordings r
                    JOIN recording_tags rt ON r.id = rt.recording_id
                    WHERE rt.tag_id = ?
                    ORDER BY r.created_at DESC
                """,
                arguments: [tagId]
            )
            return rows.compactMap { Recording(row: $0) }
        }
    }

    /// Get all tags with their recording counts
    func getTagsWithCounts() throws -> [(tag: Tag, count: Int)] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT t.*, COUNT(rt.recording_id) as recording_count
                    FROM tags t
                    LEFT JOIN recording_tags rt ON t.id = rt.tag_id
                    GROUP BY t.id
                    ORDER BY recording_count DESC, t.name
                """
            )
            return rows.compactMap { row in
                guard let tag = Tag(row: row) else { return nil }
                let count: Int? = row["recording_count"]
                return (tag: tag, count: count ?? 0)
            }
        }
    }
}

// MARK: - GRDB Row Init

extension Tag {
    /// Initialize from GRDB Row using typed subscripts
    init?(row: Row) {
        let id: Int64? = row["id"]
        let name: String? = row["name"]
        let createdAt: Date? = row["created_at"]
        guard let id, let name, let createdAt else { return nil }

        self.id = id
        self.name = name
        let color: String? = row["color"]
        self.color = color
        let description: String? = row["description"]
        self.description = description
        self.createdAt = createdAt
        self.externalId = row["external_id"]
        self.updatedAt = row["updated_at"]
    }
}
