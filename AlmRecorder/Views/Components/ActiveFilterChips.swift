import SwiftUI

struct ActiveFilterChips: View {
    let chips: [(label: String, id: String)]
    let onRemove: (String) -> Void
    let onClearAll: () -> Void

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .font(.caption)
                .foregroundColor(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chips, id: \.id) { chip in
                        FilterChip(
                            label: chip.label,
                            onRemove: { onRemove(chip.id) }
                        )
                    }
                }
            }

            Divider()
                .frame(height: 16)

            Button(action: onClearAll) {
                Text("Clear All")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .onHover { isHovering in
                if isHovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .cardSurface(cornerRadius: 10)
    }
}

// MARK: - Individual Filter Chip

private struct FilterChip: View {
    let label: String
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.primary)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(isHovering ? Color.primary.opacity(0.1) : Color.primary.opacity(0.06))
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
