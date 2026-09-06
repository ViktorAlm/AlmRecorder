import SwiftUI

struct NightlyRetranscriptionSettingsView: View {
    @ObservedObject private var nightly = NightlyQualityController.shared
    @StateObject private var gemmaModels = GemmaModelManager()
    @State private var showRebuildConfirmation = false
    @State private var showQualityComparison = false

    var body: some View {
        Section("Nightly Transcript Quality") {
            Toggle(
                "Run maximum-quality refinement overnight",
                isOn: Binding(
                    get: { nightly.configuration.enabled },
                    set: { nightly.setEnabled($0) }
                )
            )

            Text(
                "Fused 4-bit VibeVoice creates the immediate transcript and local voice evidence. "
                    + "Nightly refinement reuses those exact committed speaker turns, runs current "
                    + "Whisper independently, then asks Gemma to listen to matching sub-30-second "
                    + "audio clips and repair each locked turn from the audio, both ASR readings, "
                    + "and surrounding context. Older non-VibeVoice recordings receive a fresh "
                    + "VibeVoice compatibility candidate first. Gemma cannot change speakers, "
                    + "timestamps, or turn boundaries."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            pipelineStrip

            Picker(
                "Calls to process",
                selection: Binding(
                    get: { nightly.configuration.scope },
                    set: { nightly.setScope($0) }
                )
            ) {
                ForEach(NightlyQualityScope.allCases) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            .disabled(nightly.activeItem != nil)

            if nightly.configuration.scope == .evaluationCohort {
                HStack {
                    Button {
                        nightly.addMostRecentRecordingsToEvaluation(count: 5)
                    } label: {
                        Label("Add newest 5 calls", systemImage: "plus.rectangle.on.rectangle")
                    }
                    .disabled(nightly.activeItem != nil)

                    Text(
                        "\(nightly.configuration.additionalEvaluationRecordingIDs.count) "
                            + "explicit evaluation calls"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text(
                    "Explicit evaluation calls are private benchmark inputs only. Adding one does "
                        + "not mark its transcript or speaker assignments as reviewed gold."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Picker(
                "Result handling",
                selection: Binding(
                    get: { nightly.configuration.commitPolicy },
                    set: { nightly.setCommitPolicy($0) }
                )
            ) {
                ForEach(NightlyQualityCommitPolicy.allCases) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            .disabled(nightly.activeItem != nil)

            if nightly.configuration.commitPolicy == .shadow {
                Label(
                    "Shadow mode stores private candidates and measurements but does not run "
                        + "mutating cleanup or change the visible transcript.",
                    systemImage: "eye.slash"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Label(
                    "Only high-confidence one-to-one text corrections are automatic. Structural "
                        + "splits and merges remain private until alignment and speaker reprocessing.",
                    systemImage: "checkmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                GridRow {
                    Text("Start")
                    DatePicker(
                        "",
                        selection: timeBinding(start: true),
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    Text("Stop starting")
                    DatePicker(
                        "",
                        selection: timeBinding(start: false),
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                }
                GridRow {
                    Text("Eligible calls")
                    Text(nightly.eligibleRecordingCount.formatted())
                        .monospacedDigit()
                    Text("Audio")
                    Text(formatDuration(nightly.eligibleAudioSeconds))
                        .monospacedDigit()
                }
                GridRow {
                    Text("Compute remaining")
                    Text(formatDuration(nightly.estimatedRemainingSeconds))
                        .monospacedDigit()
                    Text("Projected nights")
                    Text("~\(nightly.estimatedNightsRemaining)")
                        .monospacedDigit()
                }
            }
            .font(.callout)

            Picker(
                "Gemma audio consensus model",
                selection: Binding(
                    get: { nightly.configuration.gemmaAudioModelKey },
                    set: { nightly.setGemmaAudioModel($0) }
                )
            ) {
                Text("Gemma 4 12B Q5 · Maximum quality").tag("12B-Q5_K_M")
                Text("Gemma 4 12B Q4 · Lower 12B memory").tag("12B-Q4_K_M")
                Text("Gemma 4 E4B Q4 · Safe fallback").tag("E4B-Q4_K_M")
            }
            .disabled(nightly.activeItem != nil)

            let selectedAudioModel = nightly.configuration.gemmaAudioModelKey
            let selectedAudioReady = gemmaModels.isAudioModelDownloaded(
                selectedAudioModel
            )
            Label(
                selectedAudioReady
                    ? "\(selectedAudioModel) and its audio projector are installed"
                    : "Download \(selectedAudioModel) and its audio projector in Models",
                systemImage: selectedAudioReady
                    ? "checkmark.circle.fill"
                    : "arrow.down.circle"
            )
            .font(.caption)
            .foregroundStyle(selectedAudioReady ? .green : .orange)

            if selectedAudioModel.hasPrefix("12B-") {
                Text(
                    "12B is the maximum-quality pass. On this 24 GB Mac it starts only when the "
                        + "proven model-plus-2 GB admission profile and live memory checks pass; "
                        + "otherwise it remains pending. E4B is available when Docker or other "
                        + "apps need the memory."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Picker(
                "Maximum LLM input per turn batch",
                selection: Binding(
                    get: { nightly.configuration.maximumInputTokens },
                    set: { nightly.setMaximumInputTokens($0) }
                )
            ) {
                Text("8,192 estimated tokens").tag(8_192)
                Text("12,000 estimated tokens · Recommended").tag(12_000)
                Text("14,000 estimated tokens").tag(14_000)
            }
            .disabled(nightly.activeItem != nil)

            Text(
                "The token count includes locked VibeVoice turns, timestamp-projected Whisper "
                    + "alternatives, committed foreground context, and adjacent speaker context. "
                    + "The displayed token estimate covers text context; attached audio ranges "
                    + "are tracked separately. "
                    + "Long calls are split into bounded text batches; cumulative input is retained "
                    + "in the private run artifact."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Toggle(
                "Protect confirmed speaker-gold recordings (\(nightly.excludedGoldCount))",
                isOn: Binding(
                    get: { nightly.configuration.excludeSpeakerGold },
                    set: { nightly.setExcludeSpeakerGold($0) }
                )
            )
            .disabled(nightly.activeItem != nil)

            Toggle(
                "Keep this Mac awake while a model is running",
                isOn: Binding(
                    get: { nightly.configuration.preventIdleSleepWhileProcessing },
                    set: { nightly.setPreventIdleSleep($0) }
                )
            )

            runProgress
            benchmarkResults

            HStack {
                Button {
                    nightly.runNextComparisonNow()
                } label: {
                    Label(
                        nightly.manualRunRecordingID == nil
                            ? "Run next comparison now"
                            : "Run-now comparison queued",
                        systemImage: nightly.manualRunRecordingID == nil
                            ? "play.fill"
                            : "hourglass"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(nightly.manualRunRecordingID != nil || nightly.activeItem != nil)
                Button {
                    showQualityComparison = true
                } label: {
                    Label("Compare quality steps…", systemImage: "rectangle.split.2x2")
                }
                .buttonStyle(.borderedProminent)
                Button("Refresh library") {
                    nightly.refreshLibrarySummary()
                }
                Button("Rebuild pending plan…") {
                    showRebuildConfirmation = true
                }
                .disabled(nightly.activeItem != nil)
                Spacer()
                if nightly.missingAudioCount > 0 {
                    Label(
                        "\(nightly.missingAudioCount) library items skipped · audio unavailable",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(
                        "These are database entries whose stored audio path is empty or no longer "
                            + "exists on this Mac. They cannot be retranscribed, but they do not "
                            + "block calls whose audio is available."
                    )
                }
            }

            Label(
                "Large models are admitted only when the memory gate is safe. Current model RAM, "
                    + "peak model RAM, available system RAM, and Gemma input length are shown below. "
                    + "Foreground work preempts this pipeline before another model loads.",
                systemImage: "memorychip"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Label(
                "AlmRecorder must be running during the window. It can prevent idle sleep while "
                    + "processing, but it cannot wake a sleeping Mac or work with the lid closed.",
                systemImage: "moon.zzz"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { nightly.refreshLibrarySummary() }
        .sheet(isPresented: $showQualityComparison) {
            NightlyQualityComparisonView()
        }
        .alert("Rebuild the pending quality plan?", isPresented: $showRebuildConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Rebuild") {
                nightly.rebuildPlan()
            }
        } message: {
            Text(
                "Completed audio fingerprints remain complete. Interrupted and newly added "
                    + "recordings are rescanned using the current nightly models and token limit."
            )
        }
    }

    private var pipelineStrip: some View {
        HStack(spacing: 6) {
            stagePill("Foreground", icon: "waveform", color: .blue)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            stagePill("Whisper", icon: "waveform.badge.mic", color: .cyan)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            stagePill("VibeVoice", icon: "text.bubble", color: .purple)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            stagePill("LLM text repair", icon: "sparkles", color: .indigo)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            stagePill(
                nightly.configuration.commitPolicy == .shadow ? "Benchmark" : "Safe apply",
                icon: nightly.configuration.commitPolicy == .shadow
                    ? "chart.bar.xaxis"
                    : "checkmark.seal",
                color: .green
            )
            Spacer()
            Text("Per call")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var benchmarkResults: some View {
        let metrics = nightly.benchmarkMetrics
        if !metrics.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Private gold results", systemImage: "chart.bar.doc.horizontal")
                    .font(.callout.weight(.semibold))
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                    GridRow {
                        Text("Candidate")
                        Text("WER")
                        Text("CER")
                        Text("Boundary F1")
                        Text("Gold lines")
                        Text("Calls")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    ForEach(metrics) { metric in
                        GridRow {
                            Text(candidateName(metric.candidate))
                            Text(formatRate(metric.wordErrorRate))
                                .monospacedDigit()
                            Text(formatRate(metric.characterErrorRate))
                                .monospacedDigit()
                            Text(formatRate(metric.boundaryF1))
                                .monospacedDigit()
                            Text(metric.referenceSegmentCount.formatted())
                                .monospacedDigit()
                            Text(metric.recordingCount.formatted())
                                .monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
                Text(
                    "Gold text comes only from user-kept or user-corrected utterances. Results "
                        + "remain on this Mac with the private candidate artifacts."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                if nightly.structuralProposalCount > 0 {
                    Label(
                        "\(nightly.structuralProposalCount) call(s) have proposed splits, merges, "
                            + "or additions awaiting acoustic alignment and speaker reprocessing.",
                        systemImage: "point.3.connected.trianglepath.dotted"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func stagePill(
        _ title: String,
        icon: String,
        color: Color
    ) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private var runProgress: some View {
        if let manifest = nightly.manifest {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(nightly.statusText)
                            .font(.callout.weight(.semibold))
                        Text(nightly.pipelineSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(
                        "\(manifest.completedCount.formatted())/"
                            + manifest.items.count.formatted()
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                ProgressView(value: nightly.progress)

                HStack(spacing: 14) {
                    Label(
                        "\(manifest.completedCount.formatted()) complete",
                        systemImage: "checkmark.circle"
                    )
                    if manifest.failedCount > 0 {
                        Label(
                            "\(manifest.failedCount.formatted()) failed",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                    }
                    if let item = nightly.activeItem {
                        Label(
                            "\(item.stage.displayName) · \(item.title)",
                            systemImage: "waveform"
                        )
                        .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let item = nightly.activeItem {
                    resourceTelemetry(item)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func resourceTelemetry(_ item: NightlyQualityItem) -> some View {
        let telemetry = item.telemetry
        let currentTokens = telemetry.currentInputTokens
        let maximumTokens = max(
            1,
            telemetry.maximumInputTokens == 12_000
                ? nightly.configuration.maximumInputTokens
                : telemetry.maximumInputTokens
        )
        let tokenFraction = min(
            1,
            Double(currentTokens) / Double(maximumTokens)
        )
        let ramTarget = telemetry.estimatedModelPeakBytes ?? 0
        let ramFraction = ramTarget > 0
            ? min(1, Double(telemetry.currentRAMBytes ?? 0) / Double(ramTarget))
            : 0

        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("Estimated Gemma input", systemImage: "text.line.first.and.arrowtriangle.forward")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(Int(tokenFraction * 100).formatted())%")
                        .font(.caption.monospacedDigit().weight(.bold))
                    Text("\(formatTokens(currentTokens)) / \(formatTokens(maximumTokens))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: tokenFraction)
                    .tint(tokenFraction > 0.9 ? .orange : .indigo)
                HStack {
                    Text(
                        "\(telemetry.completedWindows.formatted())/"
                            + "\(telemetry.totalWindows.formatted()) "
                            + (item.stage == .gemmaFinalization
                                ? "utterance repairs"
                                : "audio windows")
                    )
                    Spacer()
                    Text("\(formatTokens(telemetry.cumulativeInputTokens)) estimated cumulative")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("Model RAM", systemImage: "memorychip")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if ramTarget > 0 {
                        Text("\(Int(ramFraction * 100).formatted())% of estimated peak")
                            .font(.caption.monospacedDigit().weight(.bold))
                    }
                }
                ProgressView(value: ramFraction)
                    .tint(ramFraction > 0.9 ? .orange : .blue)
                HStack(spacing: 16) {
                    metric(
                        "Current",
                        bytes: telemetry.currentRAMBytes
                    )
                    metric(
                        "Peak",
                        bytes: telemetry.peakRAMBytes
                    )
                    metric(
                        "Estimated",
                        bytes: telemetry.estimatedModelPeakBytes
                    )
                    metric(
                        "System available",
                        bytes: telemetry.systemAvailableBytes
                    )
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private func metric(_ title: String, bytes: UInt64?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(formatBytes(bytes))
                .font(.caption.monospacedDigit().weight(.semibold))
        }
    }

    private func timeBinding(start: Bool) -> Binding<Date> {
        Binding(
            get: {
                let minute = start
                    ? nightly.configuration.window.startMinute
                    : nightly.configuration.window.endMinute
                return Calendar.current.date(
                    bySettingHour: minute / 60,
                    minute: minute % 60,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                if start {
                    nightly.setWindow(startMinute: minute)
                } else {
                    nightly.setWindow(endMinute: minute)
                }
            }
        )
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400
            ? [.day, .hour]
            : seconds >= 3_600
                ? [.hour, .minute]
                : [.minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(0, seconds)) ?? "0 min"
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000 {
            return String(format: "%.1fk", Double(tokens) / 1_000)
        }
        return tokens.formatted()
    }

    private func formatBytes(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(
            fromByteCount: Int64(clamping: bytes),
            countStyle: .memory
        )
    }

    private func formatRate(_ rate: Double?) -> String {
        rate.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "—"
    }

    private func candidateName(_ raw: String) -> String {
        switch raw {
        case "foreground_asr": return "Foreground ASR"
        case "whisper": return "Independent Whisper"
        case "vibevoice": return "VibeVoice"
        case "blind_gemma": return "Legacy blind Gemma"
        case "consensus": return "Speaker-preserving consensus"
        case "fused": return "Legacy Gemma fusion"
        default: return raw
        }
    }
}
