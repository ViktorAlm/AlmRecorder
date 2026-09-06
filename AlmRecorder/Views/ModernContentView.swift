import SwiftUI

struct ModernContentView: View {
    // The everyday loop is browse → record → find, so returning users land on their recordings
    // instead of an analytics-oriented dashboard.
    @State private var selection: NavigationItem? = .library
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @StateObject private var voiceMemosImporter = VoiceMemosImporter()
    @StateObject private var appState = AppState.shared
    @AppStorage("hasCompletedSetup") private var hasCompletedSetup = false

    var body: some View {
        // NavigationSplitView must be the ROOT scene content for macOS to give the sidebar its
        // Liquid Glass material. Wrapping it in a VStack (for the queue bar) previously demoted it
        // to a subview, which forced an opaque sidebar. The queue bar now rides in the bottom
        // safe-area inset — it still reserves its own height, so it can't overlap scroll content.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: sidebarListSelection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
        } detail: {
            ZStack {
                // No opaque base here: painting windowBackgroundColor overrode the system's
                // Liquid Glass window background (the reason the window looked a different,
                // flatter color than System Settings). Let the system material show through.

                // Content based on selection
                if let selection = selection {
                    // Swap detail content instantly, like a native desktop app (Mail / System
                    // Settings). The old slide-in + spring made every sidebar click lurch.
                    contentView(for: selection)
                        .frame(maxWidth: .infinity, minHeight: 620, maxHeight: .infinity)
                } else {
                    WelcomeView()
                        .frame(maxWidth: .infinity, minHeight: 620, maxHeight: .infinity)
                }
            }
            // A number of pages (notably Settings and Record) can have a short intrinsic
            // height. Without an explicit fill constraint, NavigationSplitView lets its
            // detail hosting view collapse to that height and exposes the window background
            // below it. Keep every destination pinned to the full detail pane.
            // Keep a concrete content minimum as well as a flexible maximum. A purely
            // `.infinity` frame can resolve to zero when NavigationSplitView measures a
            // destination with no intrinsic minimum (Dashboard, Record, Queue), even though
            // its accessibility elements still exist. Settings already had this minimum,
            // which is why it rendered while the other destinations did not.
            .frame(maxWidth: .infinity, minHeight: 620, maxHeight: .infinity)
            .navigationTitle(selection?.rawValue ?? "AlmRecorder")
            .overlay(alignment: .top) {
                // Show model download progress banner
                ModelDownloadBanner()
                    .padding(.top, 8)
                    .padding(.horizontal)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Hidden on the Queue page itself — that page has its own bottom controls, and the
            // translucent glass bar would otherwise sit on top of them (visible bleed-through).
            if (appState.queueManager.queueSize > 0 || appState.queueManager.isProcessing) && selection != .queue {
                QueueStatusBar()
                    .environmentObject(appState)
                    .transition(.opacity)
            }
        }
        // NavigationSplitView otherwise keeps the intrinsic height of a short destination and
        // merely sits inside the larger minimum-size frame, leaving the rest transparent.
        // Apply the flexible frame to the split view first so its columns consume the window.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 1100, minHeight: 680)
        // First-run setup wizard (system check → model downloads → connect Voice Memos).
        // A sheet dismissal is never setup completion: only an explicit destination button on the
        // final step may persist `hasCompletedSetup`.
        .sheet(isPresented: Binding(
            get: { !hasCompletedSetup },
            set: { _ in }
        )) {
            SetupWizardView { destination in
                selection = destination
                hasCompletedSetup = true
                if destination == .record && !MeetingRecorder.shared.isRecording {
                    Task { await MeetingRecorder.shared.start() }
                }
            }
            .interactiveDismissDisabled()
        }
        // Provide focused values for menu commands
        .focusedValue(\.navigationSelection, $selection)
        .focusedValue(\.voiceMemosImporter, voiceMemosImporter)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NavigateToSearch"))) { _ in
            selection = .search
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NavigateToVoiceMemos"))) { _ in
            selection = .voiceMemos
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NavigateToQueue"))) { _ in
            selection = .queue
        }
    }
    
    /// The sidebar List only contains `NavigationItem.sidebarItems`. Handing it a non-member
    /// selection (.history, .import, .models, .settings) makes the AppKit-backed List revert
    /// the binding to its previous row — which silently broke every programmatic navigation to
    /// those pages (menu commands and the dashboard's quick actions alike). This proxy shows
    /// the List nil for non-member values (no highlight, nothing to revert) and ignores the
    /// List's nil write-backs so `selection` stays the source of truth for the detail pane.
    private var sidebarListSelection: Binding<NavigationItem?> {
        Binding(
            get: {
                guard let selection, NavigationItem.sidebarItems.contains(selection) else { return nil }
                return selection
            },
            set: { newValue in
                if let newValue { selection = newValue }
            }
        )
    }

    @ViewBuilder
    private func contentView(for item: NavigationItem) -> some View {
        switch item {
        case .dashboard:
            DashboardView(selection: $selection)
        case .record:
            MeetingRecorderView()
        case .import:
            ImportView()  // Using original ImportView until ModernImportView is fully implemented
        case .library:
            LibraryView(selection: $selection)
        case .history:
            HistoryView()
        case .search:
            SearchView()
        case .meetings:
            MeetingsView()
        case .queue:
            QueueView()
                .environmentObject(AppState.shared)
        case .voiceMemos:
            VoiceMemosMonitorView()
        case .batch:
            BatchProcessView()
        case .promptLab:
            PromptLabView()
        case .speakers:
            PeopleView()
        case .reviewInbox:
            TranscriptReviewInboxView()
        case .models:
            ModelManagerView()
        case .settings:
            ModernSettingsView()
        }
    }
    
    private var recordingToolbarItems: some View {
        Group {
            Button(action: {}) {
                Image(systemName: "waveform")
            }
            .help("Show waveform")
            
            Button(action: {}) {
                Image(systemName: "timer")
            }
            .help("Set recording timer")
            
            Divider()
            
            Button(action: {}) {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Export recording")
        }
    }
}

// MARK: - Welcome View
struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "mic.and.signal.meter.fill")
                .font(.system(size: 80))
                .foregroundStyle(.secondary)
            
            VStack(spacing: 12) {
                Text("Welcome to AlmRecorder")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .fontDesign(.rounded)
                
                Text("Professional Audio Recording & Transcription")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            
            HStack(spacing: 20) {
                FeatureCard(
                    icon: "mic.circle.fill",
                    title: "Record",
                    description: "High-quality audio recording",
                    color: .red
                )
                
                FeatureCard(
                    icon: "brain",
                    title: "Transcribe",
                    description: "AI-powered transcription",
                    color: .purple
                )
                
                FeatureCard(
                    icon: "square.stack.3d.up",
                    title: "Process",
                    description: "Batch processing support",
                    color: .green
                )
            }
            .padding(.top)
        }
        .padding(40)
    }
}

// MARK: - Feature Card
struct FeatureCard: View {
    let icon: String
    let title: String
    let description: String
    let color: Color
    @State private var isHovering = false
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(color)
            
            Text(title)
                .font(.headline)
            
            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(width: 150, height: 150)
        .cardSurfaceProminent()
        .shadow(color: .black.opacity(0.1), radius: isHovering ? 8 : 5)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
