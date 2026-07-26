import SwiftUI

struct FilteredRecordingListView: View {
    let recordings: [Recording]
    let onSelect: (Recording) -> Void

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Count header
            Text("\(recordings.count) recording\(recordings.count == 1 ? "" : "s")")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)

            if recordings.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 4) {
                    ForEach(recordings, id: \.id) { recording in
                        FilteredRecordingRow(
                            recording: recording,
                            onTap: { onSelect(recording) }
                        )
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundColor(.secondary.opacity(0.4))

            Text("No matching recordings")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("Try adjusting your filters")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Filtered Recording Row

private struct FilteredRecordingRow: View {
    let recording: Recording
    let onTap: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) var colorScheme

    private var transcriptPreview: String {
        guard let transcript = recording.fullTranscript,
              !transcript.isEmpty else {
            return "No transcript"
        }
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 120 {
            return String(cleaned.prefix(117)) + "..."
        }
        return cleaned
    }

    private var relativeDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: recording.createdAt, relativeTo: Date())
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // Source icon
                Image(systemName: recording.source.icon)
                    .font(.body)
                    .foregroundStyle(sourceColor)
                    .frame(width: 28, height: 28)
                    .background(sourceColor.opacity(0.1))
                    .cornerRadius(6)

                // Title + preview
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(recording.title)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        Spacer()

                        Text(recording.formattedDuration)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text(relativeDate)
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.7))
                    }

                    Text(transcriptPreview)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovering ? Color.primary.opacity(0.05) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var sourceColor: Color { recording.source.color }
}
