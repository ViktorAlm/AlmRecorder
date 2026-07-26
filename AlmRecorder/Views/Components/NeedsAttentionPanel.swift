import SwiftUI

/// Dashboard panel listing everything that wants user action: missing model, failed jobs,
/// untranscribed recordings, transcript-cleanup reviews, and speaker-name suggestions.
/// Renders nothing when all clear. Rows are ordered blockers-first.
struct NeedsAttentionPanel: View {
    @ObservedObject private var reviewModel = ReviewInboxModel.shared
    @ObservedObject private var queue = TranscriptionQueueManager.shared
    let untranscribedCount: Int
    let identitySuggestionCount: Int
    let isModelMissing: Bool
    let onNavigate: (NavigationItem) -> Void
    let onTranscribeUntranscribed: () -> Void

    private var isEmpty: Bool {
        reviewModel.counts.pending == 0
            && identitySuggestionCount == 0
            && untranscribedCount == 0
            && queue.failedJobs.isEmpty
            && !isModelMissing
    }

    var body: some View {
        if !isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("Needs Attention", systemImage: "bell.badge")
                    .font(.title3)
                    .fontWeight(.semibold)

                VStack(spacing: 0) {
                    let rows = items
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                        AttentionRow(item: item)
                        if index < rows.count - 1 {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .cardSurface(cornerRadius: CardRadius.card)
            }
        }
    }

    private var items: [AttentionItem] {
        var result: [AttentionItem] = []
        if isModelMissing {
            result.append(AttentionItem(
                id: "model", icon: "exclamationmark.triangle.fill", color: .cyan,
                title: "Transcription model not downloaded", count: nil,
                actionLabel: nil, action: { onNavigate(.models) }
            ))
        }
        if !queue.failedJobs.isEmpty {
            result.append(AttentionItem(
                id: "failed", icon: "xmark.circle.fill", color: .red,
                title: "Failed transcriptions", count: queue.failedJobs.count,
                actionLabel: nil, action: { onNavigate(.queue) }
            ))
        }
        if untranscribedCount > 0 {
            result.append(AttentionItem(
                id: "untranscribed", icon: "waveform.slash", color: .blue,
                title: "Recordings without transcript", count: untranscribedCount,
                actionLabel: "Transcribe", action: onTranscribeUntranscribed
            ))
        }
        if reviewModel.counts.pending > 0 {
            result.append(AttentionItem(
                id: "review", icon: "checkmark.seal.fill", color: .orange,
                title: "Transcript lines to review", count: reviewModel.counts.pending,
                actionLabel: nil, action: { onNavigate(.reviewInbox) }
            ))
        }
        if identitySuggestionCount > 0 {
            result.append(AttentionItem(
                id: "identity", icon: "person.crop.circle.badge.questionmark", color: .pink,
                title: "Speaker name suggestions", count: identitySuggestionCount,
                actionLabel: nil, action: { onNavigate(.speakers) }
            ))
        }
        return result
    }
}

// MARK: - Row

private struct AttentionItem: Identifiable {
    let id: String
    let icon: String
    let color: Color
    let title: String
    let count: Int?
    let actionLabel: String?
    let action: () -> Void
}

private struct AttentionRow: View {
    let item: AttentionItem
    @State private var isHovering = false

    var body: some View {
        Button(action: item.action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(item.color.opacity(0.15))
                        .frame(width: 30, height: 30)
                    Image(systemName: item.icon)
                        .font(.system(size: 13))
                        .foregroundColor(item.color)
                }

                Text(item.title)
                    .font(.body)
                    .foregroundColor(.primary)

                Spacer()

                if let count = item.count {
                    Text("\(count)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(item.color.opacity(0.15))
                        .foregroundColor(item.color)
                        .clipShape(Capsule())
                }

                if let actionLabel = item.actionLabel {
                    // Styled as a small button; the whole row triggers the same action.
                    Text(actionLabel)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(item.color))
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(isHovering ? Color.primary.opacity(0.04) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }
}
