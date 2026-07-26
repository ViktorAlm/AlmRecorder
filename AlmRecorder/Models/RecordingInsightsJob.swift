import Foundation

/// A queued request to generate LLM insights (title/summary/tags) for one recording.
/// The transcript is NOT stored on the job — the worker re-fetches it from the recording at process
/// time, so re-transcription is always reflected and persistence stays small.
struct RecordingInsightsJob: Identifiable, Codable {
    let id = UUID()
    let recordingId: Int64
    let recordingTitle: String
    let force: Bool
    let priority: Priority
    let createdAt = Date()

    var status: JobStatus = .pending
    var startedAt: Date?
    var completedAt: Date?
    var error: String?
    var retryCount: Int = 0

    enum Priority: Int, Codable, Comparable {
        case low = 0
        case normal = 1
        case high = 2
        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum JobStatus: String, Codable {
        case pending, processing, completed, failed, cancelled, paused
        var isActive: Bool { self == .processing }
        var isComplete: Bool { self == .completed || self == .failed || self == .cancelled }
    }
}
