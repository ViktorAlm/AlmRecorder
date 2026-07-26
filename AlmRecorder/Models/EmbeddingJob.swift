import Foundation

/// Represents an embedding generation job in the queue
struct EmbeddingJob: Identifiable, Codable {
    let id = UUID()
    let recordingId: Int64
    let recordingTitle: String
    var utteranceData: [UtteranceEmbeddingData]
    let priority: Priority
    let createdAt = Date()
    
    var status: JobStatus = .pending
    var startedAt: Date?
    var completedAt: Date?
    var progress: Double = 0.0
    var processedCount: Int = 0
    var error: String?
    var retryCount: Int = 0
    
    /// Data for each utterance that needs embedding
    struct UtteranceEmbeddingData: Codable {
        let utteranceId: Int64
        let text: String
        var embeddingGenerated: Bool = false
        var error: String?
    }
    
    enum Priority: Int, Codable, Comparable {
        case low = 0
        case normal = 1
        case high = 2
        case urgent = 3
        
        static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }
    
    enum JobStatus: String, Codable, CaseIterable {
        case pending = "pending"
        case processing = "processing"
        case completed = "completed"
        case failed = "failed"
        case cancelled = "cancelled"
        case paused = "paused"
        
        var icon: String {
            switch self {
            case .pending: return "clock"
            case .processing: return "arrow.trianglehead.2.clockwise"
            case .completed: return "checkmark.circle.fill"
            case .failed: return "exclamationmark.triangle.fill"
            case .cancelled: return "xmark.circle"
            case .paused: return "pause.circle"
            }
        }
        
        var color: String {
            switch self {
            case .pending: return "gray"
            case .processing: return "blue"
            case .completed: return "green"
            case .failed: return "red"
            case .cancelled: return "orange"
            case .paused: return "yellow"
            }
        }
        
        var isActive: Bool {
            self == .processing
        }
        
        var isComplete: Bool {
            self == .completed || self == .failed || self == .cancelled
        }
    }
    
    // MARK: - Computed Properties
    
    var totalUtterances: Int {
        utteranceData.count
    }
    
    var completedUtterances: Int {
        utteranceData.filter { $0.embeddingGenerated }.count
    }
    
    var failedUtterances: Int {
        utteranceData.filter { $0.error != nil }.count
    }
    
    var progressPercentage: Int {
        guard totalUtterances > 0 else { return 0 }
        return Int(progress * 100)
    }
    
    var estimatedTimeRemaining: TimeInterval? {
        guard status == .processing,
              let startedAt = startedAt,
              processedCount > 0,
              processedCount < totalUtterances else {
            return nil
        }
        
        let elapsed = Date().timeIntervalSince(startedAt)
        let averageTimePerItem = elapsed / Double(processedCount)
        let remaining = totalUtterances - processedCount
        return averageTimePerItem * Double(remaining)
    }
    
    var formattedTimeRemaining: String? {
        guard let timeRemaining = estimatedTimeRemaining else { return nil }
        
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = timeRemaining > 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: timeRemaining)
    }
    
    // MARK: - Methods
    
    mutating func updateProgress() {
        processedCount = completedUtterances
        progress = Double(processedCount) / Double(max(totalUtterances, 1))
    }
    
    mutating func markUtteranceComplete(id: Int64) {
        if let index = utteranceData.firstIndex(where: { $0.utteranceId == id }) {
            utteranceData[index].embeddingGenerated = true
            utteranceData[index].error = nil
            updateProgress()
        }
    }
    
    mutating func markUtteranceFailed(id: Int64, error: String) {
        if let index = utteranceData.firstIndex(where: { $0.utteranceId == id }) {
            utteranceData[index].error = error
            updateProgress()
        }
    }
}