import SwiftUI
import UserNotifications

enum AppAppearanceChoice: String, CaseIterable, Identifiable {
    case auto
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AppAccentChoice: String, CaseIterable, Identifiable {
    case blue
    case purple
    case pink
    case red
    case orange
    case green

    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
    }

    var color: Color {
        switch self {
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .green: return .green
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When built via SPM (no .app bundle), tell macOS this is a GUI app
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Host the meeting-prompt notification actions (Record / Stop).
        // UNUserNotificationCenter requires a real .app bundle; a bare SPM binary
        // (`swift run` / launch.sh) has no bundle identifier and aborts here — so guard it.
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
            NotificationManager.shared.registerMeetingCategories()
        }
    }

    // Show meeting prompts even when AlmRecorder is foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let eventId = userInfo[NotificationManager.MeetingNotification.eventIdKey] as? String
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        Task { @MainActor in
            await handleMeetingAction(action: action, category: category, eventId: eventId)
            completionHandler()
        }
    }

    @MainActor
    private func handleMeetingAction(action: String, category: String, eventId: String?) async {
        let M = NotificationManager.MeetingNotification.self
        let recordIntent = action == M.recordAction
            || (action == UNNotificationDefaultActionIdentifier && category == M.startCategory)

        if recordIntent {
            guard !MeetingRecorder.shared.isRecording else { return }
            await MeetingRecorder.shared.start()
            if let eventId,
               let meeting = (try? GRDBMeetingRepository().getByCalendarEventId(eventId)) ?? nil {
                MeetingMonitor.shared.setActiveRecording(eventId: eventId, meeting: meeting)
            }
        } else if action == M.stopAction {
            await MeetingRecorder.shared.stopAndEnqueue()
        }
        // KEEP, default-tap on the end prompt, or dismiss → keep recording / do nothing.
    }
}

@main
struct AlmRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var logsWindow: NSWindow?
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("colorScheme") private var colorSchemeSetting = AppAppearanceChoice.auto.rawValue
    @AppStorage("accentColor") private var accentColorSetting = AppAccentChoice.blue.rawValue

    init() {
        print("[AlmRecorderApp] Application starting...")
        print("[AlmRecorderApp] Debug mode: \(isDebugMode)")
        
        // Initialize AppState to ensure queue manager is ready
        _ = AppState.shared
        print("[AlmRecorderApp] AppState and queue system initialized")
        print("[AlmRecorderApp] Queue Manager ready: \(AppState.shared.queueManager.jobs.count) jobs")
        
        // Initialize database and services
        Task {
            await AppInitializer.shared.initializeApp()

            // The local MCP endpoint starts only after database migrations complete.
            // It is opt-in and remains app-hosted so the bridge never opens SQLite itself.
            await MainActor.run {
                MCPServiceController.shared.startIfEnabled()
                // Restore the durable overnight plan even if Settings is never opened.
                _ = NightlyRetranscriptionController.shared
            }
            
            // Migrate existing data in background
            await AppInitializer.shared.migrateExistingData()
        }
    }
    
    private var isDebugMode: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
    
    var body: some Scene {
        WindowGroup {
            GeometryReader { window in
                // Give the app shell the scene's concrete size. Fully flexible destinations such
                // as Record and Queue otherwise feed a zero ideal height back through the scene
                // host, collapsing the visible window to its title bar even though their
                // accessibility elements still exist.
                ModernContentView()
                    .frame(width: window.size.width, height: window.size.height)
            }
            .preferredColorScheme(preferredColorScheme)
            .tint(accentColor)
            .frame(minWidth: 1100, minHeight: 680)
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NavigateToSearch"))) { _ in
                // Handle navigation to search
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NavigateToVoiceMemos"))) { _ in
                // Handle navigation to voice memos
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        // .contentMinSize: window min = content min (900x600) but freely resizable larger, with
        // the content filling the window. .contentSize pinned the window to the content's ideal
        // size, which clipped the bottom safe-area status bar and made resizing feel broken.
        .windowResizability(.contentMinSize)
        .commands {
            AppCommands()
            
            CommandGroup(replacing: .appSettings) {
                Button("Preferences...") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            
            CommandGroup(replacing: .help) {
                Button("AlmRecorder Help") {
                    if let url = URL(string: "https://github.com/ViktorAlm/AlmRecorder/blob/main/docs/user-guide.md") {
                        NSWorkspace.shared.open(url)
                    }
                }
                
                Divider()
                
                Button("Show Logs...") {
                    showLogsWindow()
                }
                
                Button("Report Issue...") {
                    if let url = URL(string: "https://github.com/ViktorAlm/AlmRecorder/issues") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        
        Settings {
            ModernSettingsView()
                .preferredColorScheme(preferredColorScheme)
                .tint(accentColor)
        }
        
        // Menu Bar Extra - the icon in the system menu bar. `isInserted` lets the Settings → General
        // toggle show/hide it without a conditional Scene (which the SceneBuilder can't type-check).
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarExtraView()
        } label: {
            MenuBarIcon()
        }
        .menuBarExtraStyle(.window)
    }

    private var preferredColorScheme: ColorScheme? {
        AppAppearanceChoice(rawValue: colorSchemeSetting)?.colorScheme
    }

    private var accentColor: Color {
        AppAccentChoice(rawValue: accentColorSetting)?.color ?? .blue
    }
    
    private func showLogsWindow() {
        if logsWindow == nil {
            let contentView = LogsView()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "AlmRecorder Logs"
            window.contentView = NSHostingView(rootView: contentView)
            window.center()
            logsWindow = window
        }
        logsWindow?.makeKeyAndOrderFront(nil)
    }
}

// Simple logs view for now
struct LogsView: View {
    @State private var logContent = ""
    
    var body: some View {
        ScrollView {
            Text(logContent.isEmpty ? "Loading logs..." : logContent)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .onAppear {
            loadLogs()
        }
    }
    
    private func loadLogs() {
        // For now, just show recent console output
        logContent = "AlmRecorder Log Output\n" +
                    "======================\n\n" +
                    "• Application started successfully\n" +
                    "• Models loaded: Whisper, Voxtral, Embeddings\n" +
                    "• Database connected\n" +
                    "• Voice Memos monitoring active\n\n" +
                    "For detailed logs, check Console.app"
    }
}

// MARK: - Menu Bar Icon

struct MenuBarIcon: View {
    @StateObject private var controller = MenuBarController.shared
    
    var body: some View {
        HStack(spacing: 2) {
            if controller.isRecording {
                // Recording indicator
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundColor(.red)
            } else if controller.isProcessing {
                // Processing indicator
                Image(systemName: "brain")
                    .foregroundColor(.blue)
            } else {
                // Normal state — the AlmRecorder mark (template image; macOS tints it for the menu bar)
                Image("MenuBarIcon", bundle: .module)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
            }
            
            // Show queue count if there are items
            if controller.queueCount > 0 {
                Text("\(controller.queueCount)")
                    .font(.caption2)
                    .padding(.horizontal, 3)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(4)
            }
        }
        .help(controller.isRecording ? "Recording... (\(formatTime(controller.recordingDuration)))" : "AlmRecorder - Click to start recording")
    }
    
    private func formatTime(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
