import Foundation

/// A queued transcript-cleanup pass for one recording (detection re-score + review routing).
/// Nothing heavy is stored on the job; the worker re-reads utterances at process time.
struct TranscriptCleanupJob: Identifiable, Codable {
    /// Stable across queue persistence so nightly manifests can keep waiting on the same cleanup
    /// checkpoint after an app relaunch.
    let id: UUID
    let recordingId: Int64
    let recordingTitle: String
    let mode: Mode
    /// Re-score lines a previous pass already settled (manual "Clean up transcript" runs).
    let force: Bool
    let priority: Priority
    let createdAt: Date

    var status: JobStatus = .pending
    var startedAt: Date?
    var completedAt: Date?
    var error: String?
    var retryCount: Int = 0
    /// Human-readable result ("2 hidden, 1 corrected, 3 for review") for the queue UI.
    var outcomeSummary: String?

    init(
        id: UUID = UUID(),
        recordingId: Int64,
        recordingTitle: String,
        mode: Mode,
        force: Bool,
        priority: Priority,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.recordingId = recordingId
        self.recordingTitle = recordingTitle
        self.mode = mode
        self.force = force
        self.priority = priority
        self.createdAt = createdAt
    }

    enum Mode: String, Codable {
        case auto       // post-transcription pipeline step
        case manual     // per-recording "Clean up transcript" action
        case backfill   // library discovery (transcript_cleaned_at IS NULL)
    }

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
