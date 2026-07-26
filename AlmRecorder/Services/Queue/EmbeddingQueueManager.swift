import Foundation
import Combine
import GRDB

/// Manages the queue for embedding generation jobs
class EmbeddingQueueManager: ObservableObject {
    static let shared = EmbeddingQueueManager()
    
    // MARK: - Published Properties
    
    @Published var jobs: [EmbeddingJob] = []
    @Published var isProcessing = false
    @Published var currentJob: EmbeddingJob?
    @Published var globalProgress: Double = 0.0
    @Published var currentStatus: String = ""
    @Published var totalPendingUtterances: Int = 0
    @Published var totalProcessedUtterances: Int = 0
    
    // MARK: - Computed Properties
    
    var pendingJobs: [EmbeddingJob] {
        jobs.filter { $0.status == .pending }
            .sorted { 
                if $0.priority != $1.priority {
                    return $0.priority > $1.priority
                }
                return $0.createdAt < $1.createdAt
            }
    }
    
    var activeJobs: [EmbeddingJob] {
        jobs.filter { $0.status.isActive }
    }
    
    var completedJobs: [EmbeddingJob] {
        jobs.filter { $0.status == .completed }
    }
    
    var failedJobs: [EmbeddingJob] {
        jobs.filter { $0.status == .failed }
    }
    
    var queueSize: Int {
        pendingJobs.count + activeJobs.count
    }
    
    var hasActiveJobs: Bool {
        !activeJobs.isEmpty || !pendingJobs.isEmpty
    }
    
    // MARK: - Private Properties
    
    private let embeddingService = EmbeddingService.shared
    private let utteranceRepo = GRDBUtteranceRepository()
    private let logger = VoxtralLogger.shared
    private let database = GRDBDatabaseManager.shared
    private let settingsRepo = GRDBSettingsRepository.shared
    private var cancellables = Set<AnyCancellable>()
    private var processingTask: Task<Void, Never>?
    private let processingSemaphore = DispatchSemaphore(value: 1)
    private let maxRetries = 3
    private let batchSize = 10 // Process embeddings in batches for efficiency
    
    // Periodic maintenance
    private var maintenanceTimer: Timer?
    private let maintenanceInterval: TimeInterval = 300 // 5 minutes
    private var lastMaintenanceCheck: Date?
    private var isPerformingMaintenance = false
    
    // Performance tracking
    private var processingStartTime: Date?
    private var totalProcessedCount = 0
    private var totalProcessingTime: TimeInterval = 0
    
    // JSON file path for migration only
    private let legacyQueueFileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("AlmRecorder")
        return appFolder.appendingPathComponent("embedding_queue.json")
    }()
    
    // MARK: - Init
    
    private init() {
        setupBindings()
        migrateFromJSONIfNeeded()
        reconcileQueue() // drop stale/done/empty jobs BEFORE loading them into memory
        loadQueueFromDatabase()
        logger.info("[EmbeddingQueueManager] Initialized with \(jobs.count) persisted jobs, pending: \(pendingJobs.count), completed: \(completedJobs.count)")
        
        // Auto-start processing if there are pending jobs
        if hasActiveJobs {
            logger.info("[EmbeddingQueueManager] Auto-starting queue processing with \(pendingJobs.count) pending jobs")
            startProcessing()
        }
    }
    
    private func setupBindings() {
        // Subscribe to embedding service progress
        embeddingService.$generationProgress
            .sink { [weak self] progress in
                guard let self = self,
                      var job = self.currentJob else { return }
                
                // Update current job progress
                job.progress = progress
                self.updateCurrentJob(job)
            }
            .store(in: &cancellables)
        
        embeddingService.$currentStatus
            .sink { [weak self] status in
                self?.currentStatus = status
            }
            .store(in: &cancellables)
        
        // Auto-save queue on changes
        $jobs
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.persistQueue()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Public Methods
    
    /// Add a new embedding job to the queue
    @MainActor
    func addJob(
        recordingId: Int64,
        recordingTitle: String,
        utteranceData: [(id: Int64, text: String)],
        priority: EmbeddingJob.Priority = .normal
    ) -> EmbeddingJob {
        logger.info("[EmbeddingQueueManager] === ADD JOB ===")
        logger.info("[EmbeddingQueueManager] Recording: \(recordingTitle)")
        logger.info("[EmbeddingQueueManager] Recording ID: \(recordingId)")
        logger.info("[EmbeddingQueueManager] Utterances count: \(utteranceData.count)")
        logger.info("[EmbeddingQueueManager] Priority: \(priority.rawValue)")
        
        // Convert to embedding data
        let embeddingData = utteranceData.map { 
            EmbeddingJob.UtteranceEmbeddingData(
                utteranceId: $0.id,
                text: $0.text
            )
        }
        
        let job = EmbeddingJob(
            recordingId: recordingId,
            recordingTitle: recordingTitle,
            utteranceData: embeddingData,
            priority: priority
        )
        
        jobs.append(job)
        updateStatistics()
        
        logger.info("[EmbeddingQueueManager] Added job for \(recordingTitle) | utterances=\(utteranceData.count) priority=\(priority) jobId=\(job.id)")
        logger.debug("[EmbeddingQueueManager] Queue status | total=\(jobs.count) pending=\(pendingJobs.count) active=\(activeJobs.count)")
        
        // Start processing if not already running
        if !isProcessing {
            startProcessing()
        }
        
        logger.info("[EmbeddingQueueManager] Job added successfully: \(job.id)")
        logger.info("[EmbeddingQueueManager] === END ADD JOB ===")
        return job
    }
    
    /// Start processing the queue
    func startProcessing() {
        guard !isProcessing else {
            logger.debug("[EmbeddingQueueManager] Processing already running")
            return
        }

        // Flip the flag SYNCHRONOUSLY here (all callers are on the main thread). Previously
        // `isProcessing` was only set true *asynchronously* inside the detached processQueue task,
        // so a burst of calls — e.g. retryFailedJobs() retrying dozens of failed jobs in one main-thread
        // loop — each passed this guard before any task set the flag, spawning DOZENS of concurrent
        // processQueue tasks. They then flooded @Published setters from many threads and wedged the
        // Combine ObservableObjectPublisher's unfair_lock on the main thread → hard app freeze.
        // Setting it now makes the guard effective: only one processQueue task is ever spawned.
        isProcessing = true
        logger.info("[EmbeddingQueueManager] Starting queue processing | pending=\(pendingJobs.count)")
        processingStartTime = Date()

        // Use Task.detached to ensure processing never inherits @MainActor
        // (startProcessing can be called from @MainActor contexts like GPUResourceManager)
        processingTask = Task.detached { [weak self] in
            await self?.processQueue()
        }
    }
    
    /// Stop processing the queue
    func stopProcessing() {
        logger.info("[EmbeddingQueueManager] Stopping queue processing")
        
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
        // Kill the in-flight embedding subprocess too — `runEmbeddingProcess` busy-waits on a
        // RunLoop with no cancellation check, so a bare task cancel leaves it holding the GPU and a
        // preempting consumer parked for up to ~60s. (Mirrors insights/cleanup teardown.)
        embeddingService.cancelGeneration()

        // Requeue the current job as .pending (NOT .paused): when the GPU gate resumes this queue the
        // worker only picks up pending jobs — a paused job would be stuck until the next launch.
        // Already-embedded utterances are skipped on the rerun, so this resumes rather than restarts.
        if let job = currentJob {
            updateJob(Self.requeued(job))
            currentJob = nil
            logger.debug("[EmbeddingQueueManager] Requeued current job | jobId=\(job.id) recording=\(job.recordingTitle)")
        }
    }
    
    /// Cancel a specific job
    func cancelJob(_ jobId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else {
            logger.warning("[EmbeddingQueueManager] Cannot cancel - job not found | jobId=\(jobId)")
            return
        }
        
        let job = jobs[index]
        jobs[index].status = .cancelled
        jobs[index].completedAt = Date()
        
        logger.info("[EmbeddingQueueManager] Cancelled job | recording=\(job.recordingTitle) jobId=\(jobId)")
        
        // If it's the current job, stop processing it
        if currentJob?.id == jobId {
            embeddingService.cancelGeneration()
            currentJob = nil
            logger.debug("[EmbeddingQueueManager] Cancelled current active job")
        }
        
        updateStatistics()
    }
    
    /// Reconcile the persisted queue against reality so it can't accumulate jobs that never make
    /// progress (the cause of the perpetual "[N utterances failed]" churn): an utterance that is
    /// already embedded, has empty text (nothing to embed), or no longer exists has no work left, so
    /// its job is dropped. Stuck `processing`/`paused` rows (from a prior crash/freeze or a GPU
    /// preemption that never resumed) are reset to pending.
    /// Runs on every launch — unlike the one-shot v18 migration, this keeps the queue clean over time.
    private func reconcileQueue() {
        do {
            try database.write { db in
                try db.execute(sql: """
                    DELETE FROM embedding_queue
                    WHERE utterance_id IN (
                        SELECT id FROM utterances WHERE has_embedding = 1 OR TRIM(COALESCE(text, '')) = ''
                    )
                    OR utterance_id NOT IN (SELECT id FROM utterances)
                """)
                let removed = db.changesCount
                try db.execute(sql: "UPDATE embedding_queue SET status = 'pending', started_at = NULL WHERE status IN ('processing', 'paused')")
                if removed > 0 {
                    logger.info("[EmbeddingQueueManager] Reconciled queue: dropped \(removed) stale job(s) (already-embedded / empty-text / orphaned)")
                }
            }
        } catch {
            logger.error("[EmbeddingQueueManager] Queue reconcile failed: \(error.localizedDescription)")
        }
    }

    /// Retry a failed job
    @MainActor
    func retryJob(_ jobId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else {
            logger.warning("[EmbeddingQueueManager] Cannot retry - job not found | jobId=\(jobId)")
            return
        }
        
        let job = jobs[index]
        jobs[index].status = .pending
        jobs[index].error = nil
        jobs[index].retryCount += 1
        
        logger.info("[EmbeddingQueueManager] Retrying job | recording=\(job.recordingTitle) attempt=\(jobs[index].retryCount) jobId=\(jobId)")
        
        updateStatistics()
        
        // Start processing if not already running
        if !isProcessing {
            startProcessing()
        }
    }
    
    /// Clear completed jobs
    func clearCompletedJobs() {
        jobs.removeAll { $0.status == .completed }
        updateStatistics()
    }
    
    /// Clear all jobs
    func clearAllJobs() {
        stopProcessing()
        jobs.removeAll()
        currentJob = nil
        updateStatistics()
    }
    
    /// Alias for clearAllJobs for consistency
    func clearQueue() {
        clearAllJobs()
    }
    
    // MARK: - Periodic Maintenance
    
    /// Start periodic maintenance timer
    func startPeriodicMaintenance() {
        stopPeriodicMaintenance() // Stop any existing timer
        
        logger.info("[EmbeddingQueueManager] Starting periodic maintenance | interval=\(Int(maintenanceInterval))s")
        
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: maintenanceInterval, repeats: true) { [weak self] _ in
            Task {
                await self?.performMaintenance()
            }
        }
        
        // Perform initial check
        Task {
            await performMaintenance()
        }
    }
    
    /// Stop periodic maintenance timer
    func stopPeriodicMaintenance() {
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
        logger.info("[EmbeddingQueueManager] Stopped periodic maintenance")
    }
    
    /// Perform maintenance check for missing embeddings
    @MainActor
    func performMaintenance() async {
        // Skip if already performing maintenance or actively processing
        guard !isPerformingMaintenance,
              !isProcessing || pendingJobs.isEmpty,
              EmbeddingModelManager.shared.isModelLoaded else {
            return
        }
        
        isPerformingMaintenance = true
        defer { isPerformingMaintenance = false }
        
        lastMaintenanceCheck = Date()
        
        logger.debug("[EmbeddingQueueManager] Performing maintenance check...")
        
        do {
            // Check for utterances without embeddings
            let totalUtterances = try utteranceRepo.count()
            let utterancesWithEmbeddings = try utteranceRepo.countWithEmbeddings()
            let missing = totalUtterances - utterancesWithEmbeddings
            
            if missing > 0 {
                logger.info("[EmbeddingQueueManager] Found missing embeddings | missing=\(missing) total=\(totalUtterances)")
                
                // Get all recordings with missing embeddings
                let recordingRepo = GRDBRecordingRepository()
                let recordings = try recordingRepo.getAll()
                
                var jobsAdded = 0
                for recording in recordings {
                    guard let recordingId = recording.id else { continue }
                    
                    // Check if we already have a job for this recording
                    let hasExistingJob = jobs.contains { job in
                        job.recordingId == recordingId && 
                        (job.status == .pending || job.status == .processing)
                    }
                    
                    if hasExistingJob { continue }
                    
                    // Get utterances without embeddings for this recording
                    let utterancesNeedingEmbeddings = try utteranceRepo.getUtterancesWithoutEmbeddings(
                        recordingId: recordingId,
                        limit: 100
                    )
                    
                    if !utterancesNeedingEmbeddings.isEmpty {
                        let utteranceData = utterancesNeedingEmbeddings.compactMap { utterance -> (id: Int64, text: String)? in
                            guard let id = utterance.id else { return nil }
                            return (id: id, text: utterance.text)
                        }
                        
                        if !utteranceData.isEmpty {
                            _ = addJob(
                                recordingId: recordingId,
                                recordingTitle: recording.title,
                                utteranceData: utteranceData,
                                priority: .low // Low priority for maintenance
                            )
                            jobsAdded += 1
                        }
                    }
                }
                
                if jobsAdded > 0 {
                    logger.info("[EmbeddingQueueManager] Added \(jobsAdded) maintenance jobs for missing embeddings")
                }
            } else {
                logger.debug("[EmbeddingQueueManager] All utterances have embeddings | total=\(totalUtterances)")
            }
            
            // Also check for failed jobs that should be retried
            await retryFailedJobs()
            
        } catch {
            logger.error("[EmbeddingQueueManager] === MAINTENANCE FAILED ===")
            logger.error("[EmbeddingQueueManager] Error: \(error)")
            logger.error("[EmbeddingQueueManager] Error type: \(type(of: error))")
            logger.error("[EmbeddingQueueManager] === END MAINTENANCE FAILED ===")
            
            logger.error("[EmbeddingQueueManager] Maintenance check failed | error=\(error.localizedDescription)")
        }
    }
    
    /// Retry failed jobs with exponential backoff
    @MainActor
    private func retryFailedJobs() async {
        let now = Date()
        var retriedCount = 0
        
        for job in failedJobs {
            // Skip if already retried too many times
            if job.retryCount >= maxRetries { continue }
            
            // Calculate backoff time: 2^retryCount minutes
            let backoffMinutes = pow(2.0, Double(job.retryCount))
            let backoffInterval = TimeInterval(backoffMinutes * 60)
            
            // Check if enough time has passed since last attempt
            if let completedAt = job.completedAt,
               now.timeIntervalSince(completedAt) >= backoffInterval {
                retryJob(job.id)
                retriedCount += 1
            }
        }
        
        if retriedCount > 0 {
            logger.info("[EmbeddingQueueManager] Retried \(retriedCount) failed jobs with backoff")
        }
    }
    
    /// Manually trigger maintenance check
    func triggerMaintenanceCheck() async {
        logger.info("[EmbeddingQueueManager] Manual maintenance check triggered")
        await performMaintenance()
    }
    
    // MARK: - Private Methods
    
    private func processQueue() async {
        await MainActor.run {
            isProcessing = true
        }

        var gpuHeld = false

        while !Task.isCancelled {
            // Memory gate: don't add GPU work to a starved system, and respect the Metal-OOM
            // cooldown. Deferred jobs stay .pending — the loop waits and re-checks.
            if let deferral = SystemMemoryGate.shared.deferral(modelBytes: estimatedModelBytes()) {
                if await getNextJob() == nil { break } // nothing queued — don't idle deferred forever
                try? await Task.sleep(nanoseconds: UInt64(deferral.retryAfter * 1_000_000_000))
                continue
            }

            // Check GPU gate — wait if higher-priority consumer is active
            // Suspends until the GPU is exclusively ours; false = preempted/cancelled → stop the
            // loop (the restart hook respawns us when the GPU frees).
            guard await GPUResourceManager.shared.acquire(.embedding) else { break }
            gpuHeld = true

            // Get next job
            guard let nextJob = await getNextJob() else {
                await MainActor.run { GPUResourceManager.shared.release(.embedding) }
                gpuHeld = false
                break
            }

            // Process the job (GPU held during processing)
            await processJob(nextJob)

            // Release GPU between jobs so higher-priority consumers can jump in
            await MainActor.run { GPUResourceManager.shared.release(.embedding) }
            gpuHeld = false

            // Small delay between jobs
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }

        // Safety: release GPU if still held (e.g. task was cancelled mid-processing)
        if gpuHeld {
            await MainActor.run { GPUResourceManager.shared.release(.embedding) }
        }

        await MainActor.run {
            isProcessing = false
            currentJob = nil
            currentStatus = ""
        }
    }
    
    private func getNextJob() async -> EmbeddingJob? {
        await MainActor.run {
            pendingJobs.first
        }
    }

    /// On-disk size of the embedding model a job loads (nil → the gate's floor).
    private func estimatedModelBytes() -> UInt64? {
        let manager = EmbeddingModelManager.shared
        return SystemMemoryGate.fileSize(at: manager.getModelPath(for: manager.currentModel))
    }
    
    private func processJob(_ job: EmbeddingJob) async {
        var job = job
        
        // Update job status
        job.status = .processing
        job.startedAt = Date()
        
        // Capture job explicitly to avoid concurrency warning
        let capturedJob = job
        await MainActor.run {
            currentJob = capturedJob
            updateJob(capturedJob)
        }
        
        let jobStartTime = Date()
        logger.info("[EmbeddingQueueManager] Processing job | recording=\(job.recordingTitle) utterances=\(job.totalUtterances) jobId=\(job.id)")
        
        // Process utterances in batches
        let utterances = job.utteranceData.filter { !$0.embeddingGenerated && $0.error == nil }
        let totalBatches = (utterances.count + batchSize - 1) / batchSize
        var gpuOOMHit = false

        for (batchIndex, batch) in utterances.chunked(into: batchSize).enumerated() {
            if Task.isCancelled { break }
            
            await MainActor.run {
                currentStatus = "Processing batch \(batchIndex + 1) of \(totalBatches)..."
            }
            
            // Generate embeddings for batch
            let texts = batch.map { $0.text }
            
            do {
                let batchStartTime = Date()
                logger.debug("[EmbeddingQueueManager] Processing batch | batch=\(batchIndex+1)/\(totalBatches) size=\(batch.count)")
                
                logger.info("[EmbeddingQueueManager] Generating embeddings for batch...")
                let embeddings = try await embeddingService.generateEmbeddings(for: texts)

                // Separate successes from failures. A nil embedding means generation failed;
                // we never store a placeholder vector (that poisons search and falsely marks
                // the utterance embedded). Failed utterances stay unembedded and are retried.
                var embeddingPairs: [(utteranceId: Int64, embedding: Data)] = []
                var failedIds: [Int64] = []
                for (utterance, embedding) in zip(batch, embeddings) {
                    if let embedding {
                        embeddingPairs.append((utterance.utteranceId, embedding))
                    } else {
                        failedIds.append(utterance.utteranceId)
                    }
                }

                try utteranceRepo.storeEmbeddingsBatch(embeddingPairs)
                logger.info("[EmbeddingQueueManager] Stored \(embeddingPairs.count) embeddings, \(failedIds.count) failed")

                // Mark per-utterance status based on actual success/failure.
                for pair in embeddingPairs {
                    job.markUtteranceComplete(id: pair.utteranceId)
                }
                for id in failedIds {
                    job.markUtteranceFailed(id: id, error: "Embedding generation returned no vector")
                }
                
                let batchTime = Date().timeIntervalSince(batchStartTime)
                logger.debug("[EmbeddingQueueManager] Batch completed | batch=\(batchIndex+1)/\(totalBatches) time=\(String(format: "%.2f", batchTime))s rate=\(String(format: "%.2f", Double(batch.count)/batchTime)) utterances/s")
                
                // Capture job explicitly to avoid concurrency warning
                let capturedJob = job
                await MainActor.run {
                    updateJob(capturedJob)
                    globalProgress = Double(batchIndex + 1) / Double(totalBatches)
                }
                
            } catch {
                if case TranscriptionError.gpuOutOfMemory = error {
                    // Systemic — not these utterances' fault. Stop the job without marking them
                    // failed; resolution below requeues it and the gate cooldown delays relaunch.
                    gpuOOMHit = true
                    logger.warning("[EmbeddingQueueManager] Metal OOM mid-job — requeuing remaining work (batch \(batchIndex+1)/\(totalBatches))")
                    break
                }
                logger.error("[EmbeddingQueueManager] === BATCH FAILED ===")
                logger.error("[EmbeddingQueueManager] Batch: \(batchIndex+1)/\(totalBatches)")
                logger.error("[EmbeddingQueueManager] Error: \(error)")
                logger.error("[EmbeddingQueueManager] Error type: \(type(of: error))")
                logger.error("[EmbeddingQueueManager] Recording: \(job.recordingTitle)")
                logger.error("[EmbeddingQueueManager] Utterances in batch: \(batch.count)")
                logger.error("[EmbeddingQueueManager] Sample text: \(String(batch.first?.text.prefix(100) ?? ""))...")
                logger.error("[EmbeddingQueueManager] === END BATCH FAILED ===")
                
                logger.error("[EmbeddingQueueManager] Batch failed | batch=\(batchIndex+1)/\(totalBatches) error=\(error.localizedDescription)")
                
                // Mark batch as failed
                for utterance in batch {
                    job.markUtteranceFailed(id: utterance.utteranceId, error: error.localizedDescription)
                }
                
                // If too many failures, mark job as failed
                if job.failedUtterances > job.totalUtterances / 2 {
                    job.status = .failed
                    job.error = "Too many utterances failed"
                    break
                }
            }
        }
        
        // Resolve final status. Preemption (cancelled mid-loop with work left) and Metal OOM
        // requeue as .pending so the job resumes later; otherwise complete/fail as usual.
        job = Self.resolvedAfterProcessing(job, cancelled: Task.isCancelled, gpuOOM: gpuOOMHit)

        job.completedAt = Date()
        
        // Capture job explicitly to avoid concurrency warning
        let finalJob = job
        await MainActor.run {
            updateJob(finalJob)
            currentJob = nil
            updateStatistics()
        }
        
        let processingTime = Date().timeIntervalSince(jobStartTime)
        logger.info("[EmbeddingQueueManager] Completed job | recording=\(job.recordingTitle) status=\(job.status) time=\(String(format: "%.2f", processingTime))s completed=\(job.completedUtterances) failed=\(job.failedUtterances)")
        
        // Update performance metrics
        totalProcessedCount += job.completedUtterances
        totalProcessingTime += processingTime
        if totalProcessedCount > 0 {
            let avgTimePerUtterance = totalProcessingTime / Double(totalProcessedCount)
            logger.debug("[EmbeddingQueueManager] Performance | avgTime=\(String(format: "%.3f", avgTimePerUtterance))s/utterance totalProcessed=\(totalProcessedCount)")
        }
    }
    
    private func updateJob(_ job: EmbeddingJob) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[index] = job
    }

    // MARK: - Requeue / preemption policy (pure, unit-tested)

    /// A preempted/interrupted job, reset so the worker loop picks it up again. `.pending` —
    /// NOT `.paused`: only pending jobs are scanned by the worker and only failed ones by
    /// `retryFailedJobs`, so a paused job is stuck until the next launch. Per-utterance progress is
    /// preserved (`processJob` skips already-embedded utterances), so this resumes rather than restarts.
    static func requeued(_ job: EmbeddingJob) -> EmbeddingJob {
        var job = job
        job.status = .pending
        job.startedAt = nil
        return job
    }

    /// Normalize a persisted job at load: anything left mid-flight (`.processing`) or parked by a
    /// preemption that never resumed (`.paused`) resumes as `.pending`.
    static func normalizedAfterLoad(_ job: EmbeddingJob) -> EmbeddingJob {
        (job.status == .processing || job.status == .paused) ? requeued(job) : job
    }

    /// Final status for a job after its batch loop ends. Preemption (cancelled with work still
    /// remaining) requeues as `.pending` so the GPU gate's resume picks it back up — without this it
    /// stayed `.processing`, which `performMaintenance` treats as "covered", stranding it until the
    /// next launch. A Metal OOM (`gpuOOM`) requeues the same way: it is systemic, not the
    /// utterances' fault, and `SystemMemoryGate`'s cooldown delays the relaunch. A job already
    /// failed in-loop (>50% batch failures) is left untouched.
    static func resolvedAfterProcessing(_ job: EmbeddingJob, cancelled: Bool, gpuOOM: Bool = false) -> EmbeddingJob {
        guard job.status == .processing else { return job }
        if job.completedUtterances == job.totalUtterances {
            var job = job
            job.status = .completed
            return job
        }
        if cancelled || gpuOOM {
            return requeued(job)
        }
        if job.failedUtterances > 0 {
            var job = job
            job.status = .failed
            job.error = "\(job.failedUtterances) utterances failed"
            return job
        }
        return job
    }
    
    private func updateCurrentJob(_ job: EmbeddingJob) {
        currentJob = job
        updateJob(job)
    }
    
    private func updateStatistics() {
        totalPendingUtterances = pendingJobs.reduce(0) { $0 + $1.totalUtterances }
        totalProcessedUtterances = completedJobs.reduce(0) { $0 + $1.completedUtterances }
    }
    
    // MARK: - Persistence
    
    private func persistQueue() {
        do {
            try database.writeQueue { [weak self] db in
                guard let self = self else { return }
                
                // Clear existing queue items
                try EmbeddingQueueItem.deleteAll(db)
                
                // Save current jobs
                for job in self.jobs {
                    // Serialize the job as JSON for storage
                    if let jobData = try? JSONEncoder().encode(job) {
                        let queueItem = EmbeddingQueueItem(
                            id: job.id.uuidString,
                            utteranceId: job.recordingId, // Recording ID (field misnamed — job covers multiple utterances)
                            priority: job.priority.rawValue,
                            status: job.status.rawValue,
                            retryCount: job.retryCount,
                            createdAt: job.createdAt,
                            startedAt: job.startedAt,
                            completedAt: job.completedAt,
                            error: job.error
                        )
                        // Store full job data inline (not via settingsRepo which would open a nested write)
                        let setting = AppSetting(
                            key: "embeddingJob.\(job.id.uuidString)",
                            value: jobData.base64EncodedString(),
                            type: "string",
                            updatedAt: Date()
                        )
                        try setting.save(db)
                        try queueItem.save(db)
                    }
                }
            }
            logger.debug("[EmbeddingQueueManager] Queue persisted to GRDB | jobs=\(jobs.count)")
        } catch {
            logger.error("[EmbeddingQueueManager] === PERSISTENCE FAILED ===")
            logger.error("[EmbeddingQueueManager] Error: \(error)")
            logger.error("[EmbeddingQueueManager] Error type: \(type(of: error))")
            logger.error("[EmbeddingQueueManager] Jobs count: \(self.jobs.count)")
            logger.error("[EmbeddingQueueManager] === END PERSISTENCE FAILED ===")
            
            logger.error("[EmbeddingQueueManager] Failed to persist queue | error=\(error.localizedDescription)")
        }
    }
    
    private func loadQueueFromDatabase() {
        do {
            let queueItems = try database.readQueue { db in
                try EmbeddingQueueItem.fetchAll(db)
            }
            
            // Convert to EmbeddingJob objects
            jobs = queueItems.compactMap { item in
                // Try to load full job data from settings
                if let jobData = settingsRepo.getData(forKey: "embeddingJob.\(item.id)"),
                   let job = try? JSONDecoder().decode(EmbeddingJob.self, from: jobData) {
                    return job
                }
                return nil
            }
            
            // Resume anything interrupted (.processing) or parked by a preemption that never resumed
            // (.paused — zombies from before the requeue fix) as .pending.
            var resetCount = 0
            for i in jobs.indices {
                let normalized = Self.normalizedAfterLoad(jobs[i])
                if normalized.status != jobs[i].status {
                    jobs[i] = normalized
                    resetCount += 1
                }
            }
            
            if resetCount > 0 {
                persistQueue() // Save the reset states
            }
            
            updateStatistics()
            logger.info("[EmbeddingQueueManager] Loaded queue from database | total=\(jobs.count) reset=\(resetCount)")
            
        } catch {
            logger.error("[EmbeddingQueueManager] === LOAD FAILED ===")
            logger.error("[EmbeddingQueueManager] Error: \(error)")
            logger.error("[EmbeddingQueueManager] Error type: \(type(of: error))")
            logger.error("[EmbeddingQueueManager] === END LOAD FAILED ===")
            
            logger.error("[EmbeddingQueueManager] Failed to load queue from database | error=\(error.localizedDescription)")
        }
    }
    
    // MARK: - Migration
    
    private func migrateFromJSONIfNeeded() {
        // Check if migration has been done
        if settingsRepo.getBool(forKey: "embeddingQueue.migrated") == true {
            return
        }
        
        // Check if legacy JSON file exists
        guard FileManager.default.fileExists(atPath: legacyQueueFileURL.path) else {
            // No legacy file, mark as migrated
            settingsRepo.setBool(true, forKey: "embeddingQueue.migrated")
            return
        }
        
        logger.info("[EmbeddingQueueManager] Migrating queue from JSON to GRDB...")
        
        do {
            // Load from JSON file
            let data = try Data(contentsOf: legacyQueueFileURL)
            let legacyJobs = try JSONDecoder().decode([EmbeddingJob].self, from: data)
            
            // Save to database
            try database.writeQueue { [weak self] db in
                guard let self = self else { return }
                for job in legacyJobs {
                    if let jobData = try? JSONEncoder().encode(job) {
                        let queueItem = EmbeddingQueueItem(
                            id: job.id.uuidString,
                            utteranceId: job.recordingId,
                            priority: job.priority.rawValue,
                            status: job.status.rawValue,
                            retryCount: job.retryCount,
                            createdAt: job.createdAt,
                            startedAt: job.startedAt,
                            completedAt: job.completedAt,
                            error: job.error
                        )
                        // Store full job data
                        self.settingsRepo.setData(jobData, forKey: "embeddingJob.\(job.id.uuidString)")
                        try queueItem.save(db)
                    }
                }
            }
            
            // Delete JSON file after successful migration
            try FileManager.default.removeItem(at: legacyQueueFileURL)
            
            // Mark migration complete
            settingsRepo.setBool(true, forKey: "embeddingQueue.migrated")
            
            logger.info("[EmbeddingQueueManager] Successfully migrated \(legacyJobs.count) jobs from JSON to GRDB")
            
        } catch {
            logger.error("[EmbeddingQueueManager] === MIGRATION FAILED ===")
            logger.error("[EmbeddingQueueManager] Error: \(error)")
            logger.error("[EmbeddingQueueManager] Error type: \(type(of: error))")
            logger.error("[EmbeddingQueueManager] Legacy file exists: \(FileManager.default.fileExists(atPath: self.legacyQueueFileURL.path))")
            logger.error("[EmbeddingQueueManager] Legacy file path: \(self.legacyQueueFileURL.path)")
            logger.error("[EmbeddingQueueManager] === END MIGRATION FAILED ===")
            
            logger.error("[EmbeddingQueueManager] Failed to migrate queue from JSON | error=\(error.localizedDescription)")
        }
    }
}

// MARK: - Array Extension for Chunking

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}