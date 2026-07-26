import SwiftUI

struct DashboardStatsRow: View {
    let totalRecordings: Int
    let formattedDuration: String
    let speakerCount: Int
    let thisWeekCount: Int
    var onSelectRecordings: (() -> Void)? = nil
    var onSelectSpeakers: (() -> Void)? = nil
    var onSelectThisWeek: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            StatCard(
                icon: "waveform",
                value: "\(totalRecordings)",
                label: "Recordings",
                color: .blue,
                action: onSelectRecordings
            )

            StatCard(
                icon: "clock.fill",
                value: formattedDuration,
                label: "Total Duration",
                color: .orange
            )

            StatCard(
                icon: "person.2.fill",
                value: "\(speakerCount)",
                label: "Speakers",
                color: .pink,
                action: onSelectSpeakers
            )

            StatCard(
                icon: "calendar.badge.clock",
                value: "\(thisWeekCount)",
                label: "This Week",
                color: .green,
                action: onSelectThisWeek
            )
        }
    }
}

// MARK: - Individual Stat Card

private struct StatCard: View {
    let icon: String
    let value: String
    let label: String
    let color: Color
    var action: (() -> Void)? = nil

    @State private var isHovering = false
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)

            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .cardSurface(cornerRadius: 12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isHovering && action != nil ? color.opacity(0.3) : Color.clear,
                    lineWidth: 1
                )
        )
        .shadow(color: color.opacity(isHovering && action != nil ? 0.15 : 0), radius: 6, y: 2)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
