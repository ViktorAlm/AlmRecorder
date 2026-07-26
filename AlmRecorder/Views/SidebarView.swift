import SwiftUI

struct SidebarView: View {
    @Binding var selection: NavigationItem?
    @State private var isHovering = false
    @State private var availableSpace: Int64 = 0
    @State private var showStorageWarning = false
    // Observe the queue so the sidebar badge updates live as jobs complete (it was reading a
    // non-observed queueManager, so the count was frozen).
    @ObservedObject private var queueManager = TranscriptionQueueManager.shared
    // Transcript-cleanup lines awaiting human review (badge on the Review item) —
    // database-driven via ValueObservation, so it updates the instant any writer commits.
    @ObservedObject private var reviewModel = ReviewInboxModel.shared
    private let updateTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section {
                    ForEach(NavigationItem.sidebarItems, id: \.self) { item in
                        if item == .queue {
                            NavigationLink(value: item) {
                                HStack {
                                    Label {
                                        Text(item.rawValue)
                                            .font(.system(.body, design: .rounded))
                                    } icon: {
                                        Image(systemName: item.icon)
                                            .font(.title3)
                                            .foregroundStyle(item.color)
                                    }

                                    Spacer()

                                    if queueManager.queueSize > 0 {
                                        Text("\(queueManager.queueSize)")
                                            .font(.caption)
                                            .fontWeight(.medium)
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(queueManager.isProcessing ? Color.green : Color.blue)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                        } else if item == .reviewInbox {
                            NavigationLink(value: item) {
                                HStack {
                                    Label {
                                        Text(item.rawValue)
                                            .font(.system(.body, design: .rounded))
                                    } icon: {
                                        Image(systemName: item.icon)
                                            .font(.title3)
                                            .foregroundStyle(item.color)
                                    }

                                    Spacer()

                                    if reviewModel.counts.pending > 0 {
                                        Text("\(reviewModel.counts.pending)")
                                            .font(.caption)
                                            .fontWeight(.medium)
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.orange)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                        } else {
                            NavigationLink(value: item) {
                                Label {
                                    Text(item.rawValue)
                                        .font(.system(.body, design: .rounded))
                                } icon: {
                                    Image(systemName: item.icon)
                                        .font(.title3)
                                        .foregroundStyle(item.color)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(SidebarListStyle())
            // Make the sidebar read as translucent Liquid Glass. Two layers stack under it:
            //   1. the List's own backing — hidden here so it can't tint the glass, and
            //   2. the split view's frosted `.sidebar` column material — the real culprit the
            //      user spotted ("something behind the sidebar"). SwiftUI can't reach #2, so
            //      `clearSidebarBacking()` swaps it for a see-through material to match the
            //      clear content panes.
            .scrollContentBackground(.hidden)
            .clearSidebarBacking()

            Divider()

            // Settings gear at the bottom
            Button(action: { selection = .settings }) {
                HStack {
                    Image(systemName: "gearshape.fill")
                        .font(.body)
                        .foregroundStyle(selection == .settings ? Color.accentColor : .gray)
                    Text("Settings")
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(selection == .settings ? Color.primary : .secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    selection == .settings ? Color.accentColor.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .accessibilityValue(selection == .settings ? "Selected" : "")
        }
        .frame(minWidth: 200)
    }
    
    private var storageWarningColor: Color {
        let availableGB = Double(availableSpace) / (1024 * 1024 * 1024)
        if availableGB < 1 {
            return .red
        } else {
            return .orange
        }
    }
    
    private func updateDiskSpace() {
        let fileManager = FileManager.default
        let modelsDir = VoxtralConfiguration.modelsDirectory
        
        do {
            let attributes = try fileManager.attributesOfFileSystem(forPath: modelsDir.path)
            if let freeSpace = attributes[.systemFreeSize] as? NSNumber {
                availableSpace = freeSpace.int64Value
                let availableGB = Double(availableSpace) / (1024 * 1024 * 1024)
                showStorageWarning = availableGB < 5 // Show warning if less than 5GB
            }
        } catch {
            print("Failed to get disk space: \(error)")
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

enum NavigationItem: String, Hashable, CaseIterable {
    case dashboard = "Dashboard"
    case record = "Record"
    case `import` = "Import"
    case library = "Library"
    case history = "History"
    case search = "Search"
    case meetings = "Meetings"
    case queue = "Queue"
    case voiceMemos = "Voice Memos"
    case batch = "Batch Process"
    case promptLab = "Prompt Lab"
    case speakers = "People"
    case reviewInbox = "Review"
    case models = "Models"
    case settings = "Settings"

    /// Items shown in the sidebar
    static var sidebarItems: [NavigationItem] {
        [.dashboard, .search, .meetings, .record, .speakers, .reviewInbox, .queue]
    }

    var icon: String {
        switch self {
        case .dashboard: return "house.fill"
        case .record: return "mic.circle.fill"
        case .import: return "square.and.arrow.down.fill"
        case .library: return "folder.fill"
        case .history: return "clock.arrow.circlepath"
        case .search: return "magnifyingglass.circle.fill"
        case .meetings: return "calendar"
        case .queue: return "tray.full.fill"
        case .voiceMemos: return "mic.badge.plus"
        case .batch: return "square.stack.3d.up.fill"
        case .promptLab: return "flask.fill"
        case .speakers: return "person.2.circle.fill"
        case .reviewInbox: return "checkmark.seal.fill"
        case .models: return "cpu"
        case .settings: return "gearshape.fill"
        }
    }

    var color: Color {
        switch self {
        case .dashboard: return .blue
        case .record: return .red
        case .import: return .brown
        case .library: return .yellow
        case .history: return .cyan
        case .search: return .indigo
        case .meetings: return .orange
        case .queue: return .mint
        case .voiceMemos: return .purple
        case .batch: return .green
        case .promptLab: return .teal
        case .speakers: return .pink
        case .reviewInbox: return .orange
        case .models: return .cyan
        case .settings: return .gray
        }
    }
}
