import Foundation

/// Represents a user-created tag for organizing recordings
struct Tag: Codable, Identifiable, Hashable {
    let id: Int64?
    let name: String
    let color: String?  // Hex color e.g. "#FF6B6B"
    let description: String?  // One-line meaning; used by the insights LLM for reuse + shown/edited in the UI
    let createdAt: Date
    let externalId: String?
    let updatedAt: Date?

    /// Initialize from database row
    init?(row: [String: Any?]) {
        guard let id = row["id"] as? Int64,
              let name = row["name"] as? String,
              let createdAt = row["created_at"] as? Date else {
            return nil
        }

        self.id = id
        self.name = name
        self.color = row["color"] as? String
        self.description = row["description"] as? String
        self.createdAt = createdAt
        self.externalId = row["external_id"] as? String
        self.updatedAt = row["updated_at"] as? Date
    }

    /// Initialize directly
    init(
        id: Int64? = nil,
        name: String,
        color: String? = nil,
        description: String? = nil,
        createdAt: Date = Date(),
        externalId: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.description = description
        self.createdAt = createdAt
        self.externalId = externalId
        self.updatedAt = updatedAt
    }
}
