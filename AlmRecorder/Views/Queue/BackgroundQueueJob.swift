import SwiftUI

/// Common status shape across the three simple background job queues (embedding, insights,
/// cleanup) so one view can render all of them instead of three near-identical copies.
enum QueueJobStatus: String {
    case pending, processing, completed, failed, cancelled, paused

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

    var color: Color {
        switch self {
        case .pending: return .secondary
        case .processing: return .blue
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .orange
        case .paused: return .yellow
        }
    }
}

/// A job from one of the simple background queues (embedding / insights / cleanup) — the
/// subset of fields `BackgroundQueueTabView` needs to render a list, independent of each
/// queue's own richer model.
protocol BackgroundQueueJob: Identifiable where ID == UUID {
    var recordingTitle: String { get }
    var displayStatus: QueueJobStatus { get }
    var error: String? { get }
    var retryCount: Int { get }
    var createdAt: Date { get }
    var startedAt: Date? { get }
    var completedAt: Date? { get }
}

extension EmbeddingJob: BackgroundQueueJob {
    var displayStatus: QueueJobStatus {
        switch status {
        case .pending: return .pending
        case .processing: return .processing
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .paused: return .paused
        }
    }
}

extension RecordingInsightsJob: BackgroundQueueJob {
    var displayStatus: QueueJobStatus {
        switch status {
        case .pending: return .pending
        case .processing: return .processing
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .paused: return .paused
        }
    }
}

extension TranscriptCleanupJob: BackgroundQueueJob {
    var displayStatus: QueueJobStatus {
        switch status {
        case .pending: return .pending
        case .processing: return .processing
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .paused: return .paused
        }
    }
}
