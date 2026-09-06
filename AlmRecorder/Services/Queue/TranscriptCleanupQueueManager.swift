import Foundation
import Combine
import GRDB

/// Background queue for transcript cleanup (hallucination detection + human-review routing).
///
/// Structural copy of `RecordingInsightsQueueManager`: jobs persisted to AppSettings only, and
/// Gemma audio verification is deferred.
final class TranscriptCleanupQueueManager: ObservableObject {
    static let shared = TranscriptCleanupQueueManager()

    // MARK: - Published state
    @Published var jobs: [TranscriptCleanupJob] = []
    @Published var isProcessing = false
    @Published var currentJob: TranscriptCleanupJob?
    @Published var currentStatus: String = ""

    // MARK: - Derived
    var pendingJobs: [TranscriptCleanupJob] {
        jobs.filter { $0.status == .pending }
            .sorted { $0.priority != $1.priority ? $0.priority > $1.priority : $0.createdAt > $1.createdAt } // newest-first
    }
    var activeJobs: [TranscriptCleanupJob] { jobs.filter { $0.status.isActive } }
    var failedJobs: [TranscriptCleanupJob] { jobs.filter { $0.status == .failed } }
    var completedJobs: [TranscriptCleanupJob] { jobs.filter { $0.status == .completed } }
    var hasActiveJobs: Bool { !activeJobs.isEmpty || !pendingJobs.isEmpty }
    var queueSize: Int { pendingJobs.count + activeJobs.count }

    // MARK: - Private
    private let service = TranscriptCleanupService.shared
    private let settingsRepo = GRDBSettingsRepository.shared
    private let logger = VoxtralLogger.shared
    private var cancellables = Set<AnyCancellable>()
    private var processingTask: Task<Void, Never>?
    private var processingGeneration: UUID?
    private let maxRetries = 3
    private var maintenanceTimer: Timer?
    private let maintenanceInterval: TimeInterval = 900 // 15 minutes
    private var isPerformingMaintenance = false
    private var sweepTask: Task<Void, Never>?
    private var isSweeping = false

    private let indexKey = "cleanupJob.index"
    private func jobKey(_ id: String) -> String { "cleanupJob.\(id)" }

    private init() {
        loadQueue()
        $jobs
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.persistQueue() }
            .store(in: &cancellables)
        if hasActiveJobs { startProcessing() }
    }

    // MARK: - Enqueue

    /// Enqueue a cleanup pass. No-op if a pending/processing job already covers the recording.
    @discardableResult
    @MainActor
    func enqueue(recordingId: Int64, recordingTitle: String, mode: TranscriptCleanupJob.Mode,
                 force: Bool = false,
                 priority: TranscriptCleanupJob.Priority = .normal) -> TranscriptCleanupJob? {
        if jobs.contains(where: { $0.recordingId == recordingId && ($0.status == .pending || $0.status == .processing) }) {
            return nil
        }
        let job = TranscriptCleanupJob(recordingId: recordingId, recordingTitle: recordingTitle,
                                       mode: mode, force: force, priority: priority)
        jobs.append(job)
        if !isProcessing { startProcessing() }
        return job
    }

    // MARK: - Manual job actions (queue UI)

    /// Cancel a specific job. If it's the one currently processing, also kills the in-flight
    /// llama-mtmd-cli so the worker moves on immediately.
    @MainActor
    func cancelJob(_ jobId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[index].status = .cancelled
        jobs[index].completedAt = Date()
        if currentJob?.id == jobId {
            TranscriptVerificationService.shared.cancel()
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
        // Latch synchronously before scheduling the detached task. Enqueue/backfill can call this
        // repeatedly in one run-loop turn; setting the flag inside processQueue allowed every call
        // to spawn another worker before the first task started.
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
        // Kill any in-flight llama-mtmd-cli so a preempting consumer gets the GPU promptly.
        TranscriptVerificationService.shared.cancel()
        if let job = currentJob {
            // Back to .pending (NOT .paused): when the GPU gate resumes this queue, the worker
            // only picks up pending jobs — a paused job would be stuck until the next launch.
            updateJob(Self.requeued(job))
            currentJob = nil
        }
    }

    // MARK: - Periodic maintenance / backfill discovery

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

    /// Run the retroactive exemplar sweep soon (debounced — marking several lines as trash in a
    /// row sweeps once). Text/embedding matching only, no GPU work, so it is NOT gated on the
    /// auto-cleanup toggle: a manual "mark as trash" should find lookalikes immediately.
    func scheduleExemplarSweep(after delay: TimeInterval = 2.0) {
        sweepTask?.cancel()
        sweepTask = Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.runExemplarSweepNow()
        }
    }

    private func runExemplarSweepNow() async {
        guard !isSweeping else { return }
        isSweeping = true
        defer { isSweeping = false }
        bootstrapExemplarMemoryIfNeeded()
        _ = await TranscriptCleanupService.shared.runExemplarSweep()
    }

    /// Re-run the whole sweep with the current sensitivity (the Review page's "Sweep again").
    func resweepNow() async -> Int {
        guard !isSweeping else { return 0 }
        isSweeping = true
        defer { isSweeping = false }
        let outcome = await TranscriptCleanupService.shared.resweepFromScratch()
        return outcome.flagged
    }

    /// Compatibility no-op for older callers. Audio-model verification is deferred; the exemplar
    /// sweep already writes uncertain findings directly to the human review inbox.
    @MainActor
    func enqueueVerification(for recordingIds: Set<Int64>) {
        _ = recordingIds
    }

    /// One-time back-teach: lines hidden BEFORE the exemplar memory existed (v25) never taught
    /// it. Feed every already-confirmed hidden line through recordBad once, so the very first
    /// sweep can find their siblings across the library.
    private func bootstrapExemplarMemoryIfNeeded() {
        let bootstrapKey = "exemplarMemory.bootstrapped"
        guard settingsRepo.getBool(forKey: bootstrapKey) != true else { return }
        do {
            var taught = 0
            try GRDBDatabaseManager.shared.write { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT text, review_status FROM utterances
                    WHERE is_hidden = 1 AND review_status IN (?, ?)
                """, arguments: [UtteranceReviewStatus.autoHidden.rawValue,
                                 UtteranceReviewStatus.userHidden.rawValue])
                for row in rows {
                    let source: HallucinationExemplarStore.Source =
                        (row["review_status"] as String?) == UtteranceReviewStatus.userHidden.rawValue ? .user : .detector
                    try HallucinationExemplarStore.recordBad(db, text: row["text"], source: source)
                    taught += 1
                }
            }
            settingsRepo.setBool(true, forKey: bootstrapKey)
            if taught > 0 {
                logger.info("[CleanupQueue] Exemplar memory bootstrapped from \(taught) previously hidden line(s)")
            }
        } catch {
            logger.error("[CleanupQueue] Exemplar bootstrap failed: \(error.localizedDescription)")
        }
    }

    /// Discover recordings never cleaned (`transcript_cleaned_at IS NULL`, with utterances) and
    /// enqueue them newest-first. The exemplar sweep runs on every tick regardless of the
    /// toggle (it needs no GPU); the full detector backfill below stays opt-in.
    @MainActor
    func performMaintenance() async {
        await runExemplarSweepNow()

        guard !isPerformingMaintenance,
              GlobalModelSettings.shared.autoCleanTranscripts else { return }
        isPerformingMaintenance = true
        defer { isPerformingMaintenance = false }

        do {
            let candidates: [(id: Int64, title: String)] = try GRDBDatabaseManager.shared.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT r.id AS id, r.title AS title
                    FROM recordings r
                    WHERE r.transcript_cleaned_at IS NULL
                      AND EXISTS (SELECT 1 FROM utterances u WHERE u.recording_id = r.id)
                    ORDER BY r.created_at DESC
                    LIMIT 500
                """).map { ($0["id"] as Int64, $0["title"] as String) }
            }
            var added = 0
            for candidate in candidates {
                if enqueue(recordingId: candidate.id, recordingTitle: candidate.title,
                           mode: .backfill, priority: .low) != nil { added += 1 }
            }
            if added > 0 { logger.info("[CleanupQueue] Enqueued \(added) recordings for cleanup backfill") }
            await retryFailedJobs()
        } catch {
            logger.error("[CleanupQueue] Maintenance failed: \(error.localizedDescription)")
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
            // Memory gate: every verification span reloads the whole Gemma model — never launch
            // that into a starved system, and respect the Metal-OOM cooldown.
            if let deferral = SystemMemoryGate.shared.deferral(modelBytes: estimatedModelBytes()) {
                if await getNextJob() == nil { break } // nothing queued — don't idle deferred forever
                try? await Task.sleep(nanoseconds: UInt64(deferral.retryAfter * 1_000_000_000))
                continue
            }

            // Suspends until the GPU is exclusively ours; false = the worker task was cancelled
            // (e.g. preempted by transcription) — stop the loop, the restart hook respawns us.
            guard await GPUResourceManager.shared.acquire(.cleanup) else { break }
            gpuHeld = true

            guard let job = await getNextJob() else {
                await MainActor.run { GPUResourceManager.shared.release(.cleanup) }
                gpuHeld = false
                break
            }

            await processJob(job)

            await MainActor.run { GPUResourceManager.shared.release(.cleanup) }
            gpuHeld = false
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        if gpuHeld { await MainActor.run { GPUResourceManager.shared.release(.cleanup) } }
        await MainActor.run {
            // A preempted worker may finish after its replacement has started. Never let that stale
            // task clear the replacement's latch or visible state.
            guard processingGeneration == generation else { return }
            processingGeneration = nil
            processingTask = nil
            isProcessing = false
            currentJob = nil
            currentStatus = ""
        }
    }

    private func getNextJob() async -> TranscriptCleanupJob? {
        await MainActor.run { pendingJobs.first }
    }

    /// No heavyweight audio verifier is loaded while Gemma audio input is deferred.
    private func estimatedModelBytes() -> UInt64? {
        nil
    }

    private func processJob(_ job: TranscriptCleanupJob) async {
        var job = job
        job.status = .processing
        job.startedAt = Date()
        let started = job
        await MainActor.run {
            currentJob = started
            updateJob(started)
            currentStatus = "Cleaning transcript: \(started.recordingTitle)"
        }

        do {
            let outcome = try await service.cleanRecording(recordingId: job.recordingId, force: job.force) { [weak self] status in
                Task { @MainActor in self?.currentStatus = "\(started.recordingTitle): \(status)" }
            }
            job.status = .completed
            job.outcomeSummary = outcome.summary
        } catch {
            // Preemption (CancellationError or the child killed while the worker is cancelled)
            // and Metal OOM requeue as .pending; only genuine errors fail. See the pure helper.
            job = Self.resolvedAfterError(job, error: error, workerCancelled: Task.isCancelled)
            if job.status == .failed {
                logger.error("[CleanupQueue] Job failed (recording \(job.recordingId)): \(error.localizedDescription)")
            } else if case TranscriptionError.gpuOutOfMemory = error {
                logger.warning("[CleanupQueue] Requeued after Metal OOM (recording \(job.recordingId)) — gate cooldown active")
            }
        }
        job.completedAt = Date()

        let final = job
        await MainActor.run {
            updateJob(final)
            currentJob = nil
        }
    }

    private func updateJob(_ job: TranscriptCleanupJob) {
        if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i] = job }
    }

    // MARK: - Requeue / preemption policy (pure, unit-tested)

    /// A preempted/interrupted job, reset so the worker loop picks it up again. `.pending` —
    /// NOT `.paused`: only pending jobs are scanned by the worker and only failed ones by
    /// `retryFailedJobs`. cleanRecording is safe to restart (already-settled lines are skipped).
    static func requeued(_ job: TranscriptCleanupJob) -> TranscriptCleanupJob {
        var job = job
        job.status = .pending
        job.startedAt = nil
        return job
    }

    /// Resolve a job whose processing threw. Preemption (the service's CancellationError, or the
    /// llama child killed while the worker task is cancelled) and Metal OOM are NOT failures:
    /// both requeue without burning retry budget. OOM is systemic — `SystemMemoryGate`'s cooldown
    /// (fed by the process layer) holds the relaunch back for minutes.
    static func resolvedAfterError(_ job: TranscriptCleanupJob, error: Error, workerCancelled: Bool) -> TranscriptCleanupJob {
        if workerCancelled || error is CancellationError {
            return requeued(job)
        }
        if case TranscriptionError.gpuOutOfMemory = error {
            return requeued(job)
        }
        var job = job
        job.status = .failed
        job.error = error.localizedDescription
        return job
    }

    // MARK: - Persistence (AppSettings only — no DB migration)

    private func persistQueue() {
        let toPersist = jobs.filter { $0.status == .pending || $0.status == .processing || $0.status == .failed || $0.status == .paused }
        var ids: [String] = []
        for job in toPersist {
            if let data = try? JSONEncoder().encode(job) {
                settingsRepo.setData(data, forKey: jobKey(job.id.uuidString))
                ids.append(job.id.uuidString)
            }
        }
        let oldIds = (settingsRepo.getString(forKey: indexKey) ?? "").split(separator: ",").map(String.init)
        for old in oldIds where !ids.contains(old) {
            settingsRepo.removeObject(forKey: jobKey(old))
        }
        settingsRepo.setString(ids.joined(separator: ","), forKey: indexKey)
    }

    private func loadQueue() {
        let ids = (settingsRepo.getString(forKey: indexKey) ?? "").split(separator: ",").map(String.init)
        var loaded: [TranscriptCleanupJob] = []
        for id in ids {
            guard let data = settingsRepo.getData(forKey: jobKey(id)),
                  var job = try? JSONDecoder().decode(TranscriptCleanupJob.self, from: data) else { continue }
            if job.status == .processing || job.status == .paused { // interrupted last launch → resume
                job.status = .pending
                job.startedAt = nil
            }
            loaded.append(job)
        }
        jobs = loaded
    }
}
