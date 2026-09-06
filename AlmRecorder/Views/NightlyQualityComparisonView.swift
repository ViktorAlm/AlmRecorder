import SwiftUI

/// A private, live view of every candidate produced for one quality-pipeline recording.
///
/// Candidate artifacts never leave Application Support. The view reloads the selected artifact
/// while it is open so VibeVoice, speaker-preserving consensus, and benchmark metrics appear without
/// reopening Settings.
struct NightlyQualityComparisonView: View {
    private struct ModelIOPresentation: Identifiable {
        let id = UUID()
        let traceID: UUID?
    }

    private enum Stage: String, CaseIterable, Identifiable {
        case foreground
        case whisper
        case vibeVoice
        case fused

        var id: String { rawValue }

        var title: String {
            switch self {
            case .foreground: return "Foreground"
            case .whisper: return "Whisper"
            case .vibeVoice: return "VibeVoice"
            case .fused: return "LLM consensus"
            }
        }

        var shortTitle: String {
            switch self {
            case .foreground: return "1 · Foreground"
            case .whisper: return "2 · Whisper"
            case .vibeVoice: return "3 · VibeVoice"
            case .fused: return "4 · Consensus"
            }
        }

        var icon: String {
            switch self {
            case .foreground: return "waveform"
            case .whisper: return "waveform.badge.mic"
            case .vibeVoice: return "text.bubble"
            case .fused: return "sparkles"
            }
        }

        var color: Color {
            switch self {
            case .foreground: return .blue
            case .whisper: return .cyan
            case .vibeVoice: return .purple
            case .fused: return .green
            }
        }

        var metricKey: String {
            switch self {
            case .foreground: return "foreground_asr"
            case .whisper: return "whisper"
            case .vibeVoice: return "vibevoice"
            case .fused: return "consensus"
            }
        }

        var rerunAction: RerunAction {
            switch self {
            case .foreground: return .foreground
            case .whisper: return .whisper
            case .vibeVoice: return .vibeVoice
            case .fused: return .consensus
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var nightly = NightlyQualityController.shared
    @State private var selectedRecordingID: Int64?
    @State private var selectedStage: Stage = .foreground
    @State private var artifact: NightlyQualityArtifact?
    @State private var memoryDiagnostics: MemoryDiagnosticsSnapshot?
    @State private var modelIOPresentation: ModelIOPresentation?
    @State private var showRerunConfirm = false
    @State private var pendingRerunAction: RerunAction = .whisper
    @State private var selectedConsensusStrategy: ConsensusRepairStrategy = .readableReconstruction

    private let artifactStore = NightlyQualityArtifactStore.shared

    private enum RerunAction {
        case foreground
        case whisper
        case vibeVoice
        case consensus
        case allConsensusStrategies
        case allCandidates

        var title: String {
            switch self {
            case .foreground: return "Re-transcribe foreground"
            case .whisper: return "Re-run Whisper"
            case .vibeVoice: return "Re-run VibeVoice"
            case .consensus: return "Re-run selected consensus"
            case .allConsensusStrategies: return "Run all 3 consensus strategies"
            case .allCandidates: return "Re-run all candidate models"
            }
        }

        var message: String {
            switch self {
            case .foreground:
                return "This replaces the visible transcript using the current foreground "
                    + "transcription model. User edits and decisions are carried over where they "
                    + "can be aligned. Whisper, VibeVoice, consensus, and metrics then rebuild."
            case .whisper:
                return "The cached Whisper candidate is replaced using the current model and "
                    + "segmentation settings. VibeVoice is kept; consensus and metrics rebuild."
            case .vibeVoice:
                return "The cached VibeVoice candidate is replaced using the current model. "
                    + "Whisper is kept; consensus and metrics rebuild."
            case .consensus:
                return "Whisper and VibeVoice are kept. The selected repair strategy listens to "
                    + "the matching audio and runs utterance by utterance with ±3 context turns."
            case .allConsensusStrategies:
                return "Whisper and VibeVoice are kept. Minimal repair, coherent verbatim, and "
                    + "editorial cleanup each run over the same locked VibeVoice turns, "
                    + "then appear side by side with separate metrics and model traces."
            case .allCandidates:
                return "The visible foreground transcript is kept. Whisper, VibeVoice, "
                    + "consensus, and metrics all rebuild from scratch."
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            recordingList
                .navigationTitle("Quality runs")
        } detail: {
            comparisonDetail
                .navigationTitle(selectedItem?.title ?? "Quality comparison")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .frame(minWidth: 1_080, minHeight: 720)
        .onAppear {
            if selectedRecordingID == nil {
                selectedRecordingID = nightly.manifest?.items.first?.id
            }
            reloadArtifact()
        }
        .onChange(of: selectedRecordingID) {
            selectedStage = firstAvailableStage
            reloadArtifact()
        }
        .task(id: selectedRecordingID) {
            while !Task.isCancelled {
                reloadArtifact()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .task {
            while !Task.isCancelled {
                memoryDiagnostics = await Task.detached(priority: .utility) {
                    SystemMemoryDiagnostics.capture()
                }.value
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .sheet(item: $modelIOPresentation) { presentation in
            NightlyQualityModelIOView(
                traces: selectedConsensusTraces,
                initialTraceID: presentation.traceID
            )
        }
        .alert("\(pendingRerunAction.title) for this call?", isPresented: $showRerunConfirm) {
            Button("Cancel", role: .cancel) { }
            Button(pendingRerunAction.title) {
                performPendingRerun()
            }
        } message: {
            Text(pendingRerunAction.message)
        }
    }

    private var recordingList: some View {
        List(selection: $selectedRecordingID) {
            if let items = nightly.manifest?.items {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            Text(stageCount(for: item.id))
                                .monospacedDigit()
                            Text("·")
                            Text(itemStatus(item))
                        }
                        .font(.caption)
                        .foregroundStyle(
                            item.state == .failed || artifactNeedsRebuild(recordingID: item.id)
                                ? .orange
                                : .secondary
                        )
                    }
                    .padding(.vertical, 3)
                    .tag(Optional(item.id))
                }
            } else {
                ContentUnavailableView(
                    "No quality plan",
                    systemImage: "rectangle.stack.badge.questionmark"
                )
            }
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 285, max: 340)
    }

    @ViewBuilder
    private var comparisonDetail: some View {
        if let artifact {
            VStack(spacing: 0) {
                comparisonHeader(artifact)
                Divider()
                candidateContent(artifact)
            }
        } else if let item = selectedItem {
            ContentUnavailableView {
                Label("Preparing foreground snapshot", systemImage: "hourglass")
            } description: {
                Text("\(item.title) has not written its private quality artifact yet.")
            }
        } else {
            ContentUnavailableView(
                "Select a call",
                systemImage: "waveform.and.magnifyingglass"
            )
        }
    }

    private func comparisonHeader(_ artifact: NightlyQualityArtifact) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedItem?.title ?? "Recording \(artifact.recordingID)")
                        .font(.title2.weight(.bold))
                    Text(completionSummary(artifact))
                        .font(.callout)
                        .foregroundStyle(
                            artifactIsCurrent(artifact) && artifact.completedAt != nil
                                ? .green
                                : .orange
                        )
                }
                Spacer()
                Button {
                    requestRerun(selectedStage.rerunAction)
                } label: {
                    Label(
                        selectedStage == .fused
                            ? "Run \(selectedConsensusStrategy.displayName)"
                            : selectedStage.rerunAction.title,
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(selectedStage.color)
                .disabled(selectedRecordingID == nil)
                .help(
                    "Re-run the selected stage and every dependent output. This takes priority "
                        + "and safely interrupts any active nightly model step."
                )
                Menu {
                    Button {
                        requestRerun(.foreground)
                    } label: {
                        Label("Re-transcribe foreground…", systemImage: "waveform")
                    }
                    Divider()
                    ForEach(
                        [
                            RerunAction.whisper,
                            RerunAction.vibeVoice,
                            RerunAction.consensus
                        ],
                        id: \.title
                    ) { action in
                        Button {
                            requestRerun(action)
                        } label: {
                            Text(action.title)
                        }
                    }
                    Button {
                        requestRerun(.allConsensusStrategies)
                    } label: {
                        Label(
                            "Run all 3 consensus strategies…",
                            systemImage: "square.stack.3d.up"
                        )
                    }
                    Divider()
                    Button {
                        requestRerun(.allCandidates)
                    } label: {
                        Label("Re-run all candidate models…", systemImage: "arrow.triangle.2.circlepath")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(selectedRecordingID == nil)
                .help("All rerun options")
                if nightly.queuedRerunRecordingID == selectedRecordingID {
                    Label(
                        "\(nightly.queuedRerunDescription ?? "Rerun") taking priority",
                        systemImage: "arrow.up.circle.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                }
                if !artifactIsCurrent(artifact) {
                    Label("Consensus rebuild required", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let completedAt = artifact.completedAt {
                    Label(
                        completedAt.formatted(date: .abbreviated, time: .shortened),
                        systemImage: "checkmark.seal.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)
                } else {
                    Label("Updates live", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                ForEach(Stage.allCases) { stage in
                    Button {
                        selectedStage = stage
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: stage.icon)
                            Text(stage.shortTitle)
                            Image(
                                systemName: stageStatusIcon(stage, artifact: artifact)
                            )
                            .foregroundStyle(
                                stageIsComplete(stage, artifact: artifact)
                                    ? Color.green
                                    : candidate(stage, in: artifact) == nil
                                        ? Color.secondary
                                        : Color.orange
                            )
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedStage == stage ? stage.color : .secondary)
                }
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func candidateContent(_ artifact: NightlyQualityArtifact) -> some View {
        VStack(spacing: 0) {
            if selectedStage == .fused {
                consensusStrategyBar(artifact)
                Divider()
            }
            if let candidate = candidate(selectedStage, in: artifact) {
                candidateSummary(candidate, artifact: artifact)
                if selectedStage == .fused,
                   !selectedConsensusTraces.isEmpty {
                    Divider()
                    HStack {
                        Button {
                            modelIOPresentation = ModelIOPresentation(traceID: nil)
                        } label: {
                            Label(
                                "Inspect model conversation (\(selectedConsensusTraces.count))",
                                systemImage: "text.magnifyingglass"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        Spacer()
                        Text("Stored locally with this private evaluation artifact")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                }
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(candidate.segments.enumerated()), id: \.offset) {
                            index, segment in
                            let trace = selectedStage == .fused
                                ? traceForSegment(at: index)
                                : nil
                            segmentCard(segment, trace: trace)
                                .contentShape(RoundedRectangle(cornerRadius: 10))
                                .onTapGesture {
                                    guard let trace else { return }
                                    modelIOPresentation = ModelIOPresentation(
                                        traceID: trace.id
                                    )
                                }
                                .help(
                                    trace == nil
                                        ? ""
                                        : "Show the exact model input, response, evidence scores, "
                                            + "and fallback decision for this utterance"
                                )
                                .accessibilityAddTraits(
                                    trace == nil ? [] : .isButton
                                )
                                .accessibilityAction {
                                    guard let trace else { return }
                                    modelIOPresentation = ModelIOPresentation(
                                        traceID: trace.id
                                    )
                                }
                        }
                    }
                    .padding(20)
                }
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        ContentUnavailableView {
                            Label(
                                "\(selectedStage.title) has not run yet",
                                systemImage: selectedStage.icon
                            )
                        } description: {
                            VStack(spacing: 6) {
                                if let item = selectedItem {
                                    Text(stageWorkStateTitle(item, stage: selectedStage))
                                        .fontWeight(.semibold)
                                        .foregroundStyle(
                                            item.state == .active
                                                && activeComparisonStage(for: item) == selectedStage
                                                ? Color.green
                                                : Color.orange
                                        )
                                    Text("Next step: \(nextStepTitle(item))")
                                    Text(waitReason(item, stage: selectedStage))
                                        .foregroundStyle(.secondary)
                                    if let lastError = item.lastError {
                                        Text(lastError)
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                        if let item = selectedItem,
                           item.state == .pending {
                            Button {
                                nightly.runComparisonNow(recordingID: item.id)
                            } label: {
                                Label("Run this call now", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .disabled(
                                nightly.activeItem != nil
                                    || nightly.manualRunRecordingID != nil
                            )
                        }
                        if let item = selectedItem,
                           item.state == .active,
                           activeComparisonStage(for: item) == selectedStage {
                            pipelineProgressCard(item)
                        }
                        if let diagnostics = memoryDiagnostics {
                            memoryPressureCard(diagnostics, item: selectedItem)
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private func consensusStrategyBar(_ artifact: NightlyQualityArtifact) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Text repair freedom")
                        .font(.headline)
                    Text(selectedConsensusStrategy.shortDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    requestRerun(.consensus)
                } label: {
                    Label("Run selected", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                Button {
                    requestRerun(.allConsensusStrategies)
                } label: {
                    Label("Run all 3", systemImage: "square.stack.3d.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            Picker("Repair strategy", selection: $selectedConsensusStrategy) {
                ForEach(ConsensusRepairStrategy.allCases) { strategy in
                    Text(strategy.displayName).tag(strategy)
                }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 14) {
                ForEach(ConsensusRepairStrategy.allCases) { strategy in
                    let variant = consensusVariant(strategy, in: artifact)
                    Label(
                        variant?.completedAt == nil
                            ? (variant == nil ? "Not run" : "Running")
                            : "Ready",
                        systemImage: variant?.completedAt == nil
                            ? (variant == nil ? "clock" : "arrow.triangle.2.circlepath")
                            : "checkmark.circle.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(
                        variant?.completedAt != nil
                            ? Color.green
                            : variant == nil ? Color.secondary : Color.orange
                    )
                    if strategy != ConsensusRepairStrategy.allCases.last {
                        Spacer()
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.green.opacity(0.04))
    }

    private func pipelineProgressCard(_ item: NightlyQualityItem) -> some View {
        let telemetry = item.telemetry
        let totalTurns = max(1, telemetry.totalWindows)
        let completedTurns = min(totalTurns, max(0, telemetry.completedWindows))
        let fraction = Double(completedTurns) / Double(totalTurns)
        let phase: String
        if let livePhase = telemetry.currentPhase {
            if let current = telemetry.currentClip, let total = telemetry.totalClips {
                phase = "\(livePhase) · utterance \(current)/\(total)"
            } else {
                phase = livePhase
            }
        } else if item.stage != .gemmaFinalization {
            phase = item.stage.displayName
        } else if telemetry.currentRAMBytes == nil, completedTurns == 0 {
            phase = "Loading Gemma audio model and projector"
        } else if completedTurns >= totalTurns {
            phase = "Finalizing comparison"
        } else {
            phase = "Repairing text inside locked VibeVoice turns"
        }
        let elapsed = nightly.manifest?.activeStartedAt.map {
            max(0, Date().timeIntervalSince($0))
        }
        let remaining: TimeInterval? = {
            guard let elapsed, completedTurns > 0, completedTurns < totalTurns else { return nil }
            return elapsed / Double(completedTurns) * Double(totalTurns - completedTurns)
        }()

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Transcription progress", systemImage: "waveform.badge.mic")
                    .font(.headline)
                Spacer()
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.title3.monospacedDigit().weight(.bold))
                    .foregroundStyle(selectedStage.color)
            }
            Text(phase)
                .font(.callout.weight(.semibold))
            ProgressView(value: fraction)
                .tint(selectedStage.color)
            HStack {
                Text(
                    "\(completedTurns) / \(totalTurns) "
                        + (selectedStage == .fused
                            ? "utterance repairs"
                            : "work units")
                )
                Spacer()
                if let elapsed {
                    Text("Elapsed \(formatDuration(elapsed))")
                }
                if let remaining {
                    Text("ETA \(formatDuration(remaining))")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            if telemetry.currentInputTokens > 0 {
                Divider()
                HStack {
                    Text("Current input size")
                    Spacer()
                    Text(
                        "\(telemetry.currentInputTokens.formatted()) / "
                            + telemetry.maximumInputTokens.formatted()
                            + " tokens"
                    )
                    .monospacedDigit()
                }
                .font(.caption)
                ProgressView(value: telemetry.tokenReadiness)
                    .tint(telemetry.tokenReadiness > 0.9 ? .orange : .blue)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selectedStage.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func memoryPressureCard(
        _ diagnostics: MemoryDiagnosticsSnapshot,
        item: NightlyQualityItem?
    ) -> some View {
        let modelIsRunning = item?.state == .active
            && item?.stage == .gemmaFinalization
            && item?.telemetry.currentRAMBytes != nil
        let profile: TranscriptionResourceProfile
        if selectedStage == .fused {
            profile = .gemmaAudio(
                nightly.manifest?.gemmaModelKey
                    ?? nightly.configuration.gemmaAudioModelKey
            )
        } else if selectedStage == .whisper {
            let identifier = nightly.manifest?.whisperVariantIdentifier
                ?? GlobalModelSettings.shared.selectedWhisperVariant?.toIdentifier()
            profile = .forSelection(
                TranscriptionEngineSelection(
                    backend: .whisper,
                    whisperVariantIdentifier: identifier,
                    llmEngine: nil,
                    llmModelKey: nil,
                    vibeVoiceQuantization: nil,
                    vibeVoiceSpeakerMode: nil,
                    vibeVoiceModelRevision: nil,
                    vibeVoiceRuntimeRevision: nil,
                    vibeVoiceContext: nil
                )
            )
        } else {
            profile = .vibeVoice(.fourBit)
        }
        let requirements = diagnostics.system.map {
            TranscriptionMemoryAdmission.requirements(snapshot: $0, profile: profile)
        }
        let largest = max(
            1,
            diagnostics.consumers.first?.physicalFootprintBytes ?? 1
        )

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("What is using memory right now", systemImage: "chart.bar.fill")
                    .font(.headline)
                Spacer()
                Text(diagnostics.capturedAt.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let system = diagnostics.system, let requirements {
                VStack(alignment: .leading, spacing: 5) {
                    if modelIsRunning, let telemetry = item?.telemetry {
                        HStack {
                            Text("Gemma memory while running")
                                .font(.callout.weight(.semibold))
                            Spacer()
                            Text(
                                "\(formatBytes(telemetry.currentRAMBytes)) / "
                                    + formatBytes(telemetry.estimatedModelPeakBytes)
                            )
                            .font(.callout.monospacedDigit().weight(.bold))
                        }
                        ProgressView(
                            value: min(
                                1,
                                Double(telemetry.currentRAMBytes ?? 0)
                                    / Double(max(1, telemetry.estimatedModelPeakBytes ?? 1))
                            )
                        )
                        .tint(.blue)
                        Text(
                            "The launch check has passed. "
                                + "\(formatBytes(system.availableBytes)) remains available now."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text("Safe launch headroom")
                                .font(.callout.weight(.semibold))
                            Spacer()
                            Text(
                                "\(formatBytes(system.availableBytes)) / "
                                    + formatBytes(requirements.requiredHeadroomBytes)
                            )
                            .font(.callout.monospacedDigit().weight(.bold))
                        }
                        ProgressView(
                            value: min(
                                1,
                                Double(system.availableBytes)
                                    / Double(max(1, requirements.requiredHeadroomBytes))
                            )
                        )
                        .tint(
                            requirements.headroomShortfall(for: system) == 0 ? .green : .orange
                        )
                        if requirements.headroomShortfall(for: system) > 0 {
                            Text(
                                "Release "
                                    + formatBytes(requirements.headroomShortfall(for: system))
                                    + " more physical-memory headroom to start."
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                    }
                    HStack(spacing: 18) {
                        Text(
                            "Compressed \(formatBytes(system.compressorBytes))"
                                + limitSuffix(requirements.compressorLimitBytes)
                        )
                        Text(
                            "Swap \(formatBytes(system.swapUsedBytes))"
                                + limitSuffix(requirements.swapLimitBytes)
                        )
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                Divider()
            }

            ForEach(diagnostics.consumers.prefix(6)) { consumer in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(consumer.applicationName)
                            .font(.callout.weight(.semibold))
                        if consumer.processCount > 1 {
                            Text("\(consumer.processCount) processes")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formatBytes(consumer.physicalFootprintBytes))
                            .font(.callout.monospacedDigit().weight(.semibold))
                    }
                    ProgressView(
                        value: Double(consumer.physicalFootprintBytes) / Double(largest)
                    )
                    .tint(consumer.applicationName == "AlmRecorder" ? .blue : .orange)
                }
            }

            Text(
                "Per-app values are physical footprint. Compressed memory and swap are "
                    + "system-wide and cannot be attributed exactly to the app that created them."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func candidateSummary(
        _ candidate: NightlyQualityCandidate,
        artifact: NightlyQualityArtifact
    ) -> some View {
        let metricKey = selectedStage == .fused
            ? "consensus_\(selectedConsensusStrategy.rawValue)"
            : selectedStage.metricKey
        let metric = artifact.benchmarkReport?.metrics.first {
            $0.candidate == metricKey
        } ?? artifact.benchmarkReport?.metrics.first {
            selectedStage == .fused && $0.candidate == selectedStage.metricKey
        }
        let fallbackCount = candidate.segments.filter {
            $0.source == "llm_invalid_fallback_vibevoice"
                || $0.source == "llm_unsafe_repair_fallback_vibevoice"
                || $0.source == "llm_low_ngram_fallback_vibevoice"
        }.count
        return HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Label(selectedStage.title, systemImage: selectedStage.icon)
                    .font(.headline)
                    .foregroundStyle(selectedStage.color)
                Text(candidate.model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if !stageIsComplete(selectedStage, artifact: artifact),
                   selectedStage == .fused {
                    Label(
                        "Live partial result · "
                            + "\(artifact.gemmaCompletedTurns ?? 0)/"
                            + "\(artifact.gemmaTotalTurns ?? 0) model turns",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                }
                if selectedStage == .fused, fallbackCount > 0 {
                    Label(
                        "\(fallbackCount) turns used safe VibeVoice fallback",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                }
            }
            Divider().frame(height: 38)
            summaryMetric("Lines", candidate.segments.count.formatted())
            summaryMetric("WER", formatRate(metric?.wordErrorRate))
            summaryMetric("CER", formatRate(metric?.characterErrorRate))
            summaryMetric("Boundary F1", formatRate(metric?.boundaryF1))
            Spacer()
            if let provenance = candidate.provenance {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(provenance.engineIdentifier)
                        .font(.caption.weight(.semibold))
                    Text("Provenance: \(provenance.certainty.rawValue)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(selectedStage.color.opacity(0.06))
    }

    private func segmentCard(
        _ segment: NightlyQualityCandidateSegment,
        trace: NightlyQualityLLMTrace?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(formatTime(segment.startTime))–\(formatTime(segment.endTime))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let speaker = segment.speakerLabel ?? segment.speakerUUID {
                    Label(speaker, systemImage: "person.wave.2")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(selectedStage.color)
                }
                if segment.userProtected {
                    Label("Gold", systemImage: "checkmark.shield")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                }
                if selectedStage == .fused, let source = segment.source {
                    Text(source.replacingOccurrences(of: "_", with: " "))
                        .font(.caption2)
                        .foregroundStyle(
                            source.contains("fallback") ? .orange : .secondary
                        )
                }
                Spacer()
                if let alignment = segment.alignmentMethod {
                    Text(alignment.replacingOccurrences(of: "_", with: " "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if trace != nil {
                    Label("View model call", systemImage: "chevron.right")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(selectedStage.color)
                }
            }

            if selectedStage == .foreground,
               let original = segment.originalASRText,
               original != segment.text {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ORIGINAL ASR")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(original)
                        .foregroundStyle(.secondary)
                    Text("GOLD CORRECTION")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.green)
                        .padding(.top, 3)
                    Text(segment.text)
                }
            } else {
                Text(segment.text)
            }
        }
        .textSelection(.enabled)
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            trace == nil
                ? AnyShapeStyle(.quaternary.opacity(0.35))
                : AnyShapeStyle(selectedStage.color.opacity(0.07)),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            if trace != nil {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selectedStage.color.opacity(0.22), lineWidth: 1)
            }
        }
    }

    private func summaryMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
        }
    }

    private var selectedItem: NightlyQualityItem? {
        guard let selectedRecordingID else { return nil }
        return nightly.manifest?.items.first { $0.id == selectedRecordingID }
    }

    private var firstAvailableStage: Stage {
        guard let artifact else { return .foreground }
        return Stage.allCases.last { candidate($0, in: artifact) != nil } ?? .foreground
    }

    private func candidate(
        _ stage: Stage,
        in artifact: NightlyQualityArtifact
    ) -> NightlyQualityCandidate? {
        switch stage {
        case .foreground: return artifact.whisper
        case .whisper: return artifact.whisperCandidate
        case .vibeVoice: return artifact.vibeVoice
        case .fused:
            guard artifactIsCurrent(artifact) else { return nil }
            if let variants = artifact.consensusVariants, !variants.isEmpty {
                return variants.first {
                    $0.strategy == selectedConsensusStrategy
                }?.candidate
            }
            return artifact.fused
        }
    }

    private func consensusVariant(
        _ strategy: ConsensusRepairStrategy,
        in artifact: NightlyQualityArtifact
    ) -> NightlyQualityConsensusVariant? {
        artifact.consensusVariants?.first { $0.strategy == strategy }
    }

    private var selectedConsensusTraces: [NightlyQualityLLMTrace] {
        guard let artifact else { return [] }
        return consensusVariant(selectedConsensusStrategy, in: artifact)?.traces
            ?? artifact.gemmaTextTraces
            ?? []
    }

    private func traceForSegment(at index: Int) -> NightlyQualityLLMTrace? {
        selectedConsensusTraces.last {
            $0.targetIDs.contains(index)
        } ?? selectedConsensusTraces.last {
            $0.batchIndex == index + 1
        }
    }

    private func stageCount(for recordingID: Int64) -> String {
        guard let artifact = artifactStore.load(recordingID: recordingID) else {
            return "0/\(Stage.allCases.count)"
        }
        let count = Stage.allCases.filter { stageAvailable($0, in: artifact) }.count
        return "\(count)/\(Stage.allCases.count)"
    }

    private func stageAvailable(
        _ stage: Stage,
        in artifact: NightlyQualityArtifact
    ) -> Bool {
        if stage == .fused {
            return artifactIsCurrent(artifact)
                && (artifact.fused != nil || !(artifact.consensusVariants ?? []).isEmpty)
        }
        return candidate(stage, in: artifact) != nil
    }

    private func itemStatus(_ item: NightlyQualityItem) -> String {
        if artifactNeedsRebuild(recordingID: item.id) {
            return "Rebuild required"
        }
        switch item.state {
        case .active:
            return "Processing · \(nextStepTitle(item))"
        case .pending:
            return "Queued · next \(nextStepTitle(item))"
        case .waitingForCleanup:
            return "Waiting for cleanup"
        case .completed:
            return "Complete"
        case .failed:
            return "Failed"
        case .skipped:
            return "Skipped"
        }
    }

    private func artifactNeedsRebuild(recordingID: Int64) -> Bool {
        guard let artifact = artifactStore.load(recordingID: recordingID) else { return false }
        return !artifactIsCurrent(artifact)
    }

    private func completionSummary(_ artifact: NightlyQualityArtifact) -> String {
        let count = Stage.allCases.filter { stageAvailable($0, in: artifact) }.count
        if !artifactIsCurrent(artifact) {
            return "\(count)/\(Stage.allCases.count) valid steps · evaluation artifact must be rebuilt"
        }
        if artifact.completedAt != nil, count == Stage.allCases.count {
            return "All \(count) inference steps complete · private benchmark ready"
        }
        guard let item = selectedItem else {
            return "\(count)/\(Stage.allCases.count) inference steps available"
        }
        return "\(count)/\(Stage.allCases.count) inference steps available · \(workStateTitle(item))"
    }

    private func workStateTitle(_ item: NightlyQualityItem) -> String {
        switch item.state {
        case .active:
            return "Processing now"
        case .pending:
            return nightly.manualRunRecordingID == item.id
                ? "Run-now request queued"
                : "Queued — not processing"
        case .waitingForCleanup:
            return "Model work complete — waiting for cleanup"
        case .completed:
            return "Complete"
        case .failed:
            return "Stopped after an error"
        case .skipped:
            return "Skipped"
        }
    }

    private func waitReason(_ item: NightlyQualityItem, stage: Stage) -> String {
        if item.state == .active, let active = activeComparisonStage(for: item) {
            if active != stage {
                return "\(stage.title) is waiting for \(active.title) to finish."
            }
            return "The model is running. Progress and ETA appear below."
        }
        if nightly.manualRunRecordingID == item.id {
            return nightly.statusText
        }
        if item.state == .pending {
            if let next = nightly.configuration.window.nextStart(after: Date()) {
                return "Waiting for the nightly window at "
                    + next.formatted(date: .omitted, time: .shortened)
                    + ", or choose Run this call now."
            }
            return "Waiting for the nightly window, or choose Run this call now."
        }
        return nightly.statusText
    }

    private func stageWorkStateTitle(
        _ item: NightlyQualityItem,
        stage: Stage
    ) -> String {
        if item.state == .active,
           let active = activeComparisonStage(for: item),
           active != stage {
            return "Waiting — \(active.title) is processing"
        }
        return workStateTitle(item)
    }

    private func activeComparisonStage(for item: NightlyQualityItem) -> Stage? {
        switch item.stage {
        case .whisper: return .whisper
        case .vibeVoice: return .vibeVoice
        case .gemmaFinalization: return .fused
        case .cleanup, .completed: return nil
        }
    }

    private func stageIsComplete(
        _ stage: Stage,
        artifact: NightlyQualityArtifact
    ) -> Bool {
        guard candidate(stage, in: artifact) != nil else { return false }
        switch stage {
        case .foreground, .whisper, .vibeVoice:
            return true
        case .fused:
            if let variant = consensusVariant(selectedConsensusStrategy, in: artifact) {
                return variant.completedAt != nil
            }
            guard let completed = artifact.gemmaCompletedTurns,
                  let total = artifact.gemmaTotalTurns,
                  total > 0 else {
                return artifact.completedAt != nil
            }
            return completed >= total
        }
    }

    private func stageStatusIcon(
        _ stage: Stage,
        artifact: NightlyQualityArtifact
    ) -> String {
        if stageIsComplete(stage, artifact: artifact) {
            return "checkmark.circle.fill"
        }
        if let item = selectedItem,
           item.state == .active,
           activeComparisonStage(for: item) == stage {
            return "arrow.triangle.2.circlepath"
        }
        return candidate(stage, in: artifact) == nil
            ? "clock"
            : "arrow.triangle.2.circlepath"
    }

    private func nextStepTitle(_ item: NightlyQualityItem) -> String {
        guard let artifact = artifactStore.load(recordingID: item.id) else {
            return "Foreground snapshot"
        }
        if artifact.whisperCandidate == nil {
            return "Whisper transcription"
        }
        if artifact.vibeVoice == nil {
            return "VibeVoice transcription"
        }
        if artifactIsCurrent(artifact), artifact.fused == nil {
            return "LLM text repair inside VibeVoice turns"
        }
        if item.stage == .cleanup || item.state == .waitingForCleanup {
            return "final cleanup"
        }
        return item.stage.displayName
    }

    private func artifactIsCurrent(_ artifact: NightlyQualityArtifact) -> Bool {
        artifact.schemaVersion == NightlyQualityArtifact.schemaVersion
    }

    private func reloadArtifact() {
        guard let selectedRecordingID else {
            artifact = nil
            return
        }
        let loaded = artifactStore.load(recordingID: selectedRecordingID)
        artifact = loaded
    }

    private func requestRerun(_ action: RerunAction) {
        pendingRerunAction = action
        showRerunConfirm = true
    }

    private func performPendingRerun() {
        guard let selectedRecordingID else { return }
        switch pendingRerunAction {
        case .foreground:
            selectedStage = .foreground
            nightly.retranscribeForegroundAndRerunComparison(
                recordingID: selectedRecordingID
            )
        case .whisper:
            selectedStage = .whisper
            nightly.rerunComparisonNow(
                recordingID: selectedRecordingID,
                scope: .whisper
            )
        case .vibeVoice:
            selectedStage = .vibeVoice
            nightly.rerunComparisonNow(
                recordingID: selectedRecordingID,
                scope: .vibeVoice
            )
        case .consensus:
            selectedStage = .fused
            nightly.rerunConsensusNow(
                recordingID: selectedRecordingID,
                strategies: [selectedConsensusStrategy]
            )
        case .allConsensusStrategies:
            selectedStage = .fused
            nightly.rerunConsensusNow(
                recordingID: selectedRecordingID,
                strategies: ConsensusRepairStrategy.allCases
            )
        case .allCandidates:
            selectedStage = .whisper
            nightly.rerunComparisonNow(
                recordingID: selectedRecordingID,
                scope: .allCandidates
            )
        }
    }

    private func formatRate(_ rate: Double?) -> String {
        rate.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "—"
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total >= 3_600 {
            return String(format: "%dh %02dm", total / 3_600, (total % 3_600) / 60)
        }
        if total >= 60 {
            return String(format: "%dm %02ds", total / 60, total % 60)
        }
        return "\(total)s"
    }

    private func formatBytes(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(
            fromByteCount: Int64(clamping: bytes),
            countStyle: .memory
        )
    }

    private func limitSuffix(_ limit: UInt64?) -> String {
        guard let limit else { return "" }
        return " / \(formatBytes(limit)) limit"
    }
}

private struct NightlyQualityModelIOView: View {
    @Environment(\.dismiss) private var dismiss
    let traces: [NightlyQualityLLMTrace]
    @State private var selectedTraceID: UUID?

    init(
        traces: [NightlyQualityLLMTrace],
        initialTraceID: UUID? = nil
    ) {
        self.traces = traces
        _selectedTraceID = State(
            initialValue: initialTraceID.flatMap { requestedID in
                traces.contains(where: { $0.id == requestedID })
                    ? requestedID
                    : nil
            } ?? traces.first?.id
        )
    }

    private var selectedTrace: NightlyQualityLLMTrace? {
        traces.first { $0.id == selectedTraceID } ?? traces.first
    }

    var body: some View {
        NavigationSplitView {
            List(traces) { trace in
                Button {
                    selectedTraceID = trace.id
                } label: {
                    let accepted = trace.evidenceAccepted ?? trace.parsedSuccessfully
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Utterance \(trace.batchIndex) · attempt \(trace.attempt)")
                                .font(.callout.weight(.semibold))
                            Spacer()
                            Image(
                                systemName: accepted
                                    ? "checkmark.circle.fill"
                                    : "xmark.octagon.fill"
                            )
                            .foregroundStyle(
                                accepted ? Color.green : Color.orange
                            )
                        }
                        Text(
                            "1 target + ±3 context turns · target ID "
                                + (trace.targetIDs.first.map(String.init) ?? "—")
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        if let clips = trace.audioClipRanges, !clips.isEmpty {
                            Label(
                                "\(clips.count) audio clip"
                                    + (clips.count == 1 ? "" : "s")
                                    + " attached",
                                systemImage: "waveform"
                            )
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Model calls")
            .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 380)
        } detail: {
            if let trace = selectedTrace {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Consensus repair conversation")
                                .font(.title2.weight(.bold))
                            Text(
                                "\(trace.strategy?.displayName ?? "Legacy consensus") · "
                                    + "utterance \(trace.batchIndex), attempt \(trace.attempt) · "
                                    + traceOutcome(trace)
                            )
                            .font(.callout)
                            .foregroundStyle(
                                (trace.evidenceAccepted ?? trace.parsedSuccessfully)
                                    ? Color.green
                                    : Color.orange
                            )
                        }
                        Spacer()
                        Button("Done") { dismiss() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(20)
                    Divider()
                    ScrollView {
                        if let target = trace.target {
                            structuredConversation(trace, target: target)
                                .padding(20)
                        } else {
                            VStack(alignment: .leading, spacing: 18) {
                                modelIOBlock(
                                    title: "PROMPT SENT TO GEMMA",
                                    text: trace.prompt
                                )
                                modelIOBlock(
                                    title: "CLEAN RESPONSE RECEIVED BY THE VALIDATOR",
                                    text: trace.response.isEmpty
                                        ? "(empty response)"
                                        : trace.response
                                )
                            }
                            .padding(20)
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "No model calls recorded",
                    systemImage: "text.magnifyingglass"
                )
            }
        }
        .frame(minWidth: 1_050, minHeight: 720)
    }

    private func structuredConversation(
        _ trace: NightlyQualityLLMTrace,
        target: NightlyQualityTraceTurn
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            chatBubble(
                role: "Repair instructions",
                icon: "slider.horizontal.3",
                text: trace.instructionSummary
                    ?? trace.strategy?.shortDescription
                    ?? "Repair transcript text while preserving locked structure.",
                color: .indigo,
                trailing: false
            )

            if let before = trace.contextBefore, !before.isEmpty {
                conversationSection("Context before", icon: "arrow.up") {
                    ForEach(before) { turn in
                        contextTurnBubble(turn)
                    }
                }
            }

            conversationSection("Target turn · structure locked", icon: "lock.fill") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(
                            "\(formatTime(target.startTime))–\(formatTime(target.endTime))",
                            systemImage: "clock"
                        )
                        if let speaker = target.speaker, !speaker.isEmpty {
                            Label(speaker, systemImage: "person.wave.2")
                        }
                        Spacer()
                        Label(
                            "speaker + timestamps immutable",
                            systemImage: "lock.shield.fill"
                        )
                        .foregroundStyle(.green)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                    HStack(alignment: .top, spacing: 12) {
                        evidenceBubble(
                            title: "VibeVoice",
                            subtitle: "owns speaker turns",
                            text: target.vibeVoice,
                            color: .purple
                        )
                        evidenceBubble(
                            title: "Whisper",
                            subtitle: target.whisperSelectable == false
                                ? "overlap · not selectable"
                                : "timestamp-projected evidence",
                            text: target.whisper ?? "(no overlapping Whisper text)",
                            color: target.whisperSelectable == false ? .orange : .cyan
                        )
                    }

                    if let raw = target.foregroundRaw,
                       raw != target.whisper,
                       !raw.isEmpty {
                        evidenceBubble(
                            title: "Foreground raw context",
                            subtitle: "context only",
                            text: raw,
                            color: .blue
                        )
                    }
                    if let clean = target.foregroundClean,
                       clean != target.foregroundRaw,
                       !clean.isEmpty {
                        evidenceBubble(
                            title: "Previous cleaned context",
                            subtitle: "context only · never copied blindly",
                            text: clean,
                            color: .teal
                        )
                    }
                }
                .padding(14)
                .background(
                    Color.green.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.green.opacity(0.25))
                )
            }

            if let clips = trace.audioClipRanges, !clips.isEmpty {
                conversationSection("Audio Gemma actually heard", icon: "waveform") {
                    HStack(spacing: 8) {
                        ForEach(clips) { clip in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(
                                    "\(formatTime(clip.startTime))–"
                                        + "\(formatTime(clip.endTime))"
                                )
                                .font(.caption.monospacedDigit().weight(.bold))
                                Text(
                                    clip.source.replacingOccurrences(
                                        of: "_",
                                        with: " "
                                    )
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            .padding(9)
                            .background(
                                Color.blue.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 9)
                            )
                        }
                        Spacer()
                    }
                }
            }

            if let after = trace.contextAfter, !after.isEmpty {
                conversationSection("Context after", icon: "arrow.down") {
                    ForEach(after) { turn in
                        contextTurnBubble(turn)
                    }
                }
            }

            Divider()
            chatBubble(
                role: "Gemma proposal · \(traceOutcome(trace))",
                icon: (trace.evidenceAccepted ?? trace.parsedSuccessfully)
                    ? "checkmark.circle.fill"
                    : "xmark.octagon.fill",
                text: trace.response.isEmpty ? "(empty response)" : trace.response,
                color: (trace.evidenceAccepted ?? trace.parsedSuccessfully) ? .green : .orange,
                trailing: true
            )
            if let trigram = trace.evidenceTrigramCoverage,
               let bigram = trace.evidenceBigramCoverage {
                HStack(spacing: 16) {
                    Label(
                        "Combined trigram coverage "
                            + trigram.formatted(.percent.precision(.fractionLength(0))),
                        systemImage: "character.cursor.ibeam"
                    )
                    Label(
                        "Combined bigram coverage "
                            + bigram.formatted(.percent.precision(.fractionLength(0))),
                        systemImage: "textformat.abc"
                    )
                    if let source = trace.resolutionSource {
                        Text(source.replacingOccurrences(of: "_", with: " "))
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(
                    (trace.evidenceAccepted ?? false) ? Color.green : Color.orange
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            DisclosureGroup("Raw prompt and response · developer view") {
                VStack(alignment: .leading, spacing: 16) {
                    modelIOBlock(title: "RAW PROMPT", text: trace.prompt)
                    modelIOBlock(
                        title: "RAW RESPONSE",
                        text: trace.response.isEmpty ? "(empty response)" : trace.response
                    )
                }
                .padding(.top, 12)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
    }

    private func contextTurnBubble(
        _ turn: NightlyQualityTraceTurn
    ) -> some View {
        let speaker = turn.speaker.flatMap { $0.isEmpty ? nil : $0 } ?? "Speaker"
        let preferredText = turn.previousConsensus
            ?? turn.foregroundClean
            ?? turn.foregroundRaw
            ?? turn.vibeVoice
        let source: String
        if turn.previousConsensus != nil {
            source = "previous repaired turn"
        } else if turn.foregroundClean != nil {
            source = "clean foreground context"
        } else if turn.foregroundRaw != nil {
            source = "raw foreground context"
        } else {
            source = "VibeVoice context"
        }
        return chatBubble(
            role: speaker
                + " · \(formatTime(turn.startTime))–\(formatTime(turn.endTime))"
                + " · \(source)",
            icon: "person.crop.circle",
            text: preferredText,
            color: .secondary,
            trailing: false
        )
    }

    private func conversationSection<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func chatBubble(
        role: String,
        icon: String,
        text: String,
        color: Color,
        trailing: Bool
    ) -> some View {
        HStack {
            if trailing {
                Spacer(minLength: 90)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label(role, systemImage: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(color)
                Text(text)
                    .textSelection(.enabled)
            }
            .padding(13)
            .frame(maxWidth: 760, alignment: .leading)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(color.opacity(0.18))
            )
            if !trailing {
                Spacer(minLength: 90)
            }
        }
    }

    private func evidenceBubble(
        title: String,
        subtitle: String,
        text: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(color)
                Spacer()
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }

    private func modelIOBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func traceOutcome(_ trace: NightlyQualityLLMTrace) -> String {
        if !trace.parsedSuccessfully {
            return "response could not be parsed"
        }
        if trace.evidenceAccepted == false {
            return "rejected by evidence guard · VibeVoice fallback"
        }
        if trace.evidenceAccepted == true {
            return trace.audioGrounded == true
                ? "accepted · grounded in attached audio"
                : "accepted by evidence guard"
        }
        return "parsed successfully · legacy trace"
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
