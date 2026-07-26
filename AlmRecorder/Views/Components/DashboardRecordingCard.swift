import SwiftUI

struct DashboardRecordingCard: View {
    let recording: Recording
    let onTap: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) var colorScheme

    private var relativeDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: recording.createdAt, relativeTo: Date())
    }

    /// Prefer the AI summary as the card preview; fall back to the raw transcript.
    private var preview: String {
        if let summary = recording.metadata?.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return summary
        }
        guard let transcript = recording.fullTranscript, !transcript.isEmpty else {
            return "No transcript available"
        }
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Up to two AI topics/tags for the card.
    private var tags: [String] {
        if let topics = recording.metadata?.topics, !topics.isEmpty { return Array(topics.prefix(2)) }
        if let csv = recording.metadata?.customData?["tags"], !csv.isEmpty {
            let parsed: [String] = csv.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return Array(parsed.prefix(2))
        }
        return []
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                // Top row: source icon + date
                HStack {
                    Image(systemName: recording.source.icon)
                        .font(.caption)
                        .foregroundStyle(sourceColor)

                    Spacer()

                    Text(relativeDate)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // Title
                Text(recording.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(.primary)

                // Duration badge
                Text(recording.formattedDuration)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(sourceColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(sourceColor.opacity(0.15))
                    .cornerRadius(4)

                // AI summary (falls back to transcript)
                Text(preview)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .lineLimit(tags.isEmpty ? 3 : 2)
                    .multilineTextAlignment(.leading)

                // AI topic chips
                if !tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(sourceColor.opacity(0.12))
                                .foregroundColor(sourceColor)
                                .clipShape(Capsule())
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(width: 210, height: 170)
            .cardSurface(cornerRadius: 12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isHovering ? sourceColor.opacity(0.4) : Color.clear,
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isHovering
                    ? sourceColor.opacity(0.2)
                    : Color.black.opacity(colorScheme == .dark ? 0.3 : 0.08),
                radius: isHovering ? 8 : 4,
                y: isHovering ? 4 : 2
            )
            .animation(.easeInOut(duration: 0.12), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var sourceColor: Color { recording.source.color }
}
