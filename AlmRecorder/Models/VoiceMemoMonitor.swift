import Foundation

/// Model for tracking Voice Memos monitoring
struct VoiceMemoEntry: Identifiable, Codable {
    let id: UUID
    let fileName: String
    let filePath: String
    let fileSize: Int64
    let createdDate: Date
    let processedDate: Date?
    let summary: String?
    let transcriptSnippet: String?
    let duration: TimeInterval?
    let status: ProcessingStatus
    
    enum ProcessingStatus: String, Codable {
        case pending = "pending"
        case processing = "processing"
        case completed = "completed"
        case failed = "failed"
        case skipped = "skipped" // For files already in main recordings
    }
}

/// Settings for Voice Memos monitoring
struct VoiceMemoMonitorSettings: Codable {
    var isEnabled: Bool = true
    var checkInterval: TimeInterval = 60 // Check every minute
    var maxProcessingDuration: TimeInterval = 36000 // Process up to 10 hours by default
    var enableDurationLimit: Bool = false // Duration limit disabled by default
    var autoGenerateSummary: Bool = true
    var autoProcessNew: Bool = true // Auto-process new memos when found
    var deleteAfterImport: Bool = false
    var lastCheckDate: Date?
    
    static let defaultSettings = VoiceMemoMonitorSettings()
}