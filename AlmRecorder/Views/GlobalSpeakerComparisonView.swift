import SwiftUI

/// Private, inspectable comparison of the complete cross-recording speaker pipeline.
///
/// Like `NightlyQualityComparisonView`, this view renders saved artifacts instead of recomputing
/// pretend UI state. A benchmark run fills the local clusters, acoustic evidence, every global
/// reconciliation candidate, and the gold score in order.
struct GlobalSpeakerComparisonView: View {
    private enum Stage: String, CaseIterable, Identifiable {
        case localVoices
        case evidence
        case reconciliation
        case gold

        var id: String { rawValue }

        var shortTitle: String {
            switch self {
            case .localVoices: return "1 · Local voices"
            case .evidence: return "2 · Evidence"
            case .reconciliation: return "3 · Global matching"
            case .gold: return "4 · Gold score"
            }
        }

        var title: String {
            switch self {
            case .localVoices: return "Recording-local voices"
            case .evidence: return "Voice evidence"
            case .reconciliation: return "Cross-recording reconciliation"
            case .gold: return "Gold evaluation"
            }
        }

        var icon: String {
            switch self {
            case .localVoices: return "person.wave.2"
            case .evidence: return "waveform.badge.magnifyingglass"
            case .reconciliation: return "point.3.connected.trianglepath.dotted"
            case .gold: return "checkmark.seal"
            }
        }

        var color: Color {
            switch self {
            case .localVoices: return .blue
            case .evidence: return .purple
            case .reconciliation: return .cyan
            case .gold: return .green
            }
        }
    }

    private struct RecordingEntry: Identifiable {
        let key: String
        let recordingID: Int64?
        let title: String
        let decisions: [SpeakerIdentityBenchmarkDecision]
        let isGold: Bool
        let isLatest: Bool
        let createdAt: Date?

        var id: String { key }
    }

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SpeakerEvaluationSettingsModel()
    @ObservedObject private var pipelineSettings = SpeakerPipelineSettings.shared
    @State private var selectedRecordingKey: String?
    @State private var selectedRunName: String?
    @State private var selectedStage: Stage = .localVoices
    @State private var selectedCandidateID = "production-sequential"
    @State private var didSelectLatestRecording = false

    var body: some View {
        NavigationSplitView {
            recordingList
                .navigationTitle("Speaker runs")
        } detail: {
            comparisonDetail
                .navigationTitle(selectedRecording?.title ?? "Global speaker comparison")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .frame(minWidth: 1_100, minHeight: 740)
        .task {
            model.reload()
            selectDefaults()
        }
        .onChange(of: model.benchmark) {
            selectDefaults()
        }
        .onChange(of: selectedRunName) {
            selectedCandidateID = selectedReport?.globalIdentityCandidates?.first?.id
                ?? "production-sequential"
            if !recordings.contains(where: { $0.key == selectedRecordingKey }) {
                selectedRecordingKey = recordings.first?.key
            }
        }
        .onChange(of: latestRecordingIDs) {
            guard !didSelectLatestRecording, let latest = latestRecordings.first else { return }
            selectedRecordingKey = latest.key
            didSelectLatestRecording = true
        }
    }

    private var reports: [SpeakerPipelineBenchmarkReport] {
        model.benchmark?.reports ?? []
    }

    private var selectedReport: SpeakerPipelineBenchmarkReport? {
        if let selectedRunName,
           let match = reports.first(where: { $0.runName == selectedRunName }) {
            return match
        }
        return reports.first
    }

    private var candidates: [GlobalSpeakerIdentityCandidateReport] {
        selectedReport?.globalIdentityCandidates ?? []
    }

    private var selectedCandidate: GlobalSpeakerIdentityCandidateReport? {
        candidates.first(where: { $0.id == selectedCandidateID }) ?? candidates.first
    }

    private var recordings: [RecordingEntry] {
        let decisions = selectedReport?.identityDecisions ?? []
        var entries: [RecordingEntry] = Dictionary(grouping: decisions, by: \.recordingKey)
            .map { key, decisions in
                let recordingID = recordingID(from: key)
                let candidate = recordingID.flatMap { id in
                    model.snapshot?.candidates.first(where: { $0.id == id })
                }
                return RecordingEntry(
                    key: key,
                    recordingID: recordingID,
                    title: decisions.first?.recordingTitle ?? key,
                    decisions: decisions.sorted { $0.localLabel < $1.localLabel },
                    isGold: candidate?.isGoldReady
                        ?? decisions.contains { $0.referenceSpeakerKey != nil },
                    isLatest: recordingID.map(latestRecordingIDs.contains) ?? false,
                    createdAt: candidate?.recording.createdAt
                )
            }

        let savedKeys = Set(entries.map(\.key))
        for recording in latestCandidates {
            guard let recordingID = recording.id else { continue }
            let key = "recording:\(recordingID)"
            guard !savedKeys.contains(key) else { continue }
            let snapshotCandidate = model.snapshot?.candidates.first {
                $0.id == recordingID
            }
            entries.append(RecordingEntry(
                key: key,
                recordingID: recordingID,
                title: recording.title,
                decisions: [],
                isGold: snapshotCandidate?.isGoldReady
                    ?? (
                        recording.speakerReviewStatus
                            == RecordingSpeakerReviewStatus.gold.rawValue
                    ),
                isLatest: true,
                createdAt: recording.createdAt
            ))
        }
        return entries.sorted {
            if $0.createdAt != $1.createdAt {
                return ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
            }
            if $0.title != $1.title { return $0.title < $1.title }
            return $0.key < $1.key
        }
    }

    private var latestCandidates: [Recording] {
        model.recentRecordings
    }

    private var latestRecordingIDs: [Int64] {
        latestCandidates.compactMap(\.id)
    }

    private var latestRecordings: [RecordingEntry] {
        latestRecordingIDs.compactMap { id in
            recordings.first(where: { $0.recordingID == id })
        }
    }

    private var goldRecordings: [RecordingEntry] {
        recordings.filter { $0.isGold && !$0.isLatest }
    }

    private var otherSavedRecordings: [RecordingEntry] {
        recordings.filter { !$0.isGold && !$0.isLatest && !$0.decisions.isEmpty }
    }

    private var selectedRecording: RecordingEntry? {
        recordings.first(where: { $0.key == selectedRecordingKey }) ?? recordings.first
    }

    private var goldRevisionIsCurrent: Bool {
        guard let benchmark = model.benchmark,
              let revision = model.snapshot?.summary.goldRevision else { return true }
        return benchmark.goldRevision == revision
    }

    private var recordingList: some View {
        List(selection: $selectedRecordingKey) {
            if recordings.isEmpty {
                ContentUnavailableView(
                    "No speaker run",
                    systemImage: "person.wave.2",
                    description: Text("Run the current profile to create inspectable results.")
                )
            } else {
                if !latestRecordings.isEmpty {
                    Section("Latest 5 · unscored unless gold") {
                        ForEach(latestRecordings) { recording in
                            recordingRow(recording)
                        }
                    }
                }
                if !goldRecordings.isEmpty {
                    Section("Gold benchmark") {
                        ForEach(goldRecordings) { recording in
                            recordingRow(recording)
                        }
                    }
                }
                if !otherSavedRecordings.isEmpty {
                    Section("Other saved calls") {
                        ForEach(otherSavedRecordings) { recording in
                            recordingRow(recording)
                        }
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 245, ideal: 285, max: 350)
    }

    private func recordingRow(_ recording: RecordingEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(recording.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                if recording.isLatest {
                    statusBadge("LATEST", color: .blue)
                }
                if recording.isGold {
                    statusBadge("GOLD", color: .green)
                }
            }
            HStack(spacing: 5) {
                if recording.decisions.isEmpty {
                    Text("Not in saved run · run current profile")
                        .foregroundStyle(.orange)
                } else {
                    Text(
                        "\(recording.decisions.count) local voice"
                            + (recording.decisions.count == 1 ? "" : "s")
                    )
                    if let issue = issueSummary(for: recording) {
                        Text("·")
                        Text(issue)
                            .foregroundStyle(.orange)
                    } else if recording.decisions.contains(where: {
                        $0.referenceSpeakerKey != nil
                    }) {
                        Text("· gold mapped")
                            .foregroundStyle(.green)
                    } else {
                        Text("· unscored inspection")
                            .foregroundStyle(.blue)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .tag(Optional(recording.key))
    }

    @ViewBuilder
    private var comparisonDetail: some View {
        if let report = selectedReport {
            VStack(spacing: 0) {
                comparisonHeader(report)
                Divider()
                ScrollView {
                    stageContent(report)
                        .padding(24)
                }
            }
        } else if model.isEvaluating {
            progressUnavailable
        } else {
            ContentUnavailableView {
                Label("No global speaker benchmark yet", systemImage: "person.wave.2")
            } description: {
                Text(
                    "Confirm at least one conversation as Speaker gold, then run the current "
                        + "speaker profile. The audio and result stay on this Mac."
                )
            } actions: {
                Button("Run \(pipelineSettings.selectedProfile.displayName)") {
                    model.runActiveProfile()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func comparisonHeader(_ report: SpeakerPipelineBenchmarkReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedRecording?.title ?? "Global speaker identification")
                        .font(.title2.weight(.bold))
                    Text(
                        "\(report.profile.displayName) · "
                            + "\(model.snapshot?.summary.goldRecordingCount ?? report.processedRecordingCount) gold "
                            + "call\(model.snapshot?.summary.goldRecordingCount == 1 ? "" : "s") · "
                            + "\(latestRecordings.filter { !$0.decisions.isEmpty }.count)/"
                            + "\(latestRecordings.count) latest inspected · "
                            + "\(candidates.count) global methods"
                    )
                    .font(.callout)
                    .foregroundStyle(goldRevisionIsCurrent ? .green : .orange)
                }
                Spacer()
                Button {
                    model.runActiveProfile()
                } label: {
                    Label(
                        "Run \(pipelineSettings.selectedProfile.displayName)",
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(selectedStage.color)
                .disabled(model.isEvaluating)
                .help(
                    "Rebuild local diarization and all dependent global identity candidates "
                        + "against the current private gold set."
                )
                Menu {
                    Button("Run current profile") {
                        model.runActiveProfile()
                    }
                    Button("Compare all presets") {
                        model.compareProfiles()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.isEvaluating)
                if goldRevisionIsCurrent {
                    Label(
                        report.generatedAt.formatted(date: .abbreviated, time: .shortened),
                        systemImage: "checkmark.seal.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)
                } else {
                    Label("Gold set changed · rerun required", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }

            if reports.count > 1 {
                Picker("Pipeline profile", selection: selectedRunBinding) {
                    ForEach(reports, id: \.runName) {
                        Text($0.profile.displayName).tag(Optional($0.runName))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack(spacing: 8) {
                ForEach(Stage.allCases) { stage in
                    Button {
                        selectedStage = stage
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: stage.icon)
                            Text(stage.shortTitle)
                            Image(systemName: stageComplete(stage, report: report)
                                ? "checkmark.circle.fill"
                                : "clock")
                                .foregroundStyle(
                                    stageComplete(stage, report: report)
                                        ? Color.green
                                        : Color.secondary
                                )
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedStage == stage ? stage.color : .secondary)
                }
            }

            if model.isEvaluating {
                evaluationProgress
            }
        }
        .padding(22)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func stageContent(_ report: SpeakerPipelineBenchmarkReport) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            stageIntroduction
            switch selectedStage {
            case .localVoices:
                localVoiceStage
            case .evidence:
                evidenceStage
            case .reconciliation:
                reconciliationStage(report)
            case .gold:
                goldStage(report)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var stageIntroduction: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: selectedStage.icon)
                .font(.title2)
                .foregroundStyle(selectedStage.color)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedStage.title)
                    .font(.title3.weight(.bold))
                Text(stageExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var stageExplanation: String {
        switch selectedStage {
        case .localVoices:
            return "Over-splitting is allowed here. Each clean recording-local voice becomes one "
                + "candidate; overlapping or internally mixed clusters are quarantined."
        case .evidence:
            return "Shows the winner, runner-up, prototype support, ambiguity, cohesion, and the "
                + "exact evidence used before a voice is allowed to join a person."
        case .reconciliation:
            return "Runs the current matcher and conservative controls over the same immutable "
                + "local voices. Select a method to inspect its assignments for this call."
        case .gold:
            return "Scores cross-call identity independently of local segmentation. False merges "
                + "are the safety-critical error and cannot be traded away for recall."
        }
    }

    @ViewBuilder
    private var localVoiceStage: some View {
        if let recording = selectedRecording {
            if recording.decisions.isEmpty {
                latestNeedsRun(recording)
            } else {
                metricStrip([
                    ("Local voices", recording.decisions.count.formatted(), Color.blue),
                    (
                        "Eligible globally",
                        recording.decisions.filter(\.eligibleForGlobalIdentity).count.formatted(),
                        Color.green
                    ),
                    (
                        "Quarantined",
                        recording.decisions.filter { !$0.eligibleForGlobalIdentity }.count.formatted(),
                        Color.orange
                    ),
                    (
                        "Embedding turns",
                        recording.decisions.reduce(0) { $0 + $1.clusterEmbeddingTurnCount }.formatted(),
                        Color.purple
                    ),
                ])
                ForEach(recording.decisions, id: \.localLabel) { decision in
                    voiceCard(decision, showEvidence: false)
                }
            }
        } else {
            noRecording
        }
    }

    @ViewBuilder
    private var evidenceStage: some View {
        if let recording = selectedRecording {
            if recording.decisions.isEmpty {
                latestNeedsRun(recording)
            } else {
                ForEach(recording.decisions, id: \.localLabel) { decision in
                    voiceCard(decision, showEvidence: true)
                }
            }
        } else {
            noRecording
        }
    }

    private func voiceCard(
        _ decision: SpeakerIdentityBenchmarkDecision,
        showEvidence: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(decision.localLabel, systemImage: "person.crop.circle")
                    .font(.headline)
                statusBadge(
                    decision.eligibleForGlobalIdentity ? "CLEAN EVIDENCE" : "QUARANTINED",
                    color: decision.eligibleForGlobalIdentity ? .green : .orange
                )
                Spacer()
                Text(durationLabel(decision.clusterDurationSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if showEvidence {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    evidenceRow(
                        "Best candidate",
                        abbreviatedIdentity(decision.winnerUUID),
                        "Similarity",
                        scoreLabel(decision.winnerScore)
                    )
                    evidenceRow(
                        "Runner-up",
                        decision.runnerUpScore == nil ? "None" : scoreLabel(decision.runnerUpScore),
                        "Winner gap",
                        scoreGapLabel(decision)
                    )
                    evidenceRow(
                        "Best prototype",
                        scoreLabel(decision.bestPrototypeScore),
                        "Supporting prototypes",
                        decision.supportingPrototypeCount?.formatted() ?? "—"
                    )
                    evidenceRow(
                        "Assigned result",
                        abbreviatedIdentity(decision.assignedPredictedUUID),
                        "Decision",
                        decision.reusedExistingIdentity ? "Reused identity" : "Created new"
                    )
                }
                .font(.caption)
                if !decision.priorReferenceSpeakers.isEmpty {
                    Label(
                        "Candidate already contained gold voice"
                            + (decision.priorReferenceSpeakers.count == 1 ? ": " : "s: ")
                            + decision.priorReferenceSpeakers.joined(separator: ", "),
                        systemImage: "clock.arrow.circlepath"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    evidenceRow(
                        "Cohesion",
                        scoreLabel(decision.clusterCohesion),
                        "Diarizer confidence",
                        scoreLabel(decision.clusterConfidence)
                    )
                    evidenceRow(
                        "Embedding turns",
                        decision.clusterEmbeddingTurnCount.formatted(),
                        "Mixture split gain",
                        scoreLabel(decision.mixtureSplitGain)
                    )
                }
                .font(.caption)
                if let spans = decision.spans, !spans.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Turn evidence")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        FlowLayout(spacing: 6) {
                            ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                                Text("\(timestamp(span.start))–\(timestamp(span.end))")
                                    .font(.caption2.monospacedDigit())
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(.secondary.opacity(0.09), in: Capsule())
                            }
                        }
                    }
                } else {
                    Label(
                        "Run the benchmark again to save this cluster’s exact turn spans.",
                        systemImage: "arrow.clockwise"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    decision.eligibleForGlobalIdentity
                        ? Color.secondary.opacity(0.14)
                        : Color.orange.opacity(0.45)
                )
        }
    }

    private func reconciliationStage(
        _ report: SpeakerPipelineBenchmarkReport
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if candidates.isEmpty {
                ContentUnavailableView(
                    "No global candidates saved",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Run this profile again to generate method comparisons.")
                )
            } else {
                candidateTable(report, showGoldGate: false)

                if let candidate = selectedCandidate {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(candidate.name) · assignments in this call")
                                    .font(.headline)
                                Text(
                                    candidate.threshold.map {
                                        "\(candidate.method) · threshold "
                                            + $0.formatted(.number.precision(.fractionLength(2)))
                                    } ?? candidate.method
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            statusBadge(
                                "\(candidate.metrics.predictedIdentityCount) GLOBAL IDENTITIES",
                                color: .cyan
                            )
                        }
                        if candidate.assignments == nil
                            && candidate.id != "production-sequential" {
                            Label(
                                "This older artifact has aggregate metrics only. Rerun to inspect "
                                    + "this method’s exact local-to-global assignments.",
                                systemImage: "arrow.clockwise"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                        if selectedRecording?.decisions.isEmpty != false {
                            Label(
                                "Run the current profile to add this latest call to every "
                                    + "global matching method.",
                                systemImage: "arrow.clockwise"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        } else {
                            ForEach(selectedRecording?.decisions ?? [], id: \.localLabel) { decision in
                                HStack(spacing: 12) {
                                    Label(decision.localLabel, systemImage: "person.crop.circle")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "arrow.right")
                                        .foregroundStyle(.secondary)
                                    Text(assignmentLabel(for: decision, candidate: candidate))
                                        .font(.callout.monospaced())
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(10)
                                .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    .padding(16)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func goldStage(_ report: SpeakerPipelineBenchmarkReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            candidateTable(report, showGoldGate: true)
            if let candidate = selectedCandidate, let recording = selectedRecording {
                if !recording.isGold {
                    ContentUnavailableView {
                        Label("Latest call · intentionally unscored", systemImage: "eye")
                    } description: {
                        Text(
                            "Its audio is processed by every global method, but it has no gold "
                                + "speaker labels. Inspect its assignments under Global matching."
                        )
                    }
                    .frame(minHeight: 170)
                } else if recording.decisions.isEmpty {
                    latestNeedsRun(recording)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(candidate.name) · gold explanation for this call")
                            .font(.headline)
                        ForEach(recording.decisions, id: \.localLabel) { decision in
                            let audit = goldAudit(decision, candidate: candidate, report: report)
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: audit.icon)
                                    .foregroundStyle(audit.color)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(decision.localLabel)
                                            .font(.callout.weight(.semibold))
                                        Text("→")
                                            .foregroundStyle(.secondary)
                                        Text(assignmentLabel(for: decision, candidate: candidate))
                                            .font(.caption.monospaced())
                                    }
                                    Text(
                                        "Gold voice: \(decision.referenceSpeakerKey ?? "unscored") · "
                                            + audit.message
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .padding(10)
                            .background(audit.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(16)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func candidateTable(
        _ report: SpeakerPipelineBenchmarkReport,
        showGoldGate: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Global method").frame(maxWidth: .infinity, alignment: .leading)
                Text("P").frame(width: 58, alignment: .trailing)
                Text("R").frame(width: 58, alignment: .trailing)
                Text("F1").frame(width: 64, alignment: .trailing)
                Text("B³").frame(width: 64, alignment: .trailing)
                Text("FM").frame(width: 46, alignment: .trailing)
                Text("FS").frame(width: 46, alignment: .trailing)
                Text("IDs").frame(width: 62, alignment: .trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider()
            ForEach(candidates) { candidate in
                Button {
                    selectedCandidateID = candidate.id
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(candidate.name)
                                    .font(.caption.weight(
                                        candidate.id == "production-sequential"
                                            ? .semibold
                                            : .regular
                                    ))
                                if candidate.id == selectedCandidate?.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(selectedStage.color)
                                }
                                if showGoldGate,
                                   let baseline = candidates.first,
                                   candidate.id != baseline.id,
                                   GlobalSpeakerGoldRegressionGate.passes(
                                       candidate: candidate.metrics,
                                       baseline: baseline.metrics
                                   ) {
                                    statusBadge("PASSES FM GATE", color: .green)
                                }
                            }
                            Text(candidate.method)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        metric(candidate.metrics.pairPrecision, width: 58)
                        metric(candidate.metrics.pairRecall, width: 58)
                        metric(candidate.metrics.pairF1, width: 64)
                        metric(candidate.metrics.bCubedF1, width: 64)
                        Text(candidate.metrics.falseMergePairs.formatted())
                            .frame(width: 46, alignment: .trailing)
                            .foregroundStyle(
                                candidate.metrics.falseMergePairs == 0 ? .green : .red
                            )
                        Text(candidate.metrics.falseSplitPairs.formatted())
                            .frame(width: 46, alignment: .trailing)
                        Text(
                            "\(candidate.metrics.predictedIdentityCount)/"
                                + "\(candidate.metrics.referenceIdentityCount)"
                        )
                        .frame(width: 62, alignment: .trailing)
                    }
                    .font(.caption.monospacedDigit())
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 7)
                .padding(.horizontal, 8)
                .background(
                    candidate.id == selectedCandidate?.id
                        ? selectedStage.color.opacity(0.10)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
            }
            Text(
                "All methods reuse the same local diarization and embeddings. FM = false-merge "
                    + "pairs; FS = false-split pairs. B³ weights each local voice equally."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.14))
        }
    }

    private var evaluationProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.benchmarkProgress?.message ?? "Preparing speaker evaluation…")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(
                    (model.benchmarkProgress?.fraction ?? 0)
                        .formatted(.percent.precision(.fractionLength(0)))
                )
                .font(.caption.monospacedDigit())
                Button("Cancel", role: .cancel) { model.cancelEvaluation() }
                    .controlSize(.small)
            }
            ProgressView(value: model.benchmarkProgress?.fraction ?? 0)
                .tint(selectedStage.color)
        }
        .padding(10)
        .background(selectedStage.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var progressUnavailable: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(model.benchmarkProgress?.message ?? "Preparing speaker evaluation…")
            ProgressView(value: model.benchmarkProgress?.fraction ?? 0)
                .frame(width: 360)
        }
    }

    private var noRecording: some View {
        ContentUnavailableView(
            "Select a gold call",
            systemImage: "waveform.and.magnifyingglass"
        )
    }

    private func latestNeedsRun(_ recording: RecordingEntry) -> some View {
        ContentUnavailableView {
            Label("Latest call not in the saved run", systemImage: "arrow.clockwise")
        } description: {
            Text(
                "\(recording.title) is already selected for the next comparison. Run "
                    + "\(pipelineSettings.selectedProfile.displayName) to generate its local "
                    + "voices, acoustic evidence, and global assignments."
            )
        } actions: {
            Button("Run \(pipelineSettings.selectedProfile.displayName)") {
                model.runActiveProfile()
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isEvaluating)
        }
        .frame(minHeight: 220)
    }

    private var selectedRunBinding: Binding<String?> {
        Binding(
            get: { selectedReport?.runName },
            set: { selectedRunName = $0 }
        )
    }

    private func selectDefaults() {
        if selectedRunName == nil || !reports.contains(where: { $0.runName == selectedRunName }) {
            selectedRunName = reports.first?.runName
        }
        if selectedRecordingKey == nil
            || !recordings.contains(where: { $0.key == selectedRecordingKey }) {
            selectedRecordingKey = recordings.first?.key
        }
        if !candidates.contains(where: { $0.id == selectedCandidateID }) {
            selectedCandidateID = candidates.first?.id ?? "production-sequential"
        }
    }

    private func stageComplete(
        _ stage: Stage,
        report: SpeakerPipelineBenchmarkReport
    ) -> Bool {
        switch stage {
        case .localVoices:
            return selectedRecording?.decisions.isEmpty == false
        case .evidence:
            return selectedRecording?.decisions.contains { $0.winnerScore != nil } == true
        case .reconciliation:
            return selectedRecording?.decisions.isEmpty == false
                && report.globalIdentityCandidates?.isEmpty == false
        case .gold:
            return selectedRecording?.isGold == true
                && selectedRecording?.decisions.isEmpty == false
                && report.globalIdentityCandidates?.contains {
                    $0.metrics.evaluatedNodeCount > 0
                } == true
        }
    }

    private func recordingID(from recordingKey: String) -> Int64? {
        guard recordingKey.hasPrefix("recording:") else { return nil }
        return Int64(recordingKey.dropFirst("recording:".count))
    }

    private func assignment(
        for decision: SpeakerIdentityBenchmarkDecision,
        candidate: GlobalSpeakerIdentityCandidateReport
    ) -> String? {
        let nodeID = "\(decision.recordingKey):\(decision.localLabel)"
        if let assignment = candidate.assignments?[nodeID] {
            return assignment
        }
        return candidate.id == "production-sequential"
            ? decision.assignedPredictedUUID
            : nil
    }

    private func assignmentLabel(
        for decision: SpeakerIdentityBenchmarkDecision,
        candidate: GlobalSpeakerIdentityCandidateReport
    ) -> String {
        abbreviatedIdentity(assignment(for: decision, candidate: candidate))
    }

    private func issueSummary(for recording: RecordingEntry) -> String? {
        guard let candidate = selectedCandidate else { return nil }
        var merge = false
        var split = false
        for decision in recording.decisions {
            let audit = goldAudit(decision, candidate: candidate, report: selectedReport)
            merge = merge || audit.message.contains("false merge")
            split = split || audit.message.contains("false split")
        }
        if merge && split { return "merge + split risk" }
        if merge { return "false merge risk" }
        if split { return "false split risk" }
        return nil
    }

    private func goldAudit(
        _ decision: SpeakerIdentityBenchmarkDecision,
        candidate: GlobalSpeakerIdentityCandidateReport,
        report: SpeakerPipelineBenchmarkReport?
    ) -> (message: String, icon: String, color: Color) {
        guard decision.eligibleForGlobalIdentity,
              let gold = decision.referenceSpeakerKey,
              let predicted = assignment(for: decision, candidate: candidate),
              let decisions = report?.identityDecisions else {
            return ("excluded from isolated global scoring", "minus.circle", .secondary)
        }
        let goldPredictions = Set(decisions.compactMap { other -> String? in
            guard other.eligibleForGlobalIdentity,
                  other.referenceSpeakerKey == gold else { return nil }
            return assignment(for: other, candidate: candidate)
        })
        let predictionGold = Set(decisions.compactMap { other -> String? in
            guard other.eligibleForGlobalIdentity,
                  assignment(for: other, candidate: candidate) == predicted else { return nil }
            return other.referenceSpeakerKey
        })
        if predictionGold.count > 1 {
            return (
                "false merge: this predicted identity contains \(predictionGold.count) gold people",
                "person.2.slash",
                .red
            )
        }
        if goldPredictions.count > 1 {
            return (
                "false split: this gold voice is spread across \(goldPredictions.count) identities",
                "arrow.triangle.branch",
                .orange
            )
        }
        return ("consistent across the scored calls", "checkmark.circle.fill", .green)
    }

    private func metricStrip(_ values: [(String, String, Color)]) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                VStack(alignment: .leading, spacing: 4) {
                    Text(value.1)
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                    Text(value.0)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(value.2.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    private func evidenceRow(
        _ firstLabel: String,
        _ firstValue: String,
        _ secondLabel: String,
        _ secondValue: String
    ) -> some View {
        GridRow {
            Text(firstLabel).foregroundStyle(.secondary)
            Text(firstValue).monospacedDigit()
            Text(secondLabel).foregroundStyle(.secondary)
            Text(secondValue).monospacedDigit()
        }
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.11), in: Capsule())
    }

    private func metric(_ value: Double?, width: CGFloat) -> some View {
        Text(value?.formatted(.percent.precision(.fractionLength(1))) ?? "—")
            .frame(width: width, alignment: .trailing)
    }

    private func scoreGapLabel(_ decision: SpeakerIdentityBenchmarkDecision) -> String {
        guard let winner = decision.winnerScore else { return "—" }
        guard let runner = decision.runnerUpScore else { return "Only candidate" }
        return (winner - runner).formatted(.number.precision(.fractionLength(3)))
    }

    private func scoreLabel(_ score: Float?) -> String {
        score?.formatted(.number.precision(.fractionLength(3))) ?? "—"
    }

    private func scoreLabel(_ score: Float) -> String {
        score.formatted(.number.precision(.fractionLength(3)))
    }

    private func abbreviatedIdentity(_ identity: String?) -> String {
        guard let identity, !identity.isEmpty else { return "No match" }
        if identity.count <= 22 { return identity }
        return "\(identity.prefix(10))…\(identity.suffix(7))"
    }

    private func durationLabel(_ duration: TimeInterval) -> String {
        if duration >= 60 {
            return "\(Int(duration / 60))m \(Int(duration) % 60)s"
        }
        return "\(duration.formatted(.number.precision(.fractionLength(1))))s"
    }

    private func timestamp(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time.rounded(.down)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
