import Foundation
import Combine
import GRDB

/// Global queue manager for all transcription jobs
@MainActor
class TranscriptionQueueManager: ObservableObject {
    static let shared = TranscriptionQueueManager()
    
    // MARK: - Published Properties
    
    @Published var jobs: [TranscriptionJob] = []
    @Published var isProcessing = false
    @Published var isPaused = false  // Global pause state
    @Published var currentJob: TranscriptionJob?
    @Published var globalProgress: Double = 0.0
    @Published var processingCount: Int = 0  // Number of jobs currently being processed
    @Published var activeWorkers: Int = 0  // Actual number of workers processing jobs
    @Published private(set) var maxConcurrentJobs: Int = 1
    @Published var pendingSpeakerReviews: [(recordingId: Int64, audioPath: String, result: TranscriptionResult, fileName: String)] = []

    /// Durable batch coordinators subscribe to terminal events because completed jobs are removed
    /// from `jobs` immediately. The value is the final snapshot, including elapsed timestamps and
    /// `existingRecordingId`.
    let jobCompleted = PassthroughSubject<TranscriptionJob, Never>()
    let jobFailed = PassthroughSubject<TranscriptionJob, Never>()
    
    // MARK: - Computed Properties
    
    var pendingJobs: [TranscriptionJob] {
        jobs.filter { $0.status == .pending }
            .sorted { $0.priority > $1.priority || 
                     ($0.priority == $1.priority && $0.createdAt < $1.createdAt) }
    }
    
    var activeJobs: [TranscriptionJob] {
        jobs.filter { $0.status.isActive }
    }
    
    var completedJobs: [TranscriptionJob] {
        jobs.filter { $0.status == .completed }
    }
    
    var failedJobs: [TranscriptionJob] {
        jobs.filter { $0.status == .failed }
    }
    
    var queueSize: Int {
        // Only count jobs that are actually pending (not stuck processing jobs)
        let actualPending = jobs.filter { $0.status == .pending || $0.status == .waitingForModel }
        let actualActive = jobs.filter { job in
            job.status == .processing && 
            job.lastHeartbeat != nil && 
            Date().timeIntervalSince(job.lastHeartbeat!) < 60
        }
        return actualPending.count + actualActive.count
    }
    
    var completionRate: Double {
        // Calculate completion for current session (non-completed jobs)
        let nonCompletedJobs = jobs.filter { $0.status != .completed }
        let totalJobs = completedJobs.count + nonCompletedJobs.count
        guard totalJobs > 0 else { return 0 }
        return Double(completedJobs.count) / Double(totalJobs)
    }
    
    // MARK: - Private Properties
    
    private let unifiedManager = UnifiedTranscriptionManager.shared
    private let modelManager = VoxtralModelManager()
    private let downloadQueue = UnifiedDownloadQueue.shared
    private let logger = VoxtralLogger.shared
    private let database = GRDBDatabaseManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var processingTasks: [UUID: Task<Void, Never>] = [:] // Multiple tasks for workers
    private var heartbeatTimer: Timer?
    private let heartbeatInterval: TimeInterval = 30 // Update heartbeat every 30 seconds
    
    // Worker management
    private var workers: [TranscriptionWorker] = []
    private let workerQueue = DispatchQueue(label: "com.almrecorder.queue.workers", attributes: .concurrent)
    private var memoryRetryNotBefore: [UUID: Date] = [:]
    
    // MARK: - Init
    
    private init() {
        // Set max concurrent jobs based on CPU cores
        // Default to 1 worker for better resource management
        maxConcurrentJobs = 1
        
        setupBindings()
        setupNotifications()
        
        // Load persisted jobs and recover from crashes
        loadPersistedJobs()
        recoverInterruptedJobs()
        
        // Clean up any stuck jobs from previous session
        cleanupStuckJobs()
        
        // Clean up any duplicate jobs that may have accumulated
        cleanupDuplicateJobs()
        
        // Start automatic monitoring task
        startMonitoringTask()
        
        // Start heartbeat timer for crash detection
        startHeartbeatTimer()
        
        logger.info("[QueueManager] ===== TranscriptionQueueManager INITIALIZED =====")
        logger.info("[QueueManager] Max concurrent jobs: \(maxConcurrentJobs)")
        logger.info("[QueueManager] Ready to process transcription jobs")
        logger.info("[QueueManager] Initialized with \(jobs.count) persisted jobs")
    }
    
    private func setupBindings() {
        // Subscribe to UnifiedTranscriptionManager progress updates
        unifiedManager.$transcriptionProgress
            .sink { [weak self] progress in
                self?.updateCurrentJobProgress(progress)
            }
            .store(in: &cancellables)
        
        unifiedManager.$transcriptionStatus
            .sink { [weak self] status in
                self?.updateCurrentJobStatus(status)
            }
            .store(in: &cancellables)
        
        unifiedManager.$isTranscribing
            .sink { [weak self] isTranscribing in
                if !isTranscribing {
                    // Transcription finished, check for more jobs
                    self?.checkForNextJob()
                }
            }
            .store(in: &cancellables)
    }
    
    private func setupNotifications() {
        // TODO: Set up download completion notifications from UnifiedDownloadQueue
        // For now, we'll poll the download queue status
    }
    
    private func checkForNextJob() {
        // Jobs are now handled by workers automatically
        // This method is no longer needed but kept for compatibility
    }
    
    // This method can be called when checking download status
    private func checkForCompletedModelDownloads() {
        // Check if any jobs waiting for models can now proceed
        for index in jobs.indices {
            if jobs[index].status == .waitingForModel,
               let downloadId = jobs[index].modelDownloadId {
                // Check if download completed
                if let task = downloadQueue.downloadTasks.first(where: { $0.id.uuidString == downloadId }) {
                    if task.state == .completed {
                        jobs[index].status = .pending
                        jobs[index].modelDownloadId = nil
                        logger.info("[QueueManager] Job \(jobs[index].fileName) ready after model download")
                    } else if task.state == .failed || task.state == .cancelled {
                        jobs[index].status = .failed
                        jobs[index].error = "Model download failed"
                        jobs[index].modelDownloadId = nil
                    }
                }
            }
        }
    }
    
    // MARK: - Public Methods
    
    /// Add a new job to the queue
    func addJob(
        audioFile: String,
        fileName: String? = nil,
        source: TranscriptionItem.TranscriptionSource = .recording,
        priority: TranscriptionJob.Priority = .normal,
        requiredModel: String? = nil,
        promptConfig: PromptTestConfig? = nil,
        isPromptTest: Bool = false,
        runSettings: RunSettings? = nil
    ) -> TranscriptionJob {
        
        let url = URL(fileURLWithPath: audioFile)
        let actualFileName = fileName ?? url.lastPathComponent
        
        // Check for duplicate job already in queue (pending, processing, or recently completed)
        // Match by audioFilePath OR fileName to catch both exact path matches and same-file-different-path cases
        if let existingJob = jobs.first(where: { job in
            (job.audioFilePath == audioFile || job.fileName == actualFileName) &&
            (job.status == .pending ||
             job.status == .processing ||
             job.status == .waitingForModel ||
             job.status == .paused ||
             (job.status == .completed && job.completedAt != nil &&
              Date().timeIntervalSince(job.completedAt!) < 300)) // Skip if completed within last 5 minutes
        }) {
            logger.info("[QueueManager] Duplicate job detected for: \(actualFileName), returning existing job")
            return existingJob
        }
        
        // Check if file has already been transcribed in the database (by file_name, more reliable than path)
        do {
            let recordings = try database.readQueue { db in
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM recordings WHERE file_name = ? OR file_path = ?", arguments: [actualFileName, audioFile])
                return rows.compactMap { Recording(row: $0) }
            }
            
            if !recordings.isEmpty {
                logger.info("[QueueManager] File already transcribed in database: \(actualFileName), skipping")
                // Return a dummy completed job to indicate it's already done
                var completedJob = TranscriptionJob(
                    audioFilePath: audioFile,
                    fileName: actualFileName,
                    source: source,
                    priority: priority
                )
                completedJob.status = .completed
                completedJob.completedAt = Date()
                return completedJob
            }
        } catch {
            logger.error("[QueueManager] Failed to check for existing recording: \(error)")
        }
        
        var job = TranscriptionJob(
            audioFilePath: audioFile,
            fileName: actualFileName,
            source: source,
            priority: priority
        )
        
        // Set model requirements based on backend
        if requiredModel == nil {
            // Use the selected model from GlobalModelSettings
            let modelSettings = GlobalModelSettings.shared
            switch modelSettings.transcriptionBackend {
            case .whisper:
                job.requiredModel = modelSettings.selectedWhisperVariant?.displayName
            case .llm:
                job.requiredModel = modelSettings.selectedLLMEngine == .gemma
                    ? modelSettings.selectedGemmaTranscriptionModel
                    : modelSettings.selectedVoxtralTranscriptionModel
            case .vibeVoice:
                job.requiredModel = modelSettings.selectedVibeVoiceQuantization.repositoryID
            }
        } else {
            job.requiredModel = requiredModel
        }
        job.promptConfig = promptConfig
        job.isPromptTest = isPromptTest
        
        // Set run settings (use provided or default)
        job.runSettings = (runSettings ?? .defaultSettings).snapshottingEngineIfNeeded()
        
        // Get file metadata
        if let attributes = try? FileManager.default.attributesOfItem(atPath: audioFile) {
            job.fileSize = attributes[.size] as? Int64
        }
        
        jobs.append(job)
        persistJob(job) // Persist to database
        logger.info("[QueueManager] Added job: \(actualFileName) with priority: \(priority)")
        
        // Start processing if not already running
        if !isProcessing && !isPaused {
            startProcessing()
        }
        
        return job
    }
    
    /// Add a re-transcription job for an existing recording. The current transcript remains live
    /// while ASR runs; UtteranceProcessor atomically snapshots user decisions and swaps utterances
    /// only after fresh, non-empty output is ready. Bypasses normal duplicate detection.
    func addRetranscribeJob(
        recording: Recording,
        runSettings: RunSettings? = nil,
        priority: TranscriptionJob.Priority = .immediate
    ) -> TranscriptionJob? {
        guard let recordingId = recording.id else {
            logger.error("[QueueManager] Cannot re-transcribe recording without ID")
            return nil
        }

        guard let filePath = recording.filePath,
              FileManager.default.fileExists(atPath: filePath) else {
            logger.error("[QueueManager] Audio file not found for recording \(recordingId)")
            return nil
        }

        if let existingJob = jobs.first(where: {
            $0.existingRecordingId == recordingId
                && ($0.status == .pending
                    || $0.status == .processing
                    || $0.status == .paused
                    || $0.status == .waitingForModel
                    || $0.status == .interrupted)
        }) {
            logger.info("[QueueManager] Re-transcription already queued for recording \(recordingId)")
            return existingJob
        }

        // Map Recording.RecordingSource → TranscriptionItem.TranscriptionSource
        let source: TranscriptionItem.TranscriptionSource
        switch recording.source {
        case .recording: source = .recording
        case .voiceMemos: source = .voiceMemos
        case .imported: source = .imported
        }

        // Create job directly, bypassing duplicate detection in addJob()
        var job = TranscriptionJob(
            audioFilePath: filePath,
            fileName: recording.fileName,
            source: source,
            priority: priority
        )
        job.existingRecordingId = recordingId

        // Set model from current settings
        let modelSettings = GlobalModelSettings.shared
        switch modelSettings.transcriptionBackend {
        case .whisper:
            job.requiredModel = modelSettings.selectedWhisperVariant?.displayName
        case .llm:
            job.requiredModel = modelSettings.selectedLLMEngine == .gemma
                ? modelSettings.selectedGemmaTranscriptionModel
                : modelSettings.selectedVoxtralTranscriptionModel
        case .vibeVoice:
            job.requiredModel = modelSettings.selectedVibeVoiceQuantization.repositoryID
        }

        job.runSettings = (runSettings ?? .defaultSettings).snapshottingEngineIfNeeded()

        if let attributes = try? FileManager.default.attributesOfItem(atPath: filePath) {
            job.fileSize = attributes[FileAttributeKey.size] as? Int64
        }

        jobs.append(job)
        persistJob(job)
        logger.info("[QueueManager] Added re-transcription job for recording \(recordingId) with priority \(priority.rawValue)")

        if !isProcessing && !isPaused {
            startProcessing()
        }

        return job
    }

    /// Re-queue every recording that has no transcript (failed/empty, "No transcript available") at
    /// high priority. Returns how many were queued. With the empty-segment fix, long files that
    /// previously failed on a single silent chunk now succeed on re-run.
    @discardableResult
    func requeueEmptyRecordings() -> Int {
        let empties: [Recording]
        do {
            empties = try GRDBRecordingRepository().getRecordingsWithoutTranscript()
        } catch {
            logger.error("[QueueManager] Failed to load empty recordings: \(error)")
            return 0
        }
        var queued = 0
        for rec in empties where addRetranscribeJob(recording: rec) != nil {
            queued += 1
        }
        logger.info("[QueueManager] Re-queued \(queued)/\(empties.count) empty recordings")
        return queued
    }

    /// Count recordings with no transcript (for surfacing a "Re-queue Empties (N)" affordance).
    func emptyRecordingCount() -> Int {
        (try? GRDBRecordingRepository().getRecordingsWithoutTranscript().count) ?? 0
    }

    /// Add a job and wait for it to complete
    /// Returns the completed transcription item, result, and recording ID
    func addJobAndWait(
        audioFile: String,
        fileName: String? = nil,
        source: TranscriptionItem.TranscriptionSource = .recording,
        priority: TranscriptionJob.Priority = .normal,
        requiredModel: String? = nil,
        runSettings: RunSettings? = nil,
        timeout: TimeInterval = 300 // 5 minutes default
    ) async -> (TranscriptionItem, TranscriptionResult?, Int64?) {
        
        // Add the job with specified priority
        let job = addJob(
            audioFile: audioFile,
            fileName: fileName,
            source: source,
            priority: priority,
            requiredModel: requiredModel,
            runSettings: runSettings
        )
        
        let jobId = job.id
        let startTime = Date()
        
        // Poll for completion
        while Date().timeIntervalSince(startTime) < timeout {
            // Check job status
            if let currentJob = jobs.first(where: { $0.id == jobId }) {
                switch currentJob.status {
                case .completed:
                    // Get the transcription result from the job
                    let transcriptionItem = TranscriptionItem(
                        fileName: currentJob.fileName,
                        filePath: currentJob.audioFilePath,
                        transcript: currentJob.transcript ?? "",
                        language: "auto-detected",
                        duration: currentJob.duration ?? 0,
                        fileSize: currentJob.fileSize ?? 0,
                        createdDate: currentJob.createdAt,
                        transcribedDate: currentJob.completedAt ?? Date(),
                        source: currentJob.source,
                        status: .completed,
                        error: nil
                    )
                    
                    // Return the actual TranscriptionResult and recordingId stored in the job
                    return (transcriptionItem, currentJob.transcriptionResult, currentJob.recordingId)
                    
                case .failed, .cancelled:
                    // Return failed item
                    let transcriptionItem = TranscriptionItem(
                        fileName: currentJob.fileName,
                        filePath: currentJob.audioFilePath,
                        transcript: "",
                        language: "auto-detected",
                        duration: currentJob.duration ?? 0,
                        fileSize: currentJob.fileSize ?? 0,
                        createdDate: currentJob.createdAt,
                        transcribedDate: Date(),
                        source: currentJob.source,
                        status: .failed,
                        error: currentJob.error
                    )
                    return (transcriptionItem, nil, nil)
                    
                default:
                    // Still processing, wait a bit
                    try? await Task.sleep(for: .milliseconds(250))
                }
            } else {
                // Job disappeared? This shouldn't happen
                logger.error("[QueueManager] Job \(jobId) disappeared from queue")
                break
            }
        }
        
        // Timeout occurred
        let transcriptionItem = TranscriptionItem(
            fileName: fileName ?? URL(fileURLWithPath: audioFile).lastPathComponent,
            filePath: audioFile,
            transcript: "",
            language: "auto-detected",
            duration: 0,
            fileSize: 0,
            createdDate: Date(),
            transcribedDate: Date(),
            source: source,
            status: .failed,
            error: "Transcription timeout after \(Int(timeout)) seconds"
        )
        
        return (transcriptionItem, nil, nil)
    }
    
    /// Add multiple jobs to the queue
    func addBatchJobs(
        audioFiles: [(path: String, name: String)],
        source: TranscriptionItem.TranscriptionSource = .voiceMemos,
        priority: TranscriptionJob.Priority = .normal,
        runSettings: RunSettings? = nil
    ) -> [TranscriptionJob] {
        
        let newJobs = audioFiles.map { file in
            addJob(audioFile: file.path, fileName: file.name, source: source, priority: priority, runSettings: runSettings)
        }
        
        logger.info("[QueueManager] Added \(newJobs.count) jobs to queue")
        return newJobs
    }
    
    /// Cancel a specific job
    func cancelJob(_ jobId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        
        if jobs[index].status == .processing {
            // Cancel current transcription if it's the active job
            // Cancel current transcription
        // UnifiedTranscriptionManager doesn't have a direct cancel, but we can cancel the task
            jobs[index].status = .cancelled
            persistJob(jobs[index])
        } else {
            let cancelled = jobs.remove(at: index)
            deletePersistedJob(cancelled.id)
        }

        logger.info("[QueueManager] Cancelled job: \(jobId)")
    }
    
    /// Cancel all pending jobs
    func cancelAllPendingJobs() {
        for index in jobs.indices {
            if jobs[index].status == .pending {
                jobs[index].status = .cancelled
            }
        }
        logger.info("[QueueManager] Cancelled all pending jobs")
    }
    
    /// Retry a failed job
    func retryJob(_ jobId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }),
              jobs[index].canRetry else { return }
        
        jobs[index].status = .pending
        jobs[index].retryCount += 1
        jobs[index].error = nil
        logger.info("[QueueManager] Retrying job: \(jobs[index].fileName) (attempt \(jobs[index].retryCount + 1))")
        
        if !isProcessing {
            startProcessing()
        }
    }
    
    /// Clear completed jobs from the queue
    func clearCompletedJobs() {
        jobs.removeAll { $0.status == .completed }
        logger.info("[QueueManager] Cleared completed jobs")
    }
    
    /// Clear all jobs
    func clearAllJobs() {
        if isProcessing {
            cancelAllPendingJobs()
            // Cancel current transcription
        // UnifiedTranscriptionManager doesn't have a direct cancel, but we can cancel the task
        }
        jobs.removeAll()
        currentJob = nil
        isProcessing = false
        logger.info("[QueueManager] Cleared all jobs")
    }
    
    /// Alias for clearAllJobs for consistency
    func clearQueue() {
        clearAllJobs()
    }
    
    /// Move a job up in the queue
    func moveJobUp(_ jobId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }),
              jobs[index].status == .pending,
              index > 0 else { return }
        
        // Find the previous pending job
        for i in (0..<index).reversed() {
            if jobs[i].status == .pending {
                jobs.swapAt(index, i)
                break
            }
        }
    }
    
    /// Move a job down in the queue
    func moveJobDown(_ jobId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }),
              jobs[index].status == .pending,
              index < jobs.count - 1 else { return }
        
        // Find the next pending job
        for i in (index + 1)..<jobs.count {
            if jobs[i].status == .pending {
                jobs.swapAt(index, i)
                break
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func handleJobError(at index: Int, error: Error) async {
        let job = jobs[index]
        
        // Collect comprehensive diagnostics
        // Determine backend based on model or global settings
        let backend = GlobalModelSettings.shared.transcriptionBackend
        let diagnostics = TranscriptionDiagnostics.shared.collectDiagnostics(
            for: job.audioFilePath,
            modelPath: job.requiredModel,
            backend: backend,
            error: error
        )
        
        // Log formatted diagnostics
        let diagnosticsString = TranscriptionDiagnostics.shared.formatDiagnostics(diagnostics)
        logger.error("[QueueManager] \(diagnosticsString)")
        
        // Also log individual important details
        logger.error("[QueueManager] === JOB FAILURE SUMMARY ===")
        logger.error("[QueueManager] Job ID: \(job.id)")
        logger.error("[QueueManager] File: \(job.fileName)")
        logger.error("[QueueManager] Path: \(job.audioFilePath)")
        logger.error("[QueueManager] Backend: \(backend.rawValue)")
        logger.error("[QueueManager] Model: \(job.requiredModel ?? "none")")
        logger.error("[QueueManager] Error: \(error)")
        logger.error("[QueueManager] Retry Count: \(job.retryCount)/\(job.maxRetries)")
        
        // Store diagnostics in job for persistence
        if let jsonData = try? JSONSerialization.data(withJSONObject: diagnostics, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            jobs[index].errorDiagnostics = jsonString
        }
        
        logger.error("[QueueManager] === END JOB FAILURE SUMMARY ===")
        
        // Check if this is a model not found error
        if case TranscriptionError.modelNotFound = error {
            // Model not available - should have been caught earlier, but handle it here too
            logger.warning("[QueueManager] Model not found for job: \(jobs[index].fileName)")
            
            // Mark job as waiting for model
            jobs[index].status = .waitingForModel
            jobs[index].error = "Model not available"
            
            // Try to trigger model download using VoxtralModelManager
            if let requiredModel = jobs[index].requiredModel {
                Task {
                    do {
                        try await modelManager.downloadModel(requiredModel)
                        // Model download initiated via UnifiedDownloadQueue
                        if let task = downloadQueue.downloadTasks.first(where: { 
                            $0.modelId.contains(requiredModel) 
                        }) {
                            jobs[index].modelDownloadId = task.id.uuidString
                            logger.info("[QueueManager] Triggered model download for waiting job: \(requiredModel)")
                        }
                    } catch {
                        logger.error("[QueueManager] Failed to trigger model download: \(error)")
                    }
                }
            }
            return
        }
        
        jobs[index].status = .failed
        jobs[index].completedAt = Date()
        
        // Store detailed error information
        var errorDetails = "Error: \(error)\n"
        errorDetails += "Type: \(type(of: error))\n"
        errorDetails += "Time: \(Date())\n"
        errorDetails += "File: \(jobs[index].audioFilePath)\n"
        errorDetails += "Model: \(jobs[index].requiredModel ?? "none")\n"
        errorDetails += "Backend: \(backend.rawValue)\n"
        
        jobs[index].error = errorDetails
        
        logger.error("[QueueManager] Failed job: \(jobs[index].fileName)")
        logger.error("[QueueManager] Error details stored: \(errorDetails)")
        
        // Determine if we should retry based on error type
        let shouldRetry = shouldRetryForError(error)
        
        if shouldRetry && jobs[index].canRetry {
            // Calculate exponential backoff delay
            let baseDelay: TimeInterval = 2.0 // 2 seconds base
            let maxDelay: TimeInterval = 60.0 // 60 seconds max
            let retryDelay = min(baseDelay * pow(2.0, Double(jobs[index].retryCount)), maxDelay)
            
            logger.info("[QueueManager] Will retry job \(jobs[index].fileName) after \(Int(retryDelay)) seconds (attempt \(jobs[index].retryCount + 1)/\(jobs[index].maxRetries))")
            
            // Schedule retry after delay
            Task {
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                
                // Reset job for retry
                if let currentIndex = jobs.firstIndex(where: { $0.id == jobs[index].id }) {
                    jobs[currentIndex].status = .pending
                    jobs[currentIndex].retryCount += 1
                    jobs[currentIndex].error = nil
                    jobs[currentIndex].startedAt = nil
                    jobs[currentIndex].completedAt = nil
                    jobs[currentIndex].progressMessage = "Retrying (attempt \(jobs[currentIndex].retryCount + 1))..."
                    
                    logger.info("[QueueManager] Retrying job: \(jobs[currentIndex].fileName)")
                    
                    // Restart processing if needed
                    if !isProcessing {
                        startProcessing()
                    }
                }
            }
        } else {
            // Send failure notification
            NotificationManager.shared.sendCompletionNotification(for: jobs[index])
            logger.error("[QueueManager] Job permanently failed: \(jobs[index].fileName) - No more retries")
        }
    }
    
    private func shouldRetryForError(_ error: Error) -> Bool {
        // Determine if error is retryable
        let errorString = error.localizedDescription.lowercased()
        
        // Retryable errors
        if errorString.contains("timeout") ||
           errorString.contains("process failed") ||
           errorString.contains("signal") ||
           errorString.contains("terminated") ||
           errorString.contains("memory") ||
           errorString.contains("network") {
            return true
        }
        
        // Non-retryable errors
        if errorString.contains("not found") ||
           errorString.contains("invalid") ||
           errorString.contains("unsupported") ||
           errorString.contains("permission") ||
           errorString.contains("disk space") {
            return false
        }
        
        // Default to retry for unknown errors
        return true
    }
    
    private func startProcessing() {
        guard !isProcessing else { return }
        
        isProcessing = true
        
        // Start the worker pool
        startWorkers()
    }

    /// Start the worker pool without rewriting job states. Used by durable schedules after an app
    /// relaunch; crash recovery has already converted interrupted work back to pending.
    func ensureProcessingStarted() {
        if !isProcessing {
            startProcessing()
        }
    }
    
    
    private func handleModelDownload(for index: Int, model: String) async {
        logger.info("[QueueManager] Model not available: \(model), triggering download")
        
        jobs[index].status = .waitingForModel
        jobs[index].progressMessage = "Downloading model..."
        persistJob(jobs[index])
        
        do {
            try await modelManager.downloadModel(model)
            // Model downloaded, mark job as pending again
            jobs[index].status = .pending
            persistJob(jobs[index])
        } catch {
            logger.error("[QueueManager] Failed to download model: \(error)")
            jobs[index].status = .failed
            jobs[index].error = "Failed to download model: \(error.localizedDescription)"
            persistJob(jobs[index])
        }
    }
    
    // Old processQueue method removed - now handled by workers
    private func processQueue_removed() async {
        while !pendingJobs.isEmpty {
            guard !Task.isCancelled else { break }
            
            // Get next job
            guard let nextJob = pendingJobs.first,
                  let index = jobs.firstIndex(where: { $0.id == nextJob.id }) else {
                break
            }
            
            // Check if required model is available
            let requiredModel = jobs[index].requiredModel ?? VoxtralConfiguration.defaultModel
            
            if !modelManager.isModelDownloaded(requiredModel) {
                // Model not available, trigger download
                logger.info("[QueueManager] Model not available for job: \(jobs[index].fileName), downloading: \(requiredModel)")
                logger.info("[QueueManager] Model \(requiredModel) not found, triggering automatic download...")
                
                // Update job status
                jobs[index].status = .waitingForModel
                jobs[index].progressMessage = "Downloading model..."
                
                // Request model download via VoxtralModelManager
                Task {
                    do {
                        try await modelManager.downloadModel(requiredModel)
                        // Find the download task that was created
                        if let task = downloadQueue.downloadTasks.first(where: { 
                            $0.modelId.contains(requiredModel) 
                        }) {
                            jobs[index].modelDownloadId = task.id.uuidString
                        }
                    } catch {
                        logger.error("[QueueManager] Failed to trigger model download: \(error)")
                        jobs[index].status = .failed
                        jobs[index].error = "Failed to download model: \(error.localizedDescription)"
                    }
                }
                
                logger.info("[QueueManager] Model download requested for: \(requiredModel)")
                logger.info("[QueueManager] Model download started for: \(requiredModel)")
                
                // Skip to next job
                continue
            }
            
            // Update job status
            var job = jobs[index]
            job.status = .processing
            job.startedAt = Date()
            job.progressPhase = .waiting
            job.progress = 0.0
            jobs[index] = job
            currentJob = job
            processingCount += 1
            
            logger.info("[QueueManager] Processing job: \(jobs[index].fileName)")
            
            do {
                // Perform transcription based on job type
                let transcript: String
                
                if jobs[index].isPromptTest, let config = jobs[index].promptConfig {
                    // Handle prompt test job
                    logger.info("[QueueManager] Running prompt test: \(config.name)")
                    
                    let tester = VoxtralPromptTester.shared
                    let originalPath = tester.selectedAudioPath
                    tester.selectedAudioPath = jobs[index].audioFilePath
                    
                    let result = try await tester.runSingleTest(
                        config,
                        maxChunks: 3,
                        modelKey: requiredModel,
                        progressCallback: { [weak self] phase, progress, message in
                            Task { @MainActor in
                                guard let self = self,
                                      let currentIndex = self.jobs.firstIndex(where: { $0.id == self.jobs[index].id }) else { return }
                                
                                // Get a mutable copy of the job
                                var job = self.jobs[currentIndex]
                                
                                // Update job progress fields
                                job.progressPhase = phase
                                job.progress = progress
                                job.progressMessage = message
                                
                                // Parse chunk info from message if available
                                if phase == .transcribingChunks {
                                    // Extract chunk numbers from message like "Processing chunk 2 of 5" or "Completed chunk 2 of 5"
                                    if message.contains("chunk") {
                                        let components = message.components(separatedBy: .whitespaces)
                                        if let chunkIndex = components.firstIndex(of: "chunk"),
                                           chunkIndex + 2 < components.count,
                                           let current = Int(components[chunkIndex + 1]),
                                           let ofIndex = components.firstIndex(of: "of"),
                                           ofIndex + 1 < components.count,
                                           let total = Int(components[ofIndex + 1]) {
                                            job.totalChunks = total
                                            
                                            // Check if this is a completion message
                                            if message.contains("Completed") {
                                                job.completedChunks = current
                                                job.currentChunkProgress = 0.0
                                            } else {
                                                // Currently processing this chunk
                                                job.completedChunks = max(0, current - 1)
                                                job.currentChunkProgress = 0.5  // Show 50% progress for current chunk
                                            }
                                        }
                                    }
                                }
                                
                                // Reassign the job to trigger @Published update
                                self.jobs[currentIndex] = job
                                
                                // Also update currentJob if this is the current one
                                if self.currentJob?.id == job.id {
                                    self.currentJob = job
                                }
                                
                                self.logger.debug("[QueueManager] Progress update - Phase: \(phase.rawValue), Progress: \(Int(progress * 100))%, Message: \(message)")
                            }
                        },
                        runSettings: jobs[index].runSettings
                    )
                    
                    // Restore original path
                    tester.selectedAudioPath = originalPath
                    
                    transcript = result.transcript
                    
                    // Store test result in job metadata
                    jobs[index].transcript = transcript
                    
                } else {
                    // Regular transcription - pass the required model
                    // Update progress phases for regular transcription
                    var job = jobs[index]
                    job.progressPhase = .preparingAudio
                    job.progress = 0.05
                    job.progressMessage = "Preparing audio file..."
                    jobs[index] = job
                    if currentJob?.id == job.id {
                        currentJob = job
                    }
                    
                    // Use UnifiedTranscriptionManager for transcription
                    let (transcriptionItem, transcriptionResult, recordingId) = await unifiedManager.transcribeWithResult(
                        audioFile: jobs[index].audioFilePath,
                        fileName: jobs[index].fileName,
                        source: jobs[index].source,
                        runSettings: jobs[index].runSettings,
                        progressHandler: { [weak self] phase, progress, message, totalChunks, completedChunks in
                            await MainActor.run {
                                guard let self = self,
                                      let currentIndex = self.jobs.firstIndex(where: { $0.id == self.jobs[index].id }) else { return }
                                
                                // Get a mutable copy of the job
                                var job = self.jobs[currentIndex]
                                
                                // Update job progress fields
                                job.progressPhase = phase
                                job.progress = progress
                                job.progressMessage = message
                                
                                // Update chunk counts if provided
                                if let total = totalChunks {
                                    job.totalChunks = total
                                }
                                if let completed = completedChunks {
                                    job.completedChunks = completed
                                }
                                
                                // Parse chunk info from message if not provided explicitly
                                if phase == .transcribingChunks && totalChunks == nil {
                                    // Extract chunk numbers from message like "Chunk 28/39: Transcribing Speaker 2..."
                                    if message.contains("Chunk") && message.contains("/") {
                                        let components = message.components(separatedBy: CharacterSet(charactersIn: ":/"))
                                        if components.count >= 2,
                                           let chunkStr = components.first?.replacingOccurrences(of: "Chunk", with: "").trimmingCharacters(in: .whitespaces),
                                           let current = Int(chunkStr),
                                           let total = Int(components[1].trimmingCharacters(in: .whitespaces)) {
                                            job.totalChunks = total
                                            job.completedChunks = max(0, current - 1)
                                            job.currentChunkProgress = 0.5
                                        }
                                    }
                                }
                                
                                // Reassign the job to trigger @Published update
                                self.jobs[currentIndex] = job
                                
                                // Also update currentJob if this is the current one
                                if self.currentJob?.id == job.id {
                                    self.currentJob = job
                                }
                                
                                self.logger.debug("[QueueManager] Progress update - Phase: \(phase.rawValue), Progress: \(Int(progress * 100))%, Message: \(message)")
                            }
                        }
                    )
                    
                    transcript = transcriptionItem.transcript
                    
                    // Store recording ID and speaker detection results
                    if recordingId != nil {
                        // Update job with recording ID for future reference
                        // Model tracking handled by UnifiedTranscriptionManager ?? requiredModel
                    }
                    
                    // Handle speaker detection if needed
                    if let result = transcriptionResult,
                       recordingId != nil,
                       (result.detectedSpeakerCount ?? 0) > 1 {
                        // Speaker review will be handled by the original caller
                        logger.info("[QueueManager] Multiple speakers detected for \(jobs[index].fileName): \(result.detectedSpeakerCount ?? 0)")
                    }
                    
                    // Mark as finalizing
                    job = jobs[index]
                    job.progressPhase = .finalizing
                    job.progress = 0.95
                    job.progressMessage = "Finalizing transcription..."
                    jobs[index] = job
                    if currentJob?.id == job.id {
                        currentJob = job
                    }
                }
                
                // Update job with results
                jobs[index].status = .completed
                jobs[index].completedAt = Date()
                jobs[index].transcript = transcript
                // Model tracking handled by UnifiedTranscriptionManager
                
                // Save to history
                await saveToHistory(job: jobs[index], transcript: transcript)
                
                logger.info("[QueueManager] Completed job: \(jobs[index].fileName)")
                
                // Send notification
                NotificationManager.shared.sendCompletionNotification(for: jobs[index])
                jobCompleted.send(jobs[index])
                
            } catch {
                logger.error("[QueueManager] === TRANSCRIPTION CATCH BLOCK ===")
                logger.error("[QueueManager] Caught error during transcription: \(error)")
                logger.error("[QueueManager] Job: \(jobs[index].fileName)")
                logger.error("[QueueManager] === END CATCH BLOCK ===")
                
                // Handle error with smart retry logic
                await handleJobError(at: index, error: error)
            }
            
            // Update global progress
            updateGlobalProgress()
            
            // Small delay between jobs and yield to prevent blocking
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            await Task.yield() // Allow other tasks to run
        }
        
        // Queue processing complete
        isProcessing = false
        currentJob = nil
        // Handled by processingTasks dictionary
        processingCount = 0
        logger.info("[QueueManager] Queue processing complete")
    }
    
    private func updateCurrentJobProgress(_ progress: Double) {
        guard let currentJob = currentJob,
              let index = jobs.firstIndex(where: { $0.id == currentJob.id }) else { return }
        
        jobs[index].progress = progress
        updateGlobalProgress()
    }
    
    private func updateCurrentJobStatus(_ status: String) {
        guard let currentJob = currentJob,
              let index = jobs.firstIndex(where: { $0.id == currentJob.id }) else { return }
        
        jobs[index].progressMessage = status
    }
    
    private func updateGlobalProgress() {
        let totalJobs = Double(jobs.count)
        guard totalJobs > 0 else {
            globalProgress = 0
            return
        }
        
        let completedCount = Double(completedJobs.count)
        // Use detailedProgress for more accurate calculation
        let activeProgress = activeJobs.reduce(0.0) { $0 + $1.detailedProgress }
        
        globalProgress = (completedCount + activeProgress) / totalJobs
    }
    
    private func saveToHistory(job: TranscriptionJob, transcript: String) async {
        // Create TranscriptionItem for history
        let _ = TranscriptionItem(
            fileName: job.fileName,
            filePath: job.audioFilePath,
            transcript: transcript,
            language: "auto-detected",
            duration: job.duration ?? 0,
            fileSize: job.fileSize ?? 0,
            createdDate: job.createdAt,
            transcribedDate: Date(),
            source: job.source,
            status: .completed,
            error: nil
        )
        
        // Save to history using the UnifiedTranscriptionManager's history saving
        // This will be handled by UnifiedTranscriptionManager automatically
    }
    
    // MARK: - Monitoring
    
    private var monitoringTask: Task<Void, Never>?
    
    /// Start the automatic monitoring task
    private func startMonitoringTask() {
        monitoringTask?.cancel()
        monitoringTask = Task {
            while !Task.isCancelled {
                // Wait 30 seconds between checks
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                
                guard !Task.isCancelled else { break }
                
                await MainActor.run {
                    // Clean up stuck jobs automatically
                    self.cleanupStuckJobs()
                    
                    // Remove completed jobs from the active array
                    let completedToRemove = self.jobs.filter { $0.status == .completed }
                    for job in completedToRemove {
                        if let index = self.jobs.firstIndex(where: { $0.id == job.id }) {
                            self.jobs.remove(at: index)
                            // Note: Don't delete from database, keep for history
                        }
                    }
                    
                    if !completedToRemove.isEmpty {
                        self.logger.info("[QueueManager] Auto-removed \(completedToRemove.count) completed jobs from active queue")
                    }
                    
                    // Update counts
                    self.processingCount = self.jobs.filter { $0.status == .processing }.count
                    self.updateGlobalProgress()
                }
            }
        }
    }
    
    deinit {
        monitoringTask?.cancel()
    }
    
    // MARK: - Cleanup Methods
    
    /// Clean up jobs that are stuck in processing state
    func cleanupStuckJobs() {
        let stuckJobs = jobs.filter { job in
            job.status == .processing && 
            (job.lastHeartbeat == nil || Date().timeIntervalSince(job.lastHeartbeat!) > 60)
        }
        
        if !stuckJobs.isEmpty {
            logger.warning("[QueueManager] Found \(stuckJobs.count) stuck jobs, resetting to pending")
            for job in stuckJobs {
                if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[index].status = .pending
                    jobs[index].workerId = nil
                    jobs[index].lastHeartbeat = nil
                    jobs[index].startedAt = nil
                    jobs[index].progress = 0
                    persistJob(jobs[index])
                }
            }
            
            // Clear current job if it's stuck
            if let current = currentJob, stuckJobs.contains(where: { $0.id == current.id }) {
                currentJob = nil
            }
        }
        
        // Update counts
        processingCount = jobs.filter { $0.status == .processing }.count
        updateGlobalProgress()
    }
    
    /// Manually refresh queue state (can be called from UI)
    func refreshQueueState() {
        logger.info("[QueueManager] Manually refreshing queue state")
        
        // Clean up stuck jobs
        cleanupStuckJobs()
        
        // Remove completed jobs that shouldn't be in the active queue
        let completedToRemove = jobs.filter { $0.status == .completed }
        for job in completedToRemove {
            if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs.remove(at: index)
                deletePersistedJob(job.id)
            }
        }
        
        if !completedToRemove.isEmpty {
            logger.info("[QueueManager] Removed \(completedToRemove.count) completed jobs from active queue")
        }
        
        // Update all counts
        processingCount = jobs.filter { $0.status == .processing }.count
        updateGlobalProgress()
        updateActiveWorkerCount()
    }
    
    /// Clean up duplicate jobs in the queue
    func cleanupDuplicateJobs() {
        var seenPaths = Set<String>()
        var duplicateIndices: [Int] = []
        
        // Find duplicate jobs based on audio file path
        for (index, job) in jobs.enumerated() {
            if seenPaths.contains(job.audioFilePath) {
                // This is a duplicate
                duplicateIndices.append(index)
                logger.info("[QueueManager] Found duplicate job: \(job.fileName)")
            } else {
                seenPaths.insert(job.audioFilePath)
            }
        }
        
        // Remove duplicates (in reverse order to maintain indices)
        for index in duplicateIndices.reversed() {
            let removedJob = jobs.remove(at: index)
            deletePersistedJob(removedJob.id)
        }
        
        if !duplicateIndices.isEmpty {
            logger.info("[QueueManager] Removed \(duplicateIndices.count) duplicate jobs from queue")
        }
        
        // Also remove completed jobs that shouldn't be in the queue
        let completedJobs = jobs.filter { $0.status == .completed }
        for job in completedJobs {
            if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs.remove(at: index)
                deletePersistedJob(job.id)
            }
        }
        
        if !completedJobs.isEmpty {
            logger.info("[QueueManager] Removed \(completedJobs.count) completed jobs from queue")
        }
    }
    
    // MARK: - Persistence Methods
    
    /// Load persisted jobs from database
    private func loadPersistedJobs() {
        do {
            let persistedJobs = try database.readQueue { db in
                try PersistentTranscriptionJob.fetchAll(db)
            }
            
            // Convert to TranscriptionJob objects
            let loadedJobs = persistedJobs.compactMap { $0.toTranscriptionJob() }
            
            // Separate completed and failed jobs from active ones
            let completedOrFailedJobs = loadedJobs.filter { 
                $0.status == TranscriptionJob.JobStatus.completed || 
                $0.status == TranscriptionJob.JobStatus.failed 
            }
            
            // Only keep active jobs in memory
            jobs = loadedJobs.filter { 
                $0.status != TranscriptionJob.JobStatus.completed && 
                $0.status != TranscriptionJob.JobStatus.failed 
            }
            
            // Immediately delete completed/failed jobs from persistence — they're done
            for job in completedOrFailedJobs {
                deletePersistedJob(job.id)
            }

            if !completedOrFailedJobs.isEmpty {
                logger.info("[QueueManager] Cleaned up \(completedOrFailedJobs.count) completed/failed jobs from persistence")
            }
            
            logger.info("[QueueManager] Loaded \(jobs.count) active jobs from persistence")
        } catch {
            logger.error("[QueueManager] Failed to load persisted jobs: \(error)")
        }
    }
    
    /// Recover jobs that were interrupted when app crashed
    private func recoverInterruptedJobs() {
        do {
            let interruptedCount = try database.writeQueue { db in
                try PersistentTranscriptionJob.markStaleJobsAsInterrupted(db)
            }
            
            if interruptedCount > 0 {
                logger.info("[QueueManager] Recovered \(interruptedCount) interrupted jobs")
                
                // Reload jobs to get the updated status
                loadPersistedJobs()
                
                // Mark interrupted jobs as pending so they can be retried
                for index in jobs.indices {
                    if jobs[index].status == .interrupted {
                        jobs[index].status = .pending
                        jobs[index].error = nil
                        persistJob(jobs[index])
                    }
                }
            }
        } catch {
            logger.error("[QueueManager] Failed to recover interrupted jobs: \(error)")
        }
    }
    
    /// Persist a job to database
    private func persistJob(_ job: TranscriptionJob) {
        do {
            let persistentJob = PersistentTranscriptionJob(from: job)
            
            try database.writeQueue { db in
                try persistentJob.save(db)
            }
        } catch {
            logger.error("[QueueManager] Failed to persist job \(job.fileName): \(error)")
        }
    }
    
    /// Delete a job from persistence
    private func deletePersistedJob(_ jobId: UUID) {
        do {
            try database.writeQueue { db in
                try PersistentTranscriptionJob
                    .filter(PersistentTranscriptionJob.Columns.id == jobId.uuidString)
                    .deleteAll(db)
            }
        } catch {
            logger.error("[QueueManager] Failed to delete persisted job: \(error)")
        }
    }
    
    /// Get file names of all jobs currently in the transcription queue (for duplicate checking)
    func getQueuedFileNames() -> Set<String> {
        do {
            return try database.readQueue { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT file_name FROM transcription_queue
                        WHERE status NOT IN ('Completed', 'Failed', 'Cancelled')
                    """
                )
                var names = Set<String>()
                for row in rows {
                    let name: String? = row["file_name"]
                    if let name { names.insert(name) }
                }
                return names
            }
        } catch {
            logger.error("[QueueManager] Failed to get queued file names: \(error)")
            return Set(jobs.map { $0.fileName })
        }
    }

    /// Start heartbeat timer for crash detection
    private func startHeartbeatTimer() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            self?.updateHeartbeats()
        }
    }
    
    /// Update heartbeats for all active jobs
    private func updateHeartbeats() {
        let activeJobs = jobs.filter { $0.status == .processing }
        
        for job in activeJobs {
            do {
                try database.writeQueue { db in
                    try PersistentTranscriptionJob.updateHeartbeat(
                        db,
                        jobId: job.id.uuidString,
                        workerId: job.workerId ?? "main"
                    )
                }
            } catch {
                logger.error("[QueueManager] Failed to update heartbeat for job \(job.fileName): \(error)")
            }
        }
    }
    
    // MARK: - Worker Management
    
    /// Initialize the worker pool
    private func initializeWorkerPool() {
        // Create workers based on CPU cores
        let workerCount = maxConcurrentJobs
        
        for i in 1...workerCount {
            let worker = TranscriptionWorker(id: "Worker-\(i)", queueManager: self)
            workers.append(worker)
        }
        
        logger.info("[QueueManager] Initialized \(workerCount) workers")
    }
    
    /// Start all workers
    private func startWorkers() {
        if workers.isEmpty {
            initializeWorkerPool()
        }
        
        for worker in workers {
            worker.start()
        }
        
        // Update active worker count
        updateActiveWorkerCount()
        
        logger.info("[QueueManager] Started \(workers.count) workers")
    }
    
    /// Update the active worker count based on actual worker states
    private func updateActiveWorkerCount() {
        let activeCount = workers.filter { $0.currentJob != nil }.count
        activeWorkers = activeCount
    }
    
    /// Stop all workers
    private func stopWorkers() {
        for worker in workers {
            worker.stop()
        }
        
        logger.info("[QueueManager] Stopped all workers")
    }
    
    /// Get next pending job for a worker (thread-safe)
    func getNextPendingJob() -> TranscriptionJob? {
        guard !isPaused else { return nil }

        // GPU gate check — don't start new jobs if higher-priority consumer is active
        guard GPUResourceManager.shared.canProceed(.transcription) else { return nil }

        // Scheduled nightly jobs remain durable and visible during the day, but workers may only
        // claim them inside their snapshotted window. A job already processing is allowed to finish.
        guard let candidate = pendingJobs.first(where: {
            $0.runSettings.schedulingPolicy?.allows() ?? true
        }) else {
            return nil
        }
        if let retryAt = memoryRetryNotBefore[candidate.id], retryAt > Date() {
            return nil
        }
        let profile = TranscriptionResourceProfile.forSelection(
            candidate.runSettings.engineSelection
        )
        if let deferral = SystemMemoryGate.shared.transcriptionDeferral(
            profile: profile
        ) {
            setMemoryWaitingMessage(
                jobID: candidate.id,
                reason: deferral.reason
            )
            memoryRetryNotBefore[candidate.id] = Date().addingTimeInterval(
                deferral.retryAfter
            )
            return nil
        }
        memoryRetryNotBefore[candidate.id] = nil
        clearMemoryWaitingMessage(jobID: candidate.id)
        return candidate
    }

    private func setMemoryWaitingMessage(jobID: UUID, reason: String) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let message = "Waiting for safe memory · \(reason)"
        guard jobs[index].progressMessage != message else { return }
        jobs[index].progressPhase = .waiting
        jobs[index].progressMessage = message
        persistJob(jobs[index])
    }

    private func clearMemoryWaitingMessage(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[index].progressMessage.hasPrefix("Waiting for safe memory") else {
            return
        }
        jobs[index].progressMessage = ""
        persistJob(jobs[index])
    }
    
    /// Mark job as processing (called by worker)
    func markJobProcessing(_ jobId: UUID, workerId: String) async {
        await MainActor.run {
            if let index = jobs.firstIndex(where: { $0.id == jobId }) {
                jobs[index].status = .processing
                jobs[index].workerId = workerId
                jobs[index].startedAt = Date()
                jobs[index].lastHeartbeat = Date()
                persistJob(jobs[index])
                
                // Update current job if needed
                currentJob = jobs[index]
                
                // Update active worker count
                updateActiveWorkerCount()
                
                // Update processing count
                processingCount = jobs.filter { $0.status == .processing }.count
            }
        }
    }
    
    /// Mark job as completed (called by worker)
    func markJobCompleted(_ jobId: UUID, transcript: String, result: TranscriptionResult?, recordingId: Int64?) async {
        await MainActor.run {
            if let index = jobs.firstIndex(where: { $0.id == jobId }) {
                jobs[index].status = .completed
                jobs[index].transcript = transcript
                jobs[index].transcriptionResult = result  // Store the result
                jobs[index].recordingId = recordingId      // Store the recording ID
                jobs[index].completedAt = Date()
                jobs[index].checkpointData = nil  // Clear checkpoint on successful completion
                deletePersistedJob(jobs[index].id)  // Remove from DB — recording is saved to recordings table
                
                // Clear current job if this was it
                if currentJob?.id == jobId {
                    currentJob = nil
                }
                
                // Update active worker count
                updateActiveWorkerCount()
                
                // Update processing count
                processingCount = jobs.filter { $0.status == .processing }.count
                
                // Update global progress
                updateGlobalProgress()
                
                // Handle speaker detection
                if let result = result, let recordingId = recordingId {
                    let speakerCount = result.detectedSpeakerCount ?? 0
                    let embeddingCount = result.speakerEmbeddings?.count ?? 0
                    let hasMultipleSpeakers = speakerCount > 1 || embeddingCount > 1
                    
                    if hasMultipleSpeakers {
                        pendingSpeakerReviews.append((
                            recordingId: recordingId,
                            audioPath: jobs[index].audioFilePath,
                            result: result,
                            fileName: jobs[index].fileName
                        ))
                        
                        logger.info("[QueueManager] Added \(jobs[index].fileName) to speaker review queue")
                    }
                }
                
                // Send notification
                NotificationManager.shared.sendCompletionNotification(for: jobs[index])
                
                logger.info("[QueueManager] Job completed: \(jobs[index].fileName), removing from active queue")

                // If this was a meeting track, fold the mic + system pair into one normal recording
                // once both have transcribed (no-op until the sibling finishes).
                if let stamp = MeetingAssembler.stamp(fromFileName: jobs[index].fileName) {
                    Task.detached(priority: .utility) { _ = await MeetingAssembler.assembleIfReady(stamp: stamp) }
                }

                // Publish the final snapshot before removing it. Durable batch coordinators cannot
                // infer completion from `jobs` because successful work intentionally disappears.
                jobCompleted.send(jobs[index])

                // Remove completed job from active queue immediately
                // This prevents it from showing in the queue UI
                jobs.remove(at: index)
            }
        }
    }
    
    /// Update job progress (called by worker during processing)
    func updateJobProgress(
        _ jobId: UUID,
        phase: TranscriptionJob.ProgressPhase? = nil,
        progress: Double? = nil,
        message: String? = nil,
        totalChunks: Int? = nil,
        completedChunks: Int? = nil,
        currentChunkProgress: Double? = nil
    ) async {
        await MainActor.run {
            guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }
            
            if let phase = phase {
                jobs[index].progressPhase = phase
            }
            if let progress = progress {
                jobs[index].progress = progress
            }
            if let message = message {
                jobs[index].progressMessage = message
            }
            if let totalChunks = totalChunks {
                jobs[index].totalChunks = totalChunks
            }
            if let completedChunks = completedChunks {
                jobs[index].completedChunks = completedChunks
            }
            if let currentChunkProgress = currentChunkProgress {
                jobs[index].currentChunkProgress = currentChunkProgress
            }
            
            // Update heartbeat to show activity
            jobs[index].lastHeartbeat = Date()
            
            // Update global progress
            updateGlobalProgress()

            // Sync currentJob so queue list UI updates
            if self.currentJob?.id == jobId {
                self.currentJob = self.jobs[index]
            }
        }
    }

    /// Mark job as failed (called by worker)
    func markJobFailed(_ jobId: UUID, error: String) async {
        await MainActor.run {
            if let index = jobs.firstIndex(where: { $0.id == jobId }) {
                let job = jobs[index]
                
                logger.error("[QueueManager] === WORKER REPORTED FAILURE ===")
                logger.error("[QueueManager] Job: \(job.fileName)")
                logger.error("[QueueManager] Job ID: \(jobId)")
                logger.error("[QueueManager] Worker error: \(error)")
                logger.error("[QueueManager] File path: \(job.audioFilePath)")
                logger.error("[QueueManager] Model: \(job.requiredModel ?? "none")")
                logger.error("[QueueManager] === END WORKER FAILURE ===")
                
                jobs[index].status = .failed
                jobs[index].error = error
                jobs[index].completedAt = Date()
                persistJob(jobs[index])
                
                // Clear current job if this was it
                if currentJob?.id == jobId {
                    currentJob = nil
                }
                
                // Update active worker count
                updateActiveWorkerCount()
                
                // Update processing count
                processingCount = jobs.filter { $0.status == .processing }.count
                
                // Update global progress
                updateGlobalProgress()
                
                logger.error("[QueueManager] Job failed: \(jobs[index].fileName) - \(error)")
                jobFailed.send(jobs[index])
            }
        }
    }

    /// A model launch was proactively refused or an in-flight model was stopped as memory became
    /// unsafe. Preserve the job and retry budget; workers will claim it automatically when the
    /// strict admission check passes again.
    func deferJobForResources(_ jobId: UUID, reason: String) async {
        await MainActor.run {
            guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }
            jobs[index].status = .pending
            jobs[index].progress = 0
            jobs[index].progressPhase = .waiting
            jobs[index].progressMessage = "Waiting for safe memory · \(reason)"
            jobs[index].workerId = nil
            jobs[index].startedAt = nil
            jobs[index].lastHeartbeat = nil
            jobs[index].error = nil
            memoryRetryNotBefore[jobId] = Date().addingTimeInterval(30)
            persistJob(jobs[index])
            if currentJob?.id == jobId {
                currentJob = nil
            }
            processingCount = jobs.filter { $0.status == .processing }.count
            updateActiveWorkerCount()
            updateGlobalProgress()
            logger.warning(
                "[QueueManager] Deferred \(jobs[index].fileName) without consuming retry: \(reason)"
            )
        }
    }
    
    // MARK: - Checkpoint Management
    
    /// Create a checkpoint for a job in progress
    private func createCheckpoint(for job: TranscriptionJob) -> TranscriptionCheckpoint? {
        // Return existing checkpoint data if available (from incremental saves),
        // otherwise return an empty checkpoint
        if let existing = job.checkpointData, !existing.processedChunks.isEmpty {
            logger.info("[QueueManager] Using existing checkpoint for job: \(job.fileName) (\(existing.processedChunks.count) chunks)")
            return existing
        }
        return nil
    }

    /// Save incremental checkpoint data for a job (called after each VAD chunk completes)
    func saveCheckpoint(_ jobId: UUID, checkpoint: TranscriptionCheckpoint) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[index].checkpointData = checkpoint
        jobs[index].completedChunks = checkpoint.processedChunks.count
        persistJob(jobs[index])
        logger.info("[QueueManager] Saved checkpoint for \(jobs[index].fileName): \(checkpoint.processedChunks.count) chunks processed")
    }
    
    /// Resume a job from checkpoint — marks it as pending so workers pick it up.
    /// The actual resume logic (skipping completed chunks) is in WhisperService,
    /// which reads job.checkpointData via WhisperService.activeCheckpoint.
    private func resumeFromCheckpoint(_ job: TranscriptionJob) async {
        if let checkpoint = job.checkpointData, !checkpoint.processedChunks.isEmpty {
            logger.info("[QueueManager] Resuming job from checkpoint: \(job.fileName)")
            logger.info("[QueueManager] Checkpoint has \(checkpoint.processedChunks.count) processed chunks, will skip on next run")
        } else {
            logger.info("[QueueManager] No checkpoint for \(job.fileName), will restart from beginning")
        }

        // Mark as pending — worker will read checkpointData and pass to WhisperService
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index].status = .pending
            persistJob(jobs[index])
        }
    }
    
    // MARK: - Public Pause/Resume Methods
    
    /// Pause all processing
    func pauseAllProcessing() {
        isPaused = true
        
        // Stop all workers
        stopWorkers()
        
        // Pause all active jobs
        for index in jobs.indices {
            if jobs[index].status == .processing {
                jobs[index].status = .paused
                
                // Save checkpoint if transcription is in progress
                if let checkpoint = createCheckpoint(for: jobs[index]) {
                    jobs[index].checkpointData = checkpoint
                }
                
                persistJob(jobs[index])
            }
        }
        
        // Cancel all processing tasks
        processingTasks.values.forEach { $0.cancel() }
        processingTasks.removeAll()
        
        // Update active worker count
        updateActiveWorkerCount()
        
        logger.info("[QueueManager] All processing paused")
    }
    
    /// Resume all processing
    func resumeAllProcessing() {
        isPaused = false
        
        // Resume paused jobs
        for index in jobs.indices {
            if jobs[index].status == .paused {
                jobs[index].status = .pending
                persistJob(jobs[index])
            }
        }
        
        // Restart processing
        if !isProcessing {
            startProcessing()
        }

        logger.info("[QueueManager] All processing resumed")
    }

    /// Robustly (re)start processing. Recovers the stuck state where `isProcessing` stayed true
    /// after an interruption but no worker is actually running, which `startProcessing()`'s
    /// `guard !isProcessing` would otherwise refuse to fix. Safe to call anytime.
    func startOrResumeProcessing() {
        isPaused = false
        // Reset any jobs stuck mid-flight back to pending so a worker re-picks them.
        for index in jobs.indices where jobs[index].status == .processing
            || jobs[index].status == .paused
            || jobs[index].status == .interrupted {
            jobs[index].status = .pending
            persistJob(jobs[index])
        }
        // Clear the stuck flag so startProcessing isn't blocked, then (re)start the worker pool.
        isProcessing = false
        currentJob = nil
        startProcessing()
        logger.info("[QueueManager] startOrResumeProcessing: worker pool restarted")
    }
    
    /// Clean up completed jobs older than 7 days
    func cleanupOldJobs() {
        let cutoffDate = Date().addingTimeInterval(-7 * 24 * 60 * 60) // 7 days ago
        
        do {
            try database.writeQueue { db in
                try PersistentTranscriptionJob
                    .filter(PersistentTranscriptionJob.Columns.status == "completed")
                    .filter(PersistentTranscriptionJob.Columns.completedAt < cutoffDate)
                    .deleteAll(db)
            }
            
            logger.info("[QueueManager] Cleaned up old completed jobs")
        } catch {
            logger.error("[QueueManager] Failed to cleanup old jobs: \(error)")
        }
    }
}

// MARK: - TranscriptionWorker

/// Worker class for processing transcription jobs
class TranscriptionWorker {
    let id: String
    private(set) var isActive: Bool = false
    private(set) var currentJob: TranscriptionJob?
    private var workTask: Task<Void, Never>?
    
    weak var queueManager: TranscriptionQueueManager?
    
    init(id: String, queueManager: TranscriptionQueueManager) {
        self.id = id
        self.queueManager = queueManager
    }
    
    /// Start the worker to process jobs
    func start() {
        guard !isActive else { return }

        isActive = true
        // Use Task.detached to ensure worker never inherits @MainActor
        // (start() can be called from @MainActor contexts like startWorkers())
        workTask = Task.detached { [weak self] in
            while let self, self.isActive {
                // Check for cancellation
                if Task.isCancelled {
                    break
                }

                // Get next job from queue
                guard let nextJob = await self.queueManager?.getNextPendingJob() else {
                    // No jobs available, wait a bit
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                    continue
                }

                // Process the job
                await self.process(nextJob)

                // Add delay between jobs to allow GPU memory cleanup
                // Large models (3GB+) need more time to fully release GPU memory
                // This is especially important after failures
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            }

            self?.isActive = false
        }
    }
    
    /// Stop the worker
    func stop() {
        isActive = false
        workTask?.cancel()
        workTask = nil
        currentJob = nil
    }
    
    /// Process a single job
    private func process(_ job: TranscriptionJob) async {
        currentJob = job

        let resourceProfile = TranscriptionResourceProfile.forSelection(
            job.runSettings.engineSelection
        )
        if let deferral = SystemMemoryGate.shared.transcriptionDeferral(
            profile: resourceProfile
        ) {
            await queueManager?.deferJobForResources(
                job.id,
                reason: deferral.reason
            )
            currentJob = nil
            return
        }

        // Notify queue manager that this job is being processed
        await queueManager?.markJobProcessing(job.id, workerId: id)
        
        do {
            // Create progress callback for this job
            let progressCallback: (TranscriptionJob.ProgressPhase, Double, String, Int?, Int?) async -> Void = { [weak self] phase, progress, message, totalChunks, completedChunks in
                guard let self = self else { return }
                await self.queueManager?.updateJobProgress(
                    job.id,
                    phase: phase,
                    progress: progress,
                    message: message,
                    totalChunks: totalChunks,
                    completedChunks: completedChunks
                )
            }
            
            // Set up checkpoint on WhisperService so it can skip already-processed chunks
            let whisperService = WhisperService.shared
            whisperService.activeCheckpoint = job.checkpointData
            var runningCheckpoint = job.checkpointData ?? .empty

            whisperService.onVADChunkCompleted = { [weak self] vadIndex, chunks, offset in
                runningCheckpoint.processedChunks.append(vadIndex)
                runningCheckpoint.chunkTranscripts[vadIndex] = chunks.map {
                    TranscriptionCheckpoint.ChunkResult(
                        text: $0.text,
                        startTime: $0.startTime,
                        endTime: $0.endTime,
                        speaker: $0.speaker,
                        speakerUUID: $0.speakerUUID
                    )
                }
                runningCheckpoint.chunkOffsets[vadIndex] = offset
                runningCheckpoint.lastProcessedTime = Date()
                await self?.queueManager?.saveCheckpoint(job.id, checkpoint: runningCheckpoint)
            }

            // Acquire GPU — suspends until granted (a higher-priority search may briefly hold it).
            // false = this task was cancelled while waiting; bail without running or releasing.
            guard await GPUResourceManager.shared.acquire(.transcription) else {
                whisperService.activeCheckpoint = nil
                whisperService.onVADChunkCompleted = nil
                currentJob = nil
                return
            }
            // Safety net: guarantee the GPU is released even if a future early-return/throw is
            // added between here and the explicit release. transcription is the highest background
            // holder — leaking it would park every other queue until relaunch.
            var gpuHeld = true
            defer { if gpuHeld { Task { @MainActor in GPUResourceManager.shared.release(.transcription) } } }

            // Memory can change while waiting for another GPU consumer to release. Re-sample at
            // the last safe point before any backend is allowed to map model weights.
            if let deferral = SystemMemoryGate.shared.transcriptionDeferral(
                profile: resourceProfile
            ) {
                whisperService.activeCheckpoint = nil
                whisperService.onVADChunkCompleted = nil
                await queueManager?.deferJobForResources(
                    job.id,
                    reason: deferral.reason
                )
                currentJob = nil
                return
            }

            // Use UnifiedTranscriptionManager to perform transcription with progress
            let unifiedManager = UnifiedTranscriptionManager.shared

            let (transcriptionItem, transcriptionResult, recordingId) = await unifiedManager.transcribeWithResult(
                audioFile: job.audioFilePath,
                fileName: job.fileName,
                source: job.source,
                runSettings: job.runSettings,
                existingRecordingId: job.existingRecordingId,
                progressHandler: progressCallback
            )

            // Release GPU after transcription completes
            await MainActor.run { GPUResourceManager.shared.release(.transcription) }
            gpuHeld = false

            // Clear checkpoint state after transcription (success or failure)
            whisperService.activeCheckpoint = nil
            whisperService.onVADChunkCompleted = nil

            if let resourceFailure = unifiedManager.consumeLastResourceFailure() {
                let reason: String
                switch resourceFailure {
                case .gpuOutOfMemory:
                    reason = "model hit its memory limit; cooling down before retry"
                case .resourcesUnavailable(let detail):
                    reason = detail
                default:
                    reason = resourceFailure.localizedDescription
                }
                await queueManager?.deferJobForResources(job.id, reason: reason)
                currentJob = nil
                return
            }

            // Check if transcription failed
            if transcriptionItem.status == .failed {
                let errorMessage = transcriptionItem.error ?? "Transcription failed"
                await queueManager?.markJobFailed(job.id, error: errorMessage)
            } else {
                // Notify completion
                await queueManager?.markJobCompleted(
                    job.id,
                    transcript: transcriptionItem.transcript,
                    result: transcriptionResult,
                    recordingId: recordingId
                )
            }
        }

        currentJob = nil
    }
    
    deinit {
        stop()
    }
}
