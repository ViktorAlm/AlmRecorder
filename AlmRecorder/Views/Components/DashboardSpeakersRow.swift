import SwiftUI

/// Horizontal strip of recently-heard people (named people first, then unnamed clusters).
/// Clicking a chip opens that person's profile on the People page. Renders nothing while
/// the library has no speakers.
struct DashboardSpeakersRow: View {
    let speakers: [SpeakerProfile]
    let onSelect: (String) -> Void
    var onSeeAll: (() -> Void)? = nil

    var body: some View {
        if !speakers.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("People")
                        .font(.title3)
                        .fontWeight(.semibold)

                    Spacer()

                    if let onSeeAll {
                        Button(action: onSeeAll) {
                            HStack(spacing: 4) {
                                Text("See all")
                                Image(systemName: "arrow.right")
                            }
                            .font(.subheadline)
                            .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help("Open the People page")
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(speakers, id: \.uuid) { speaker in
                            SpeakerChip(speaker: speaker, onTap: { onSelect(speaker.uuid) })
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

// MARK: - Chip

private struct SpeakerChip: View {
    let speaker: SpeakerProfile
    let onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Circle()
                    .fill(speaker.avatarColor)
                    .frame(width: 28, height: 28)
                    .overlay(
                        Text(speaker.initials)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(speaker.displayName)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: 140, alignment: .leading)
                    Text(speaker.lastSeenFormatted)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .cardSurface(cornerRadius: 10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isHovering ? speaker.avatarColor.opacity(0.4) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .help("Open \(speaker.displayName) in People")
    }
}
