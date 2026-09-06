import Combine
import Foundation
import GRDB

/// Maximum-quality background transcript refinement:
///
/// 1. fused VibeVoice is committed, indexed, and usable immediately by the foreground pipeline;
/// 2. the exact committed VibeVoice speaker turns become the immutable nightly structure anchor;
/// 3. Whisper creates a fresh, independent noise-robust candidate;
/// 4. Gemma listens to the matching audio and repairs one locked VibeVoice turn at a time from
///    both ASR candidates and three turns of context on either side;
/// 5. safe audio-grounded one-to-one repairs commit automatically, then embeddings, insights, and
///    the normal reversible cleanup pipeline refresh the derived data.
///
/// The controller never starts while foreground transcription is queued, and its GPU lease is
/// preemptible. Per-recording candidate artifacts make every stage crash-resumable.
@MainActor
final class NightlyQualityController: ObservableObject {
    static let shared = NightlyQualityController()

    @Published private(set) var configuration = NightlyQualityConfiguration()
    @Published private(set) var manifest: NightlyQualityManifest?
    @Published private(set) var libraryRecordingCount = 0
    @Published private(set) var eligibleRecordingCount = 0
    @Published private(set) var excludedGoldCount = 0
    @Published private(set) var missingAudioCount = 0
    @Published private(set) var eligibleAudioSeconds: TimeInterval = 0
    @Published private(set) var statusText = "Preparing nightly quality plan"
    @Published private(set) var manualRunRecordingID: Int64?
    @Published private(set) var queuedRerunRecordingID: Int64?
    @Published private(set) var queuedRerunDescription: String?

    private struct PersistedState: Codable {
        var configuration: NightlyQualityConfiguration
        var manifest: NightlyQualityManifest?
    }

    private enum QueuedManualRerun {
        case comparison(recordingID: Int64, scope: NightlyQualityRerunScope)
        case consensusStrategies(
            recordingID: Int64,
            strategies: [ConsensusRepairStrategy]
        )
        case foreground(recordingID: Int64)
    }

    private struct WhisperCandidateSettings: Codable {
        /// Bump whenever the timestamp extraction or transcript-row assembly semantics change.
        let pipelineVersion: Int
        let selection: TranscriptionEngineSelection
        let speakerConfiguration: SpeakerPipelineConfiguration
        let persistSpeakerIdentities: Bool
    }

    private static let persistenceKey = "nightlyQuality.state.v1"
    private static let productionRolloutKey =
        "nightlyQuality.vibeVoiceForegroundEditorial.v1"
    private static let maximumAttempts = 3
    private static let fallbackRealTimeFactor = 2.0

    private let settings = GRDBSettingsRepository.shared
    private let recordingRepository = GRDBRecordingRepository()
    private let utteranceRepository = GRDBUtteranceRepository()
    private let artifactStore = NightlyQualityArtifactStore.shared
    private let transcriptionQueue = TranscriptionQueueManager.shared
    private let cleanupQueue = TranscriptCleanupQueueManager.shared
    private var timer: Timer?
    private var processingTask: Task<Void, Never>?
    private var processingGeneration: UUID?
    private var activityToken: NSObjectProtocol?
    private var foregroundRerunSubscriptions = Set<AnyCancellable>()
    private var queuedManualRerun: QueuedManualRerun?

    private init() {
        restore()
        applyProductionRolloutIfNeeded()
        recoverInterruptedState()
        refreshLibrarySummary()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    deinit {
        timer?.invalidate()
        processingTask?.cancel()
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
        }
    }

    var progress: Double {
        guard let manifest, !manifest.items.isEmpty else { return 0 }
        let stageValue: [NightlyQualityStage: Double] = [
            .whisper: 0,
            .vibeVoice: 1,
            .gemmaFinalization: 2,
            .cleanup: 3,
            .completed: 4
        ]
        let work = manifest.items.reduce(0.0) { partial, item in
            if item.state == .completed || item.stage == .completed {
                return partial + 4
            }
            return partial + (stageValue[item.stage] ?? 0)
        }
        return work / Double(manifest.items.count * 4)
    }

    var activeItem: NightlyQualityItem? {
        guard let id = manifest?.activeRecordingID else { return nil }
        return manifest?.items.first(where: { $0.id == id })
    }

    var currentTelemetry: NightlyQualityTelemetry? {
        activeItem?.telemetry
    }

    var benchmarkMetrics: [NightlyQualityAggregateMetric] {
        guard let manifest else { return [] }
        let reports = manifest.items.compactMap {
            artifactStore.load(recordingID: $0.id)?.benchmarkReport
        }
        let grouped = Dictionary(grouping: reports.flatMap(\.metrics), by: \.candidate)
        return grouped.map { candidate, metrics in
            NightlyQualityAggregateMetric(
                candidate: candidate,
                recordingCount: metrics.count,
                referenceSegmentCount: metrics.reduce(0) {
                    $0 + $1.referenceSegmentCount
                },
                wordErrors: metrics.reduce(0) { $0 + $1.wordErrors },
                referenceWordCount: metrics.reduce(0) { $0 + $1.referenceWordCount },
                characterErrors: metrics.reduce(0) { $0 + $1.characterErrors },
                referenceCharacterCount: metrics.reduce(0) {
                    $0 + $1.referenceCharacterCount
                },
                matchedBoundaries: metrics.reduce(0) {
                    $0 + ($1.matchedBoundaries ?? 0)
                },
                referenceBoundaryCount: metrics.reduce(0) {
                    $0 + ($1.referenceBoundaryCount ?? 0)
                },
                candidateBoundaryCount: metrics.reduce(0) {
                    $0 + ($1.candidateBoundaryCount ?? 0)
                }
            )
        }.sorted {
            ($0.wordErrorRate ?? .greatestFiniteMagnitude)
                < ($1.wordErrorRate ?? .greatestFiniteMagnitude)
        }
    }

    var structuralProposalCount: Int {
        guard let manifest else { return 0 }
        return manifest.items.reduce(0) { count, item in
            artifactStore.load(recordingID: item.id)?.requiresSpeakerReprocessing == true
                ? count + 1
                : count
        }
    }

    var estimatedRemainingSeconds: TimeInterval {
        (manifest?.remainingModelAudioWorkSeconds ?? eligibleAudioSeconds * 2)
            * (manifest?.observedRealTimeFactor ?? Self.fallbackRealTimeFactor)
    }

    var estimatedNightsRemaining: Int {
        let usableWindow = max(1, configuration.window.duration * 0.85)
        return max(0, Int(ceil(estimatedRemainingSeconds / usableWindow)))
    }

    var pipelineSummary: String {
        let whisper = manifest?.whisperVariantIdentifier
            ?? GlobalModelSettings.shared.selectedWhisperVariant?.toIdentifier()
            ?? "default"
        let vibeVoice = manifest?.vibeVoiceQuantization.rawValue
            ?? TranscriptionProductionDefaults.vibeVoiceQuantization.rawValue
        return "VibeVoice \(vibeVoice)"
            + " foreground → indexed → Whisper \(whisper)"
            + " → Editorial Gemma audio repair "
            + (manifest?.gemmaModelKey ?? configuration.gemmaAudioModelKey)
            + (configuration.commitPolicy == .shadow
                ? " → private benchmark"
                : " → commit → re-index + cleanup")
    }

    func setEnabled(_ enabled: Bool) {
        configuration.enabled = enabled
        if enabled {
            if manifest == nil || manifest?.isComplete == true {
                createPlan()
            }
            tick()
        } else {
            manualRunRecordingID = nil
            stopProcessing(reason: "Paused")
        }
        persist()
    }

    /// Runs exactly one pending call through every configured quality stage without changing the
    /// nightly schedule. Resource admission, foreground preemption, retries, and shadow/automatic
    /// result handling remain identical to a scheduled run.
    func runNextComparisonNow() {
        guard configuration.enabled else {
            statusText = "Enable nightly transcript quality first"
            return
        }
        if manifest == nil || manifest?.isComplete == true {
            createPlan()
        }
        guard let manifest,
              let next = nextPendingItem(in: manifest) else {
            statusText = "No pending quality comparison"
            return
        }
        manualRunRecordingID = next.id
        statusText = "Run now queued · \(next.title)"
        tick()
    }

    func runComparisonNow(recordingID: Int64) {
        guard configuration.enabled else {
            statusText = "Enable nightly transcript quality first"
            return
        }
        guard processingTask == nil, manifest?.activeRecordingID == nil else {
            statusText = "Another quality comparison is already processing"
            return
        }
        guard let item = manifest?.items.first(where: { $0.id == recordingID }) else {
            statusText = "This call is not in the current evaluation plan"
            return
        }
        guard item.state == .pending else {
            statusText = item.state == .completed
                ? "This quality comparison is already complete"
                : "This call cannot run from its current \(item.state.rawValue) state"
            return
        }
        manualRunRecordingID = recordingID
        statusText = "Run now queued · \(item.title)"
        tick()
    }

    /// Re-runs one comparison stage with dependency-aware invalidation. Independent upstream
    /// candidates are preserved, while every downstream output is cleared and rebuilt.
    func rerunComparisonNow(
        recordingID: Int64,
        scope: NightlyQualityRerunScope
    ) {
        guard configuration.enabled else {
            statusText = "Enable nightly transcript quality first"
            return
        }
        if processingTask != nil || manifest?.activeRecordingID != nil {
            queueManualRerun(
                .comparison(recordingID: recordingID, scope: scope),
                recordingID: recordingID,
                description: "Re-run \(scope.displayName)"
            )
            preemptActiveQualityStepForManualRerun()
            return
        }
        executeComparisonRerun(recordingID: recordingID, scope: scope)
    }

    private func executeComparisonRerun(
        recordingID: Int64,
        scope: NightlyQualityRerunScope
    ) {
        guard var manifest,
              let itemIndex = manifest.items.firstIndex(where: { $0.id == recordingID }) else {
            statusText = "This call is not in the current evaluation plan"
            return
        }
        guard let recording = try? recordingRepository.getById(recordingID),
              let audioPath = recording.filePath,
              FileManager.default.fileExists(atPath: audioPath) else {
            statusText = "The original audio is unavailable for this call"
            return
        }

        do {
            var artifact = try makeOrLoadArtifact(
                recording: recording,
                audioPath: audioPath
            )
            artifact.invalidateForRerun(scope)
            try artifactStore.save(artifact)

            manifest.items[itemIndex].stage = Self.pendingStage(
                artifact: artifact,
                commitPolicy: manifest.commitPolicy ?? configuration.commitPolicy
            )
            manifest.items[itemIndex].state = .pending
            manifest.items[itemIndex].attempts = 0
            manifest.items[itemIndex].lastError = nil
            manifest.items[itemIndex].cleanupJobID = nil
            manifest.items[itemIndex].telemetry = NightlyQualityTelemetry()
            self.manifest = manifest
            manualRunRecordingID = recordingID
            statusText = "Fresh \(scope.displayName) run queued · \(recording.title)"
            persist()
            tick()
        } catch {
            statusText = "Could not reset \(scope.displayName): \(error.localizedDescription)"
        }
    }

    func rerunConsensusNow(
        recordingID: Int64,
        strategies: [ConsensusRepairStrategy]
    ) {
        let uniqueStrategies = ConsensusRepairStrategy.allCases.filter(strategies.contains)
        guard !uniqueStrategies.isEmpty else { return }
        guard configuration.enabled else {
            statusText = "Enable nightly transcript quality first"
            return
        }
        if processingTask != nil || manifest?.activeRecordingID != nil {
            queueManualRerun(
                .consensusStrategies(
                    recordingID: recordingID,
                    strategies: uniqueStrategies
                ),
                recordingID: recordingID,
                description: uniqueStrategies.count == 1
                    ? "Re-run \(uniqueStrategies[0].displayName)"
                    : "Run all \(uniqueStrategies.count) consensus strategies"
            )
            preemptActiveQualityStepForManualRerun()
            return
        }
        executeConsensusRerun(
            recordingID: recordingID,
            strategies: uniqueStrategies
        )
    }

    private func executeConsensusRerun(
        recordingID: Int64,
        strategies: [ConsensusRepairStrategy]
    ) {
        guard var manifest,
              let itemIndex = manifest.items.firstIndex(where: { $0.id == recordingID }) else {
            statusText = "This call is not in the current evaluation plan"
            return
        }
        guard let recording = try? recordingRepository.getById(recordingID),
              let audioPath = recording.filePath,
              FileManager.default.fileExists(atPath: audioPath) else {
            statusText = "The original audio is unavailable for this call"
            return
        }
        do {
            var artifact = try makeOrLoadArtifact(
                recording: recording,
                audioPath: audioPath
            )
            guard artifact.whisperCandidate != nil, artifact.vibeVoice != nil else {
                statusText = "Run Whisper and VibeVoice before consensus"
                return
            }
            artifact.invalidateForRerun(.consensus)
            let requested = Set(strategies)
            artifact.consensusVariants = (artifact.consensusVariants ?? []).filter {
                !requested.contains($0.strategy)
            }
            artifact.requestedConsensusStrategies = strategies
            try artifactStore.save(artifact)

            manifest.items[itemIndex].stage = .gemmaFinalization
            manifest.items[itemIndex].state = .pending
            manifest.items[itemIndex].attempts = 0
            manifest.items[itemIndex].lastError = nil
            manifest.items[itemIndex].cleanupJobID = nil
            manifest.items[itemIndex].telemetry = NightlyQualityTelemetry()
            self.manifest = manifest
            manualRunRecordingID = recordingID
            statusText = strategies.count == 1
                ? "\(strategies[0].displayName) queued · \(recording.title)"
                : "Three consensus strategies queued · \(recording.title)"
            persist()
            tick()
        } catch {
            statusText = "Could not reset consensus: \(error.localizedDescription)"
        }
    }

    /// Foreground is the visible, committed transcript rather than a private candidate. Re-run it
    /// through the normal immediate queue, preserving user decisions via RetranscribeCarryover.
    /// When it finishes, the comparison is invalidated and all private candidates run again.
    func retranscribeForegroundAndRerunComparison(recordingID: Int64) {
        guard configuration.enabled else {
            statusText = "Enable nightly transcript quality first"
            return
        }
        if processingTask != nil || manifest?.activeRecordingID != nil {
            queueManualRerun(
                .foreground(recordingID: recordingID),
                recordingID: recordingID,
                description: "Re-transcribe foreground"
            )
            preemptActiveQualityStepForManualRerun()
            return
        }
        executeForegroundRerun(recordingID: recordingID)
    }

    private func executeForegroundRerun(recordingID: Int64) {
        guard let recording = try? recordingRepository.getById(recordingID),
              let audioPath = recording.filePath,
              FileManager.default.fileExists(atPath: audioPath) else {
            statusText = "The original audio is unavailable for this call"
            return
        }
        guard let job = transcriptionQueue.addRetranscribeJob(
            recording: recording,
            priority: .immediate
        ) else {
            statusText = "Could not queue foreground re-transcription"
            return
        }

        statusText = "Foreground re-transcription queued · \(recording.title)"
        transcriptionQueue.jobCompleted
            .filter { $0.id == job.id }
            .prefix(1)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.rerunComparisonNow(
                        recordingID: recordingID,
                        scope: .allCandidates
                    )
                }
            }
            .store(in: &foregroundRerunSubscriptions)
        transcriptionQueue.jobFailed
            .filter { $0.id == job.id }
            .prefix(1)
            .sink { [weak self] failedJob in
                Task { @MainActor [weak self] in
                    self?.statusText = "Foreground re-transcription failed: "
                        + (failedJob.error ?? "unknown error")
                }
            }
            .store(in: &foregroundRerunSubscriptions)
    }

    private func queueManualRerun(
        _ request: QueuedManualRerun,
        recordingID: Int64,
        description: String
    ) {
        queuedManualRerun = request
        queuedRerunRecordingID = recordingID
        queuedRerunDescription = description
        let activeTitle = activeItem?.title ?? "the active call"
        statusText = "\(description) taking priority · stopping \(activeTitle)"
    }

    private func preemptActiveQualityStepForManualRerun() {
        stopProcessing(reason: "Stopping the current nightly step for your rerun")
        // Cancellation is synchronous at the controller but the model process and GPU lease need
        // a brief handoff before another heavyweight model can be admitted.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            self?.tick()
        }
    }

    /// Two heavyweight model processes never overlap. A manual request cancels the active nightly
    /// step, waits for its GPU lease to unwind, then runs before any scheduled item.
    @discardableResult
    private func drainQueuedManualRerunIfPossible() -> Bool {
        guard processingTask == nil,
              manifest?.activeRecordingID == nil,
              let request = queuedManualRerun else {
            return false
        }
        queuedManualRerun = nil
        queuedRerunRecordingID = nil
        queuedRerunDescription = nil
        switch request {
        case let .comparison(recordingID, scope):
            executeComparisonRerun(recordingID: recordingID, scope: scope)
        case let .consensusStrategies(recordingID, strategies):
            executeConsensusRerun(
                recordingID: recordingID,
                strategies: strategies
            )
        case let .foreground(recordingID):
            executeForegroundRerun(recordingID: recordingID)
        }
        return true
    }

    func setWindow(startMinute: Int? = nil, endMinute: Int? = nil) {
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
        guard processingTask == nil else { return }
        configuration.excludeSpeakerGold = exclude
        createPlan()
        persist()
        tick()
    }

    func setPreventIdleSleep(_ prevent: Bool) {
        configuration.preventIdleSleepWhileProcessing = prevent
        if prevent, processingTask != nil {
            beginActivity()
        } else {
            endActivity()
        }
        persist()
    }

    func setMaximumInputTokens(_ maximum: Int) {
        guard processingTask == nil else { return }
        configuration.maximumInputTokens = min(14_000, max(4_096, maximum))
        persist()
    }

    func setGemmaAudioModel(_ modelKey: String) {
        guard processingTask == nil else { return }
        let validated = GemmaConfiguration.validatedAudioModelKey(modelKey)
        guard configuration.gemmaAudioModelKey != validated else { return }
        configuration.gemmaAudioModelKey = validated
        createPlan()
        statusText = "Gemma audio consensus set to \(validated)"
        persist()
        tick()
    }

    func setMode(_ mode: NightlyQualityMode) {
        guard processingTask == nil else { return }
        configuration.mode = mode
        createPlan()
        persist()
        tick()
    }

    func setCommitPolicy(_ policy: NightlyQualityCommitPolicy) {
        guard processingTask == nil else { return }
        configuration.commitPolicy = policy
        createPlan()
        persist()
        tick()
    }

    func setScope(_ scope: NightlyQualityScope) {
        guard processingTask == nil else { return }
        configuration.scope = scope
        if scope == .newRecordings {
            configuration.enrollmentDate = Date()
        }
        createPlan()
        persist()
        tick()
    }

    /// Enrolls recent calls for private evaluation without manufacturing a gold/edit signal.
    /// Selection is persisted by recording ID so rebuilding the plan keeps the same cohort.
    @discardableResult
    func addMostRecentRecordingsToEvaluation(count: Int = 5) -> [String] {
        guard processingTask == nil else {
            statusText = "Wait for the active quality comparison to finish"
            return []
        }
        let maximum = max(1, count)
        let all = (try? recordingRepository.getAll(limit: 100_000)) ?? []
        let recent = all.filter { recording in
            guard recording.transcribedAt != nil,
                  recording.duration ?? 0 > 0,
                  let path = recording.filePath else {
                return false
            }
            return FileManager.default.fileExists(atPath: path)
        }
        .prefix(maximum)

        let selected = Array(recent)
        configuration.additionalEvaluationRecordingIDs.formUnion(
            selected.compactMap(\.id)
        )
        configuration.scope = .evaluationCohort
        createPlan()
        persist()
        tick()
        statusText = selected.isEmpty
            ? "No recent transcribed calls with available audio"
            : "Added \(selected.count) newest calls to private evaluation"
        return selected.map(\.title)
    }

    func rebuildPlan() {
        guard processingTask == nil else { return }
        createPlan()
        configuration.enabled = true
        persist()
        tick()
    }

    func refreshLibrarySummary() {
        let all = (try? recordingRepository.getAll(limit: 100_000)) ?? []
        libraryRecordingCount = all.count
        excludedGoldCount = all.filter {
            $0.speakerReviewStatus == RecordingSpeakerReviewStatus.gold.rawValue
        }.count
        missingAudioCount = all.filter {
            guard let path = $0.filePath else { return true }
            return !FileManager.default.fileExists(atPath: path)
        }.count
        let eligible = eligibleRecordings(from: all, excludeCompleted: true)
        eligibleRecordingCount = eligible.count
        eligibleAudioSeconds = eligible.reduce(0) { $0 + ($1.duration ?? 0) }
    }

    func tick(now: Date = Date()) {
        reconcileCleanupJobs()
        guard configuration.enabled else {
            statusText = "Paused"
            return
        }
        guard processingTask == nil else { return }
        if drainQueuedManualRerunIfPossible() {
            return
        }

        if manifest == nil {
            createPlan()
        }
        guard let manifest else { return }
        if manifest.isComplete {
            refreshLibrarySummary()
            if eligibleRecordingCount > 0 {
                createPlan()
                tick(now: now)
            } else {
                statusText = "Up to date · waiting for new foreground transcripts"
            }
            return
        }
        if let manualRunRecordingID,
           let manualItem = manifest.items.first(where: { $0.id == manualRunRecordingID }),
           manualItem.state == .completed || manualItem.state == .failed {
            self.manualRunRecordingID = nil
        }
        guard configuration.window.contains(now) || manualRunRecordingID != nil else {
            statusText = nextWindowText(from: now)
            return
        }
        guard !MeetingRecorder.shared.isRecording else {
            statusText = "Waiting for the meeting recording to finish"
            return
        }
        guard !hasForegroundTranscriptionWork else {
            statusText = "Waiting for foreground transcription to finish"
            return
        }
        let next = manualRunRecordingID.flatMap { manualID in
            manifest.items.first {
                $0.id == manualID && $0.state == .pending
            }
        } ?? (manualRunRecordingID == nil ? nextPendingItem(in: manifest) : nil)
        guard let next else {
            statusText = "Waiting for final cleanup"
            return
        }

        if next.stage == .cleanup {
            enqueueCleanup(for: next)
            return
        }
        if let reason = unavailableReason(for: next.stage, manifest: manifest) {
            statusText = reason
            return
        }
        startProcessing(next)
    }

    /// Called by the GPU arbiter before a higher-priority model is admitted.
    func stopProcessingForPreemption() {
        stopProcessing(reason: "Yielded to foreground work")
    }

    /// Called after the preempting GPU consumer releases its model.
    func resumeAfterPreemption() {
        guard configuration.enabled else { return }
        tick()
    }

    private var hasForegroundTranscriptionWork: Bool {
        transcriptionQueue.jobs.contains {
            $0.status == .pending
                || $0.status == .processing
                || $0.status == .paused
                || $0.status == .waitingForModel
                || $0.status == .interrupted
        }
    }

    private func nextPendingItem(
        in manifest: NightlyQualityManifest
    ) -> NightlyQualityItem? {
        // Finish one recording end-to-end so useful benchmark results appear immediately and an
        // interrupted multi-week library plan does not strand every call between model passes.
        manifest.items.first(where: { $0.state == .pending })
    }

    private func startProcessing(_ item: NightlyQualityItem) {
        guard processingTask == nil else { return }
        let generation = UUID()
        processingGeneration = generation
        markActive(item.id)
        beginActivity()
        processingTask = Task { [weak self] in
            guard let self else { return }
            let acquired = await GPUResourceManager.shared.acquire(.nightlyEnhancement)
            guard acquired, !Task.isCancelled else {
                self.finishCancelled(itemID: item.id, generation: generation)
                return
            }
            defer { GPUResourceManager.shared.release(.nightlyEnhancement) }

            do {
                switch item.stage {
                case .whisper:
                    try await self.runWhisper(recordingID: item.id)
                case .vibeVoice:
                    try await self.runVibeVoice(recordingID: item.id)
                case .gemmaFinalization:
                    try await self.runGemma(recordingID: item.id)
                case .cleanup, .completed:
                    break
                }
                self.finishSuccess(itemID: item.id, stage: item.stage, generation: generation)
            } catch is CancellationError {
                self.finishCancelled(itemID: item.id, generation: generation)
            } catch {
                self.finishFailure(
                    itemID: item.id,
                    error: error,
                    generation: generation
                )
            }
        }
    }

    private func runWhisper(recordingID: Int64) async throws {
        guard let manifest,
              let recording = try recordingRepository.getById(recordingID),
              let audioPath = recording.filePath else {
            throw TranscriptionError.invalidURL
        }
        statusText = "Whisper candidate · \(recording.title)"

        var artifact = try makeOrLoadArtifact(recording: recording, audioPath: audioPath)
        let variant = manifest.whisperVariantIdentifier
            .flatMap(WhisperModelVariant.fromIdentifier)
            ?? GlobalModelSettings.shared.selectedWhisperVariant
            ?? WhisperModelVariant.defaultVariant()
        let selection = TranscriptionEngineSelection(
            backend: .whisper,
            whisperVariantIdentifier: variant.toIdentifier(),
            llmEngine: nil,
            llmModelKey: nil,
            vibeVoiceQuantization: nil,
            vibeVoiceSpeakerMode: nil,
            vibeVoiceModelRevision: nil,
            vibeVoiceRuntimeRevision: nil,
            vibeVoiceContext: nil
        )
        let speakerConfiguration = SpeakerPipelineSettings.shared.activeConfiguration
        let candidateSettings = WhisperCandidateSettings(
            pipelineVersion: 4,
            selection: selection,
            speakerConfiguration: speakerConfiguration,
            persistSpeakerIdentities: false
        )
        let candidateSettingsJSON = Self.jsonString(candidateSettings)
        if artifact.whisperCandidate?.provenance?.modelIdentifier == variant.toIdentifier(),
           artifact.whisperCandidate?.provenance?.settingsJSON == candidateSettingsJSON {
            return
        }
        artifact.whisperCandidate = nil
        artifact.blindGemma = nil
        artifact.fused = nil
        artifact.gemmaDecisions = []
        artifact.benchmarkReport = nil
        artifact.completedAt = nil
        let profile = TranscriptionResourceProfile.forSelection(selection)
        if let deferral = SystemMemoryGate.shared.transcriptionDeferral(profile: profile) {
            throw TranscriptionError.resourcesUnavailable(deferral.reason)
        }

        resetStageTelemetry(
            recordingID: recordingID,
            phase: "Starting Whisper transcription",
            totalWorkUnits: 100
        )
        let whisper = WhisperService.shared
        let controller = self
        let progressTask = Task { @MainActor in
            while !Task.isCancelled {
                controller.updateWhisperProgress(
                    recordingID: recordingID,
                    progress: whisper.transcriptionProgress,
                    phase: whisper.transcriptionStatus,
                    estimatedPeakBytes: profile.estimatedPeakBytes
                )
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { progressTask.cancel() }

        let result = try await whisper.transcribeWithResult(
            audioFile: audioPath,
            variant: variant,
            language: Self.whisperLanguage(recording.language),
            speakerConfiguration: speakerConfiguration,
            persistSpeakerIdentities: false
        )
        artifact.whisperCandidate = NightlyQualityCandidate(
            engine: .whisper,
            model: "Whisper · \(variant.displayName)",
            createdAt: Date(),
            segments: result.chunks.map {
                NightlyQualityCandidateSegment(
                    utteranceID: nil,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    text: $0.text,
                    speakerUUID: nil,
                    speakerLabel: $0.nativeSpeakerLabel ?? $0.speaker,
                    userProtected: false,
                    confidence: $0.confidence.map { String($0) },
                    source: "whisper_independent_candidate"
                )
            },
            provenance: NightlyQualityCandidateProvenance(
                role: "independent_candidate",
                engineIdentifier: TranscriptionBackend.whisper.rawValue,
                modelIdentifier: variant.toIdentifier(),
                modelRevision: nil,
                runtimeRevision: nil,
                settingsJSON: candidateSettingsJSON,
                sourceRevisionDate: Date(),
                certainty: .exact
            )
        )
        artifact.updatedAt = Date()
        try artifactStore.save(artifact)
        updateWhisperProgress(
            recordingID: recordingID,
            progress: 1,
            phase: "Whisper candidate complete",
            estimatedPeakBytes: profile.estimatedPeakBytes
        )
    }

    private func runVibeVoice(recordingID: Int64) async throws {
        guard let manifest,
              let recording = try recordingRepository.getById(recordingID),
              let audioPath = recording.filePath else {
            throw TranscriptionError.invalidURL
        }
        statusText = "VibeVoice candidate · \(recording.title)"

        var artifact = try makeOrLoadArtifact(recording: recording, audioPath: audioPath)
        if artifact.vibeVoice?.provenance?.modelIdentifier
            == manifest.vibeVoiceQuantization.repositoryID {
            return
        }
        artifact.vibeVoice = nil
        artifact.blindGemma = nil
        artifact.fused = nil
        artifact.gemmaDecisions = []
        artifact.benchmarkReport = nil
        artifact.completedAt = nil
        resetStageTelemetry(
            recordingID: recordingID,
            phase: "Starting VibeVoice transcription",
            totalWorkUnits: 1
        )

        let selection = TranscriptionEngineSelection(
            backend: .vibeVoice,
            whisperVariantIdentifier: nil,
            llmEngine: nil,
            llmModelKey: nil,
            vibeVoiceQuantization: manifest.vibeVoiceQuantization,
            vibeVoiceSpeakerMode: .native,
            vibeVoiceModelRevision: VibeVoiceConfiguration.modelRevision(
                for: manifest.vibeVoiceQuantization
            ),
            vibeVoiceRuntimeRevision: VibeVoiceConfiguration.mlxAudioRevision,
            vibeVoiceContext: nil
        )
        let profile = TranscriptionResourceProfile.forSelection(selection)
        updateVibeMemory(
            recordingID: recordingID,
            currentBytes: nil,
            availableBytes: SystemMemoryGate.memorySnapshot()?.availableBytes,
            estimatedPeakBytes: profile.estimatedPeakBytes
        )
        let vibeVoice = VibeVoiceService.shared
        let controller = self
        vibeVoice.setMemoryTelemetryHandler { current, available in
            Task { @MainActor in
                controller.updateVibeMemory(
                    recordingID: recordingID,
                    currentBytes: current,
                    availableBytes: available,
                    estimatedPeakBytes: profile.estimatedPeakBytes
                )
            }
        }
        defer { vibeVoice.setMemoryTelemetryHandler(nil) }
        _ = try await vibeVoice.transcribe(
            audioFile: audioPath,
            selection: selection,
            runSettings: nil,
            speakerConfiguration: SpeakerPipelineSettings.shared.activeConfiguration
        )
        guard let result = vibeVoice.lastTranscriptionResult else {
            throw TranscriptionError.invalidResponse
        }
        artifact.vibeVoice = NightlyQualityCandidate(
            engine: .vibeVoice,
            model: selection.displayName,
            createdAt: Date(),
            segments: result.chunks.map {
                NightlyQualityCandidateSegment(
                    utteranceID: nil,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    text: $0.text,
                    speakerUUID: nil,
                    speakerLabel: $0.nativeSpeakerLabel ?? $0.speaker,
                    userProtected: false
                )
            },
            provenance: NightlyQualityCandidateProvenance(
                role: "independent_candidate",
                engineIdentifier: TranscriptionBackend.vibeVoice.rawValue,
                modelIdentifier: manifest.vibeVoiceQuantization.repositoryID,
                modelRevision: selection.vibeVoiceModelRevision,
                runtimeRevision: selection.vibeVoiceRuntimeRevision,
                settingsJSON: Self.jsonString(selection),
                sourceRevisionDate: Date(),
                certainty: .exact
            )
        )
        artifact.updatedAt = Date()
        if let peakGB = vibeVoice.lastPeakMemoryGB {
            artifact.peakRAMBytes = UInt64(max(0, peakGB) * 1_073_741_824)
            updateVibeMemory(
                recordingID: recordingID,
                currentBytes: nil,
                availableBytes: SystemMemoryGate.memorySnapshot()?.availableBytes,
                estimatedPeakBytes: profile.estimatedPeakBytes,
                reportedPeakBytes: artifact.peakRAMBytes
            )
        }
        try artifactStore.save(artifact)
    }

    private func runGemma(recordingID: Int64) async throws {
        guard let manifest,
              let runGeneration = processingGeneration,
              let recording = try recordingRepository.getById(recordingID),
              let audioPath = recording.filePath else {
            throw TranscriptionError.transcriptionFailed(
                "The recording or its audio path is missing"
            )
        }
        // A persisted manifest can survive an app upgrade and resume directly at this stage.
        // Re-enter through the artifact version boundary before writing new consensus output;
        // otherwise a valid v5 result can be trapped inside a legacy v3/v4 envelope and the
        // comparison UI will correctly reject it as stale.
        var artifact = try makeOrLoadArtifact(
            recording: recording,
            audioPath: audioPath
        )
        guard artifact.whisperCandidate != nil else {
            throw TranscriptionError.transcriptionFailed(
                "The independent Whisper candidate is missing"
            )
        }
        guard artifact.vibeVoice != nil else {
            throw TranscriptionError.transcriptionFailed(
                "The VibeVoice candidate is missing"
            )
        }
        let strategies = artifact.requestedConsensusStrategies.flatMap {
            $0.isEmpty ? nil : $0
        } ?? [.readableReconstruction]
        let controller = self
        var completedVariants = artifact.consensusVariants ?? []
        var selectedResult: GemmaFinalizationResult?
        var selectedStrategy: ConsensusRepairStrategy?
        var cumulativeTokensBeforeStrategy = 0

        for (strategyIndex, strategy) in strategies.enumerated() {
            try Task.checkCancellation()
            statusText = strategies.count == 1
                ? "\(strategy.displayName) · \(recording.title)"
                : "\(strategy.displayName) · strategy \(strategyIndex + 1)/"
                    + "\(strategies.count) · \(recording.title)"
            let finalizer = GemmaMultimodalConsensusFinalizer(
                maximumInputTokens: configuration.maximumInputTokens,
                modelKey: GemmaConfiguration.validatedAudioModelKey(
                    manifest.gemmaModelKey
                ),
                strategy: strategy
            )
            let inputTokenOffset = cumulativeTokensBeforeStrategy
            let result = try await finalizer.finalize(
                artifact: artifact,
                audioPath: audioPath,
                language: recording.language,
                onProgress: { telemetry in
                    let scaled = Self.scaledConsensusTelemetry(
                        telemetry,
                        strategy: strategy,
                        strategyIndex: strategyIndex,
                        strategyCount: strategies.count,
                        inputTokenOffset: inputTokenOffset
                    )
                    await MainActor.run {
                        guard controller.processingGeneration == runGeneration else {
                            return
                        }
                        controller.updateTelemetry(
                            recordingID: recordingID,
                            telemetry: scaled
                        )
                    }
                },
                onCheckpoint: { blindCandidate, fusedCandidate, telemetry, traces in
                    await MainActor.run {
                        guard controller.processingGeneration == runGeneration else {
                            return
                        }
                        controller.checkpointGemmaCandidates(
                            recordingID: recordingID,
                            strategy: strategy,
                            blindCandidate: blindCandidate,
                            fusedCandidate: fusedCandidate,
                            telemetry: telemetry,
                            traces: traces
                        )
                    }
                }
            )
            try Task.checkCancellation()
            guard processingGeneration == runGeneration else {
                throw CancellationError()
            }
            cumulativeTokensBeforeStrategy += result.cumulativeInputTokens
            let variant = NightlyQualityConsensusVariant(
                strategy: strategy,
                candidate: result.fusedCandidate,
                decisions: result.decisions,
                traces: result.textTraces,
                cumulativeInputTokens: result.cumulativeInputTokens,
                peakRAMBytes: result.peakRAMBytes,
                completedAt: Date()
            )
            completedVariants.removeAll { $0.strategy == strategy }
            completedVariants.append(variant)

            artifact = artifactStore.load(recordingID: recordingID) ?? artifact
            artifact.consensusVariants = completedVariants
            artifact.fused = result.fusedCandidate
            artifact.gemmaDecisions = result.decisions
            artifact.gemmaTextTraces = result.textTraces
            artifact.cumulativeInputTokens = cumulativeTokensBeforeStrategy
            artifact.peakRAMBytes = maxOptional(
                artifact.peakRAMBytes,
                result.peakRAMBytes
            )
            artifact.updatedAt = Date()
            try artifactStore.save(artifact)

            if strategy == .readableReconstruction || selectedResult == nil {
                selectedResult = result
                selectedStrategy = strategy
            }
        }
        guard let result = selectedResult, let selectedStrategy else {
            throw TranscriptionError.transcriptionFailed(
                "No consensus repair strategy completed"
            )
        }
        try Task.checkCancellation()
        guard processingGeneration == runGeneration else {
            throw CancellationError()
        }

        // Save the complete adjudication before touching live rows. A crash after this point can
        // replay the guarded transaction; a crash before it leaves the committed transcript alone.
        artifact = artifactStore.load(recordingID: recordingID) ?? artifact
        artifact.blindGemma = result.blindCandidate
        artifact.fused = result.fusedCandidate
        artifact.gemmaDecisions = result.decisions
        artifact.cumulativeInputTokens = cumulativeTokensBeforeStrategy
        artifact.gemmaTextTraces = result.textTraces
        artifact.consensusVariants = completedVariants.sorted {
            let lhs = ConsensusRepairStrategy.allCases.firstIndex(of: $0.strategy) ?? 0
            let rhs = ConsensusRepairStrategy.allCases.firstIndex(of: $1.strategy) ?? 0
            return lhs < rhs
        }
        artifact.requestedConsensusStrategies = nil
        artifact.peakRAMBytes = maxOptional(artifact.peakRAMBytes, result.peakRAMBytes)
        if let telemetry = self.manifest?.items.first(where: {
            $0.id == recordingID
        })?.telemetry {
            artifact.gemmaCompletedTurns = telemetry.completedWindows
            artifact.gemmaTotalTurns = telemetry.totalWindows
        }
        let requiresGlobalSpeakerReconciliation = result.fusedCandidate.segments.contains {
            $0.speakerLabel != nil && $0.speakerUUID == nil
        }
        artifact.requiresSpeakerReprocessing = false
        artifact.postProcessingRequirements = NightlyQualityPostProcessingRequirements(
            requiresAcousticAlignment: false,
            requiresLocalDiarization: false,
            requiresGlobalSpeakerReconciliation: requiresGlobalSpeakerReconciliation,
            reasons: requiresGlobalSpeakerReconciliation
                ? [
                    "VibeVoice native turn timestamps and local speakers are locked",
                    "Recording-local VibeVoice labels still require global identity reconciliation"
                ]
                : ["VibeVoice native turn timestamps and speakers are locked"]
        )
        artifact.benchmarkReport = NightlyQualityBenchmark.evaluate(artifact)
        artifact.updatedAt = Date()
        try artifactStore.save(artifact)
        statusText = "Consensus complete · \(selectedStrategy.displayName) selected"

        if (manifest.commitPolicy ?? configuration.commitPolicy) == .automaticHighConfidence {
            try applyHighConfidenceDecisions(
                recordingID: recordingID,
                decisions: result.decisions
            )
        }
    }

    private func makeOrLoadArtifact(
        recording: Recording,
        audioPath: String
    ) throws -> NightlyQualityArtifact {
        guard let recordingID = recording.id else {
            throw TranscriptionError.transcriptionFailed("Recording has no database ID")
        }
        let fingerprint = NightlyQualityArtifactStore.inputFingerprint(
            path: audioPath,
            duration: recording.duration ?? 0,
            transcribedAt: recording.transcribedAt
        )
        let utterances = try utteranceRepository.getByRecording(
            id: recordingID,
            includeHidden: false
        )
        guard !utterances.isEmpty else {
            throw TranscriptionError.transcriptionFailed(
                "The foreground transcript has no utterances"
            )
        }
        let foreground = Self.foregroundCandidateIdentity(recording.transcriptionProvenance)
        let foregroundSegments = Self.foregroundSegments(utterances)
        let whisper = NightlyQualityCandidate(
            engine: foreground.engine,
            model: foreground.displayName,
            createdAt: Date(),
            segments: foregroundSegments,
            provenance: foreground.provenance
        )
        let foregroundVibeVoice = Self.foregroundVibeVoiceAnchor(
            recordingProvenance: recording.transcriptionProvenance,
            segments: foregroundSegments
        )
        if let existing = artifactStore.load(recordingID: recordingID),
           existing.schemaVersion == NightlyQualityArtifact.schemaVersion,
           existing.audioFingerprint == fingerprint,
           existing.whisper.segments == whisper.segments {
            guard let foregroundVibeVoice,
                  existing.vibeVoice != foregroundVibeVoice else {
                return existing
            }
            var refreshed = existing
            refreshed.vibeVoice = foregroundVibeVoice
            refreshed.blindGemma = nil
            refreshed.fused = nil
            refreshed.gemmaDecisions = []
            refreshed.gemmaTextTraces = nil
            refreshed.consensusVariants = nil
            refreshed.gemmaCompletedTurns = nil
            refreshed.gemmaTotalTurns = nil
            refreshed.benchmarkReport = nil
            refreshed.completedAt = nil
            refreshed.updatedAt = Date()
            try artifactStore.save(refreshed)
            return refreshed
        }

        var artifact = NightlyQualityArtifact(
            recordingID: recordingID,
            audioFingerprint: fingerprint,
            whisper: whisper
        )
        artifact.vibeVoice = foregroundVibeVoice
        if let existing = artifactStore.load(recordingID: recordingID),
           existing.audioFingerprint == fingerprint {
            // Preserve prior candidates long enough for each stage's settings fingerprint to make
            // the reuse decision. Whisper pipeline v3 rejects v2 candidates and retranscribes;
            // unchanged VibeVoice candidates can still be reused.
            if existing.schemaVersion >= 7 {
                artifact.whisperCandidate = existing.whisperCandidate
            }
            if artifact.vibeVoice == nil {
                artifact.vibeVoice = existing.vibeVoice
            }
            if existing.schemaVersion >= 7 {
                artifact.peakRAMBytes = existing.peakRAMBytes
            }
        }
        try artifactStore.save(artifact)
        return artifact
    }

    private func applyHighConfidenceDecisions(
        recordingID: Int64,
        decisions: [NightlyQualityDecision]
    ) throws {
        let accepted = decisions.filter {
            $0.confidence == "high"
                && $0.finalText != $0.originalText
        }
        guard !accepted.isEmpty else { return }

        var applied: [(id: Int64, text: String)] = []
        try GRDBDatabaseManager.shared.write { db in
            for decision in accepted {
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT recording_id, text, text_source, review_status
                        FROM utterances WHERE id = ?
                    """,
                    arguments: [decision.utteranceID]
                ) else { continue }
                let rowRecordingID: Int64 = row["recording_id"]
                let currentText: String = row["text"]
                let textSource: String = row["text_source"]
                let reviewStatus: String? = row["review_status"]
                guard rowRecordingID == recordingID,
                      currentText == decision.originalText,
                      textSource != UtteranceTextSource.user.rawValue,
                      !Self.isTerminalUserStatus(reviewStatus) else {
                    continue
                }
                let provenance = try? JSONSerialization.data(
                    withJSONObject: [
                        "pipeline": "nightly_quality_v3_vibevoice_anchored_consensus",
                        "confidence": decision.confidence,
                        "source": decision.source,
                        "estimated_input_tokens": decision.estimatedInputTokens
                    ],
                    options: [.sortedKeys]
                )
                try UtteranceReviewStore.applyCorrection(
                    db,
                    utteranceId: decision.utteranceID,
                    newText: decision.finalText,
                    source: .verifier,
                    status: .autoCorrected,
                    verifierResultJSON: provenance.flatMap {
                        String(data: $0, encoding: .utf8)
                    }
                )
                applied.append((decision.utteranceID, decision.finalText))
            }
            try UtteranceReviewStore.rebuildFullTranscript(
                db,
                recordingId: recordingID
            )
        }
        guard !applied.isEmpty else { return }

        // Make completion idempotent against the now-committed transcript while retaining each
        // row's `originalASRText` as benchmark provenance.
        try refreshArtifactForegroundReference(recordingID: recordingID)

        let title = (try? recordingRepository.getById(recordingID)?.title)
            ?? "Recording \(recordingID)"
        _ = EmbeddingQueueManager.shared.addJob(
            recordingId: recordingID,
            recordingTitle: title,
            utteranceData: applied,
            priority: .normal
        )
        _ = RecordingInsightsQueueManager.shared.enqueue(
            recordingId: recordingID,
            recordingTitle: title,
            force: true,
            priority: .low
        )
    }

    /// Refreshes only the committed-reference side of an artifact. The raw VibeVoice anchor,
    /// independent Whisper candidate, decisions, and exact model traces remain unchanged.
    private func refreshArtifactForegroundReference(recordingID: Int64) throws {
        guard var artifact = artifactStore.load(recordingID: recordingID),
              let recording = try recordingRepository.getById(recordingID) else {
            return
        }
        let utterances = try utteranceRepository.getByRecording(
            id: recordingID,
            includeHidden: false
        )
        let identity = Self.foregroundCandidateIdentity(recording.transcriptionProvenance)
        artifact.whisper = NightlyQualityCandidate(
            engine: identity.engine,
            model: identity.displayName,
            createdAt: Date(),
            segments: Self.foregroundSegments(utterances),
            provenance: identity.provenance
        )
        artifact.benchmarkReport = NightlyQualityBenchmark.evaluate(artifact)
        artifact.updatedAt = Date()
        try artifactStore.save(artifact)
    }

    private func finishSuccess(
        itemID: Int64,
        stage: NightlyQualityStage,
        generation: UUID
    ) {
        guard processingGeneration == generation, var manifest,
              let index = manifest.items.firstIndex(where: { $0.id == itemID }) else {
            return
        }
        if let startedAt = manifest.activeStartedAt {
            let elapsed = max(0, Date().timeIntervalSince(startedAt))
            manifest.completedWallClockSeconds += elapsed
            let completedWork = (manifest.completedAudioWorkSeconds ?? 0)
                + manifest.items[index].duration
            manifest.completedAudioWorkSeconds = completedWork
            if completedWork > 0 {
                manifest.observedRealTimeFactor =
                    manifest.completedWallClockSeconds / completedWork
            }
        }
        switch stage {
        case .whisper:
            // New recordings already have the exact committed VibeVoice foreground turns. Only
            // historical non-VibeVoice recordings need the compatibility candidate pass.
            manifest.items[index].stage =
                artifactStore.load(recordingID: itemID)?.vibeVoice == nil
                ? .vibeVoice
                : .gemmaFinalization
            manifest.items[index].state = .pending
        case .vibeVoice:
            manifest.items[index].stage = .gemmaFinalization
            manifest.items[index].state = .pending
        case .gemmaFinalization:
            if (manifest.commitPolicy ?? configuration.commitPolicy) == .shadow {
                manifest.items[index].stage = .completed
                manifest.items[index].state = .completed
                if var artifact = artifactStore.load(recordingID: itemID) {
                    artifact.completedAt = Date()
                    artifact.updatedAt = Date()
                    try? artifactStore.save(artifact)
                }
            } else {
                manifest.items[index].stage = .cleanup
                manifest.items[index].state = .pending
            }
        case .cleanup, .completed:
            break
        }
        manifest.items[index].lastError = nil
        manifest.activeRecordingID = nil
        manifest.activeStartedAt = nil
        self.manifest = manifest
        if manifest.items[index].state == .completed {
            manualRunRecordingID = nil
        }
        clearProcessing(generation: generation)
        persist()
        // The current task still owns the GPU until its defer runs. Starting the next same-consumer
        // task synchronously would be rejected as a duplicate lease, so resume on the next beat.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.tick()
        }
    }

    private func finishFailure(
        itemID: Int64,
        error: Error,
        generation: UUID
    ) {
        guard processingGeneration == generation, var manifest,
              let index = manifest.items.firstIndex(where: { $0.id == itemID }) else {
            return
        }
        let retryableResourceWait = Self.isRetryableResourceWait(error)
        if !retryableResourceWait {
            manifest.items[index].attempts += 1
        }
        manifest.items[index].lastError = error.localizedDescription
        manifest.items[index].state = retryableResourceWait
            ? .pending
            : manifest.items[index].attempts >= Self.maximumAttempts ? .failed : .pending
        manifest.activeRecordingID = nil
        manifest.activeStartedAt = nil
        self.manifest = manifest
        if manifest.items[index].state == .failed {
            manualRunRecordingID = nil
        }
        statusText = "\(manifest.items[index].stage.displayName) paused: \(error.localizedDescription)"
        clearProcessing(generation: generation)
        persist()
    }

    private func finishCancelled(itemID: Int64, generation: UUID) {
        guard processingGeneration == generation, var manifest else { return }
        if let index = manifest.items.firstIndex(where: { $0.id == itemID }) {
            manifest.items[index].state = .pending
            manifest.items[index].lastError = "Interrupted safely; will resume"
        }
        manifest.activeRecordingID = nil
        manifest.activeStartedAt = nil
        self.manifest = manifest
        clearProcessing(generation: generation)
        persist()
    }

    private func markActive(_ itemID: Int64) {
        guard var manifest,
              let index = manifest.items.firstIndex(where: { $0.id == itemID }) else {
            return
        }
        manifest.items[index].state = .active
        manifest.items[index].lastError = nil
        manifest.activeRecordingID = itemID
        manifest.activeStartedAt = Date()
        self.manifest = manifest
        persist()
    }

    private func updateTelemetry(
        recordingID: Int64,
        telemetry: NightlyQualityTelemetry
    ) {
        guard var manifest,
              let index = manifest.items.firstIndex(where: { $0.id == recordingID }) else {
            return
        }
        manifest.items[index].telemetry = telemetry
        self.manifest = manifest
        if let phase = telemetry.currentPhase {
            let clip: String
            if let current = telemetry.currentClip, let total = telemetry.totalClips {
                clip = " · utterance \(current)/\(total)"
            } else {
                clip = ""
            }
            statusText = phase + clip + " · \(manifest.items[index].title)"
        }
    }

    private nonisolated static func scaledConsensusTelemetry(
        _ telemetry: NightlyQualityTelemetry,
        strategy: ConsensusRepairStrategy,
        strategyIndex: Int,
        strategyCount: Int,
        inputTokenOffset: Int
    ) -> NightlyQualityTelemetry {
        var scaled = telemetry
        let windowsPerStrategy = max(1, telemetry.totalWindows)
        scaled.completedWindows =
            strategyIndex * windowsPerStrategy + telemetry.completedWindows
        scaled.totalWindows = max(1, strategyCount * windowsPerStrategy)
        if let currentClip = telemetry.currentClip {
            let clipsPerStrategy = max(1, telemetry.totalClips ?? windowsPerStrategy)
            scaled.currentClip = strategyIndex * clipsPerStrategy + currentClip
            scaled.totalClips = strategyCount * clipsPerStrategy
        }
        scaled.cumulativeInputTokens =
            inputTokenOffset + telemetry.cumulativeInputTokens
        let phase = telemetry.currentPhase
            ?? "Repairing text inside locked VibeVoice turns"
        scaled.currentPhase =
            "\(strategy.displayName) · strategy \(strategyIndex + 1)/\(strategyCount)"
            + " · \(phase)"
        return scaled
    }

    private func checkpointGemmaCandidates(
        recordingID: Int64,
        strategy: ConsensusRepairStrategy,
        blindCandidate: NightlyQualityCandidate?,
        fusedCandidate: NightlyQualityCandidate?,
        telemetry: NightlyQualityTelemetry,
        traces: [NightlyQualityLLMTrace]
    ) {
        guard var artifact = artifactStore.load(recordingID: recordingID) else { return }
        if let blindCandidate {
            artifact.blindGemma = blindCandidate
        }
        if let fusedCandidate {
            artifact.fused = fusedCandidate
            var variants = artifact.consensusVariants ?? []
            variants.removeAll { $0.strategy == strategy }
            variants.append(
                NightlyQualityConsensusVariant(
                    strategy: strategy,
                    candidate: fusedCandidate,
                    decisions: [],
                    traces: traces,
                    cumulativeInputTokens: telemetry.cumulativeInputTokens,
                    peakRAMBytes: telemetry.peakRAMBytes,
                    completedAt: nil
                )
            )
            artifact.consensusVariants = variants
        }
        artifact.gemmaCompletedTurns = telemetry.completedWindows
        artifact.gemmaTotalTurns = telemetry.totalWindows
        artifact.cumulativeInputTokens = telemetry.cumulativeInputTokens
        artifact.gemmaTextTraces = traces
        artifact.peakRAMBytes = maxOptional(artifact.peakRAMBytes, telemetry.peakRAMBytes)
        artifact.updatedAt = Date()
        try? artifactStore.save(artifact)
    }

    private func updateVibeMemory(
        recordingID: Int64,
        currentBytes: UInt64?,
        availableBytes: UInt64?,
        estimatedPeakBytes: UInt64,
        reportedPeakBytes: UInt64? = nil
    ) {
        guard var manifest,
              let index = manifest.items.firstIndex(where: { $0.id == recordingID }) else {
            return
        }
        var telemetry = manifest.items[index].telemetry
        telemetry.maximumInputTokens = configuration.maximumInputTokens
        telemetry.currentRAMBytes = currentBytes
        telemetry.systemAvailableBytes = availableBytes
        telemetry.estimatedModelPeakBytes = estimatedPeakBytes
        if let currentBytes {
            telemetry.peakRAMBytes = max(telemetry.peakRAMBytes ?? 0, currentBytes)
        }
        if let reportedPeakBytes {
            telemetry.peakRAMBytes = max(
                telemetry.peakRAMBytes ?? 0,
                reportedPeakBytes
            )
        }
        manifest.items[index].telemetry = telemetry
        self.manifest = manifest
    }

    private func updateWhisperProgress(
        recordingID: Int64,
        progress: Double,
        phase: String,
        estimatedPeakBytes: UInt64
    ) {
        guard var manifest,
              let index = manifest.items.firstIndex(where: { $0.id == recordingID }) else {
            return
        }
        let fraction = min(1, max(0, progress))
        var telemetry = manifest.items[index].telemetry
        telemetry.currentInputTokens = 0
        telemetry.completedWindows = Int((fraction * 100).rounded(.down))
        telemetry.totalWindows = 100
        telemetry.currentPhase = phase.isEmpty ? "Whisper transcription" : phase
        telemetry.currentRAMBytes = nil
        telemetry.systemAvailableBytes = SystemMemoryGate.memorySnapshot()?.availableBytes
        telemetry.estimatedModelPeakBytes = estimatedPeakBytes
        manifest.items[index].telemetry = telemetry
        self.manifest = manifest
        statusText = "\(telemetry.currentPhase ?? "Whisper transcription") · "
            + manifest.items[index].title
    }

    private func resetStageTelemetry(
        recordingID: Int64,
        phase: String,
        totalWorkUnits: Int
    ) {
        guard var manifest,
              let index = manifest.items.firstIndex(where: { $0.id == recordingID }) else {
            return
        }
        var telemetry = NightlyQualityTelemetry()
        telemetry.maximumInputTokens = configuration.maximumInputTokens
        telemetry.totalWindows = max(1, totalWorkUnits)
        telemetry.currentPhase = phase
        manifest.items[index].telemetry = telemetry
        self.manifest = manifest
    }

    private func clearProcessing(generation: UUID) {
        guard processingGeneration == generation else { return }
        processingGeneration = nil
        processingTask = nil
        endActivity()
    }

    private func stopProcessing(reason: String) {
        let task = processingTask
        processingGeneration = nil
        processingTask = nil
        task?.cancel()
        WhisperService.shared.cancelTranscription()
        VibeVoiceService.shared.cancel()
        if var manifest, let id = manifest.activeRecordingID,
           let index = manifest.items.firstIndex(where: { $0.id == id }) {
            manifest.items[index].state = .pending
            manifest.items[index].lastError = "Interrupted safely; will resume"
            manifest.activeRecordingID = nil
            manifest.activeStartedAt = nil
            self.manifest = manifest
        }
        statusText = reason
        endActivity()
        persist()
    }

    private func enqueueCleanup(for item: NightlyQualityItem) {
        guard var manifest,
              let index = manifest.items.firstIndex(where: { $0.id == item.id }) else {
            return
        }
        if let existing = cleanupQueue.jobs.first(where: {
            $0.recordingId == item.id
                && ($0.status == .pending || $0.status == .processing)
        }) {
            manifest.items[index].cleanupJobID = existing.id
            manifest.items[index].state = .waitingForCleanup
        } else if let job = cleanupQueue.enqueue(
            recordingId: item.id,
            recordingTitle: item.title,
            mode: .backfill,
            force: true,
            priority: .low
        ) {
            manifest.items[index].cleanupJobID = job.id
            manifest.items[index].state = .waitingForCleanup
        } else {
            statusText = "Waiting to queue cleanup · \(item.title)"
            return
        }
        self.manifest = manifest
        statusText = "Final cleanup · \(item.title)"
        persist()
    }

    private func reconcileCleanupJobs() {
        guard var manifest else { return }
        var changed = false
        for index in manifest.items.indices
        where manifest.items[index].state == .waitingForCleanup {
            guard let jobID = manifest.items[index].cleanupJobID,
                  let job = cleanupQueue.jobs.first(where: { $0.id == jobID }) else {
                // Completed jobs are not persisted forever. Re-enqueueing forced cleanup is safe
                // and gives an interrupted launch a durable checkpoint.
                manifest.items[index].state = .pending
                manifest.items[index].cleanupJobID = nil
                changed = true
                continue
            }
            switch job.status {
            case .completed:
                manifest.items[index].stage = .completed
                manifest.items[index].state = .completed
                manifest.items[index].lastError = nil
                try? refreshArtifactForegroundReference(
                    recordingID: manifest.items[index].id
                )
                if var artifact = artifactStore.load(recordingID: manifest.items[index].id) {
                    artifact.completedAt = Date()
                    artifact.updatedAt = Date()
                    try? artifactStore.save(artifact)
                }
                changed = true
            case .failed, .cancelled:
                manifest.items[index].attempts += 1
                manifest.items[index].lastError = job.error ?? "Final cleanup did not complete"
                manifest.items[index].state =
                    manifest.items[index].attempts >= Self.maximumAttempts ? .failed : .pending
                manifest.items[index].cleanupJobID = nil
                changed = true
            case .pending, .processing, .paused:
                break
            }
        }
        if changed {
            if let manualRunRecordingID,
               let item = manifest.items.first(where: { $0.id == manualRunRecordingID }),
               item.state == .completed || item.state == .failed {
                self.manualRunRecordingID = nil
            }
            self.manifest = manifest
            persist()
        }
    }

    private func createPlan() {
        refreshLibrarySummary()
        let all = (try? recordingRepository.getAll(limit: 100_000)) ?? []
        let visibleTextGold = visibleTextGoldRecordingIDs()
        let candidates = eligibleRecordings(from: all, excludeCompleted: true)
            .sorted {
                let lhsHasTextGold = ($0.id).map(visibleTextGold.contains) ?? false
                let rhsHasTextGold = ($1.id).map(visibleTextGold.contains) ?? false
                if lhsHasTextGold != rhsHasTextGold {
                    return lhsHasTextGold
                }
                if ($0.duration ?? 0) != ($1.duration ?? 0) {
                    return ($0.duration ?? 0) < ($1.duration ?? 0)
                }
                return ($0.id ?? 0) < ($1.id ?? 0)
            }
        manifest = NightlyQualityManifest(
            id: UUID(),
            createdAt: Date(),
            vibeVoiceQuantization: TranscriptionProductionDefaults.vibeVoiceQuantization,
            whisperVariantIdentifier: (
                GlobalModelSettings.shared.selectedWhisperVariant
                    ?? WhisperModelVariant.defaultVariant()
            ).toIdentifier(),
            gemmaModelKey: configuration.gemmaAudioModelKey,
            qualityMode: configuration.mode,
            commitPolicy: configuration.commitPolicy,
            scope: configuration.scope,
            items: candidates.compactMap { recording in
                guard let id = recording.id, let audioPath = recording.filePath else {
                    return nil
                }
                let artifact = try? makeOrLoadArtifact(
                    recording: recording,
                    audioPath: audioPath
                )
                if configuration.commitPolicy == .shadow,
                   let artifact,
                   Self.hasCompleteGemmaCheckpoint(artifact) {
                    // The complete private output was saved before the process died. Finishing
                    // this checkpoint must not spend another full Gemma pass after relaunch.
                    var recovered = artifact
                    recovered.completedAt = Date()
                    recovered.updatedAt = Date()
                    try? artifactStore.save(recovered)
                    return nil
                }
                return NightlyQualityItem(
                    id: id,
                    title: recording.title,
                    duration: recording.duration ?? 0,
                    stage: Self.pendingStage(
                        artifact: artifact,
                        commitPolicy: configuration.commitPolicy
                    )
                )
            }
        )
        statusText = candidates.isEmpty ? "Up to date" : nextWindowText()
        persist()
    }

    private func eligibleRecordings(
        from all: [Recording],
        excludeCompleted: Bool
    ) -> [Recording] {
        let editedRecordingIDs = configuration.scope == .evaluationCohort
            ? manuallyReviewedRecordingIDs()
            : []
        let resumableRecordingIDs = excludeCompleted
            ? artifactStore.resumableRecordingIDs()
            : []
        return all.filter { recording in
            guard let id = recording.id,
                  let path = recording.filePath,
                  FileManager.default.fileExists(atPath: path) else { return false }
            let isExplicitShadowEvaluation =
                configuration.scope == .evaluationCohort
                && configuration.commitPolicy == .shadow
                && configuration.additionalEvaluationRecordingIDs.contains(id)
            if Self.excludesSpeakerGold(
                protectionEnabled: configuration.excludeSpeakerGold,
                isSpeakerGold:
                    recording.speakerReviewStatus == RecordingSpeakerReviewStatus.gold.rawValue,
                isExplicitShadowEvaluation: isExplicitShadowEvaluation
            ) {
                return false
            }
            let fingerprint = NightlyQualityArtifactStore.inputFingerprint(
                path: path,
                duration: recording.duration ?? 0,
                transcribedAt: recording.transcribedAt
            )
            let utterances = try? utteranceRepository.getByRecording(
                id: id,
                includeHidden: false
            )
            let foregroundSegments = utterances.map(Self.foregroundSegments)
            let isResumable = resumableRecordingIDs.contains(id)
                && foregroundSegments.map {
                    artifactStore.isResumable(
                        recordingID: id,
                        fingerprint: fingerprint,
                        foregroundSegments: $0
                    )
                } == true

            // Scope controls new enrollment, not recovery. A current-schema artifact with the
            // same audio and exact foreground rows has already been enrolled and may contain hours
            // of saved model work, so finish it even when a rollout moved the enrollment date.
            if !isResumable {
                switch configuration.scope {
                case .evaluationCohort:
                    let isSpeakerGold =
                        recording.speakerReviewStatus
                            == RecordingSpeakerReviewStatus.gold.rawValue
                    let isExplicitEvaluation =
                        configuration.additionalEvaluationRecordingIDs.contains(id)
                    guard editedRecordingIDs.contains(id)
                            || isSpeakerGold
                            || isExplicitEvaluation else {
                        return false
                    }
                case .newRecordings:
                    guard (recording.transcribedAt ?? recording.createdAt)
                        >= configuration.enrollmentDate else { return false }
                case .entireLibrary:
                    break
                }
            }
            guard excludeCompleted else { return true }
            guard let foregroundSegments else { return true }
            return !artifactStore.isCompleted(
                recordingID: id,
                fingerprint: fingerprint,
                foregroundSegments: foregroundSegments
            )
        }
    }

    nonisolated static func excludesSpeakerGold(
        protectionEnabled: Bool,
        isSpeakerGold: Bool,
        isExplicitShadowEvaluation: Bool
    ) -> Bool {
        protectionEnabled && isSpeakerGold && !isExplicitShadowEvaluation
    }

    nonisolated static func hasCompleteGemmaCheckpoint(
        _ artifact: NightlyQualityArtifact
    ) -> Bool {
        guard artifact.fused != nil,
              let completed = artifact.gemmaCompletedTurns,
              let total = artifact.gemmaTotalTurns,
              total > 0 else {
            return false
        }
        return completed >= total
    }

    private func manuallyReviewedRecordingIDs() -> Set<Int64> {
        (try? GRDBDatabaseManager.shared.read { db in
            Set(try Int64.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT recording_id
                    FROM utterances
                    WHERE text_source = ?
                       OR review_status IN (?, ?, ?)
                """,
                arguments: [
                    UtteranceTextSource.user.rawValue,
                    UtteranceReviewStatus.userKept.rawValue,
                    UtteranceReviewStatus.userCorrected.rawValue,
                    UtteranceReviewStatus.userHidden.rawValue
                ]
            ))
        }) ?? []
    }

    /// Corrected/kept speech gives WER/CER reference text immediately. Hidden-only cleanup remains
    /// eligible, but follows these higher-information calls because it needs a separate
    /// false-positive/silence metric rather than an ordinary text reference.
    private func visibleTextGoldRecordingIDs() -> Set<Int64> {
        (try? GRDBDatabaseManager.shared.read { db in
            Set(try Int64.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT recording_id
                    FROM utterances
                    WHERE is_hidden = 0
                      AND (
                        text_source = ?
                        OR review_status IN (?, ?)
                      )
                """,
                arguments: [
                    UtteranceTextSource.user.rawValue,
                    UtteranceReviewStatus.userKept.rawValue,
                    UtteranceReviewStatus.userCorrected.rawValue
                ]
            ))
        }) ?? []
    }

    private func unavailableReason(
        for stage: NightlyQualityStage,
        manifest: NightlyQualityManifest
    ) -> String? {
        switch stage {
        case .whisper:
            let identifier = manifest.whisperVariantIdentifier
                ?? GlobalModelSettings.shared.selectedWhisperVariant?.toIdentifier()
                ?? WhisperModelVariant.defaultVariant().toIdentifier()
            guard let variant = WhisperModelVariant.fromIdentifier(identifier) else {
                return "Pending: invalid Whisper model \(identifier)"
            }
            guard WhisperModelManager.shared.isModelDownloaded(variant) else {
                return "Pending: download Whisper \(variant.displayName)"
            }
        case .vibeVoice:
            guard VibeVoiceModelManager.shared.isModelDownloaded(
                manifest.vibeVoiceQuantization
            ) else {
                return "Pending: download VibeVoice \(manifest.vibeVoiceQuantization.rawValue)"
            }
            guard VibeVoiceService.shared.isRuntimeInstalled else {
                return "Pending: VibeVoice runtime is not installed"
            }
        case .gemmaFinalization:
            let audioKey = GemmaConfiguration.validatedAudioModelKey(
                manifest.gemmaModelKey
            )
            guard GemmaModelManager().isAudioModelDownloaded(audioKey) else {
                return "Pending: download Gemma \(audioKey) and its audio projector"
            }
            guard LlamaRuntime.findBinary(named: "llama-server") != nil else {
                return "Pending: llama-server is missing; reinstall AlmRecorder"
            }
        case .cleanup, .completed:
            break
        }
        return nil
    }

    private func recoverInterruptedState() {
        guard var manifest else { return }
        for index in manifest.items.indices {
            if manifest.items[index].state == .active
                || manifest.items[index].state == .waitingForCleanup {
                manifest.items[index].state = .pending
                manifest.items[index].cleanupJobID = nil
                manifest.items[index].lastError = "Interrupted safely; queued to resume"
            }
            // Older nightly builds spent the ordinary three-attempt error budget on memory
            // admission deferrals. Those were never model failures: no child process launched and
            // no candidate was produced. Put them back in the queue after an upgrade so a busy Mac
            // cannot permanently strand private-gold evaluation work.
            if manifest.items[index].state == .failed,
               Self.isPersistedResourceWait(manifest.items[index].lastError) {
                manifest.items[index].state = .pending
                manifest.items[index].attempts = 0
                manifest.items[index].lastError =
                    "Waiting for safe memory; queued to resume"
            }
            if let recording = try? recordingRepository.getById(manifest.items[index].id),
               let audioPath = recording.filePath,
               let artifact = try? makeOrLoadArtifact(
                   recording: recording,
                   audioPath: audioPath
               ),
               manifest.items[index].stage != .cleanup {
                let recoveredStage = Self.pendingStage(
                    artifact: artifact,
                    commitPolicy: manifest.commitPolicy ?? configuration.commitPolicy
                )
                if recoveredStage != .completed {
                    manifest.items[index].stage = recoveredStage
                    manifest.items[index].state = .pending
                }
            }
        }
        manifest.activeRecordingID = nil
        manifest.activeStartedAt = nil
        self.manifest = manifest
        persist()
    }

    nonisolated static func pendingStage(
        artifact: NightlyQualityArtifact?,
        commitPolicy: NightlyQualityCommitPolicy
    ) -> NightlyQualityStage {
        guard let artifact,
              artifact.schemaVersion == NightlyQualityArtifact.schemaVersion,
              artifact.whisperCandidate != nil else {
            return .whisper
        }
        guard artifact.vibeVoice != nil else { return .vibeVoice }
        guard hasCompleteGemmaCheckpoint(artifact) else { return .gemmaFinalization }
        return commitPolicy == .shadow ? .completed : .cleanup
    }

    nonisolated static func isRetryableResourceWait(_ error: Error) -> Bool {
        guard let transcriptionError = error as? TranscriptionError else {
            return false
        }
        switch transcriptionError {
        case .resourcesUnavailable, .gpuOutOfMemory:
            return true
        default:
            return false
        }
    }

    nonisolated static func isPersistedResourceWait(_ message: String?) -> Bool {
        guard let message else { return false }
        return message.hasPrefix("Waiting for safe memory:")
            || message.hasPrefix("GPU ran out of memory:")
    }

    private func nextWindowText(from date: Date = Date()) -> String {
        if configuration.window.contains(date) {
            return "Ready when foreground transcription is finished"
        }
        guard let next = configuration.window.nextStart(after: date) else {
            return "Waiting for the nightly window"
        }
        return "Next quality window \(next.formatted(date: .abbreviated, time: .shortened))"
    }

    private func beginActivity() {
        guard configuration.preventIdleSleepWhileProcessing, activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Nightly AlmRecorder transcript quality refinement"
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
        // A v1 manifest may contain the entire historical library and has no quality/scope/apply
        // snapshot. Never reinterpret that backlog under the new pipeline; rebuild it through the
        // migrated shadow + evaluation-cohort gate instead.
        if let restored = state.manifest, restored.hasPipelineSnapshot {
            manifest = restored
        } else {
            manifest = nil
        }
    }

    /// One requested product rollout, separate from legacy decoding. Old persisted plans remain
    /// safe when decoded in isolation, while the installed app explicitly adopts the new
    /// foreground-first production pipeline once.
    private func applyProductionRolloutIfNeeded() {
        guard settings.getBool(forKey: Self.productionRolloutKey) != true else {
            return
        }
        configuration.enabled = true
        configuration.mode = .maximum
        configuration.commitPolicy = .automaticHighConfidence
        configuration.scope = .newRecordings
        configuration.enrollmentDate = Date()
        configuration.maximumInputTokens = 12_000
        configuration.gemmaAudioModelKey = GemmaConfiguration.defaultAudioModel

        // A manifest snapshots its scope and commit policy. Rebuild it rather than accidentally
        // running an old shadow/evaluation plan under labels that now promise automatic quality.
        manifest = nil
        settings.setBool(true, forKey: Self.productionRolloutKey)
        persist()
    }

    private static func foregroundCandidateIdentity(
        _ recordingProvenance: RecordingTranscriptionProvenance?
    ) -> (
        engine: NightlyQualityCandidate.Engine,
        displayName: String,
        provenance: NightlyQualityCandidateProvenance
    ) {
        guard let recordingProvenance else {
            return (
                .unknown,
                "Committed foreground transcript · engine unknown",
                NightlyQualityCandidateProvenance(
                    role: "foreground_baseline",
                    engineIdentifier: "unknown",
                    modelIdentifier: "unknown",
                    modelRevision: nil,
                    runtimeRevision: nil,
                    settingsJSON: nil,
                    sourceRevisionDate: nil,
                    certainty: .unknown
                )
            )
        }
        let selection = recordingProvenance.engineSelection
        let engine: NightlyQualityCandidate.Engine
        switch selection.backend {
        case .whisper:
            engine = .whisper
        case .vibeVoice:
            engine = .vibeVoice
        case .llm:
            engine = selection.llmEngine == .gemma ? .gemma : .unknown
        }
        return (
            engine,
            "Committed foreground transcript · \(selection.displayName)",
            NightlyQualityCandidateProvenance(
                role: "foreground_baseline",
                engineIdentifier: selection.backend.rawValue,
                modelIdentifier: selection.displayName,
                modelRevision: selection.vibeVoiceModelRevision,
                runtimeRevision: selection.vibeVoiceRuntimeRevision,
                settingsJSON: jsonString(recordingProvenance.runSettings),
                sourceRevisionDate: recordingProvenance.completedAt,
                certainty: .exact
            )
        )
    }

    /// The committed rows are the authoritative VibeVoice structure for a VibeVoice foreground
    /// run. `originalASRText` deliberately wins over later user/verifier edits so the nightly
    /// candidate remains honest raw model output while keeping the exact persisted timestamps,
    /// utterance IDs, local speaker labels, and globally reconciled speaker UUIDs.
    nonisolated static func foregroundVibeVoiceAnchor(
        recordingProvenance: RecordingTranscriptionProvenance?,
        segments: [NightlyQualityCandidateSegment]
    ) -> NightlyQualityCandidate? {
        guard let recordingProvenance,
              recordingProvenance.engineSelection.backend == .vibeVoice else {
            return nil
        }
        let selection = recordingProvenance.engineSelection
        let quantization = selection.vibeVoiceQuantization
            ?? TranscriptionProductionDefaults.vibeVoiceQuantization
        let anchoredSegments = segments.map { segment in
            NightlyQualityCandidateSegment(
                utteranceID: segment.utteranceID,
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: segment.originalASRText ?? segment.text,
                speakerUUID: segment.speakerUUID,
                speakerLabel: segment.speakerLabel,
                userProtected: segment.userProtected,
                originalASRText: segment.originalASRText,
                confidence: segment.confidence,
                source: "vibevoice_committed_foreground_anchor",
                supportingUtteranceIDs: segment.utteranceID.map { [$0] },
                alignmentMethod: "exact_committed_foreground_turn"
            )
        }
        return NightlyQualityCandidate(
            engine: .vibeVoice,
            model: selection.displayName,
            createdAt: recordingProvenance.completedAt,
            segments: anchoredSegments,
            provenance: NightlyQualityCandidateProvenance(
                role: "committed_foreground_structure_anchor",
                engineIdentifier: TranscriptionBackend.vibeVoice.rawValue,
                modelIdentifier: quantization.repositoryID,
                modelRevision: selection.vibeVoiceModelRevision,
                runtimeRevision: selection.vibeVoiceRuntimeRevision,
                settingsJSON: jsonString(recordingProvenance.runSettings),
                sourceRevisionDate: recordingProvenance.completedAt,
                certainty: .exact
            )
        )
    }

    private static func hasStructuralDifference(
        baseline: [NightlyQualityCandidateSegment],
        fused: [NightlyQualityCandidateSegment]
    ) -> Bool {
        let baselineByID = Dictionary(
            uniqueKeysWithValues: baseline.compactMap { segment in
                segment.utteranceID.map { ($0, segment) }
            }
        )
        guard fused.count == baselineByID.count else { return true }
        for segment in fused {
            guard let ids = segment.supportingUtteranceIDs,
                  ids.count == 1,
                  let baselineSegment = baselineByID[ids[0]],
                  abs(segment.startTime - baselineSegment.startTime) <= 0.5,
                  abs(segment.endTime - baselineSegment.endTime) <= 0.5 else {
                return true
            }
        }
        return false
    }

    private nonisolated static func jsonString<Value: Encodable>(_ value: Value) -> String? {
        (try? JSONEncoder().encode(value))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    private nonisolated static func whisperLanguage(_ value: String?) -> String? {
        guard let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalized.isEmpty,
              normalized != "auto",
              normalized != "auto-detected",
              normalized != "unknown" else {
            return nil
        }
        return normalized
    }

    private static func isUserProtected(_ utterance: Utterance) -> Bool {
        utterance.textSource == UtteranceTextSource.user.rawValue
            || isTerminalUserStatus(utterance.reviewStatus)
    }

    private static func foregroundSegments(
        _ utterances: [Utterance]
    ) -> [NightlyQualityCandidateSegment] {
        utterances.map {
            NightlyQualityCandidateSegment(
                utteranceID: $0.id,
                startTime: $0.startTime,
                endTime: $0.endTime,
                text: $0.text,
                speakerUUID: $0.speakerUuid,
                speakerLabel: $0.speaker,
                userProtected: isUserProtected($0),
                originalASRText: $0.originalText
            )
        }
    }

    private static func isTerminalUserStatus(_ raw: String?) -> Bool {
        raw == UtteranceReviewStatus.userKept.rawValue
            || raw == UtteranceReviewStatus.userCorrected.rawValue
            || raw == UtteranceReviewStatus.userHidden.rawValue
    }
}

private func maxOptional(_ lhs: UInt64?, _ rhs: UInt64?) -> UInt64? {
    switch (lhs, rhs) {
    case let (lhs?, rhs?): return max(lhs, rhs)
    case let (lhs?, nil): return lhs
    case let (nil, rhs?): return rhs
    case (nil, nil): return nil
    }
}
