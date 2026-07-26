import SwiftUI

/// One-line live status for the processing pipeline: the transcription queue plus subtle
/// indicators for the background queues (embeddings, insights, cleanup). Renders nothing
/// when everything is idle; the whole strip is a button to the Queue page.
struct PipelineStatusStrip: View {
    @ObservedObject private var queue = TranscriptionQueueManager.shared
    @ObservedObject private var embedding = EmbeddingQueueManager.shared
    @ObservedObject private var insights = RecordingInsightsQueueManager.shared
    @ObservedObject private var cleanup = TranscriptCleanupQueueManager.shared
    let onOpenQueue: () -> Void

    @State private var isHovering = false

    private var isActive: Bool {
        queue.isProcessing || queue.queueSize > 0
            || embedding.isProcessing || embedding.hasActiveJobs
            || insights.isProcessing || insights.hasActiveJobs
            || cleanup.isProcessing || cleanup.hasActiveJobs
    }

    var body: some View {
        if isActive {
            Button(action: onOpenQueue) {
                content
            }
            .buttonStyle(.plain)
            .help("Open the transcription queue")
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            if queue.isProcessing {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.mint)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(primaryText)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if queue.isProcessing {
                    HStack(spacing: 8) {
                        ProgressView(value: queue.currentJob?.detailedProgress ?? queue.globalProgress)
                            .frame(maxWidth: 280)
                        Text(progressCaption)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            if embedding.isProcessing || embedding.hasActiveJobs {
                miniIndicator(icon: "brain", color: .orange,
                              count: embedding.totalPendingUtterances,
                              help: "Generating embeddings")
            }
            if insights.isProcessing || insights.hasActiveJobs {
                miniIndicator(icon: "sparkles", color: .purple,
                              count: insights.queueSize,
                              help: "Generating insights")
            }
            if cleanup.isProcessing || cleanup.hasActiveJobs {
                miniIndicator(icon: "text.badge.checkmark", color: .teal,
                              count: cleanup.queueSize,
                              help: "Cleaning transcripts")
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .cardSurface(cornerRadius: CardRadius.card)
        .overlay(
            RoundedRectangle(cornerRadius: CardRadius.card)
                .strokeBorder(isHovering ? Color.mint.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
    }

    private var primaryText: String {
        if let job = queue.currentJob {
            return "Transcribing \(job.fileName)"
        }
        if queue.queueSize > 0 {
            return "\(queue.queueSize) transcription job\(queue.queueSize == 1 ? "" : "s") queued"
        }
        return "Finishing background work…"
    }

    private var progressCaption: String {
        let progress = queue.currentJob?.detailedProgress ?? queue.globalProgress
        var caption = "\(Int(progress * 100))%"
        if queue.queueSize > 1 {
            caption += " · \(queue.queueSize) in queue"
        }
        return caption
    }

    private func miniIndicator(icon: String, color: Color, count: Int, help: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(color)
            if count > 0 {
                Text("\(count)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
        }
        .help(help)
    }
}
