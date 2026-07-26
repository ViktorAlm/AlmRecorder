import Foundation
import SwiftUI
import Combine

/// Global app state shared across all views
@MainActor
class AppState: ObservableObject {
    
    // MARK: - Singleton
    static let shared = AppState()
    
    // MARK: - Queue Management
    let queueManager = TranscriptionQueueManager.shared
    let notificationManager = NotificationManager.shared
    
    // MARK: - Published Properties
    
    @Published var isProcessingGlobally: Bool = false
    @Published var globalStatusMessage: String = ""
    @Published var showQueuePanel: Bool = false
    @Published var showNotificationPanel: Bool = false
    @Published var currentTab: Int = 0

    /// One-shot handoff: another page (e.g. the dashboard) asks the Search page to run a query
    /// on arrival. SearchView consumes and nils it in its `.task`.
    struct PendingSearchHandoff: Equatable {
        let query: String
        let semantic: Bool
    }
    @Published var pendingSearch: PendingSearchHandoff? = nil

    /// One-shot handoff: pre-select a person on the People page (dashboard People row).
    /// PeopleView consumes and nils it in `reload()`.
    @Published var pendingPersonUuid: String? = nil
    
    // MARK: - Services (Shared Instances)
    
    let voxtralService = VoxtralCppService()
    let transcriptionService = TranscriptionService()
    let unifiedManager = UnifiedTranscriptionManager.shared
    
    // MARK: - Computed Properties
    
    var hasActiveJobs: Bool {
        !queueManager.activeJobs.isEmpty
    }
    
    var pendingJobsCount: Int {
        queueManager.pendingJobs.count
    }
    
    var queueBadgeCount: Int {
        queueManager.queueSize
    }
    
    var processingStatusText: String {
        if let currentJob = queueManager.currentJob {
            return "Processing: \(currentJob.fileName)"
        } else if queueManager.pendingJobs.count > 0 {
            return "\(queueManager.pendingJobs.count) jobs in queue"
        } else {
            return "Ready"
        }
    }
    
    // MARK: - Private Properties
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Init
    
    private init() {
        // Ensure queue manager is initialized
        _ = queueManager
        print("🎙️ [AppState] Initialized with queue manager")
        // Defer binding setup to avoid accessing $-projected properties mid-init
        DispatchQueue.main.async { [self] in
            setupBindings()
        }
    }
    
    private func setupBindings() {
        // Monitor queue processing state
        queueManager.$isProcessing
            .assign(to: &$isProcessingGlobally)
        
        // Monitor current job for status updates
        queueManager.$currentJob
            .sink { [weak self] job in
                if let job = job {
                    self?.globalStatusMessage = "Processing: \(job.fileName)"
                } else if self?.queueManager.pendingJobs.count ?? 0 > 0 {
                    self?.globalStatusMessage = "Queue ready"
                } else {
                    self?.globalStatusMessage = ""
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Public Methods
    
    /// Submit a recording for transcription
    func transcribeRecording(audioFile: String, priority: TranscriptionJob.Priority = .high, runSettings: RunSettings? = nil) -> TranscriptionJob {
        return queueManager.addJob(
            audioFile: audioFile,
            source: .recording,
            priority: priority,
            runSettings: runSettings
        )
    }
    
    /// Submit imported files for transcription
    func transcribeImportedFiles(_ files: [(path: String, name: String)], runSettings: RunSettings? = nil) -> [TranscriptionJob] {
        return queueManager.addBatchJobs(
            audioFiles: files,
            source: .voiceMemos,  // Using voiceMemos for imported files
            priority: .normal,
            runSettings: runSettings
        )
    }
    
    /// Submit voice memos for transcription
    func transcribeVoiceMemos(_ memos: [VoiceMemoFile], runSettings: RunSettings? = nil) -> [TranscriptionJob] {
        let files = memos.map { (path: $0.url.path, name: $0.name) }
        return queueManager.addBatchJobs(
            audioFiles: files,
            source: .voiceMemos,
            priority: .normal,
            runSettings: runSettings
        )
    }
    
    /// Submit a prompt test job
    func runPromptTest(
        audioFile: String,
        config: PromptTestConfig,
        modelKey: String = VoxtralConfiguration.defaultModel,
        priority: TranscriptionJob.Priority = .low,
        runSettings: RunSettings? = nil
    ) -> TranscriptionJob {
        // For prompt tests, we'll use a special source
        return queueManager.addJob(
            audioFile: audioFile,
            fileName: "Test: \(config.name)",
            source: .voiceMemos, // Using voiceMemos for test files
            priority: priority,
            requiredModel: modelKey,
            promptConfig: config,
            isPromptTest: true,
            runSettings: runSettings
        )
    }
    
    /// Toggle queue panel visibility
    func toggleQueuePanel() {
        showQueuePanel.toggle()
    }
    
    /// Toggle notification panel visibility
    func toggleNotificationPanel() {
        showNotificationPanel.toggle()
        if showNotificationPanel {
            notificationManager.markAllAsRead()
        }
    }
    
    /// Switch to a specific tab
    func switchToTab(_ tab: Int) {
        currentTab = tab
    }
    
    /// Show queue and switch to specific job
    func showJobInQueue(_ jobId: UUID) {
        showQueuePanel = true
        // Could implement scrolling to specific job
    }
}