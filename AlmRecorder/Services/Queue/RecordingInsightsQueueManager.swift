import Foundation
import Combine

/// Background queue that generates LLM insights (title/summary/tags) for recordings.
///
/// Mirrors `EmbeddingQueueManager` but lighter: one Gemma text call per recording, jobs persisted to
/// AppSettings only (no GRDB table → no migration), and gated at the LOWEST GPU priority (`.insights`)
/// so it always yields to transcription/embedding/search.
final class RecordingInsightsQueueManager: ObservableObject {
    static let shared = RecordingInsightsQueueManager()

    // MARK: - Published state
    @Published var jobs: [RecordingInsightsJob] = []
    @Published var isProcessing = false
    @Published var currentJob: RecordingInsightsJob?
    @Published var currentStatus: String = ""

    // MARK: - Derived
    var pendingJobs: [RecordingInsightsJob] {
        jobs.filter { $0.status == .pending }
            .sorted { $0.priority != $1.priority ? $0.priority > $1.priority : $0.createdAt > $1.createdAt } // newest-first
    }
    var activeJobs: [RecordingInsightsJob] { jobs.filter { $0.status.isActive } }
    var completedJobs: [RecordingInsightsJob] { jobs.filter { $0.status == .completed } }
    var failedJobs: [RecordingInsightsJob] { jobs.filter { $0.status == .failed } }
    var hasActiveJobs: Bool { !activeJobs.isEmpty || !pendingJobs.isEmpty }
    var queueSize: Int { pendingJobs.count + activeJobs.count }

    // MARK: - Private
    private let service = RecordingInsightsService.shared
    private let settingsRepo = GRDBSettingsRepository.shared
    private let logger = VoxtralLogger.shared
    private let gemmaModels = GemmaModelManager()
    private var cancellables = Set<AnyCancellable>()
    private var processingTask: Task<Void, Never>?
    private var processingGeneration: UUID?
    private let maxRetries = 3
    private var maintenanceTimer: Timer?
    private let maintenanceInterval: TimeInterval = 600 // 10 minutes
    private var isPerformingMaintenance = false

    private let indexKey = "insightsJob.index"
    private func jobKey(_ id: String) -> String { "insightsJob.\(id)" }

    private init() {
        loadQueue()
        // Auto-save on changes (debounced).
        $jobs
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.persistQueue() }
            .store(in: &cancellables)
        if hasActiveJobs { startProcessing() }
    }

    // MARK: - Enqueue

    /// Enqueue a recording for insight generation. No-op if a pending/processing job already covers it.
    @discardableResult
    @MainActor
    func enqueue(recordingId: Int64, recordingTitle: String, force: Bool = false,
                 priority: RecordingInsightsJob.Priority = .normal) -> RecordingInsightsJob? {
        if jobs.contains(where: { $0.recordingId == recordingId && ($0.status == .pending || $0.status == .processing) }) {
            return nil
        }
        let job = RecordingInsightsJob(recordingId: recordingId, recordingTitle: recordingTitle, force: force, priority: priority)
        jobs.append(job)
        if !isProcessing { startProcessing() }
        return job
    }

    // MARK: - Manual job actions (queue UI)

    /// Cancel a specific job. If it's the one currently processing, also kills the in-flight
    /// Gemma call so the worker moves on immediately.
    @MainActor
    func cancelJob(_ jobId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[index].status = .cancelled
        jobs[index].completedAt = Date()
        if currentJob?.id == jobId {
            LLMTextService.shared.cancel()
            currentJob = nil
        }
    }

    /// Retry a failed job — same requeue-and-restart shape as `EmbeddingQueueManager.retryJob`.
    @MainActor
    func retryJob(_ jobId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[index].status = .pending
        jobs[index].error = nil
        jobs[index].retryCount += 1
        if !isProcessing { startProcessing() }
    }

    @MainActor
    func clearCompletedJobs() {
        jobs.removeAll { $0.status == .completed }
    }

    // MARK: - Processing control

    func startProcessing() {
        guard processingGeneration == nil else { return }
        // Latch before the detached task starts so a burst of enqueue/maintenance calls cannot
        // create multiple workers for the same logical GPU consumer.
        let generation = UUID()
        processingGeneration = generation
        isProcessing = true
        // Task.detached so processing never inherits @MainActor (GPUResourceManager calls this).
        processingTask = Task.detached { [weak self] in
            await self?.processQueue(generation: generation)
        }
    }

    func stopProcessing() {
        processingTask?.cancel()
        processingTask = nil
        processingGeneration = nil
        isProcessing = false
        // Kill any in-flight llama-cli so a preempting (higher-priority) consumer gets the GPU promptly.
        LLMTextService.shared.cancel()
        if let job = currentJob {
            // Back to .pending (NOT .paused): when the GPU gate resumes this queue the worker only
            // picks up pending jobs — a paused job would be stuck until the next launch.
            updateJob(Self.requeued(job))
            currentJob = nil
        }
    }

    // MARK: - Periodic maintenance / discovery

    func startPeriodicMaintenance() {
        stopPeriodicMaintenance()
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: maintenanceInterval, repeats: true) { [weak self] _ in
            Task { await self?.performMaintenance() }
        }
        Task { await performMaintenance() }
    }

    func stopPeriodicMaintenance() {
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
    }

    /// Discover recordings that have a transcript but no insights and enqueue them (newest-first).
    /// Full no-op when no Gemma text model is available.
    @MainActor
    func performMaintenance() async {
        guard !isPerformingMaintenance, LLMTextService.shared.isAvailable else { return }
        isPerformingMaintenance = true
        defer { isPerformingMaintenance = false }

        do {
            let recordingRepo = GRDBRecordingRepository()
            let recordings = try recordingRepo.getAll(limit: 100_000)
                .sorted { $0.createdAt > $1.createdAt } // newest first
            var added = 0
            for rec in recordings {
                guard let id = rec.id else { continue }
                let transcript = (rec.fullTranscript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard transcript.count >= 40 else { continue }
                if RecordingInsightsService.hasInsights(rec) { continue }
                if enqueue(recordingId: id, recordingTitle: rec.title, priority: .low) != nil { added += 1 }
            }
            if added > 0 { logger.info("[InsightsQueue] Enqueued \(added) recordings for insights backfill") }
            await retryFailedJobs()
        } catch {
            logger.error("[InsightsQueue] Maintenance failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func retryFailedJobs() async {
        let now = Date()
        for job in failedJobs where job.retryCount < maxRetries {
            let backoff = TimeInterval(pow(2.0, Double(job.retryCount)) * 60)
            if let done = job.completedAt, now.timeIntervalSince(done) >= backoff,
               let i = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[i].status = .pending
                jobs[i].error = nil
                jobs[i].retryCount += 1
            }
        }
        if !isProcessing && !pendingJobs.isEmpty { startProcessing() }
    }

    // MARK: - Worker loop

    private func processQueue(generation: UUID) async {
        var gpuHeld = false

        while !Task.isCancelled {
            // Memory gate: never launch a multi-GB Gemma load into a starved system, and respect
            // the Metal-OOM cooldown. Deferred jobs stay .pending — the loop waits and re-checks.
            if let deferral = SystemMemoryGate.shared.deferral(modelBytes: estimatedModelBytes()) {
                if await getNextJob() == nil { break } // nothing queued — don't idle deferred forever
                try? await Task.sleep(nanoseconds: UInt64(deferral.retryAfter * 1_000_000_000))
                continue
            }

            // Lowest-priority GPU gate: wait while anything else holds the GPU.
            // Suspends until the GPU is exclusively ours; false = preempted/cancelled → stop the
            // loop (the restart hook respawns us when the GPU frees).
            guard await GPUResourceManager.shared.acquire(.insights) else { break }
            gpuHeld = true

            guard let job = await getNextJob() else {
                await MainActor.run { GPUResourceManager.shared.release(.insights) }
                gpuHeld = false
                break
            }

            await processJob(job)

            await MainActor.run { GPUResourceManager.shared.release(.insights) }
            gpuHeld = false
            try? await Task.sleep(nanoseconds: 500_000_000) // breathe between jobs
        }

        if gpuHeld { await MainActor.run { GPUResourceManager.shared.release(.insights) } }
        await MainActor.run {
            guard processingGeneration == generation else { return }
            processingGeneration = nil
            processingTask = nil
            isProcessing = false
            currentJob = nil
            currentStatus = ""
        }
    }

    private func getNextJob() async -> RecordingInsightsJob? {
        await MainActor.run { pendingJobs.first }
    }

    /// On-disk size of the Gemma text model an insights job would load (nil → the gate's floor).
    private func estimatedModelBytes() -> UInt64? {
        SystemMemoryGate.fileSize(at: gemmaModels.getModelPath(for: GlobalModelSettings.shared.selectedTextLLMModel))
    }

    private func processJob(_ job: RecordingInsightsJob) async {
        var job = job
        job.status = .processing
        job.startedAt = Date()
        let started = job
        await MainActor.run {
            currentJob = started
            updateJob(started)
            currentStatus = "Generating insights: \(started.recordingTitle)"
        }

        do {
            try await service.generateAndPersist(recordingId: job.recordingId, force: job.force)
            job.status = .completed
        } catch {
            // Preemption (worker cancelled, or llama-completion killed mid-flight) requeues as
            // .pending; a genuine error fails. stopProcessing already requeues currentJob, but the
            // worker can win the race — without this it would clobber that back to .failed.
            job = Self.resolvedAfterError(job, error: error, workerCancelled: Task.isCancelled)
            if job.status == .failed {
                logger.error("[InsightsQueue] Job failed (recording \(job.recordingId)): \(error.localizedDescription)")
            } else if case TranscriptionError.gpuOutOfMemory = error {
                logger.warning("[InsightsQueue] Requeued after Metal OOM (recording \(job.recordingId)) — gate cooldown active")
            }
        }
        job.completedAt = Date()

        let final = job
        await MainActor.run {
            updateJob(final)
            currentJob = nil
        }
    }

    private func updateJob(_ job: RecordingInsightsJob) {
        if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i] = job }
    }

    // MARK: - Requeue / preemption policy (pure, unit-tested)

    /// A preempted/interrupted job, reset so the worker loop picks it up again. `.pending` —
    /// NOT `.paused`: only pending jobs are scanned by the worker and only failed ones by
    /// `retryFailedJobs`, so a paused job is stuck until the next launch.
    static func requeued(_ job: RecordingInsightsJob) -> RecordingInsightsJob {
        var job = job
        job.status = .pending
        job.startedAt = nil
        return job
    }

    /// Resolve a job whose processing threw. Preemption is NOT a failure: it requeues without
    /// burning retry budget. Unlike cleanup (whose service throws `CancellationError`), killing
    /// llama-completion surfaces as `TranscriptionError.processFailed`, so we also treat any error
    /// raised while the worker task was cancelled as preemption.
    static func resolvedAfterError(_ job: RecordingInsightsJob, error: Error, workerCancelled: Bool) -> RecordingInsightsJob {
        if workerCancelled || error is CancellationError {
            return requeued(job)
        }
        // Metal OOM is systemic, not the job's fault: requeue without burning retry budget.
        // SystemMemoryGate's escalating backoff (fed by the process layer) delays the relaunch.
        if case TranscriptionError.gpuOutOfMemory = error {
            return requeued(job)
        }
        var job = job
        job.status = .failed
        job.error = error.localizedDescription
        return job
    }

    /// Normalize a persisted job at load: anything left mid-flight (`.processing`) or parked by a
    /// preemption that never resumed (`.paused`) resumes as `.pending`. `generateAndPersist` is
    /// idempotent, so re-running an interrupted job is safe.
    static func normalizedAfterLoad(_ job: RecordingInsightsJob) -> RecordingInsightsJob {
        (job.status == .processing || job.status == .paused) ? requeued(job) : job
    }

    /// Drop duplicate pending jobs for the same recording. Pre-fix, a stuck `.paused` zombie plus
    /// the NEW job `performMaintenance` created for the same recording could both be persisted;
    /// each would trigger an expensive Gemma load to produce identical insights. Non-pending jobs
    /// pass through (a failed job awaiting retry-backoff is a distinct state).
    static func dedupedAtLoad(_ jobs: [RecordingInsightsJob]) -> [RecordingInsightsJob] {
        var seenPending = Set<Int64>()
        return jobs.filter { job in
            guard job.status == .pending else { return true }
            return seenPending.insert(job.recordingId).inserted
        }
    }

    // MARK: - Persistence (AppSettings only — no DB migration)

    private func persistQueue() {
        // Only keep work-to-do across launches; completed jobs are dropped. `.paused` is included
        // defensively so any legacy zombie survives to be healed (→ .pending) by loadQueue.
        let toPersist = jobs.filter { $0.status == .pending || $0.status == .processing || $0.status == .failed || $0.status == .paused }
        var ids: [String] = []
        for job in toPersist {
            if let data = try? JSONEncoder().encode(job) {
                settingsRepo.setData(data, forKey: jobKey(job.id.uuidString))
                ids.append(job.id.uuidString)
            }
        }
        // Remove persisted jobs that are no longer tracked.
        let oldIds = (settingsRepo.getString(forKey: indexKey) ?? "").split(separator: ",").map(String.init)
        for old in oldIds where !ids.contains(old) {
            settingsRepo.removeObject(forKey: jobKey(old))
        }
        settingsRepo.setString(ids.joined(separator: ","), forKey: indexKey)
    }

    private func loadQueue() {
        let ids = (settingsRepo.getString(forKey: indexKey) ?? "").split(separator: ",").map(String.init)
        var loaded: [RecordingInsightsJob] = []
        for id in ids {
            guard let data = settingsRepo.getData(forKey: jobKey(id)),
                  let job = try? JSONDecoder().decode(RecordingInsightsJob.self, from: data) else { continue }
            // Resume anything interrupted (.processing) or parked by a preemption that never
            // resumed (.paused — zombies from before the requeue fix) as .pending.
            loaded.append(Self.normalizedAfterLoad(job))
        }
        // Collapse pending duplicates (a healed zombie + the maintenance-created job for the same
        // recording); the dropped entries are purged from AppSettings on the next persist.
        jobs = Self.dedupedAtLoad(loaded)
    }
}
