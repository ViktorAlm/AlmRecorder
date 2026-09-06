import SwiftUI

/// Preview-and-apply UI for repairing a global speaker profile that contains several real people.
///
/// This intentionally never applies a threshold on appearance. The user can compare grouping
/// strategies and choose which group keeps the original profile/name before one transactional write.
struct SpeakerProfileSplitView: View {
    let speaker: SpeakerProfile
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var threshold: Double = 0.86
    @State private var linkage: PersonaLinkage = .complete
    @State private var keepLocalLabelsSeparate = true
    @State private var preview: SpeakerProfileSplitter.Preview?
    @State private var anchorGroupID: String?
    @State private var isLoading = false
    @State private var isApplying = false
    @State private var canUndo = false
    @State private var errorText: String?
    @State private var analysisTask: Task<Void, Never>?
    @State private var confirmApply = false
    @State private var confirmUndo = false
    @StateObject private var samplePlayer = QuotePlayerViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    explanation
                    controls
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Comparing local voice clusters…")
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    } else if let preview {
                        summary(preview)
                        groups(preview)
                        overlapNotice
                    }
                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundColor(.orange)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(18)
            }

            Divider()
            footer
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 650, idealHeight: 760)
        .background(Color(NSColor.windowBackgroundColor))
        .task {
            canUndo = SpeakerProfileSplitter.canUndo(sourceSpeakerUUID: speaker.uuid)
            scheduleAnalysis(immediate: true)
        }
        .onDisappear { analysisTask?.cancel() }
        .alert("Create \(max(0, (preview?.groups.count ?? 1) - 1)) new speaker profiles?", isPresented: $confirmApply) {
            Button("Cancel", role: .cancel) {}
            Button("Split speaker") { applySplit() }
        } message: {
            Text("The selected group keeps \(speaker.displayName). The other groups become separate unnamed people. All moved utterances are recorded so the operation can be undone until those new profiles are edited.")
        }
        .alert("Undo the last automatic split?", isPresented: $confirmUndo) {
            Button("Cancel", role: .cancel) {}
            Button("Undo split", role: .destructive) { undoSplit() }
        } message: {
            Text("Utterances will return to \(speaker.displayName) and the automatically created profiles will be removed.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.badge.gearshape")
                .font(.title2)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Split mixed speaker").font(.headline)
                Text(speaker.displayName).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if canUndo {
                Button("Undo last split") { confirmUndo = true }
                    .disabled(isApplying)
            }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(14)
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Repair thousands of utterances at once")
                .font(.title3.weight(.semibold))
            Text("The app first makes one voiceprint for every local diarizer label in every recording, then groups matching voiceprints into people. All utterances in a local cluster move together, so old lines without their own voiceprint do not need manual correction.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Voice-match strictness").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int((threshold * 100).rounded()))%")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
            }
            HStack(spacing: 8) {
                presetButton("Broader", value: 0.82, help: "Fewer, broader people")
                presetButton("Balanced", value: 0.86, help: "Safer default")
                presetButton("Strict", value: 0.90, help: "More people; lowest false-merge risk")
                Slider(value: $threshold, in: 0.80...0.95, step: 0.01) { Text("Threshold") }
                    .onChange(of: threshold) { scheduleAnalysis() }
            }

            HStack(spacing: 16) {
                Picker("Grouping", selection: $linkage) {
                    Text("Complete linkage (safer)").tag(PersonaLinkage.complete)
                    Text("Single linkage (legacy)").tag(PersonaLinkage.single)
                }
                .pickerStyle(.menu)
                .onChange(of: linkage) { scheduleAnalysis() }

                Toggle("Keep different labels in one recording separate", isOn: $keepLocalLabelsSeparate)
                    .toggleStyle(.checkbox)
                    .onChange(of: keepLocalLabelsSeparate) { scheduleAnalysis() }
                    .help("A cannot-link safety rule: two local diarizer labels from the same recording cannot be merged into one person.")
            }
            Text(strictnessExplanation)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func presetButton(_ title: String, value: Double, help: String) -> some View {
        Button(title) {
            threshold = value
            scheduleAnalysis(immediate: true)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help)
    }

    private var strictnessExplanation: String {
        switch threshold {
        case ..<0.84:
            return "Broader grouping: tolerates recording/device changes, but has a higher risk of keeping two similar voices together."
        case ..<0.89:
            return "Balanced grouping: biases toward separate people when the evidence is borderline."
        default:
            return "Strict grouping: minimizes false merges, but the same person may appear as several profiles that can be merged later."
        }
    }

    private func summary(_ preview: SpeakerProfileSplitter.Preview) -> some View {
        HStack(spacing: 12) {
            metric("\(preview.groups.count)", "proposed people")
            metric("\(preview.localClusterCount)", "local clusters")
            metric("\(preview.utteranceCount.formatted())", "utterances")
            metric("\(Int((preview.vectorCoverage * 100).rounded()))%", "voice coverage")
            if preview.unresolvedGroupCount > 0 {
                metric("\(preview.unresolvedGroupCount)", "no-voiceprint groups", warning: true)
            }
        }
    }

    private func metric(_ value: String, _ label: String, warning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundColor(warning ? .orange : .primary)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((warning ? Color.orange : Color.accentColor).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func groups(_ preview: SpeakerProfileSplitter.Preview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Proposed people").font(.headline)
                Spacer()
                Text("Choose who keeps the original profile")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            ForEach(Array(preview.groups.enumerated()), id: \.element.id) { index, group in
                groupRow(index: index, group: group)
            }
        }
    }

    private func groupRow(index: Int, group: SpeakerProfileSplitter.Group) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: anchorGroupID == group.id ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(anchorGroupID == group.id ? .accentColor : .secondary)
                    .padding(.top, 3)
                Circle()
                    .fill(color(for: index))
                    .frame(width: 34, height: 34)
                    .overlay(Text("\(index + 1)").font(.caption.bold()).foregroundColor(.white))
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(anchorGroupID == group.id ? "\(speaker.displayName) (keeps original)" : "New person \(index + 1)")
                            .font(.subheadline.weight(.semibold))
                        if group.lacksVoiceprint {
                            Label("No voiceprint", systemImage: "waveform.slash")
                                .font(.caption2.bold())
                                .foregroundColor(.orange)
                        } else if let similarity = group.minimumSimilarity {
                            Text("≥ \(Int((similarity * 100).rounded()))% within group")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Distinct voice cluster")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    Text("\(group.utteranceCount.formatted()) utterances · \(formatDuration(group.duration)) · \(group.recordingCount) recording\(group.recordingCount == 1 ? "" : "s") · \(group.vectorCount.formatted()) vectors")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(group.clusters.prefix(3).map(\.recordingTitle).joined(separator: "  ·  "))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    if group.clusters.count > 3 {
                        Text("+ \(group.clusters.count - 3) more local clusters")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    let samples = Array(group.samples.prefix(3))
                    if !samples.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(Array(samples.enumerated()), id: \.element.id) { sampleIndex, sample in
                                Button {
                                    samplePlayer.toggle(sample.quoteItem)
                                } label: {
                                    Label(
                                        samplePlayer.playingId == Int(sample.utteranceId)
                                            ? "Pause"
                                            : "Sample \(sampleIndex + 1)",
                                        systemImage: samplePlayer.playingId == Int(sample.utteranceId)
                                            ? "pause.circle.fill"
                                            : "play.circle.fill"
                                    )
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .help("Listen to \(sample.recordingTitle)")
                            }
                        }
                        .padding(.top, 3)
                    }
                }
                Spacer(minLength: 4)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(anchorGroupID == group.id ? Color.accentColor.opacity(0.10) : Color(NSColor.controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(anchorGroupID == group.id ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.15))
            )
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .contentShape(Rectangle())
        .onTapGesture { anchorGroupID = group.id }
    }

    private var overlapNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.2.wave.2")
                .foregroundColor(.purple)
            VStack(alignment: .leading, spacing: 3) {
                Text("Simultaneous speech is a separate problem")
                    .font(.subheadline.weight(.semibold))
                Text("This repairs a mixed global identity without forcing individual utterances to a new person. A section where two people speak at once needs overlap-aware, multi-label diarization; the current transcript row can still hold only one primary speaker. Keep those sections out of gold data until an overlap pass or a reviewer confirms their boundaries.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.purple.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var footer: some View {
        HStack {
            Text("Nothing changes until you confirm. The split is one transaction with undo.")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }
            Button {
                confirmApply = true
            } label: {
                if isApplying {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Apply split")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isApplying || isLoading || preview == nil || (preview?.groups.count ?? 0) < 2 || anchorGroupID == nil)
        }
        .padding(14)
    }

    private func scheduleAnalysis(immediate: Bool = false) {
        analysisTask?.cancel()
        let requestedThreshold = Float(threshold)
        let requestedLinkage = linkage
        let requestedConstraint = keepLocalLabelsSeparate
        let uuid = speaker.uuid
        isLoading = true
        errorText = nil
        analysisTask = Task {
            if !immediate {
                try? await Task.sleep(nanoseconds: 180_000_000)
            }
            guard !Task.isCancelled else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try SpeakerProfileSplitter.preview(
                        sourceSpeakerUUID: uuid,
                        threshold: requestedThreshold,
                        linkage: requestedLinkage,
                        keepLocalLabelsSeparate: requestedConstraint
                    )
                }.value
                guard !Task.isCancelled else { return }
                preview = result
                if !result.groups.contains(where: { $0.id == anchorGroupID }) {
                    anchorGroupID = result.suggestedAnchorGroupID
                }
                isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                preview = nil
                errorText = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func applySplit() {
        guard let preview, let anchorGroupID, !isApplying else { return }
        isApplying = true
        errorText = nil
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try SpeakerProfileSplitter.apply(preview, anchorGroupID: anchorGroupID)
                }.value
                isApplying = false
                onChanged()
                dismiss()
            } catch {
                isApplying = false
                errorText = error.localizedDescription
            }
        }
    }

    private func undoSplit() {
        guard !isApplying else { return }
        isApplying = true
        errorText = nil
        let uuid = speaker.uuid
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try SpeakerProfileSplitter.undoLatest(sourceSpeakerUUID: uuid)
                }.value
                isApplying = false
                onChanged()
                dismiss()
            } catch {
                isApplying = false
                errorText = error.localizedDescription
            }
        }
    }

    private func color(for index: Int) -> Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .mint]
        return colors[index % colors.count]
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "0s"
    }
}
