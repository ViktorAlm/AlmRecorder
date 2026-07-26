import Combine
import Foundation

struct NightlyRetranscriptionConfiguration: Codable, Equatable {
    var enabled = false
    var window = NightlyProcessingWindow.defaultWindow
    var excludeSpeakerGold = true
    var preventIdleSleepWhileProcessing = true
}

struct NightlyRetranscriptionItem: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        case pending
        case active
        case completed
        case failed
        case skipped
    }

    let id: Int64
    let title: String
    let duration: TimeInterval
    var state: State = .pending
    var attempts = 0
    var lastError: String?
}

struct NightlyRetranscriptionManifest: Codable, Equatable {
    let id: UUID
    let createdAt: Date
    var runSettings: RunSettings
    var items: [NightlyRetranscriptionItem]
    var activeJobID: UUID?
    var activeRecordingID: Int64?
    var activeStartedAt: Date?
    var observedRealTimeFactor: Double?
    var completedWallClockSeconds: TimeInterval = 0

    var completedCount: Int {
        items.filter { $0.state == .completed }.count
    }

    var failedCount: Int {
        items.filter { $0.state == .failed }.count
    }

    var terminalCount: Int {
        items.filter { $0.state == .completed || $0.state == .failed || $0.state == .skipped }.count
    }

    var isComplete: Bool {
        terminalCount == items.count
    }

    var remainingAudioSeconds: TimeInterval {
        items
            .filter { $0.state == .pending || $0.state == .active }
            .reduce(0) { $0 + $1.duration }
    }
}

/// Runs a durable library re-transcription a single recording at a time inside an overnight
/// window. It never floods the normal queue, excludes speaker-gold calls by default, and snapshots
/// both the ASR engine and speaker pipeline for reproducibility.
@MainActor
final class NightlyRetranscriptionController: ObservableObject {
    static let shared = NightlyRetranscriptionController()

    @Published private(set) var configuration = NightlyRetranscriptionConfiguration()
    @Published private(set) var manifest: NightlyRetranscriptionManifest?
    @Published private(set) var libraryRecordingCount = 0
    @Published private(set) var eligibleRecordingCount = 0
    @Published private(set) var excludedGoldCount = 0
    @Published private(set) var missingAudioCount = 0
    @Published private(set) var eligibleAudioSeconds: TimeInterval = 0
    @Published private(set) var statusText = "Not scheduled"

    private struct PersistedState: Codable {
        var configuration: NightlyRetranscriptionConfiguration
        var manifest: NightlyRetranscriptionManifest?
    }

    private static let persistenceKey = "nightlyRetranscription.state.v1"
    private static let maximumAttempts = 2
    private static let fallbackRealTimeFactor = 0.70

    private let settings = GRDBSettingsRepository.shared
    private let recordings = GRDBRecordingRepository()
    private let queue = TranscriptionQueueManager.shared
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var activityToken: NSObjectProtocol?

    private init() {
        restore()
        refreshLibrarySummary()
        reconcileRestoredActiveJob()

        queue.jobCompleted
            .receive(on: RunLoop.main)
            .sink { [weak self] job in self?.handleCompletion(job) }
            .store(in: &cancellables)
        queue.jobFailed
            .receive(on: RunLoop.main)
            .sink { [weak self] job in self?.handleFailure(job) }
            .store(in: &cancellables)

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    deinit {
        timer?.invalidate()
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
        }
    }

    var progress: Double {
        guard let manifest, !manifest.items.isEmpty else { return 0 }
        return Double(manifest.terminalCount) / Double(manifest.items.count)
    }

    var activeTitle: String? {
        guard let id = manifest?.activeRecordingID else { return nil }
        return manifest?.items.first(where: { $0.id == id })?.title
    }

    var effectiveRealTimeFactor: Double {
        manifest?.observedRealTimeFactor ?? benchmarkRealTimeFactor()
    }

    var estimatedRemainingSeconds: TimeInterval {
        (manifest?.remainingAudioSeconds ?? eligibleAudioSeconds) * effectiveRealTimeFactor
    }

    var estimatedNightsRemaining: Int {
        let usableWindow = max(1, configuration.window.duration * 0.85)
        return max(0, Int(ceil(estimatedRemainingSeconds / usableWindow)))
    }

    var settingsSummary: String {
        guard let runSettings = manifest?.runSettings else {
            let engine = TranscriptionEngineSelection.snapshot().displayName
            return "\(engine) · \(SpeakerPipelineSettings.shared.selectedProfile.displayName)"
        }
        return "\(runSettings.engineSelection?.displayName ?? "Current engine") · "
            + "\(runSettings.speakerProfile?.displayName ?? "Current speaker profile")"
    }

    func setEnabled(_ enabled: Bool) {
        configuration.enabled = enabled
        if enabled {
            if manifest == nil || manifest?.isComplete == true {
                createPlan()
            }
            statusText = configuration.window.contains(Date())
                ? "Waiting for the queue…"
                : nextWindowText()
        } else {
            cancelPendingActiveJobIfNeeded()
            statusText = manifest?.activeJobID == nil
                ? "Paused"
                : "Pausing after the current recording"
        }
        persist()
        tick()
    }

    func setWindow(startMinute: Int? = nil, endMinute: Int? = nil) {
        // A scheduled-but-not-started job carries its own durable window snapshot. Remove it before
        // changing the window so it cannot remain "active" in the plan while no worker may claim it.
        cancelPendingActiveJobIfNeeded()
        if let startMinute {
            configuration.window.startMinute = min(1439, max(0, startMinute))
        }
        if let endMinute {
            configuration.window.endMinute = min(1439, max(0, endMinute))
        }
        persist()
        tick()
    }

    func setExcludeSpeakerGold(_ exclude: Bool) {
        guard manifest?.activeJobID == nil else { return }
        configuration.excludeSpeakerGold = exclude
        createPlan()
        persist()
        tick()
    }

    func setPreventIdleSleep(_ prevent: Bool) {
        configuration.preventIdleSleepWhileProcessing = prevent
        if prevent, manifest?.activeJobID != nil {
            beginActivity()
        } else {
            endActivity()
        }
        persist()
    }

    func restartPlanWithCurrentSettings() {
        guard manifest?.activeJobID == nil else { return }
        createPlan()
        configuration.enabled = true
        persist()
        tick()
    }

    func refreshLibrarySummary() {
        let all = (try? recordings.getAll(limit: 100_000)) ?? []
        libraryRecordingCount = all.count
        excludedGoldCount = all.filter {
            $0.speakerReviewStatus == RecordingSpeakerReviewStatus.gold.rawValue
        }.count
        missingAudioCount = all.filter {
            guard let path = $0.filePath else { return true }
            return !FileManager.default.fileExists(atPath: path)
        }.count
        let eligible = eligibleRecordings(from: all)
        eligibleRecordingCount = eligible.count
        eligibleAudioSeconds = eligible.reduce(0) { $0 + ($1.duration ?? 0) }
    }

    func tick(now: Date = Date()) {
        guard configuration.enabled else { return }
        guard var manifest else {
            createPlan()
            return
        }
        guard !manifest.isComplete else {
            configuration.enabled = false
            self.manifest = manifest
            statusText = "Complete"
            persist()
            return
        }

        if let activeJobID = manifest.activeJobID {
            let queuedJob = queue.jobs.first(where: { $0.id == activeJobID })
            if queuedJob == nil {
                reconcileRestoredActiveJob()
                tick(now: now)
                return
            }
            if queuedJob?.status == .processing {
                statusText = activeTitle.map { "Retranscribing \($0)" } ?? "Retranscribing…"
                beginActivity()
            } else if configuration.window.contains(now) {
                statusText = activeTitle.map { "Starting \($0)…" } ?? "Starting nightly job…"
                endActivity()
                queue.ensureProcessingStarted()
            } else {
                statusText = nextWindowText(from: now)
                endActivity()
            }
            return
        }
        guard configuration.window.contains(now) else {
            statusText = nextWindowText(from: now)
            return
        }
        guard !MeetingRecorder.shared.isRecording else {
            statusText = "Waiting for the meeting recording to finish"
            return
        }
        guard !hasForegroundQueueWork(runID: manifest.id) else {
            statusText = "Waiting for the transcription queue"
            return
        }
        guard let nextIndex = manifest.items.firstIndex(where: { $0.state == .pending }) else {
            self.manifest = manifest
            return
        }

        let item = manifest.items[nextIndex]
        guard let recording = try? recordings.getById(item.id),
              let path = recording.filePath,
              FileManager.default.fileExists(atPath: path) else {
            manifest.items[nextIndex].state = .skipped
            manifest.items[nextIndex].lastError = "Audio file is unavailable"
            self.manifest = manifest
            persist()
            tick(now: now)
            return
        }

        var runSettings = manifest.runSettings
        runSettings.schedulingPolicy = TranscriptionSchedulingPolicy(
            nightlyRunID: manifest.id,
            window: configuration.window
        )
        guard let job = queue.addRetranscribeJob(
            recording: recording,
            runSettings: runSettings,
            priority: .low
        ) else {
            manifest.items[nextIndex].attempts += 1
            manifest.items[nextIndex].lastError = "Could not add the recording to the queue"
            if manifest.items[nextIndex].attempts >= Self.maximumAttempts {
                manifest.items[nextIndex].state = .failed
            }
            self.manifest = manifest
            persist()
            return
        }

        manifest.items[nextIndex].state = .active
        manifest.items[nextIndex].attempts += 1
        manifest.activeJobID = job.id
        manifest.activeRecordingID = item.id
        manifest.activeStartedAt = Date()
        self.manifest = manifest
        statusText = "Retranscribing \(item.title)"
        beginActivity()
        persist()
    }

    private func createPlan() {
        refreshLibrarySummary()
        let all = (try? recordings.getAll(limit: 100_000)) ?? []
        let candidates = eligibleRecordings(from: all)
            .sorted {
                if ($0.duration ?? 0) != ($1.duration ?? 0) {
                    return ($0.duration ?? 0) < ($1.duration ?? 0)
                }
                return ($0.id ?? 0) < ($1.id ?? 0)
            }

        var runSettings = GlobalTranscriptionSettings.shared
            .createRunSettings()
            .snapshottingEngineIfNeeded()
        let runID = UUID()
        runSettings.schedulingPolicy = TranscriptionSchedulingPolicy(
            nightlyRunID: runID,
            window: configuration.window
        )
        manifest = NightlyRetranscriptionManifest(
            id: runID,
            createdAt: Date(),
            runSettings: runSettings,
            items: candidates.compactMap { recording in
                guard let id = recording.id else { return nil }
                return NightlyRetranscriptionItem(
                    id: id,
                    title: recording.title,
                    duration: recording.duration ?? 0
                )
            }
        )
        statusText = candidates.isEmpty ? "No eligible recordings" : nextWindowText()
        persist()
    }

    private func eligibleRecordings(from all: [Recording]) -> [Recording] {
        all.filter { recording in
            guard recording.id != nil,
                  let path = recording.filePath,
                  FileManager.default.fileExists(atPath: path) else { return false }
            if configuration.excludeSpeakerGold,
               recording.speakerReviewStatus == RecordingSpeakerReviewStatus.gold.rawValue {
                return false
            }
            return true
        }
    }

    private func hasForegroundQueueWork(runID: UUID) -> Bool {
        queue.jobs.contains { job in
            guard job.status == .pending
                    || job.status == .processing
                    || job.status == .paused
                    || job.status == .waitingForModel
                    || job.status == .interrupted else { return false }
            return job.runSettings.schedulingPolicy?.nightlyRunID != runID
        }
    }

    private func handleCompletion(_ job: TranscriptionJob) {
        guard var manifest,
              job.id == manifest.activeJobID,
              let recordingID = manifest.activeRecordingID,
              let index = manifest.items.firstIndex(where: { $0.id == recordingID }) else {
            return
        }
        let elapsed = max(
            0,
            (job.completedAt ?? Date()).timeIntervalSince(
                job.startedAt ?? manifest.activeStartedAt ?? Date()
            )
        )
        let duration = max(1, manifest.items[index].duration)
        let sampleRTF = elapsed / duration
        if sampleRTF.isFinite, sampleRTF > 0 {
            manifest.observedRealTimeFactor = manifest.observedRealTimeFactor
                .map { 0.75 * $0 + 0.25 * sampleRTF }
                ?? sampleRTF
        }
        manifest.completedWallClockSeconds += elapsed
        manifest.items[index].state = .completed
        manifest.items[index].lastError = nil
        manifest.activeJobID = nil
        manifest.activeRecordingID = nil
        manifest.activeStartedAt = nil
        self.manifest = manifest
        if !configuration.enabled {
            statusText = "Paused"
        }
        endActivity()
        persist()
        Task {
            try? await Task.sleep(for: .seconds(6))
            await MainActor.run { self.tick() }
        }
    }

    private func handleFailure(_ job: TranscriptionJob) {
        guard var manifest,
              job.id == manifest.activeJobID,
              let recordingID = manifest.activeRecordingID,
              let index = manifest.items.firstIndex(where: { $0.id == recordingID }) else {
            return
        }
        manifest.items[index].lastError = job.error ?? "Transcription failed"
        manifest.items[index].state = manifest.items[index].attempts >= Self.maximumAttempts
            ? .failed
            : .pending
        manifest.activeJobID = nil
        manifest.activeRecordingID = nil
        manifest.activeStartedAt = nil
        self.manifest = manifest
        if !configuration.enabled {
            statusText = "Paused"
        }
        endActivity()
        persist()
        Task {
            try? await Task.sleep(for: .seconds(6))
            await MainActor.run { self.tick() }
        }
    }

    private func reconcileRestoredActiveJob() {
        guard var manifest,
              let jobID = manifest.activeJobID,
              let recordingID = manifest.activeRecordingID,
              !queue.jobs.contains(where: { $0.id == jobID }) else { return }

        let completedAfterStart: Bool
        if let recording = try? recordings.getById(recordingID),
           let transcribedAt = recording.transcribedAt,
           let startedAt = manifest.activeStartedAt {
            completedAfterStart = transcribedAt >= startedAt
        } else {
            completedAfterStart = false
        }
        if let index = manifest.items.firstIndex(where: { $0.id == recordingID }) {
            manifest.items[index].state = completedAfterStart ? .completed : .pending
            if !completedAfterStart {
                manifest.items[index].lastError = "Interrupted; queued to retry"
            }
        }
        manifest.activeJobID = nil
        manifest.activeRecordingID = nil
        manifest.activeStartedAt = nil
        self.manifest = manifest
        persist()
    }

    private func cancelPendingActiveJobIfNeeded() {
        guard var manifest,
              let jobID = manifest.activeJobID,
              let index = queue.jobs.firstIndex(where: { $0.id == jobID }),
              queue.jobs[index].status != .processing else { return }
        queue.cancelJob(jobID)
        if let recordingID = manifest.activeRecordingID,
           let itemIndex = manifest.items.firstIndex(where: { $0.id == recordingID }) {
            manifest.items[itemIndex].state = .pending
        }
        manifest.activeJobID = nil
        manifest.activeRecordingID = nil
        manifest.activeStartedAt = nil
        self.manifest = manifest
        endActivity()
    }

    private func benchmarkRealTimeFactor() -> Double {
        guard let selection = manifest?.runSettings.engineSelection
            ?? RunSettings.defaultSettings.snapshottingEngineIfNeeded().engineSelection else {
            return Self.fallbackRealTimeFactor
        }
        guard selection.backend == .vibeVoice,
              let quantization = selection.vibeVoiceQuantization,
              let mode = selection.vibeVoiceSpeakerMode,
              let report = VibeVoiceGoldBenchmarkStore.load()?.reports.first(where: {
                  $0.configuration.quantization == quantization
                      && $0.configuration.speakerMode == mode
              }),
              let rtf = report.metrics.realTimeFactor,
              rtf > 0 else {
            return Self.fallbackRealTimeFactor
        }
        return rtf
    }

    private func nextWindowText(from date: Date = Date()) -> String {
        if configuration.window.contains(date) {
            return "Ready during the current nightly window"
        }
        guard let next = configuration.window.nextStart(after: date) else {
            return "Waiting for the nightly window"
        }
        return "Next run \(next.formatted(date: .abbreviated, time: .shortened))"
    }

    private func beginActivity() {
        guard configuration.preventIdleSleepWhileProcessing, activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Nightly AlmRecorder re-transcription"
        )
    }

    private func endActivity() {
        guard let activityToken else { return }
        ProcessInfo.processInfo.endActivity(activityToken)
        self.activityToken = nil
    }

    private func persist() {
        let state = PersistedState(configuration: configuration, manifest: manifest)
        settings.setData(try? JSONEncoder().encode(state), forKey: Self.persistenceKey)
    }

    private func restore() {
        guard let data = settings.getData(forKey: Self.persistenceKey),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return
        }
        configuration = state.configuration
        manifest = state.manifest
    }
}
