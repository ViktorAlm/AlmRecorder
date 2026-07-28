import SwiftUI
import AVFoundation

// MARK: - Focused Values for Commands

struct NavigationSelectionKey: FocusedValueKey {
    typealias Value = Binding<NavigationItem?>
}

struct VoiceMemosImporterKey: FocusedValueKey {
    typealias Value = VoiceMemosImporter
}

extension FocusedValues {
    var navigationSelection: Binding<NavigationItem?>? {
        get { self[NavigationSelectionKey.self] }
        set { self[NavigationSelectionKey.self] = newValue }
    }
    
    var voiceMemosImporter: VoiceMemosImporter? {
        get { self[VoiceMemosImporterKey.self] }
        set { self[VoiceMemosImporterKey.self] = newValue }
    }
}

extension Notification.Name {
    static let vibeVoiceGoldBenchmarkDidChange = Notification.Name(
        "VibeVoiceGoldBenchmarkDidChange"
    )
}

@MainActor
final class VibeVoiceMenuBenchmarkRunner: ObservableObject {
    static let shared = VibeVoiceMenuBenchmarkRunner()

    @Published private(set) var isRunning = false
    @Published private(set) var status = ""
    @Published private(set) var errorMessage: String?

    private var task: Task<Void, Never>?

    func runThreeCallFourBitComparison() {
        guard !isRunning else { return }
        isRunning = true
        status = "Loading Speaker gold…"
        errorMessage = nil
        task = Task {
            do {
                let provider = LocalSpeakerEvaluationDataProvider()
                let completeDataset = try await Task.detached(priority: .utility) {
                    try provider.loadDataset()
                }.value
                let recordings = Array(
                    completeDataset.recordings.sorted {
                        let leftDuration = $0.recording.duration ?? .greatestFiniteMagnitude
                        let rightDuration = $1.recording.duration ?? .greatestFiniteMagnitude
                        if leftDuration != rightDuration {
                            return leftDuration < rightDuration
                        }
                        return ($0.recording.id ?? 0) < ($1.recording.id ?? 0)
                    }
                    .prefix(3)
                )
                guard !recordings.isEmpty else {
                    throw RunnerError.noGold
                }
                let dataset = SpeakerEvaluationDataset(
                    recordings: recordings,
                    goldRevision: completeDataset.goldRevision
                )
                let bundle = await VibeVoiceGoldBenchmarkRunner.run(
                    dataset: dataset,
                    configurations: [
                        .current(quantization: .fourBit, speakerMode: .fused)
                    ],
                    speakerResolver: try provider.loadSpeakerResolver()
                ) { [weak self] progress in
                    self?.status = progress.message
                }
                try Task.checkCancellation()
                if bundle.reports.isEmpty, let failure = bundle.failures.first {
                    throw RunnerError.failed(failure.message)
                }
                try VibeVoiceGoldBenchmarkStore.save(bundle)
                status = "Finished \(recordings.count) calls"
                NotificationCenter.default.post(
                    name: .vibeVoiceGoldBenchmarkDidChange,
                    object: nil
                )
            } catch is CancellationError {
                status = "Cancelled"
            } catch {
                status = "Comparison failed"
                errorMessage = error.localizedDescription
            }
            isRunning = false
            task = nil
        }
    }

    private enum RunnerError: LocalizedError {
        case noGold
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noGold:
                return "Confirm at least one complete conversation as Speaker gold."
            case .failed(let message):
                return message
            }
        }
    }
}

// MARK: - App Commands

struct AppCommands: Commands {
    // The Record page renders MeetingRecorder.shared, so the menu commands must drive the same
    // recorder (the legacy per-window AudioRecorder started a recorder no view displayed).
    // Observed directly — a singleton outlives window focus, so the commands work even when no
    // window has focus, matching AppDelegate.handleMeetingAction.
    @ObservedObject private var meetingRecorder = MeetingRecorder.shared
    @ObservedObject private var vibeVoiceBenchmarkRunner = VibeVoiceMenuBenchmarkRunner.shared
    @FocusedValue(\.navigationSelection) var navigationSelection
    @FocusedValue(\.voiceMemosImporter) var voiceMemosImporter
    
    @State private var showingImportDialog = false
    @State private var showingModelManager = false
    @State private var showingSearchWindow = false
    @State private var showingDatabaseResetAlert = false
    @State private var showingDatabaseClearAlert = false
    
    var body: some Commands {
        // File Menu
        CommandGroup(replacing: .newItem) {
            Button("New Recording") {
                startRecording()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(meetingRecorder.isRecording)

            Button("Stop Recording") {
                stopRecording()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!meetingRecorder.isRecording)

            Divider()

            Button("Import Audio Files...") {
                showImportFilePicker()
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        // Recording Menu
        CommandMenu("Recording") {
            Button("Start Recording") {
                startRecording()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(meetingRecorder.isRecording)

            Button("Stop Recording") {
                stopRecording()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!meetingRecorder.isRecording)

            Divider()

            Text("Duration: \(formatDuration(meetingRecorder.duration))")
                .font(.caption)
        }
        
        // Search Menu
        CommandMenu("Search") {
            Button("Search Transcripts...") {
                navigationSelection?.wrappedValue = .search
            }
            .keyboardShortcut("f", modifiers: .command)

            Divider()

            Button("Open Library") {
                navigationSelection?.wrappedValue = .library
            }
        }
        
        // Transcription Menu
        CommandMenu("Transcription") {
            Button("Batch Transcribe...") {
                navigationSelection?.wrappedValue = .import
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            
            Divider()
            
            Button("Process Voice Memos") {
                navigationSelection?.wrappedValue = .voiceMemos
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            
            Divider()
            
            Button("Transcription Queue") {
                navigationSelection?.wrappedValue = .queue
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        
        // Add destinations to the native View menu instead of creating a second "View" menu.
        CommandGroup(after: .sidebar) {
            Button("Show Dashboard") {
                navigationSelection?.wrappedValue = .dashboard
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("Show Recording") {
                navigationSelection?.wrappedValue = .record
            }
            .keyboardShortcut("2", modifiers: .command)

            Button("Show Library") {
                navigationSelection?.wrappedValue = .library
            }
            .keyboardShortcut("3", modifiers: .command)

            Button("Show Search") {
                navigationSelection?.wrappedValue = .search
            }
            .keyboardShortcut("4", modifiers: .command)

            Divider()

            Button("Show Queue") {
                navigationSelection?.wrappedValue = .queue
            }
        }

        if FeatureFlags.developerTools {
            CommandMenu("Database") {
                Button("Clear All Data...") {
                    clearDatabase()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift, .option])

                Button("Reset Database...") {
                    resetDatabase()
                }

                Divider()

                Button("Vacuum Database") {
                    vacuumDatabase()
                }

                Button("Show Database Info") {
                    showDatabaseInfo()
                }
            }

            CommandMenu("Evaluation") {
                Button(
                    vibeVoiceBenchmarkRunner.isRunning
                        ? vibeVoiceBenchmarkRunner.status
                        : "Compare 3 Calls: Whisper vs 4-bit Fused"
                ) {
                    vibeVoiceBenchmarkRunner.runThreeCallFourBitComparison()
                }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(
                    vibeVoiceBenchmarkRunner.isRunning
                        || !VibeVoiceModelManager.shared.isModelDownloaded(.fourBit)
                )

                if let error = vibeVoiceBenchmarkRunner.errorMessage {
                    Divider()
                    Text(error)
                }
            }
        }
        
        // Models Menu
        CommandMenu("Models") {
            Button("Manage Models...") {
                navigationSelection?.wrappedValue = .models
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            
            Divider()
            
            Section("Transcription Models") {
                Button("Download Whisper Models") {
                    navigationSelection?.wrappedValue = .models
                    // Will open models view with Whisper tab selected
                }
                
                Button("Download Voxtral Models") {
                    navigationSelection?.wrappedValue = .models
                    // Will open models view with Voxtral tab selected
                }
            }
            
            Divider()
            
            Button("Download Embedding Models") {
                navigationSelection?.wrappedValue = .models
                // Will open models view with Embedding tab selected
            }
            
            Divider()
            
            // Show current model status
            ModelStatusSection()
        }
    }
    
    private func showImportFilePicker() {
        let panel = NSOpenPanel()
        panel.title = "Import Audio Files"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .movie]
        
        if panel.runModal() == .OK {
            let urls = panel.urls
            voiceMemosImporter?.importFromFiles(urls)
            navigationSelection?.wrappedValue = .import
        }
    }
    
    /// Same record-intent path as AppDelegate.handleMeetingAction / the dashboard quick action:
    /// the Record page renders MeetingRecorder.shared, so starting here lands on live levels.
    private func startRecording() {
        if !MeetingRecorder.shared.isRecording {
            Task { await MeetingRecorder.shared.start() }
        }
        navigationSelection?.wrappedValue = .record
    }

    private func stopRecording() {
        Task { await MeetingRecorder.shared.stopAndEnqueue() }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: duration) ?? "00:00"
    }
    
    // MARK: - Database Commands
    
    private func clearDatabase() {
        // Show confirmation alert
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Clear All Data?"
            alert.informativeText = "This will delete all recordings, transcriptions, and settings from the database. This action cannot be undone."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Clear All Data")
            alert.addButton(withTitle: "Cancel")
            
            if alert.runModal() == .alertFirstButtonReturn {
                Task {
                    do {
                        let database = GRDBDatabaseManager.shared
                        try database.clearAllData()
                        
                        // Show success notification
                        DispatchQueue.main.async {
                            let successAlert = NSAlert()
                            successAlert.messageText = "Database Cleared"
                            successAlert.informativeText = "All data has been removed from the database."
                            successAlert.alertStyle = .informational
                            successAlert.runModal()
                        }
                    } catch {
                        DispatchQueue.main.async {
                            let errorAlert = NSAlert()
                            errorAlert.messageText = "Failed to Clear Database"
                            errorAlert.informativeText = error.localizedDescription
                            errorAlert.alertStyle = .critical
                            errorAlert.runModal()
                        }
                    }
                }
            }
        }
    }
    
    private func resetDatabase() {
        // Show confirmation alert
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Reset Database?"
            alert.informativeText = "This will completely reset the database, removing all data and recreating the schema. This action cannot be undone."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Reset Database")
            alert.addButton(withTitle: "Cancel")
            
            if alert.runModal() == .alertFirstButtonReturn {
                Task {
                    do {
                        let database = GRDBDatabaseManager.shared
                        try database.resetDatabase()
                        
                        // Show success notification
                        DispatchQueue.main.async {
                            let successAlert = NSAlert()
                            successAlert.messageText = "Database Reset"
                            successAlert.informativeText = "The database has been completely reset to its initial state."
                            successAlert.alertStyle = .informational
                            successAlert.runModal()
                        }
                    } catch {
                        DispatchQueue.main.async {
                            let errorAlert = NSAlert()
                            errorAlert.messageText = "Failed to Reset Database"
                            errorAlert.informativeText = error.localizedDescription
                            errorAlert.alertStyle = .critical
                            errorAlert.runModal()
                        }
                    }
                }
            }
        }
    }
    
    private func vacuumDatabase() {
        Task {
            do {
                let database = GRDBDatabaseManager.shared
                try database.vacuum()
                
                // Show success notification
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Database Optimized"
                    alert.informativeText = "The database has been vacuumed to reclaim space and optimize performance."
                    alert.alertStyle = .informational
                    alert.runModal()
                }
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Failed to Vacuum Database"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .critical
                    alert.runModal()
                }
            }
        }
    }
    
    private func showDatabaseInfo() {
        let database = GRDBDatabaseManager.shared
        let stats = database.getDatabaseStatistics()
        
        var info = "Database Location:\n\(database.getDatabasePath())\n\n"
        info += "Statistics:\n"
        info += "• Total Queries: \(stats.totalQueries)\n"
        info += "• Average Query Time: \(String(format: "%.4f", stats.averageQueryTime))s\n\n"
        info += "Table Counts:\n"
        
        for (table, count) in stats.tableCounts.sorted(by: { $0.key < $1.key }) {
            info += "• \(table): \(count) rows\n"
        }
        
        if let fileSize = stats.fileSizeBytes {
            let sizeMB = Double(fileSize) / (1024 * 1024)
            info += "\nDatabase Size: \(String(format: "%.2f", sizeMB)) MB"
        }
        
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Database Information"
            alert.informativeText = info
            alert.alertStyle = .informational
            alert.runModal()
        }
    }
}

// MARK: - Model Status Section

struct ModelStatusSection: View {
    @StateObject private var whisperManager = WhisperModelManager.shared
    @StateObject private var voxtralService = VoxtralCppService()
    @StateObject private var embeddingManager = EmbeddingModelManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if whisperManager.isModelLoaded {
                Text("✓ Whisper: \(whisperManager.currentModel)")
                    .font(.caption)
            } else {
                Text("⚠️ Whisper: No model")
                    .font(.caption)
            }
            
            if voxtralService.isModelLoaded {
                Text("✓ Voxtral: Ready")
                    .font(.caption)
            } else {
                Text("⚠️ Voxtral: No model")
                    .font(.caption)
            }
            
            if embeddingManager.isModelLoaded {
                Text("✓ Embeddings: \(embeddingManager.currentModel)")
                    .font(.caption)
            } else {
                Text("⚠️ Embeddings: No model")
                    .font(.caption)
            }
        }
    }
}
