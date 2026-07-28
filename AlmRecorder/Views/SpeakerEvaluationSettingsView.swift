import SwiftUI

@MainActor
final class SpeakerEvaluationSettingsModel: ObservableObject {
    @Published private(set) var snapshot: SpeakerEvaluationSnapshot?
    @Published private(set) var pairWorkspace: SpeakerPairReviewWorkspace?
    @Published private(set) var benchmark: SpeakerEvaluationBenchmarkBundle?
    @Published private(set) var vibeVoiceBenchmark: VibeVoiceGoldBenchmarkBundle?
    @Published private(set) var isLoading = false
    @Published private(set) var isEvaluating = false
    @Published private(set) var isSavingPair = false
    @Published private(set) var isApplyingReconciliation = false
    @Published private(set) var benchmarkProgress: SpeakerEvaluationBenchmarkProgress?
    @Published private(set) var vibeVoiceBenchmarkProgress: VibeVoiceGoldBenchmarkProgress?
    @Published var errorMessage: String?
    @Published var reconciliationMessage: String?

    private var reloadTask: Task<Void, Never>?
    private var evaluationTask: Task<Void, Never>?
    private var pairTask: Task<Void, Never>?
    private var lastPairAction: (
        left: Int64,
        right: Int64,
        mixedClusterId: Int64?
    )?

    var canUndoPairLabel: Bool { lastPairAction != nil }

    init() {
        benchmark = SpeakerEvaluationBenchmarkStore.load()
        vibeVoiceBenchmark = VibeVoiceGoldBenchmarkStore.load()
    }

    func reload() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        reloadTask = Task {
            do {
                let loaded = try await Task.detached(priority: .utility) {
                    (
                        try SpeakerEvaluationWorkspace.loadSnapshot(),
                        try SpeakerPairGoldStore.loadWorkspace()
                    )
                }.value
                try Task.checkCancellation()
                snapshot = loaded.0
                pairWorkspace = loaded.1
            } catch is CancellationError {
                // A superseded view load needs no banner.
            } catch {
                errorMessage = "Could not load the labeling workspace: \(error.localizedDescription)"
            }
            isLoading = false
            reloadTask = nil
        }
    }

    func reloadBenchmarkResults() {
        benchmark = SpeakerEvaluationBenchmarkStore.load()
        vibeVoiceBenchmark = VibeVoiceGoldBenchmarkStore.load()
    }

    func labelPair(
        _ candidate: SpeakerPairReviewCandidate,
        verdict: SpeakerPairGoldVerdict
    ) {
        guard !isSavingPair else { return }
        isSavingPair = true
        errorMessage = nil
        pairTask = Task {
            do {
                try await Task.detached(priority: .utility) {
                    try SpeakerPairGoldStore.save(
                        leftClusterId: candidate.left.id,
                        rightClusterId: candidate.right.id,
                        verdict: verdict,
                        role: candidate.goldRole
                    )
                }.value
                lastPairAction = (
                    candidate.left.id,
                    candidate.right.id,
                    nil
                )
                pairWorkspace = try await Task.detached(priority: .utility) {
                    try SpeakerPairGoldStore.loadWorkspace()
                }.value
                // Pair gold participates in the benchmark revision.
                if var current = snapshot {
                    current = try await Task.detached(priority: .utility) {
                        try SpeakerEvaluationWorkspace.loadSnapshot()
                    }.value
                    snapshot = current
                }
            } catch {
                errorMessage = "Could not save the voice comparison: \(error.localizedDescription)"
            }
            isSavingPair = false
            pairTask = nil
        }
    }

    func markMultipleSpeakers(
        _ candidate: SpeakerPairReviewCandidate,
        sample: SpeakerPairVoiceSample
    ) {
        guard !isSavingPair else { return }
        isSavingPair = true
        errorMessage = nil
        pairTask = Task {
            do {
                try await Task.detached(priority: .utility) {
                    try SpeakerPairGoldStore.markMultipleSpeakers(
                        pairLeftClusterId: candidate.left.id,
                        pairRightClusterId: candidate.right.id,
                        mixedClusterId: sample.id
                    )
                }.value
                lastPairAction = (
                    candidate.left.id,
                    candidate.right.id,
                    sample.id
                )
                pairWorkspace = try await Task.detached(priority: .utility) {
                    try SpeakerPairGoldStore.loadWorkspace()
                }.value
                snapshot = try await Task.detached(priority: .utility) {
                    try SpeakerEvaluationWorkspace.loadSnapshot()
                }.value
            } catch {
                errorMessage = "Could not save the multi-speaker clip: \(error.localizedDescription)"
            }
            isSavingPair = false
            pairTask = nil
        }
    }

    func undoLastPairLabel() {
        guard !isSavingPair, let lastPairAction else { return }
        isSavingPair = true
        pairTask = Task {
            do {
                try await Task.detached(priority: .utility) {
                    try SpeakerPairGoldStore.undo(
                        leftClusterId: lastPairAction.left,
                        rightClusterId: lastPairAction.right,
                        mixedClusterId: lastPairAction.mixedClusterId
                    )
                }.value
                self.lastPairAction = nil
                pairWorkspace = try await Task.detached(priority: .utility) {
                    try SpeakerPairGoldStore.loadWorkspace()
                }.value
                snapshot = try await Task.detached(priority: .utility) {
                    try SpeakerEvaluationWorkspace.loadSnapshot()
                }.value
            } catch {
                errorMessage = "Could not undo the voice comparison: \(error.localizedDescription)"
            }
            isSavingPair = false
            pairTask = nil
        }
    }

    func runActiveProfile() {
        run(profiles: [SpeakerPipelineSettings.shared.selectedProfile])
    }

    func compareProfiles() {
        run(profiles: [.legacy, .balanced, .accuracy, .targetedSortformer])
    }

    func runSelectedVibeVoice(recordingID: Int64?) {
        let settings = GlobalModelSettings.shared
        runVibeVoice(configurations: [
            .current(
                quantization: settings.selectedVibeVoiceQuantization,
                speakerMode: settings.vibeVoiceSpeakerMode
            )
        ], recordingID: recordingID, shortestRecordingLimit: nil)
    }

    func compareDownloadedVibeVoice(recordingID: Int64?) {
        let downloaded = VibeVoiceQuantization.allCases.filter {
            VibeVoiceModelManager.shared.isModelDownloaded($0)
        }
        runVibeVoice(configurations: downloaded.flatMap { quantization in
            VibeVoiceSpeakerMode.allCases.map {
                .current(quantization: quantization, speakerMode: $0)
            }
        }, recordingID: recordingID, shortestRecordingLimit: nil)
    }

    func compareWhisperWithFourBitFused() {
        runVibeVoice(
            configurations: [
                .current(quantization: .fourBit, speakerMode: .fused)
            ],
            recordingID: nil,
            shortestRecordingLimit: 3
        )
    }

    func cancelEvaluation() {
        evaluationTask?.cancel()
    }

    func applyReconciliation(_ report: GlobalSpeakerReconciliationShadowReport) {
        guard !isApplyingReconciliation else { return }
        isApplyingReconciliation = true
        errorMessage = nil
        reconciliationMessage = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try GlobalSpeakerLibraryReconciliation.apply(expectedReport: report)
                }.value
                SpeakerPipelineSettings.shared.continuousReconciliationEnabled = true
                reconciliationMessage = "Applied \(result.changedClusterCount) local voice changes. Created \(result.createdIdentityCount) new identities and retired \(result.retiredIdentityCount)."
                pairWorkspace = try await Task.detached(priority: .utility) {
                    try SpeakerPairGoldStore.loadWorkspace()
                }.value
                snapshot = try await Task.detached(priority: .utility) {
                    try SpeakerEvaluationWorkspace.loadSnapshot()
                }.value
            } catch {
                errorMessage = "Global reconciliation was not applied: \(error.localizedDescription)"
            }
            isApplyingReconciliation = false
        }
    }

    func undoLatestReconciliation() {
        guard !isApplyingReconciliation else { return }
        isApplyingReconciliation = true
        errorMessage = nil
        reconciliationMessage = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try GlobalSpeakerLibraryReconciliation.undoLatest()
                }.value
                if let result {
                    SpeakerPipelineSettings.shared.continuousReconciliationEnabled = false
                    reconciliationMessage = "Restored \(result.restoredClusterCount) local voices"
                        + (result.skippedClusterCount > 0
                            ? "; \(result.skippedClusterCount) newer manual changes were preserved."
                            : ".")
                } else {
                    reconciliationMessage = "There is no active reconciliation run to undo."
                }
                pairWorkspace = try await Task.detached(priority: .utility) {
                    try SpeakerPairGoldStore.loadWorkspace()
                }.value
                snapshot = try await Task.detached(priority: .utility) {
                    try SpeakerEvaluationWorkspace.loadSnapshot()
                }.value
            } catch {
                errorMessage = "Could not undo reconciliation: \(error.localizedDescription)"
            }
            isApplyingReconciliation = false
        }
    }

    private func run(profiles: [SpeakerPipelineProfile]) {
        guard !isEvaluating else { return }
        isEvaluating = true
        errorMessage = nil
        benchmarkProgress = nil
        evaluationTask = Task {
            do {
                let provider = LocalSpeakerEvaluationDataProvider()
                let dataset = try await Task.detached(priority: .utility) {
                    try provider.loadDataset()
                }.value
                guard !dataset.recordings.isEmpty else {
                    throw EvaluationUIError.noGold
                }
                let bundle = await SpeakerEvaluationBenchmarkRunner.run(
                    dataset: dataset,
                    profiles: profiles,
                    pairGoldBenchmark: try? provider.loadPairGoldBenchmark(),
                    calibrationBackend: try? provider.loadCalibrationBackend()
                ) { [weak self] progress in
                    self?.benchmarkProgress = progress
                }
                try Task.checkCancellation()
                try SpeakerEvaluationBenchmarkStore.save(bundle)
                benchmark = bundle
                reload()
            } catch is CancellationError {
                // Cancellation is an expected user action and needs no error banner.
            } catch {
                errorMessage = "Evaluation failed: \(error.localizedDescription)"
            }
            benchmarkProgress = nil
            isEvaluating = false
            evaluationTask = nil
        }
    }

    private func runVibeVoice(
        configurations: [VibeVoiceGoldBenchmarkConfiguration],
        recordingID: Int64?,
        shortestRecordingLimit: Int?
    ) {
        guard !isEvaluating else { return }
        guard !configurations.isEmpty else {
            errorMessage = "Download at least one VibeVoice model before comparing it."
            return
        }
        isEvaluating = true
        errorMessage = nil
        benchmarkProgress = nil
        vibeVoiceBenchmarkProgress = nil
        evaluationTask = Task {
            do {
                let provider = LocalSpeakerEvaluationDataProvider()
                let completeDataset = try await Task.detached(priority: .utility) {
                    try provider.loadDataset()
                }.value
                let dataset: SpeakerEvaluationDataset
                if let recordingID {
                    dataset = SpeakerEvaluationDataset(
                        recordings: completeDataset.recordings.filter {
                            $0.recording.id == recordingID
                        },
                        goldRevision: completeDataset.goldRevision
                    )
                } else if let shortestRecordingLimit {
                    dataset = SpeakerEvaluationDataset(
                        recordings: Array(
                            completeDataset.recordings.sorted {
                                let leftDuration = $0.recording.duration ?? .greatestFiniteMagnitude
                                let rightDuration = $1.recording.duration ?? .greatestFiniteMagnitude
                                if leftDuration != rightDuration {
                                    return leftDuration < rightDuration
                                }
                                return ($0.recording.id ?? 0) < ($1.recording.id ?? 0)
                            }
                            .prefix(shortestRecordingLimit)
                        ),
                        goldRevision: completeDataset.goldRevision
                    )
                } else {
                    dataset = completeDataset
                }
                guard !dataset.recordings.isEmpty else {
                    throw EvaluationUIError.noGold
                }
                let bundle = await VibeVoiceGoldBenchmarkRunner.run(
                    dataset: dataset,
                    configurations: configurations,
                    speakerResolver: try provider.loadSpeakerResolver()
                ) { [weak self] progress in
                    self?.vibeVoiceBenchmarkProgress = progress
                }
                try Task.checkCancellation()
                try VibeVoiceGoldBenchmarkStore.save(bundle)
                vibeVoiceBenchmark = bundle
                reload()
            } catch is CancellationError {
                VibeVoiceService.shared.cancel()
            } catch {
                errorMessage = "VibeVoice evaluation failed: \(error.localizedDescription)"
            }
            vibeVoiceBenchmarkProgress = nil
            isEvaluating = false
            evaluationTask = nil
        }
    }

    private enum EvaluationUIError: LocalizedError {
        case noGold

        var errorDescription: String? {
            "Confirm at least one complete conversation as Speaker gold before evaluating."
        }
    }
}

struct SpeakerEvaluationSettingsView: View {
    private enum QueueFilter: String, CaseIterable, Identifiable {
        case recommended = "Recommended"
        case activeLearning = "Active learning"
        case inProgress = "In progress"
        case needsCorrection = "Needs correction"
        case gold = "Gold"
        case all = "All"

        var id: String { rawValue }
    }

    @StateObject private var model = SpeakerEvaluationSettingsModel()
    @StateObject private var pairPlayer = QuotePlayerViewModel()
    @ObservedObject private var transcriptionQueue = TranscriptionQueueManager.shared
    @ObservedObject private var pipelineSettings = SpeakerPipelineSettings.shared
    @ObservedObject private var modelSettings = GlobalModelSettings.shared
    @AppStorage("speakerEvaluation.goldTarget") private var goldTarget = 20
    @State private var filter: QueueFilter = .recommended
    @State private var searchText = ""
    @State private var selectedRecording: Recording?
    @State private var vibeVoiceGoldRecordingID: Int64?
    @State private var reconciliationToApply: GlobalSpeakerReconciliationShadowReport?
    @State private var showReconciliationConfirmation = false

    private var summary: SpeakerEvaluationSummary {
        model.snapshot?.summary ?? SpeakerEvaluationSummary()
    }

    private var visibleCandidates: [SpeakerEvaluationCandidate] {
        let candidates = model.snapshot?.candidates ?? []
        return candidates.filter { candidate in
            let matchesFilter: Bool
            switch filter {
            case .recommended:
                matchesFilter = !candidate.isGoldReady
            case .activeLearning:
                matchesFilter = !candidate.isGoldReady && candidate.activeLearning.score >= 15
            case .inProgress:
                matchesFilter = candidate.reviewStatus == .inProgress
                    || candidate.reviewStatus == .complete
            case .needsCorrection:
                matchesFilter = candidate.reviewStatus == .needsCorrection
                    || (candidate.reviewStatus == .gold && !candidate.isGoldReady)
            case .gold:
                matchesFilter = candidate.isGoldReady
            case .all:
                matchesFilter = true
            }
            guard matchesFilter else { return false }
            guard !searchText.isEmpty else { return true }
            return candidate.recording.title.localizedCaseInsensitiveContains(searchText)
                || candidate.recording.fileName.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var benchmarkIsStale: Bool {
        guard let benchmark = model.benchmark else { return false }
        return benchmark.goldRevision != summary.goldRevision
    }

    private var vibeVoiceBenchmarkIsStale: Bool {
        guard let benchmark = model.vibeVoiceBenchmark else { return false }
        return benchmark.goldRevision != summary.goldRevision
    }

    private var downloadedVibeVoiceModelCount: Int {
        VibeVoiceQuantization.allCases.filter {
            VibeVoiceModelManager.shared.isModelDownloaded($0)
        }.count
    }

    private var vibeVoiceGoldRecordings: [Recording] {
        (model.snapshot?.candidates ?? [])
            .filter(\.isGoldReady)
            .map(\.recording)
            .sorted {
                if ($0.duration ?? 0) != ($1.duration ?? 0) {
                    return ($0.duration ?? 0) < ($1.duration ?? 0)
                }
                return $0.title < $1.title
            }
    }

    private var activeLearningCount: Int {
        model.snapshot?.candidates.filter {
            !$0.isGoldReady && $0.activeLearning.score >= 15
        }.count ?? 0
    }

    private var evaluationDisabled: Bool {
        summary.goldRecordingCount == 0
            || model.isEvaluating
            || transcriptionQueueIsBusy
    }

    private var transcriptionQueueIsBusy: Bool {
        transcriptionQueue.activeWorkers > 0
            || transcriptionQueue.processingCount > 0
            || transcriptionQueue.currentJob != nil
            || !transcriptionQueue.pendingJobs.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let error = model.errorMessage {
                    errorBanner(error)
                }
                if let message = model.reconciliationMessage {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundColor(.green)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                datasetSection
                pairReviewSection
                labelingQueueSection
                benchmarkSection
            }
            .padding(24)
        }
        .task { model.reload() }
        .onReceive(
            NotificationCenter.default.publisher(for: .vibeVoiceGoldBenchmarkDidChange)
        ) { _ in
            model.reloadBenchmarkResults()
        }
        .sheet(item: $selectedRecording, onDismiss: model.reload) { recording in
            RecordingDetailSheet(recording: recording)
        }
        .confirmationDialog(
            "Apply global speaker reconciliation?",
            isPresented: $showReconciliationConfirmation,
            titleVisibility: .visible
        ) {
            Button("Apply reversible changes") {
                if let report = reconciliationToApply {
                    model.applyReconciliation(report)
                }
                reconciliationToApply = nil
            }
            Button("Cancel", role: .cancel) {
                reconciliationToApply = nil
            }
        } message: {
            Text(
                "This can split contaminated automatic identities and merge matching voices across recordings. Manual and gold assignments are protected. The complete run can be undone."
            )
        }
        .onDisappear { pairPlayer.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Speaker evaluation")
                        .font(.title2.bold())
                    Text("Build a trustworthy test set from your own conversations, then compare speaker pipelines locally.")
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    model.reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading || model.isEvaluating)
            }
            Text("Nothing becomes ground truth automatically. Only conversations you explicitly confirm as Speaker gold are scored.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var datasetSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Gold dataset", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                    Spacer()
                    Stepper("Goal: \(goldTarget) calls", value: $goldTarget, in: 5...100, step: 5)
                        .fixedSize()
                }

                HStack(spacing: 12) {
                    summaryTile(
                        value: "\(summary.goldRecordingCount)",
                        label: "Gold calls",
                        color: .green
                    )
                    summaryTile(
                        value: summary.goldVisibleUtteranceCount.formatted(),
                        label: "Gold labels",
                        color: .blue
                    )
                    summaryTile(
                        value: durationLabel(summary.goldDuration),
                        label: "Reviewed audio",
                        color: .purple
                    )
                    summaryTile(
                        value: "\(summary.inProgressCount + summary.needsCorrectionCount)",
                        label: "Under review",
                        color: .orange
                    )
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Dataset goal")
                        Spacer()
                        Text("\(summary.goldRecordingCount) of \(goldTarget)")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    ProgressView(
                        value: min(1, Double(summary.goldRecordingCount) / Double(max(1, goldTarget)))
                    )
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Gold-set coverage")
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 8) {
                        coveragePill("1 speaker", summary.coverage.singleSpeaker)
                        coveragePill("2 speakers", summary.coverage.twoSpeakers)
                        coveragePill("3 speakers", summary.coverage.threeSpeakers)
                        coveragePill("4+ speakers", summary.coverage.fourPlusSpeakers)
                        Spacer()
                        coveragePill("Mic", summary.coverage.microphone)
                        coveragePill("System", summary.coverage.system)
                        coveragePill("Mixed", summary.coverage.mixed)
                    }
                    Text("Aim for several calls in every speaker-count and audio-source bucket. Room meetings recorded through one computer microphone belong in the multi-speaker buckets.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var labelingQueueSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Labeling queue", systemImage: "list.number")
                            .font(.headline)
                        Text("Recommended calls combine review effort and coverage with embedding contradictions. \(activeLearningCount) calls currently have active-learning evidence.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundColor(.purple)
                    Text("Active learning looks for probable false splits, mixed voices under one label, identity outliers across calls, and a smaller sample of clearly different voices. A clip marked multi-speaker is immediately removed from global voice enrollment and future Same/Different questions.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .background(.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))

                HStack {
                    Picker("Show", selection: $filter) {
                        ForEach(QueueFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    TextField("Search calls", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                }

                if model.isLoading && model.snapshot == nil {
                    ProgressView("Finding the best calls to label…")
                        .frame(maxWidth: .infinity, minHeight: 90)
                } else if visibleCandidates.isEmpty {
                    ContentUnavailableView(
                        filter == .gold ? "No gold calls yet" : "No matching calls",
                        systemImage: "waveform.badge.magnifyingglass",
                        description: Text(
                            filter == .gold
                                ? "Open a recommended call, correct every visible speaker label, then choose Confirm as Speaker gold."
                                : "Try another filter or search."
                        )
                    )
                    .frame(minHeight: 130)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(visibleCandidates.enumerated()), id: \.element.id) { index, candidate in
                            candidateRow(candidate, rank: index + 1)
                            if index < visibleCandidates.count - 1 {
                                Divider().padding(.leading, 38)
                            }
                        }
                    }
                }
            }
        }
    }

    private var pairReviewSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(
                            "Active learning · Compare voices",
                            systemImage: "waveform.badge.magnifyingglass"
                        )
                            .font(.headline)
                        Text("Fast global-speaker gold: listen to two short samples and answer one question.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if let workspace = model.pairWorkspace {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(workspace.counts.scored) scored pair\(workspace.counts.scored == 1 ? "" : "s")")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.green)
                            Text(
                                "\(workspace.developmentCounts.scored) calibration · "
                                    + "\(workspace.heldOutCounts.scored) held-out"
                            )
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            if workspace.multipleSpeakerClipCount > 0 {
                                Text(
                                    "\(workspace.multipleSpeakerClipCount) multi-speaker clip"
                                        + (workspace.multipleSpeakerClipCount == 1 ? "" : "s")
                                        + " marked"
                                )
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.orange)
                            }
                        }
                    }
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "shield.lefthalf.filled")
                        .foregroundColor(.blue)
                    Text("Same/Different becomes direct global-identity gold. Mark a specific clip when it contains multiple speakers; it will be excluded from identity scoring and saved for future audio splitting. None of these actions changes People.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))

                if let counts = model.pairWorkspace?.heldOutCounts,
                   counts.samePerson < 3 || counts.differentPeople < 3 {
                    let missingSame = max(0, 3 - counts.samePerson)
                    let missingDifferent = max(0, 3 - counts.differentPeople)
                    Label(
                        [
                            missingSame > 0
                                ? "\(missingSame) held-out Same"
                                : nil,
                            missingDifferent > 0
                                ? "\(missingDifferent) held-out Different"
                                : nil,
                        ]
                        .compactMap { $0 }
                        .joined(separator: " and ")
                            + " answer"
                            + (missingSame + missingDifferent == 1 ? "" : "s")
                            + " needed before automatic global reconciliation",
                        systemImage: "target"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.purple)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                if model.isLoading && model.pairWorkspace == nil {
                    ProgressView("Finding the most informative voice pairs…")
                        .frame(maxWidth: .infinity, minHeight: 100)
                } else if let candidate = model.pairWorkspace?.candidates.first {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            pairSampleCard(
                                "Voice A",
                                sample: candidate.left,
                                candidate: candidate
                            )
                            pairSampleCard(
                                "Voice B",
                                sample: candidate.right,
                                candidate: candidate
                            )
                        }

                        DisclosureGroup("Show why this pair was selected and its current labels") {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(candidate.reason)
                                Text(
                                    "Current labels: "
                                        + currentLabel(candidate.left)
                                        + " / "
                                        + currentLabel(candidate.right)
                                )
                                Text(
                                    "Embedding similarity: "
                                        + candidate.similarity.formatted(
                                            .percent.precision(.fractionLength(1))
                                        )
                                )
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 5)
                        }
                        .font(.caption)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Are Voice A and Voice B the same real person?")
                                    .font(.subheadline.weight(.semibold))
                                Text(candidate.goldRole.displayName)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundColor(
                                        candidate.goldRole == .heldOut ? .purple : .blue
                                    )
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        (candidate.goldRole == .heldOut
                                            ? Color.purple
                                            : Color.blue
                                        ).opacity(0.10),
                                        in: Capsule()
                                    )
                            }
                            Text("Only answer when each clip contains one person. Otherwise mark the affected clip above.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        HStack(spacing: 8) {
                            Button {
                                pairPlayer.stop()
                                model.labelPair(candidate, verdict: .samePerson)
                            } label: {
                                Label("Same person", systemImage: "person.crop.circle.badge.checkmark")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)

                            Button {
                                pairPlayer.stop()
                                model.labelPair(candidate, verdict: .differentPeople)
                            } label: {
                                Label("Different people", systemImage: "person.2.slash")
                            }
                            .buttonStyle(.bordered)

                            Button("Unsure — skip pair") {
                                pairPlayer.stop()
                                model.labelPair(candidate, verdict: .unsure)
                            }
                            .buttonStyle(.borderless)

                            Spacer()
                            if model.isSavingPair {
                                ProgressView().controlSize(.small)
                            }
                            Button("Undo last") {
                                pairPlayer.stop()
                                model.undoLastPairLabel()
                            }
                            .disabled(model.isSavingPair || !model.canUndoPairLabel)
                        }
                        .disabled(model.isSavingPair)
                    }
                } else {
                    ContentUnavailableView(
                        "No voice pairs ready",
                        systemImage: "checkmark.circle",
                        description: Text(
                            "Pairs appear after recordings have local voice embeddings and accessible audio."
                        )
                    )
                    .frame(minHeight: 130)
                }

                if let pairBenchmark = model.pairWorkspace?.benchmark {
                    pairGoldBenchmark(pairBenchmark)
                }
                if let shadow = model.pairWorkspace?.reconciliationShadow {
                    reconciliationShadow(shadow)
                }
            }
        }
    }

    private func pairSampleCard(
        _ title: String,
        sample: SpeakerPairVoiceSample,
        candidate: SpeakerPairReviewCandidate
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.bold())
                .foregroundColor(.secondary)
            QuoteRow(
                item: QuoteItem(
                    id: Int(sample.id),
                    text: sample.text.isEmpty ? "No transcript text" : sample.text,
                    start: sample.startTime,
                    end: sample.endTime,
                    audioPath: sample.audioPath,
                    recordingTitle: sample.recordingTitle,
                    recordingDate: nil
                ),
                player: pairPlayer
            )
            Button {
                pairPlayer.stop()
                model.markMultipleSpeakers(candidate, sample: sample)
            } label: {
                Label(
                    "Multiple speakers in this clip",
                    systemImage: "person.3.sequence.fill"
                )
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.small)
            .disabled(model.isSavingPair)
            .help(
                "Exclude this recording-local voice cluster from identity scoring "
                    + "and save it for future audio splitting."
            )
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.secondary.opacity(0.12))
        }
    }

    private func currentLabel(_ sample: SpeakerPairVoiceSample) -> String {
        if let name = sample.currentSpeakerName,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        if let uuid = sample.currentSpeakerUUID {
            return "Speaker \(uuid.prefix(8))"
        }
        return "unassigned local voice"
    }

    private func pairGoldBenchmark(
        _ report: SpeakerPairGoldBenchmarkReport
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
            Text("Live global benchmark on pair gold")
                .font(.subheadline.weight(.semibold))
            HStack {
                Text("Method").frame(maxWidth: .infinity, alignment: .leading)
                Text("Accuracy").frame(width: 72, alignment: .trailing)
                Text("FM").frame(width: 42, alignment: .trailing)
                Text("FS").frame(width: 42, alignment: .trailing)
                Text("Pairs").frame(width: 48, alignment: .trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundColor(.secondary)
            ForEach(report.candidates) { candidate in
                HStack {
                    HStack(spacing: 5) {
                        Text(candidate.name)
                        if let threshold = candidate.threshold {
                            Text(threshold.formatted(.number.precision(.fractionLength(2))))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(
                        candidate.metrics.accuracy?.formatted(
                            .percent.precision(.fractionLength(1))
                        ) ?? "—"
                    )
                    .frame(width: 72, alignment: .trailing)
                    Text(candidate.metrics.falseMergePairs.formatted())
                        .frame(width: 42, alignment: .trailing)
                    Text(candidate.metrics.falseSplitPairs.formatted())
                        .frame(width: 42, alignment: .trailing)
                    Text(candidate.metrics.evaluatedPairCount.formatted())
                        .frame(width: 48, alignment: .trailing)
                }
                .font(.caption.monospacedDigit())
            }
            Text("Marked multi-speaker clips and unsure pairs are excluded from accuracy. A larger number is not enough to promote a matcher if it creates additional false merges.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func reconciliationShadow(
        _ report: GlobalSpeakerReconciliationShadowReport
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Label("Global reconciliation · preview", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(
                    report.canApply
                        ? "Held-out safety gate passed"
                        : "Preview only"
                )
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(report.canApply ? .green : .orange)
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                GridRow {
                    Text("Clean local voices")
                    Text(report.evaluatedNodeCount.formatted()).monospacedDigit()
                    Text("Excluded mixed/unreliable")
                    Text(report.excludedNodeCount.formatted()).monospacedDigit()
                }
                GridRow {
                    Text("Current identities")
                    Text(report.existingIdentityCount.formatted()).monospacedDigit()
                    Text("Shadow identities")
                    Text(report.proposedIdentityCount.formatted()).monospacedDigit()
                }
                GridRow {
                    Text("Identities needing split")
                    Text(report.proposedSplitIdentityCount.formatted()).monospacedDigit()
                    Text("Components joining identities")
                    Text(report.proposedMergeComponentCount.formatted()).monospacedDigit()
                }
                GridRow {
                    Text("Calibration pairs")
                    Text(report.trainingPairCount.formatted()).monospacedDigit()
                    Text("Learned merge threshold")
                    Text(
                        report.calibratedMergeProbability.formatted(
                            .number.precision(.fractionLength(3))
                        )
                    )
                    .monospacedDigit()
                }
                GridRow {
                    Text("Same / different gold")
                    Text(
                        "\(report.samePersonPairCount.formatted()) / "
                            + report.differentPeoplePairCount.formatted()
                    )
                    .monospacedDigit()
                    Text("Acoustic merge steps")
                    Text(report.automaticAcousticMergeCount.formatted()).monospacedDigit()
                }
                GridRow {
                    Text("Held-out safety pairs")
                    Text(
                        "\(report.heldOutSamePersonPairCount) same / "
                            + "\(report.heldOutDifferentPeoplePairCount) different"
                    )
                    .monospacedDigit()
                    Text("Held-out false merges")
                    Text(report.heldOutFalseMergePairs.formatted())
                        .monospacedDigit()
                        .foregroundColor(
                            report.heldOutFalseMergePairs == 0 ? .green : .red
                        )
                }
                GridRow {
                    Text("Held-out accuracy")
                    Text(
                        report.heldOutAccuracy?.formatted(
                            .percent.precision(.fractionLength(1))
                        ) ?? "Not enough data"
                    )
                    .monospacedDigit()
                    Text("Held-out false splits")
                    Text(report.heldOutFalseSplitPairs.formatted()).monospacedDigit()
                }
                GridRow {
                    Text("Constraint conflicts")
                    Text(report.constraintConflictCount.formatted()).monospacedDigit()
                    Text("")
                    Text("")
                }
            }
            .font(.caption)
            if report.applyBlockers.isEmpty {
                Label(
                    "Calibration and held-out safety gates passed. Manual/gold assignments remain locked.",
                    systemImage: "checkmark.shield.fill"
                )
                .font(.caption)
                .foregroundColor(.green)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(report.applyBlockers, id: \.self) {
                        Label($0, systemImage: "lock.fill")
                    }
                }
                .font(.caption)
                .foregroundColor(.orange)
            }
            HStack {
                Button {
                    reconciliationToApply = report
                    showReconciliationConfirmation = true
                } label: {
                    Label("Apply reconciliation", systemImage: "arrow.triangle.merge")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!report.canApply || model.isApplyingReconciliation)

                Button {
                    model.undoLatestReconciliation()
                } label: {
                    Label("Undo latest run", systemImage: "arrow.uturn.backward")
                }
                .disabled(model.isApplyingReconciliation)

                if model.isApplyingReconciliation {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            Text(
                "The preview rebuilds from immutable recording-local voices, ignores legacy automatic "
                    + "merges, enforces Same/Different and overlap constraints, and stores a complete "
                    + "undo snapshot before changing People."
            )
            .font(.caption2)
            .foregroundColor(.secondary)
        }
    }

    private func candidateRow(_ candidate: SpeakerEvaluationCandidate, rank: Int) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(filter == .recommended ? "\(rank)" : " ")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .frame(width: 20)

            Image(systemName: candidate.recording.source.icon)
                .foregroundColor(candidate.recording.source.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(candidate.recording.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    statusPill(candidate)
                    if !candidate.audioExists {
                        Label("No audio", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                    if !candidate.isGoldReady && candidate.activeLearning.score >= 30 {
                        Label("HIGH INFORMATION", systemImage: "sparkles")
                            .font(.caption2.bold())
                            .foregroundColor(.purple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.purple.opacity(0.11), in: Capsule())
                            .help("This call contains an embedding contradiction or an uncertain speaker boundary.")
                    }
                }
                Text(candidate.recommendationReasons.joined(separator: " · "))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                HStack(spacing: 12) {
                    Label("\(candidate.visibleSpeakerCount) speakers", systemImage: "person.2")
                    Label("\(candidate.visibleUtteranceCount) lines", systemImage: "text.bubble")
                    Label(candidate.recording.formattedDuration, systemImage: "clock")
                    Text("~\(candidate.estimatedReviewMinutes) min review")
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                if !candidate.isGoldReady && candidate.assignmentProgress > 0 {
                    ProgressView(value: candidate.assignmentProgress)
                        .frame(width: 90)
                    Text("\(Int(candidate.assignmentProgress * 100))% labeled")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Button(candidate.isGoldReady ? "Inspect" : "Review") {
                    selectedRecording = candidate.recording
                }
            }
        }
        .padding(.vertical, 10)
    }

    private var benchmarkSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Performance on your data", systemImage: "gauge.with.dots.needle.67percent")
                            .font(.headline)
                        Text("Runs diarization and cross-recording identity from scratch against the current gold calls. Audio and labels stay on this Mac.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Evaluate \(pipelineSettings.selectedProfile.displayName)") {
                        model.runActiveProfile()
                    }
                    .disabled(evaluationDisabled)
                    Button("Compare presets") {
                        model.compareProfiles()
                    }
                    .disabled(evaluationDisabled)
                }

                if transcriptionQueueIsBusy {
                    Label(
                        "Evaluation waits until transcription is idle so it does not compete for the audio models.",
                        systemImage: "hourglass"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                if model.isEvaluating {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(
                                model.vibeVoiceBenchmarkProgress?.message
                                    ?? model.benchmarkProgress?.message
                                    ?? "Preparing evaluation…"
                            )
                            Spacer()
                            Button("Cancel", role: .cancel) { model.cancelEvaluation() }
                        }
                        ProgressView(
                            value: model.vibeVoiceBenchmarkProgress?.fraction
                                ?? model.benchmarkProgress?.fraction
                                ?? 0
                        )
                    }
                }

                if let benchmark = model.benchmark {
                    Divider()
                    HStack {
                        Text("Latest result")
                            .font(.subheadline.weight(.semibold))
                        Text(benchmark.generatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if benchmarkIsStale {
                            Text("GOLD SET CHANGED")
                                .font(.caption2.bold())
                                .foregroundColor(.orange)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.orange.opacity(0.12), in: Capsule())
                        }
                        Spacer()
                        Text("Saved locally as JSON")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if benchmark.reports.isEmpty {
                        Text("No profile completed successfully.")
                            .foregroundColor(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            benchmarkHeader
                            Divider()
                            ForEach(Array(benchmark.reports.enumerated()), id: \.offset) { index, report in
                                benchmarkRow(report)
                                if index < benchmark.reports.count - 1 { Divider() }
                            }
                        }
                        .padding(.horizontal, 12)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    }

                    ForEach(benchmark.failures) { failure in
                        Label(
                            "\(failure.profile.displayName) did not run: \(failure.message)",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundColor(.orange)
                    }

                    ForEach(
                        benchmark.reports.filter {
                            $0.transcriptSegmentationCandidates?.isEmpty == false
                        },
                        id: \.runName
                    ) { report in
                        transcriptSegmentationBenchmark(report)
                    }

                    ForEach(
                        benchmark.reports.filter {
                            $0.globalIdentityCandidates?.isEmpty == false
                        },
                        id: \.runName
                    ) { report in
                        globalIdentityBenchmark(report)
                    }
                } else if !model.isEvaluating {
                    Text(
                        summary.goldRecordingCount == 0
                            ? "Create the first gold call to unlock evaluation."
                            : "No benchmark has been run yet."
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                vibeVoiceGoldBenchmarkSection

                Text("WDER is word-weighted speaker attribution error (lower is better). Each profile also reports transcript-row count, p95 row duration, and the fraction of rows crossing more than one gold speaker. Extra short rows are acceptable when E2E/global identity stays correct; mixed-speaker rows are not. Speaker-count MAE is the average count error. Strict temporal DER is intentionally omitted until turn boundaries are hand-verified.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var vibeVoiceGoldBenchmarkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack {
                Text("Benchmark scope")
                    .font(.caption.weight(.semibold))
                Picker("Benchmark scope", selection: $vibeVoiceGoldRecordingID) {
                    Text("All gold calls").tag(Int64?.none)
                    ForEach(vibeVoiceGoldRecordings) { recording in
                        if let id = recording.id {
                            Text(
                                "\(recording.title) · "
                                    + durationLabel(recording.duration ?? 0)
                            )
                            .tag(Optional(id))
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 420)
                Spacer()
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("VibeVoice ASR on the same gold calls", systemImage: "waveform.and.mic")
                        .font(.subheadline.weight(.semibold))
                    Text(
                        "Compare the selected quantization or every downloaded quantization "
                            + "with native and AlmRecorder-fused speaker handling."
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                Spacer()
                Button("Show 3 · Whisper ↔ 4-bit fused") {
                    model.compareWhisperWithFourBitFused()
                }
                .disabled(
                    evaluationDisabled
                        || !VibeVoiceModelManager.shared.isModelDownloaded(.fourBit)
                )
                Button(
                    "Evaluate \(modelSettings.selectedVibeVoiceQuantization.rawValue) · "
                        + modelSettings.vibeVoiceSpeakerMode.displayName
                ) {
                    model.runSelectedVibeVoice(recordingID: vibeVoiceGoldRecordingID)
                }
                .disabled(
                    evaluationDisabled
                        || !VibeVoiceModelManager.shared.isModelDownloaded(
                            modelSettings.selectedVibeVoiceQuantization
                        )
                )
                Button("Compare downloaded (\(downloadedVibeVoiceModelCount))") {
                    model.compareDownloadedVibeVoice(
                        recordingID: vibeVoiceGoldRecordingID
                    )
                }
                .disabled(evaluationDisabled || downloadedVibeVoiceModelCount == 0)
            }

            if downloadedVibeVoiceModelCount == 0 {
                Label(
                    "Download a VibeVoice model in Models to unlock this comparison.",
                    systemImage: "arrow.down.circle"
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }

            if let benchmark = model.vibeVoiceBenchmark {
                HStack {
                    Text("Latest ASR result")
                        .font(.caption.weight(.semibold))
                    Text(benchmark.generatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if let recordingIDs = benchmark.recordingIDs {
                        Text(
                            recordingIDs.count == 1
                                ? "1 call"
                                : "\(recordingIDs.count) calls"
                        )
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                    }
                    if vibeVoiceBenchmarkIsStale {
                        Text("GOLD SET CHANGED")
                            .font(.caption2.bold())
                            .foregroundColor(.orange)
                    }
                }

                if !benchmark.reports.isEmpty {
                    HStack {
                        Text("Configuration").frame(maxWidth: .infinity, alignment: .leading)
                        Text("WER").frame(width: 58, alignment: .trailing)
                        Text("CER").frame(width: 58, alignment: .trailing)
                        Text("WDER").frame(width: 58, alignment: .trailing)
                        Text("Count MAE").frame(width: 72, alignment: .trailing)
                        Text("Mixed").frame(width: 58, alignment: .trailing)
                        Text("Peak GB").frame(width: 60, alignment: .trailing)
                        Text("RTF").frame(width: 52, alignment: .trailing)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)

                    ForEach(benchmark.reports) { report in
                        HStack {
                            Text(report.configuration.displayName)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(percentLabel(report.metrics.wordErrorRate))
                                .frame(width: 58, alignment: .trailing)
                            Text(percentLabel(report.metrics.characterErrorRate))
                                .frame(width: 58, alignment: .trailing)
                            Text(percentLabel(report.metrics.wordDiarizationErrorRate))
                                .frame(width: 58, alignment: .trailing)
                            Text(
                                report.metrics.speakerCountMeanAbsoluteError.formatted(
                                    .number.precision(.fractionLength(2))
                                )
                            )
                            .frame(width: 72, alignment: .trailing)
                            Text(percentLabel(report.metrics.mixedSpeakerTranscriptSegmentRate))
                                .frame(width: 58, alignment: .trailing)
                            Text(
                                report.metrics.peakMemoryGB?.formatted(
                                    .number.precision(.fractionLength(1))
                                ) ?? "—"
                            )
                            .frame(width: 60, alignment: .trailing)
                            Text(
                                report.metrics.realTimeFactor?.formatted(
                                    .number.precision(.fractionLength(2))
                                ) ?? "—"
                            )
                            .frame(width: 52, alignment: .trailing)
                        }
                        .font(.caption.monospacedDigit())
                    }
                }

                ForEach(
                    benchmark.reports.filter { $0.callResults?.isEmpty == false }
                ) { report in
                    vibeVoiceTranscriptComparisons(report)
                }

                ForEach(benchmark.failures) { failure in
                    Label(
                        "\(failure.configuration.displayName) did not run: \(failure.message)",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundColor(.orange)
                }
            }

            Text(
                "WER and CER use the saved, cleaned transcript text as the reference; correct that "
                    + "text before treating them as gold. WDER and speaker-count error use your "
                    + "confirmed speaker labels. Native VibeVoice labels remain recording-local; "
                    + "the normal global Evidence Graph benchmark above measures cross-call identity."
            )
            .font(.caption2)
            .foregroundColor(.secondary)
        }
    }

    private func vibeVoiceTranscriptComparisons(
        _ report: VibeVoiceGoldBenchmarkReport
    ) -> some View {
        let calls = report.callResults ?? []
        return VStack(alignment: .leading, spacing: 8) {
            Divider()
            Label(
                "Readable call comparison · \(report.configuration.displayName)",
                systemImage: "rectangle.split.2x1"
            )
            .font(.subheadline.weight(.semibold))

            Text(
                "Left is the currently saved transcript (normally Whisper, including any cleanup "
                    + "or corrections). Right is the fresh VibeVoice result. Nothing here replaces "
                    + "the saved call."
            )
            .font(.caption2)
            .foregroundColor(.secondary)

            ForEach(calls) { call in
                DisclosureGroup {
                    HStack(alignment: .top, spacing: 12) {
                        transcriptComparisonPane(
                            title: "Saved / Whisper baseline",
                            lines: call.savedTranscript,
                            tint: .secondary
                        )
                        transcriptComparisonPane(
                            title: report.configuration.displayName,
                            lines: call.predictedTranscript,
                            tint: .accentColor
                        )
                    }
                    .padding(.top, 8)
                } label: {
                    HStack {
                        Text(call.title)
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(durationLabel(call.duration))
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
                .padding(10)
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8)
                )
            }
        }
    }

    private func transcriptComparisonPane(
        title: String,
        lines: [VibeVoiceGoldTranscriptLine],
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(tint)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(timestampLabel(line.startTime))
                                    .foregroundColor(.secondary)
                                if let speaker = line.speaker, !speaker.isEmpty {
                                    Text(speaker)
                                        .fontWeight(.semibold)
                                }
                            }
                            .font(.caption2.monospacedDigit())
                            Text(line.text)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 180, maxHeight: 420)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.secondary.opacity(0.18))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var benchmarkHeader: some View {
        HStack {
            Text("Profile").frame(maxWidth: .infinity, alignment: .leading)
            Text("WDER").frame(width: 72, alignment: .trailing)
            Text("Count MAE").frame(width: 82, alignment: .trailing)
            Text("E2E ID F1").frame(width: 82, alignment: .trailing)
            Text("RTF").frame(width: 58, alignment: .trailing)
            Text("Calls").frame(width: 54, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundColor(.secondary)
        .padding(.vertical, 8)
    }

    private func transcriptSegmentationBenchmark(
        _ report: SpeakerPipelineBenchmarkReport
    ) -> some View {
        let candidates = report.transcriptSegmentationCandidates ?? []
        return VStack(alignment: .leading, spacing: 8) {
            Divider()
            Label(
                "\(report.profile.displayName): transcript row splitting",
                systemImage: "text.line.first.and.arrowtriangle.forward"
            )
            .font(.subheadline.weight(.semibold))

            HStack {
                Text("Policy").frame(maxWidth: .infinity, alignment: .leading)
                Text("WDER").frame(width: 64, alignment: .trailing)
                Text("Rows").frame(width: 58, alignment: .trailing)
                Text("Rows/gold").frame(width: 72, alignment: .trailing)
                Text("P95").frame(width: 58, alignment: .trailing)
                Text("Mixed").frame(width: 64, alignment: .trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundColor(.secondary)

            ForEach(candidates) { candidate in
                HStack {
                    HStack(spacing: 6) {
                        Text(candidate.mode.displayName)
                        if candidate.mode == report.configuration.effectiveUtteranceSegmentation {
                            Text("SELECTED")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(percentLabel(candidate.metrics.wordDiarizationErrorRate))
                        .frame(width: 64, alignment: .trailing)
                    Text(candidate.metrics.transcriptSegmentCount?.formatted() ?? "—")
                        .frame(width: 58, alignment: .trailing)
                    Text(
                        candidate.metrics.transcriptFragmentationRatio?
                            .formatted(.number.precision(.fractionLength(2))) ?? "—"
                    )
                    .frame(width: 72, alignment: .trailing)
                    Text(candidate.metrics.p95TranscriptSegmentDuration.map {
                        "\($0.formatted(.number.precision(.fractionLength(1))))s"
                    } ?? "—")
                    .frame(width: 58, alignment: .trailing)
                    Text(percentLabel(candidate.metrics.mixedSpeakerTranscriptSegmentRate))
                        .frame(width: 64, alignment: .trailing)
                }
                .font(.caption.monospacedDigit())
                .padding(.vertical, 3)
            }

            Text("These three policies reuse the same acoustic diarization and global matcher. The benchmark therefore isolates transcript-row coalescing; it does not retrain or alter speaker profiles.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func globalIdentityBenchmark(
        _ report: SpeakerPipelineBenchmarkReport
    ) -> some View {
        let candidates = report.globalIdentityCandidates ?? []
        return VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Label(
                    "\(report.profile.displayName): global identity only",
                    systemImage: "person.2.badge.gearshape"
                )
                .font(.subheadline.weight(.semibold))
                Spacer()
                if let first = candidates.first {
                    Text(
                        "\(first.metrics.evaluatedNodeCount) clean local clusters · "
                            + "\(first.metrics.excludedNodeCount) mixed/weak excluded"
                    )
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
            }

            HStack {
                Text("Method").frame(maxWidth: .infinity, alignment: .leading)
                Text("P").frame(width: 54, alignment: .trailing)
                Text("R").frame(width: 54, alignment: .trailing)
                Text("Global F1").frame(width: 72, alignment: .trailing)
                Text("B³ F1").frame(width: 62, alignment: .trailing)
                Text("FM").frame(width: 42, alignment: .trailing)
                Text("FS").frame(width: 42, alignment: .trailing)
                Text("IDs").frame(width: 48, alignment: .trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundColor(.secondary)

            ForEach(candidates) { candidate in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(candidate.name)
                                .font(.caption.weight(
                                    candidate.id == "production-sequential" ? .semibold : .regular
                                ))
                            if let baseline = candidates.first,
                               candidate.id != baseline.id,
                               GlobalSpeakerGoldRegressionGate.passes(
                                   candidate: candidate.metrics,
                                   baseline: baseline.metrics
                               ) {
                                Text("PASSES FM GATE")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.green)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.green.opacity(0.12), in: Capsule())
                            }
                        }
                        if let threshold = candidate.threshold {
                            Text("threshold \(threshold.formatted(.number.precision(.fractionLength(2))))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    metricPercent(candidate.metrics.pairPrecision, width: 54)
                    metricPercent(candidate.metrics.pairRecall, width: 54)
                    metricPercent(candidate.metrics.pairF1, width: 72)
                    metricPercent(candidate.metrics.bCubedF1, width: 62)
                    Text(candidate.metrics.falseMergePairs.formatted())
                        .frame(width: 42, alignment: .trailing)
                    Text(candidate.metrics.falseSplitPairs.formatted())
                        .frame(width: 42, alignment: .trailing)
                    Text(
                        "\(candidate.metrics.predictedIdentityCount)/"
                            + "\(candidate.metrics.referenceIdentityCount)"
                    )
                    .frame(width: 48, alignment: .trailing)
                }
                .padding(.vertical, 4)
                .background(
                    candidate.id == "production-sequential"
                        ? Color.accentColor.opacity(0.07)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
            }
            Text("P/R/F1 and false merge/split counts compare global clusters across recordings. B³ gives every local cluster equal weight. A candidate passes the development gate only if global F1 and B³ improve with no additional false-merge pairs or identity-count error; it must still win on held-out gold before becoming a default. Running a comparison never changes your People data.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func metricPercent(_ value: Double?, width: CGFloat) -> some View {
        Text(value.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "—")
            .monospacedDigit()
            .frame(width: width, alignment: .trailing)
    }

    private func benchmarkRow(_ report: SpeakerPipelineBenchmarkReport) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(report.profile.displayName)
                    .font(.subheadline.weight(.semibold))
                Text(report.configuration.diarizationBackend.displayName)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(transcriptSegmentationLabel(report.metrics))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(percentLabel(report.metrics.wordDiarizationErrorRate))
                .frame(width: 72, alignment: .trailing)
            Text(report.metrics.speakerCountMeanAbsoluteError.formatted(.number.precision(.fractionLength(2))))
                .frame(width: 82, alignment: .trailing)
            Text(percentLabel(
                report.metrics.identityPairF1
                    ?? (report.metrics.falseSplitPairs > 0 ? 0 : nil)
            ))
                .frame(width: 82, alignment: .trailing)
                .help(
                    "\(report.metrics.falseMergePairs.formatted()) false-merge pairs · \(report.metrics.falseSplitPairs.formatted()) false-split pairs"
                )
            Text(report.realTimeFactor?.formatted(.number.precision(.fractionLength(2))) ?? "—")
                .frame(width: 58, alignment: .trailing)
            Text("\(report.processedRecordingCount)/\(report.requestedRecordingCount)")
                .frame(width: 54, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
        .padding(.vertical, 9)
    }

    private func transcriptSegmentationLabel(_ metrics: SpeakerPipelineMetrics) -> String {
        let rows = metrics.transcriptSegmentCount.map { "\($0) rows" } ?? "rows —"
        let p95 = metrics.p95TranscriptSegmentDuration.map {
            "p95 \($0.formatted(.number.precision(.fractionLength(1))))s"
        } ?? "p95 —"
        let mixed = metrics.mixedSpeakerTranscriptSegmentRate.map {
            "mixed \($0.formatted(.percent.precision(.fractionLength(1))))"
        } ?? "mixed —"
        return "\(rows) · \(p95) · \(mixed)"
    }

    private func settingsCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(18)
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.62),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.16))
            }
    }

    private func summaryTile(value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title3.bold())
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
    }

    private func coveragePill(_ label: String, _ count: Int) -> some View {
        HStack(spacing: 5) {
            Text(label)
            Text("\(count)")
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundColor(count > 0 ? .primary : .secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            count > 0 ? Color.green.opacity(0.12) : Color.secondary.opacity(0.08),
            in: Capsule()
        )
    }

    private func statusPill(_ candidate: SpeakerEvaluationCandidate) -> some View {
        let label: String
        let color: Color
        if candidate.isGoldReady {
            label = "GOLD"
            color = .green
        } else {
            switch candidate.reviewStatus {
            case .needsCorrection:
                label = "FIX"
                color = .orange
            case .inProgress, .complete:
                label = "STARTED"
                color = .blue
            case .gold:
                label = "STALE GOLD"
                color = .orange
            case nil:
                label = ""
                color = .secondary
            }
        }
        return Text(label)
            .font(.caption2.bold())
            .foregroundColor(color)
            .padding(.horizontal, label.isEmpty ? 0 : 6)
            .padding(.vertical, label.isEmpty ? 0 : 2)
            .background(color.opacity(label.isEmpty ? 0 : 0.11), in: Capsule())
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundColor(.red)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
    }

    private func durationLabel(_ duration: TimeInterval) -> String {
        if duration >= 3600 {
            return (duration / 3600).formatted(.number.precision(.fractionLength(1))) + " h"
        }
        return "\(Int(duration / 60)) min"
    }

    private func timestampLabel(_ time: TimeInterval) -> String {
        let totalSeconds = max(0, Int(time.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func percentLabel(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.percent.precision(.fractionLength(1)))
    }
}
