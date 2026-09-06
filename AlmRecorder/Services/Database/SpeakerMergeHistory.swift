import Foundation
import GRDB

// MARK: - Speaker Merge History

struct SpeakerMergeHistory: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    let primarySpeakerUUID: String
    let mergedSpeakerUUID: String
    let mergedSpeakerName: String?
    let mergedSpeakerData: Data // Stores serialized speaker data for restoration
    let mergedAt: Date
    let mergedBy: String // Could be "manual" or "automatic"

    static let databaseTableName = "speaker_merge_history"

    // Column mapping for snake_case database columns. Without this, GRDB maps the camelCase property names
    // verbatim (`primarySpeakerUUID`, …), none of which exist in the table, so every insert/fetch throws —
    // which silently broke *all* speaker merges (the call sites used `try?`). Mirror the `Speaker` record.
    enum CodingKeys: String, CodingKey {
        case id
        case primarySpeakerUUID = "primary_speaker_uuid"
        case mergedSpeakerUUID = "merged_speaker_uuid"
        case mergedSpeakerName = "merged_speaker_name"
        case mergedSpeakerData = "merged_speaker_data"
        case mergedAt = "merged_at"
        case mergedBy = "merged_by"
    }
}

// MARK: - Database Migration

extension GRDBDatabaseManager {
    
    func createSpeakerMergeHistoryTable(_ db: Database) throws {
        try db.create(table: "speaker_merge_history", ifNotExists: true) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("primary_speaker_uuid", .text).notNull()
            t.column("merged_speaker_uuid", .text).notNull()
            t.column("merged_speaker_name", .text)
            t.column("merged_speaker_data", .blob).notNull()
            t.column("merged_at", .datetime).notNull()
            t.column("merged_by", .text).notNull()
            
            // Indexes for quick lookups
            t.column("primary_speaker_uuid", .text).indexed()
            t.column("merged_at", .datetime).indexed()
        }
    }
}

// MARK: - Serializable Speaker Data

struct SerializedSpeakerData: Codable {
    let uuid: String
    let name: String?
    let notes: String?
    let embedding: [Float]
    let embeddingCount: Int
    let totalDuration: TimeInterval
    let utteranceCount: Int
    let createdAt: Date
    let lastSeenAt: Date
    let confidence: Float
    
    // Store utterance UUIDs that belonged to this speaker
    let originalUtteranceIds: [Int64]
}

// MARK: - Merge History Repository

class SpeakerMergeHistoryRepository {
    private let db: GRDBDatabaseManager
    
    init(database: GRDBDatabaseManager = .shared) {
        self.db = database
    }
    
    /// Record a speaker merge operation
    func recordMerge(
        primaryUUID: String,
        mergedSpeaker: SpeakerProfile,
        utteranceIds: [Int64],
        mergedBy: String = "manual"
    ) throws {
        // Serialize the merged speaker data
        let serializedData = SerializedSpeakerData(
            uuid: mergedSpeaker.uuid,
            name: mergedSpeaker.name,
            notes: mergedSpeaker.notes,
            embedding: mergedSpeaker.averageEmbedding,
            embeddingCount: 1, // We'll need to track this properly
            totalDuration: mergedSpeaker.totalDuration,
            utteranceCount: mergedSpeaker.utteranceCount,
            createdAt: mergedSpeaker.firstSeen,
            lastSeenAt: mergedSpeaker.lastSeen,
            confidence: mergedSpeaker.confidence,
            originalUtteranceIds: utteranceIds
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(serializedData)
        
        let history = SpeakerMergeHistory(
            id: nil,
            primarySpeakerUUID: primaryUUID,
            mergedSpeakerUUID: mergedSpeaker.uuid,
            mergedSpeakerName: mergedSpeaker.name,
            mergedSpeakerData: data,
            mergedAt: Date(),
            mergedBy: mergedBy
        )
        
        try db.write { database in
            try history.insert(database)
        }
    }
    
    /// Get merge history for a speaker
    func getMergeHistory(for speakerUUID: String) throws -> [SpeakerMergeHistory] {
        return try db.read { database in
            try SpeakerMergeHistory
                .filter(Column("primary_speaker_uuid") == speakerUUID)
                .order(Column("merged_at").desc)
                .fetchAll(database)
        }
    }
    
    /// Get all speakers that were merged into a primary speaker
    func getMergedSpeakers(for primaryUUID: String) throws -> [(history: SpeakerMergeHistory, data: SerializedSpeakerData)] {
        let histories = try getMergeHistory(for: primaryUUID)
        
        let decoder = JSONDecoder()
        var results: [(SpeakerMergeHistory, SerializedSpeakerData)] = []
        
        for history in histories {
            if let data = try? decoder.decode(SerializedSpeakerData.self, from: history.mergedSpeakerData) {
                results.append((history, data))
            }
        }
        
        return results
    }
    
    /// Check if a speaker can be unmerged
    func canUnmerge(speakerUUID: String) throws -> Bool {
        return try db.read { database in
            try SpeakerMergeHistory
                .filter(Column("primary_speaker_uuid") == speakerUUID)
                .fetchCount(database) > 0
        }
    }
    
    /// Get the most recent merge for undoing
    func getLastMerge(for primaryUUID: String) throws -> SpeakerMergeHistory? {
        return try db.read { database in
            try SpeakerMergeHistory
                .filter(Column("primary_speaker_uuid") == primaryUUID)
                .order(Column("merged_at").desc)
                .fetchOne(database)
        }
    }
    
    /// Delete merge history records (after successful unmerge)
    func deleteMergeHistory(historyId: Int64) throws {
        _ = try db.write { database in
            try SpeakerMergeHistory.deleteOne(database, key: historyId)
        }
    }
}
