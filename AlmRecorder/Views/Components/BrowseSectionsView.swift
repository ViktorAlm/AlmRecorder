import SwiftUI

struct BrowseSectionsView: View {
    let dateGroups: [(period: String, count: Int)]
    let speakers: [(speakerUuid: String, speakerName: String?, recordingCount: Int)]
    let tags: [(tag: Tag, count: Int)]
    let sourceCounts: [String: Int]
    let onSelectDate: (DatePeriod) -> Void
    let onSelectSpeaker: (String, String?) -> Void
    let onSelectTag: (Int64) -> Void
    let onSelectSource: (Recording.RecordingSource) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Browse")
                .font(.title3)
                .fontWeight(.semibold)

            LazyVGrid(columns: columns, spacing: 16) {
                dateSection
                speakerSection
                tagSection
                sourceSection
            }
        }
    }

    // MARK: - By Date

    private var dateSection: some View {
        let activePeriods = allDatePeriods.filter { countForPeriod($0) > 0 }
        return BrowseSectionContainer(title: "By Date", icon: "calendar") {
            if activePeriods.isEmpty {
                emptyPlaceholder("No recordings")
            } else {
                VStack(spacing: 4) {
                    ForEach(activePeriods, id: \.self) { period in
                        let count = countForPeriod(period)
                        Button(action: { onSelectDate(period) }) {
                            HStack {
                                Text(period.displayName)
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                Spacer()
                                Text("\(count)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.12))
                                    .cornerRadius(4)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.03))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - By Speaker

    private var speakerSection: some View {
        BrowseSectionContainer(title: "By Speaker", icon: "person.2") {
            if speakers.isEmpty {
                emptyPlaceholder("No speakers identified")
            } else {
                VStack(spacing: 4) {
                    ForEach(speakers.prefix(8), id: \.speakerUuid) { speaker in
                        Button(action: { onSelectSpeaker(speaker.speakerUuid, speaker.speakerName) }) {
                            HStack(spacing: 8) {
                                // Avatar circle with initial
                                speakerAvatar(name: speaker.speakerName, uuid: speaker.speakerUuid)

                                Text(speaker.speakerName ?? "Speaker \(speaker.speakerUuid.prefix(8))")
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)

                                Spacer()

                                Text("\(speaker.recordingCount)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.12))
                                    .cornerRadius(4)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.03))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }

                    if speakers.count > 8 {
                        Text("\(speakers.count - 8) more...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }
                }
            }
        }
    }

    // MARK: - By Tag

    private var tagSection: some View {
        BrowseSectionContainer(title: "By Tag", icon: "tag") {
            if tags.isEmpty {
                emptyPlaceholder("No tags created")
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.tag.id) { item in
                        Button(action: {
                            if let tagId = item.tag.id {
                                onSelectTag(tagId)
                            }
                        }) {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(tagColor(item.tag))
                                    .frame(width: 8, height: 8)

                                Text(item.tag.name)
                                    .font(.caption)
                                    .foregroundColor(.primary)

                                Text("\(item.count)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(tagColor(item.tag).opacity(0.1))
                            .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                    }

                    // Placeholder add button
                    Button(action: {
                        // Placeholder for adding tags
                    }) {
                        Image(systemName: "plus")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - By Source

    private var sourceSection: some View {
        let activeSources = Recording.RecordingSource.allCases.filter { (sourceCounts[$0.rawValue] ?? 0) > 0 }
        return BrowseSectionContainer(title: "By Source", icon: "tray.full") {
            if activeSources.isEmpty {
                emptyPlaceholder("No sources")
            } else {
                VStack(spacing: 4) {
                    ForEach(activeSources, id: \.self) { source in
                        let count = sourceCounts[source.rawValue] ?? 0
                        Button(action: { onSelectSource(source) }) {
                            HStack(spacing: 8) {
                                Image(systemName: source.icon)
                                    .font(.caption)
                                    .foregroundStyle(sourceColor(source))
                                    .frame(width: 20)

                                Text(source.displayName)
                                    .font(.subheadline)
                                    .foregroundColor(.primary)

                                Spacer()

                                Text("\(count)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.12))
                                    .cornerRadius(4)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.03))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var allDatePeriods: [DatePeriod] {
        [.today, .yesterday, .thisWeek, .thisMonth, .older]
    }

    private func countForPeriod(_ period: DatePeriod) -> Int {
        dateGroups.first(where: { $0.period == period.displayName })?.count ?? 0
    }

    private func speakerAvatar(name: String?, uuid: String) -> some View {
        let initial = (name?.first.map(String.init) ?? "?").uppercased()
        let color = Color.speakerColor(for: uuid)

        return ZStack {
            Circle()
                .fill(color)
                .frame(width: 24, height: 24)

            Text(initial)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(.white)
        }
    }

    private func tagColor(_ tag: Tag) -> Color {
        if let hex = tag.color {
            return Color(hex: hex)
        }
        // Deterministic fallback from the tag name (stable across launches)
        return Color.speakerColor(for: tag.name)
    }

    private func sourceColor(_ source: Recording.RecordingSource) -> Color { source.color }

    private func emptyPlaceholder(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
    }
}

// MARK: - Browse Section Container

private struct BrowseSectionContainer<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
            }

            // Scrollable content
            ScrollView(.vertical, showsIndicators: false) {
                content
            }
            .frame(maxHeight: 220)
        }
        .padding(14)
        .cardSurface(cornerRadius: 12)
    }
}

// MARK: - Flow Layout for Tags

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(in: proposal.width ?? 0, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(in width: CGFloat, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > width, currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxWidth = max(maxWidth, currentX - spacing)
        }

        return (
            size: CGSize(width: maxWidth, height: currentY + lineHeight),
            positions: positions
        )
    }
}

// (Color(hex:) now lives in Views/Support/ColorPalette.swift)
