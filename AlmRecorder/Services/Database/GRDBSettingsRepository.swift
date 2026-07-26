import Foundation
import GRDB

/// Repository for managing app settings in GRDB database
class GRDBSettingsRepository {
    static let shared = GRDBSettingsRepository()
    
    private let database = GRDBDatabaseManager.shared
    private let logger = VoxtralLogger.shared
    
    private init() {}
    
    // MARK: - App Settings
    
    /// Get a string setting
    func getString(forKey key: String) -> String? {
        do {
            return try database.readQueue { db in
                try AppSetting
                    .filter(AppSetting.Columns.key == key)
                    .fetchOne(db)?
                    .value
            }
        } catch {
            logger.error("[SettingsRepo] Failed to get string: \(key) - \(error)")
            return nil
        }
    }
    
    /// Set a string setting
    func setString(_ value: String?, forKey key: String) {
        do {
            try database.writeQueue { db in
                if let value = value {
                    let setting = AppSetting(key: key, value: value, type: "string", updatedAt: Date())
                    try setting.save(db)
                } else {
                    // Delete if nil
                    try AppSetting.deleteOne(db, key: key)
                }
            }
        } catch {
            logger.error("[SettingsRepo] Failed to set string: \(key) - \(error)")
        }
    }
    
    /// Get a boolean setting
    func getBool(forKey key: String) -> Bool? {
        guard let value = getString(forKey: key) else { return nil }
        return value == "true"
    }
    
    /// Set a boolean setting
    func setBool(_ value: Bool?, forKey key: String) {
        setString(value.map { $0 ? "true" : "false" }, forKey: key)
    }
    
    /// Get an integer setting
    func getInt(forKey key: String) -> Int? {
        guard let value = getString(forKey: key) else { return nil }
        return Int(value)
    }
    
    /// Set an integer setting
    func setInt(_ value: Int?, forKey key: String) {
        setString(value.map { String($0) }, forKey: key)
    }
    
    /// Get a double setting
    func getDouble(forKey key: String) -> Double? {
        guard let value = getString(forKey: key) else { return nil }
        return Double(value)
    }
    
    /// Set a double setting
    func setDouble(_ value: Double?, forKey key: String) {
        setString(value.map { String($0) }, forKey: key)
    }
    
    /// Get data setting
    func getData(forKey key: String) -> Data? {
        guard let value = getString(forKey: key) else { return nil }
        return Data(base64Encoded: value)
    }
    
    /// Set data setting
    func setData(_ value: Data?, forKey key: String) {
        setString(value?.base64EncodedString(), forKey: key)
    }
    
    /// Remove a setting
    func removeObject(forKey key: String) {
        setString(nil, forKey: key)
    }
    
    /// Get all settings
    func getAllSettings() -> [String: String] {
        do {
            return try database.readQueue { db in
                let settings = try AppSetting.fetchAll(db)
                return Dictionary(uniqueKeysWithValues: settings.map { ($0.key, $0.value) })
            }
        } catch {
            logger.error("[SettingsRepo] Failed to get all settings: \(error)")
            return [:]
        }
    }
    
    /// Clear all settings
    func clearAllSettings() {
        do {
            _ = try database.writeQueue { db in
                try AppSetting.deleteAll(db)
            }
            logger.info("[SettingsRepo] Cleared all settings")
        } catch {
            logger.error("[SettingsRepo] Failed to clear settings: \(error)")
        }
    }
    
    // MARK: - Migration from UserDefaults
    
    /// Migrate settings from UserDefaults to GRDB
    func migrateFromUserDefaults() {
        logger.info("[SettingsRepo] Starting UserDefaults migration...")
        
        let keysToMigrate = [
            // Global model settings
            "transcriptionBackend",
            "selectedWhisperModel",
            "selectedWhisperVariant",
            "selectedVoxtralTranscriptionModel",
            "selectedSummaryModel",
            "autoGenerateSummaries",
            "selectedEmbeddingModel",
            "autoGenerateEmbeddings",
            "preferVoxtral",
            "autoResumeQueue",
            
            // Voice memos settings
            "VoiceMemosMonitorSettings",
            "VoiceMemosProcessedMemos",
            "VoiceMemosProcessedFileNames",
            
            // Other app settings
            "SavedTranscriptions",
            "preferredEmbeddingModel"
        ]
        
        var migratedCount = 0
        
        for key in keysToMigrate {
            if let value = UserDefaults.standard.object(forKey: key) {
                // Determine type and convert to string
                if let stringValue = value as? String {
                    setString(stringValue, forKey: key)
                    migratedCount += 1
                } else if let boolValue = value as? Bool {
                    setBool(boolValue, forKey: key)
                    migratedCount += 1
                } else if let intValue = value as? Int {
                    setInt(intValue, forKey: key)
                    migratedCount += 1
                } else if let doubleValue = value as? Double {
                    setDouble(doubleValue, forKey: key)
                    migratedCount += 1
                } else if let dataValue = value as? Data {
                    setData(dataValue, forKey: key)
                    migratedCount += 1
                }
            }
        }
        
        logger.info("[SettingsRepo] Migrated \(migratedCount) settings from UserDefaults")
    }
    
    /// Clean up UserDefaults after migration
    func cleanupUserDefaults() {
        logger.info("[SettingsRepo] Cleaning up UserDefaults...")
        
        let keysToRemove = [
            "transcriptionBackend",
            "selectedWhisperModel",
            "selectedWhisperVariant",
            "selectedVoxtralTranscriptionModel",
            "selectedSummaryModel",
            "autoGenerateSummaries",
            "selectedEmbeddingModel",
            "autoGenerateEmbeddings",
            "preferVoxtral",
            "autoResumeQueue",
            "VoiceMemosMonitorSettings",
            "VoiceMemosProcessedMemos",
            "VoiceMemosProcessedFileNames",
            "SavedTranscriptions",
            "preferredEmbeddingModel"
        ]
        
        for key in keysToRemove {
            UserDefaults.standard.removeObject(forKey: key)
        }
        
        logger.info("[SettingsRepo] Removed \(keysToRemove.count) keys from UserDefaults")
    }
}

// MARK: - Database Models

/// App setting record
struct AppSetting: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "app_settings"
    
    let key: String
    let value: String
    let type: String
    let updatedAt: Date
    
    enum Columns {
        static let key = Column("key")
        static let value = Column("value")
        static let type = Column("type")
        static let updatedAt = Column("updated_at")
    }
    
    // Override encode to use database column names
    func encode(to container: inout PersistenceContainer) {
        container["key"] = key
        container["value"] = value
        container["type"] = type
        container["updated_at"] = updatedAt
    }
    
    // Override init from database row to use column names
    init(row: Row) {
        key = row["key"]
        value = row["value"]
        type = row["type"]
        updatedAt = row["updated_at"]
    }
    
    // Regular initializer
    init(key: String, value: String, type: String, updatedAt: Date) {
        self.key = key
        self.value = value
        self.type = type
        self.updatedAt = updatedAt
    }
}

/// Voice memo settings record
struct VoiceMemoSettings: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "voice_memo_settings"
    
    var id: Int?
    var isEnabled: Bool
    var checkInterval: Double
    var maxProcessingDuration: Double
    var enableDurationLimit: Bool
    var autoGenerateSummary: Bool
    var autoProcessNew: Bool
    var deleteAfterImport: Bool
    var lastCheckDate: Date?
    var updatedAt: Date
    
    enum Columns {
        static let id = Column("id")
        static let isEnabled = Column("is_enabled")
        static let checkInterval = Column("check_interval")
        static let maxProcessingDuration = Column("max_processing_duration")
        static let enableDurationLimit = Column("enable_duration_limit")
        static let autoGenerateSummary = Column("auto_generate_summary")
        static let autoProcessNew = Column("auto_process_new")
        static let deleteAfterImport = Column("delete_after_import")
        static let lastCheckDate = Column("last_check_date")
        static let updatedAt = Column("updated_at")
    }
    
    // Override encode to use database column names
    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["is_enabled"] = isEnabled
        container["check_interval"] = checkInterval
        container["max_processing_duration"] = maxProcessingDuration
        container["enable_duration_limit"] = enableDurationLimit
        container["auto_generate_summary"] = autoGenerateSummary
        container["auto_process_new"] = autoProcessNew
        container["delete_after_import"] = deleteAfterImport
        container["last_check_date"] = lastCheckDate
        container["updated_at"] = updatedAt
    }
    
    // Override init from database row to use column names
    init(row: Row) {
        id = row["id"]
        isEnabled = row["is_enabled"]
        checkInterval = row["check_interval"]
        maxProcessingDuration = row["max_processing_duration"]
        enableDurationLimit = row["enable_duration_limit"] ?? false
        autoGenerateSummary = row["auto_generate_summary"]
        autoProcessNew = row["auto_process_new"]
        deleteAfterImport = row["delete_after_import"]
        lastCheckDate = row["last_check_date"]
        updatedAt = row["updated_at"]
    }
    
    // Regular initializer
    init(id: Int? = nil, isEnabled: Bool, checkInterval: Double, maxProcessingDuration: Double,
         enableDurationLimit: Bool = false, autoGenerateSummary: Bool, autoProcessNew: Bool, 
         deleteAfterImport: Bool, lastCheckDate: Date? = nil, updatedAt: Date) {
        self.id = id
        self.isEnabled = isEnabled
        self.checkInterval = checkInterval
        self.maxProcessingDuration = maxProcessingDuration
        self.enableDurationLimit = enableDurationLimit
        self.autoGenerateSummary = autoGenerateSummary
        self.autoProcessNew = autoProcessNew
        self.deleteAfterImport = deleteAfterImport
        self.lastCheckDate = lastCheckDate
        self.updatedAt = updatedAt
    }
}

/// Voice memo processed file record
struct VoiceMemoProcessed: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "voice_memo_processed"
    
    var id: Int64?
    let fileName: String
    let filePath: String
    let fileSize: Int64?
    let processedDate: Date
    let status: String
    let summary: String?
    let transcriptSnippet: String?
    let duration: Double?
    
    enum Columns {
        static let id = Column("id")
        static let fileName = Column("file_name")
        static let filePath = Column("file_path")
        static let fileSize = Column("file_size")
        static let processedDate = Column("processed_date")
        static let status = Column("status")
        static let summary = Column("summary")
        static let transcriptSnippet = Column("transcript_snippet")
        static let duration = Column("duration")
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case fileName = "file_name"
        case filePath = "file_path"
        case fileSize = "file_size"
        case processedDate = "processed_date"
        case status
        case summary
        case transcriptSnippet = "transcript_snippet"
        case duration
    }
    
    // Override encode to use database column names
    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["file_name"] = fileName
        container["file_path"] = filePath
        container["file_size"] = fileSize
        container["processed_date"] = processedDate
        container["status"] = status
        container["summary"] = summary
        container["transcript_snippet"] = transcriptSnippet
        container["duration"] = duration
    }
    
    // Override init from database row to use column names
    init(row: Row) {
        id = row["id"]
        fileName = row["file_name"]
        filePath = row["file_path"]
        fileSize = row["file_size"]
        processedDate = row["processed_date"]
        status = row["status"]
        summary = row["summary"]
        transcriptSnippet = row["transcript_snippet"]
        duration = row["duration"]
    }
    
    // Regular initializer
    init(id: Int64? = nil, fileName: String, filePath: String, fileSize: Int64? = nil,
         processedDate: Date, status: String, summary: String? = nil,
         transcriptSnippet: String? = nil, duration: Double? = nil) {
        self.id = id
        self.fileName = fileName
        self.filePath = filePath
        self.fileSize = fileSize
        self.processedDate = processedDate
        self.status = status
        self.summary = summary
        self.transcriptSnippet = transcriptSnippet
        self.duration = duration
    }
}

/// Embedding queue record
struct EmbeddingQueueItem: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "embedding_queue"
    
    let id: String
    let utteranceId: Int64
    let priority: Int
    let status: String
    let retryCount: Int
    let createdAt: Date
    let startedAt: Date?
    let completedAt: Date?
    let error: String?
    
    enum Columns {
        static let id = Column("id")
        static let utteranceId = Column("utterance_id")
        static let priority = Column("priority")
        static let status = Column("status")
        static let retryCount = Column("retry_count")
        static let createdAt = Column("created_at")
        static let startedAt = Column("started_at")
        static let completedAt = Column("completed_at")
        static let error = Column("error")
    }
    
    // Override encode to use database column names
    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["utterance_id"] = utteranceId
        container["priority"] = priority
        container["status"] = status
        container["retry_count"] = retryCount
        container["created_at"] = createdAt
        container["started_at"] = startedAt
        container["completed_at"] = completedAt
        container["error"] = error
    }
    
    // Override init from database row to use column names
    init(row: Row) {
        id = row["id"]
        utteranceId = row["utterance_id"]
        priority = row["priority"]
        status = row["status"]
        retryCount = row["retry_count"]
        createdAt = row["created_at"]
        startedAt = row["started_at"]
        completedAt = row["completed_at"]
        error = row["error"]
    }
    
    // Regular initializer
    init(id: String, utteranceId: Int64, priority: Int, status: String, retryCount: Int,
         createdAt: Date, startedAt: Date? = nil, completedAt: Date? = nil, error: String? = nil) {
        self.id = id
        self.utteranceId = utteranceId
        self.priority = priority
        self.status = status
        self.retryCount = retryCount
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.error = error
    }
}