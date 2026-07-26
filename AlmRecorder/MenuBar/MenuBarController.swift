import SwiftUI
import AppKit
import Combine

/// Controller for the menu bar extra functionality
@MainActor
class MenuBarController: ObservableObject {
    static let shared = MenuBarController()
    
    // MARK: - Published Properties
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var isProcessing = false
    @Published var queueCount = 0
    @Published var recentTranscriptions: [RecentTranscription] = []
    @Published var showMainWindow = false
    
    // MARK: - Services
    private let unifiedManager = UnifiedTranscriptionManager.shared
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Recent Transcription Model
    struct RecentTranscription: Identifiable {
        let id = UUID()
        let fileName: String
        let transcript: String
        let timestamp: Date
        
        var truncatedTranscript: String {
            if transcript.count > 50 {
                return String(transcript.prefix(50)) + "..."
            }
            return transcript
        }
    }
    
    private init() {
        setupBindings()
        loadRecentTranscriptions()
    }
    
    private func setupBindings() {
        // Mirror the shared meeting recorder (the same one the Record page renders), so the
        // menu bar icon and dropdown always reflect the recording the rest of the app sees.
        MeetingRecorder.shared.$isRecording
            .receive(on: DispatchQueue.main)
            .assign(to: &$isRecording)

        MeetingRecorder.shared.$duration
            .receive(on: DispatchQueue.main)
            .assign(to: &$recordingDuration)


        // Bind to queue manager
        AppState.shared.queueManager.$jobs
            .map { $0.count }
            .receive(on: DispatchQueue.main)
            .assign(to: &$queueCount)
        
        AppState.shared.queueManager.$isProcessing
            .receive(on: DispatchQueue.main)
            .assign(to: &$isProcessing)
        
        // Monitor transcription completion
        unifiedManager.$lastTranscriptionItem
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in
                self?.addRecentTranscription(item)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Recording Control

    func toggleRecording() {
        if MeetingRecorder.shared.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard !MeetingRecorder.shared.isRecording else { return }
        Task { await MeetingRecorder.shared.start() }

        sendNotification(
            title: "Recording Started",
            body: "AlmRecorder is now recording audio"
        )
    }

    func stopRecording() {
        // stopAndEnqueue hands both tracks to the transcription queue.
        Task { await MeetingRecorder.shared.stopAndEnqueue() }

        sendNotification(
            title: "Recording Stopped",
            body: "Recording saved. Tracks queued for transcription."
        )
    }

    // MARK: - Recent Transcriptions
    
    private func loadRecentTranscriptions() {
        // Load from database or cache
        Task {
            let repo = GRDBRecordingRepository()
            if let recent = try? repo.getAll(limit: 5) {
                let sorted = recent.sorted { $0.createdAt > $1.createdAt }
                let topFive = Array(sorted.prefix(5))
                
                await MainActor.run {
                    self.recentTranscriptions = topFive.map { recording in
                        RecentTranscription(
                            fileName: recording.fileName,
                            transcript: recording.fullTranscript ?? "",
                            timestamp: recording.createdAt
                        )
                    }
                }
            }
        }
    }
    
    private func addRecentTranscription(_ item: TranscriptionItem) {
        let recent = RecentTranscription(
            fileName: item.fileName,
            transcript: item.transcript,
            timestamp: item.transcribedDate
        )
        
        recentTranscriptions.insert(recent, at: 0)
        
        // Keep only last 5
        if recentTranscriptions.count > 5 {
            recentTranscriptions = Array(recentTranscriptions.prefix(5))
        }
    }
    
    // MARK: - Utility
    
    func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        
        // Find and show main window
        if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
        
        showMainWindow = true
    }
    
    func openSemanticSearch() {
        openMainWindow()
        // Navigate to search view
        NotificationCenter.default.post(
            name: Notification.Name("NavigateToSearch"),
            object: nil
        )
    }
    
    func copyTranscriptToClipboard(_ transcript: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
        
        sendNotification(
            title: "Copied",
            body: "Transcript copied to clipboard"
        )
    }
    
    private func sendNotification(title: String, body: String) {
        // For now, just print. Real implementation would use UserNotifications
        print("[MenuBarController] \(title): \(body)")
    }
    
    func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}