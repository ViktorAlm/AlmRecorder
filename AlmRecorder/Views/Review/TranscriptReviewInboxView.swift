import SwiftUI

/// The transcript-cleanup review inbox (mirrors SuggestedPeopleView): lines the detector or the
/// Gemma audio verifier wasn't sure about land in "Needs review" with playback and Keep / Fix /
/// Hide actions; "Auto-hidden" and "Auto-corrected" sections show what was applied automatically,
/// each with one-click undo. Every action is recorded with user-level provenance, which the
/// detector and verifier never overwrite.
struct TranscriptReviewInboxView: View {

    private struct ReviewItem: Identifiable {
        let utterance: Utterance
        let recordingTitle: String
        let recordingDate: Date?
        let audioPath: String?
        let speakerDisplayName: String?   // global identity (uuid → name / stable label), not local "Speaker N"
        var id: Int64 { utterance.id ?? -1 }
    }

    @State private var pending: [ReviewItem] = []
    @State private var autoHidden: [ReviewItem] = []
    @State private var autoCorrected: [ReviewItem] = []
    @State private var userCorrected: [ReviewItem] = []
    @State private var userHidden: [ReviewItem] = []
    @State private var isLoading = false
    @State private var fixingItem: ReviewItem?
    @State private var fixText = ""

    @StateObject private var player = QuotePlayerViewModel()
    @ObservedObject private var audioHealth = LlamaAudioHealthMonitor.shared
    @ObservedObject private var settings = GlobalModelSettings.shared
    @ObservedObject private var cleanupQueue = TranscriptCleanupQueueManager.shared
    @State private var isSweeping = false
    @State private var showAdvanced = false
    @ObservedObject private var reviewModel = ReviewInboxModel.shared
    private let utteranceRepo = GRDBUtteranceRepository()

    var body: some View {
        VStack(spacing: 0) {
            header
            tuningBar
            Divider()
            if audioHealth.projectorFailure != nil,
               let reason = TranscriptVerificationService.shared.projectorFailureReason {
                projectorFailureBanner(reason)
            }
            if isLoading && pending.isEmpty && autoHidden.isEmpty && autoCorrected.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !pending.isEmpty {
                            section("Needs review",
                                    subtitle: "The audio check wasn't sure about these lines — listen and decide.",
                                    items: pending) { pendingRow($0) }
                        }
                        if !autoCorrected.isEmpty {
                            section("Auto-corrected",
                                    subtitle: "Rewritten from the audio with high confidence. Original is kept.",
                                    items: autoCorrected) { correctedRow($0) }
                        }
                        if !autoHidden.isEmpty {
                            section("Auto-hidden",
                                    subtitle: "Detected as hallucinated filler (boilerplate, loops, noise). Undo restores them.",
                                    items: autoHidden) { hiddenRow($0) }
                        }
                        if !userCorrected.isEmpty {
                            section("Your fixes",
                                    subtitle: "Lines you edited — the original is kept and survives re-transcription.",
                                    items: userCorrected) { correctedRow($0) }
                        }
                        if !userHidden.isEmpty {
                            section("Your hidden lines",
                                    subtitle: "Lines you marked as trash — these taught the cleanup and survive re-transcription.",
                                    items: userHidden) { hiddenRow($0) }
                        }
                        if pending.isEmpty && autoHidden.isEmpty && autoCorrected.isEmpty
                            && userCorrected.isEmpty && userHidden.isEmpty {
                            emptyState
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .task { await reload() }
        // Database-driven refresh: rows resolve live as Gemma verdicts land, the sweep flags
        // lookalikes, or lines get trashed from any other surface.
        .onChange(of: reviewModel.counts) { _ in
            Task { await reload() }
        }
        .onDisappear { player.stop() }
        .sheet(item: $fixingItem) { item in fixSheet(item) }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Transcript review").font(.headline)
                Text("Suspected transcription errors: hallucinated lines, loops, and audio mismatches.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button { Task { await reload() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .padding(12)
    }

    /// Sweep sensitivity + actions: the master slider applies a preset to ALL four similarity
    /// thresholds (strict = surgical, eager = wide net for Gemma/you to sort); the Advanced
    /// disclosure exposes each threshold individually. "Sweep again" re-runs the lookalike
    /// sweep from scratch at the current thresholds. Pending suggestions are ALSO queued for
    /// the Gemma double-check automatically on every maintenance tick — the button just skips
    /// the wait.
    private var tuningBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Sensitivity").font(.caption).foregroundColor(.secondary)
                Slider(value: $settings.sweepSensitivity, in: 0...2, step: 1)
                    .frame(width: 130)
                    .help("How aggressively learned hallucinations match similar lines")
                    .onChange(of: settings.sweepSensitivity) { newValue in
                        settings.applySweepPreset(newValue)
                    }
                Text(sensitivityLabel)
                    .font(.caption.bold())
                    .frame(width: 60, alignment: .leading)
                    .foregroundColor(.secondary)

                Button {
                    isSweeping = true
                    Task {
                        _ = await TranscriptCleanupQueueManager.shared.resweepNow()
                        await reload()
                        isSweeping = false
                    }
                } label: {
                    Label(isSweeping ? "Sweeping…" : "Sweep again", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isSweeping)
                .help("Clear unactioned suggestions and re-match the library at the current thresholds")

                Spacer()

                Button {
                    let recordings = Set(pending.map(\.utterance.recordingId))
                    TranscriptCleanupQueueManager.shared.enqueueVerification(for: recordings)
                } label: {
                    Label("Verify now", systemImage: "waveform.and.mic")
                }
                .disabled(pending.isEmpty || !TranscriptVerificationService.shared.isAvailable)
                .help(TranscriptVerificationService.shared.isAvailable
                      ? "Suggestions are verified automatically in the background — this skips the wait"
                      : "Needs the Gemma audio model (Models tab)")

                if cleanupQueue.isProcessing, !cleanupQueue.currentStatus.isEmpty {
                    ProgressView().scaleEffect(0.5)
                    Text(cleanupQueue.currentStatus).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                }
            }

            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(spacing: 6) {
                    thresholdSlider("Embedding similarity", value: $settings.sweepCosineFloor,
                                    range: 0.80...0.99,
                                    help: "Minimum text-embedding cosine for a semantic match — lower finds looser paraphrases")
                    thresholdSlider("Text overlap", value: $settings.sweepOverlapFloor,
                                    range: 0.50...0.95,
                                    help: "Minimum character n-gram overlap with a known hallucination")
                    thresholdSlider("Line coverage", value: $settings.sweepCoverageFloor,
                                    range: 0.20...0.90,
                                    help: "How much of the line the match must explain — lower flags lines that merely contain junk")
                    thresholdSlider("Silence gate (chars/sec)", value: $settings.sweepSparseCPS,
                                    range: 0.5...5.0,
                                    help: "Short matches only flag lines below this speech density — higher lets denser lines through")
                }
                .padding(.top, 4)
            } label: {
                Text("Advanced thresholds").font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func thresholdSlider(_ title: String, value: Binding<Double>,
                                 range: ClosedRange<Double>, help: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption2).foregroundColor(.secondary)
                .frame(width: 160, alignment: .leading)
            Slider(value: value, in: range)
                .frame(width: 180)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .help(help)
    }

    /// Preset name when the four thresholds match one, otherwise "Custom" (Advanced override).
    private var sensitivityLabel: String {
        switch settings.sweepTuning {
        case .strict: return "Strict"
        case .balanced: return "Balanced"
        case .eager: return "Eager"
        default: return "Custom"
        }
    }

    /// Shown while the llama runtime provably cannot load the current audio projector: every
    /// flagged line skips the audio check and lands here unverified, and the user should know why.
    private func projectorFailureBanner(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Audio verification is unavailable").font(.caption.bold())
                Text("The Gemma audio projector failed to load (\(reason)). Lines below were not checked against the audio — this usually means the app's bundled llama.cpp is older than the model files.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    // MARK: - Sections

    private func section(_ title: String, subtitle: String, items: [ReviewItem],
                         @ViewBuilder row: @escaping (ReviewItem) -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.bold())
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            ForEach(items) { row($0) }
        }
    }

    private func pendingRow(_ item: ReviewItem) -> some View {
        rowShell(item) {
            VStack(alignment: .leading, spacing: 4) {
                itemHeader(item)
                Text("“\(item.utterance.text)”").font(.body)
                if let heard = verifierHeard(item.utterance), !heard.isEmpty {
                    Label("Heard instead: “\(heard)”", systemImage: "ear")
                        .font(.caption).foregroundColor(.orange)
                }
                reasonChips(item.utterance)
            }
        } actions: {
            Button {
                resolve(item) { try utteranceRepo.setReviewStatus(utteranceId: $0, status: .userKept) }
            } label: {
                Label("Keep", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.regular)

            Button {
                fixText = verifierHeard(item.utterance) ?? item.utterance.text
                fixingItem = item
            } label: {
                Label("Fix…", systemImage: "pencil")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Button(role: .destructive) {
                resolve(item) { try utteranceRepo.hideUtterance($0, status: .userHidden) }
            } label: {
                Label("Hide", systemImage: "eye.slash")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Menu {
                Button {
                    retranscribeLine(item)
                } label: {
                    Label("Re-transcribe this line", systemImage: "waveform")
                }
                Divider()
                Button {
                    retranscribe(recordingId: item.utterance.recordingId)
                } label: {
                    Label("Re-transcribe whole recording…", systemImage: "arrow.counterclockwise")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Re-run transcription on just this line, or re-split and re-transcribe the whole recording (your hides and fixes are carried over)")
        }
    }

    /// Re-run whisper on just this line's audio span; the result resolves the row (correction
    /// applied, or "no speech" pointing at Hide).
    private func retranscribeLine(_ item: ReviewItem) {
        guard let id = item.utterance.id else { return }
        player.stop()
        Task {
            let result = await UtteranceActionService.retranscribeLine(utteranceId: id)
            if case .replaced = result {
                // Re-transcribed text is a user-level decision — it leaves the pending queue.
            }
            await reload()
        }
    }

    /// Queue a full re-transcription (re-split + re-run). User decisions are snapshotted at
    /// queue time and re-applied onto the new utterances.
    private func retranscribe(recordingId: Int64) {
        player.stop()
        Task {
            await Task.detached {
                guard let recording = try? GRDBRecordingRepository().getById(recordingId) else { return }
                _ = await MainActor.run {
                    TranscriptionQueueManager.shared.addRetranscribeJob(recording: recording)
                }
            }.value
            await reload()
        }
    }

    private func correctedRow(_ item: ReviewItem) -> some View {
        rowShell(item) {
            VStack(alignment: .leading, spacing: 4) {
                itemHeader(item)
                if let original = item.utterance.originalText {
                    Text("“\(original)”").font(.callout).foregroundColor(.secondary).strikethrough()
                }
                Text("“\(item.utterance.text)”").font(.body)
            }
        } actions: {
            Button("Keep fix") { resolve(item) { try utteranceRepo.setReviewStatus(utteranceId: $0, status: .userCorrected) } }
                .buttonStyle(.borderedProminent).controlSize(.regular)
            Button("Revert") { resolve(item) { try utteranceRepo.revertUtteranceText($0) } }
                .controlSize(.regular)
        }
    }

    private func hiddenRow(_ item: ReviewItem) -> some View {
        rowShell(item) {
            VStack(alignment: .leading, spacing: 4) {
                itemHeader(item)
                Text("“\(item.utterance.text)”").font(.body).foregroundColor(.secondary).italic()
                reasonChips(item.utterance)
            }
        } actions: {
            Button("Undo") { resolve(item) { try utteranceRepo.unhideUtterance($0) } }
                .controlSize(.regular)
        }
    }

    private func rowShell(_ item: ReviewItem,
                          @ViewBuilder content: () -> some View,
                          @ViewBuilder actions: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 10) {
            playButton(item)
            content()
            Spacer(minLength: 12)
            HStack(spacing: 6) { actions() }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func itemHeader(_ item: ReviewItem) -> some View {
        HStack(spacing: 6) {
            Text(item.recordingTitle).font(.caption.bold()).foregroundColor(.secondary).lineLimit(1)
            Text(item.utterance.formattedTimeRange).font(.caption2).foregroundColor(.secondary)
            if let speaker = item.speakerDisplayName, !speaker.isEmpty {
                Text(speaker).font(.caption2).foregroundColor(.secondary)
            }
            if let suspicion = item.utterance.suspicion, suspicion > 0 {
                Text(String(format: "%.2f", suspicion))
                    .font(.caption2.monospacedDigit().bold())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.orange.opacity(0.12))
                    .foregroundColor(.orange)
                    .clipShape(Capsule())
                    .help("Suspicion score (0–1)")
            }
        }
    }

    private func playButton(_ item: ReviewItem) -> some View {
        let quote = QuoteItem(id: Int(item.utterance.id ?? -1),
                              text: item.utterance.text,
                              start: item.utterance.startTime,
                              end: item.utterance.endTime,
                              audioPath: item.audioPath,
                              recordingTitle: item.recordingTitle,
                              recordingDate: item.recordingDate)
        let isPlaying = player.playingId == quote.id
        return Button { player.toggle(quote) } label: {
            Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle")
                .font(.title2)
                .foregroundColor(item.audioPath == nil ? .gray : .accentColor)
        }
        .buttonStyle(.plain)
        .disabled(item.audioPath == nil)
        .help(item.audioPath == nil ? "Audio file unavailable" : "Play this part of the recording")
    }

    private func reasonChips(_ utterance: Utterance) -> some View {
        let labels = reasonLabels(utterance)
        return HStack(spacing: 4) {
            ForEach(labels, id: \.self) { label in
                Text(label)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15))
                    .foregroundColor(.orange)
                    .clipShape(Capsule())
            }
            if let error = verifierError(utterance) {
                Text(error)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.gray.opacity(0.15))
                    .foregroundColor(.secondary)
                    .clipShape(Capsule())
                    .help(verifierRawError(utterance) ?? error)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal").font(.system(size: 30)).foregroundColor(.secondary)
            Text("Nothing to review").foregroundColor(.secondary)
            Text("Suspicious transcript lines show up here after a cleanup pass — enable it in Models, or use “Clean up transcript” on a recording.")
                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center).frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 30)
    }

    // MARK: - Fix sheet

    private func fixSheet(_ item: ReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fix transcript line").font(.headline)
            Text("Original transcription: “\(item.utterance.originalText ?? item.utterance.text)”")
                .font(.caption).foregroundColor(.secondary)
            TextEditor(text: $fixText)
                .font(.body)
                .frame(minHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("Cancel") { fixingItem = nil }
                Button("Save") {
                    let text = fixText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        resolve(item) {
                            try utteranceRepo.applyCorrection(utteranceId: $0, newText: text,
                                                              source: .user, status: .userCorrected)
                        }
                    }
                    fixingItem = nil
                }
                .buttonStyle(.borderedProminent)
                .disabled(fixText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 420)
    }

    // MARK: - Actions / data

    /// Run a mutation for the item's utterance, rebuild its recording transcript, refresh.
    /// Every decision here is a label — hides teach the exemplar memory, keeps un-teach — so
    /// the (debounced, cheap) sweep runs after each batch of actions to propagate the lesson.
    private func resolve(_ item: ReviewItem, _ mutation: @escaping (Int64) throws -> Void) {
        guard let id = item.utterance.id else { return }
        player.stop()
        let recordingId = item.utterance.recordingId
        Task {
            await Task.detached {
                do {
                    try mutation(id)
                    try GRDBUtteranceRepository().rebuildFullTranscript(recordingId: recordingId)
                } catch {
                    VoxtralLogger.shared.error("[ReviewInbox] Action failed for utterance \(id): \(error.localizedDescription)")
                }
            }.value
            TranscriptCleanupQueueManager.shared.scheduleExemplarSweep()
            await reload()
        }
    }

    private func reload() async {
        isLoading = true
        let snapshot = await Task.detached { () -> ([ReviewItem], [ReviewItem], [ReviewItem], [ReviewItem], [ReviewItem]) in
            let repo = GRDBUtteranceRepository()
            let recordingRepo = GRDBRecordingRepository()
            var recordingCache: [Int64: Recording] = [:]
            // Resolve speaker uuids → global names once, so the inbox header shows the stable named
            // identity instead of the per-recording local "Speaker N".
            let resolver = SpeakerNameResolver(speakers: (try? GRDBSpeakerRepository().getAll()) ?? [])

            func items(_ status: UtteranceReviewStatus) -> [ReviewItem] {
                let utterances = (try? repo.utterances(withReviewStatus: status)) ?? []
                return utterances.map { utterance in
                    let recording: Recording? = recordingCache[utterance.recordingId]
                        ?? (try? recordingRepo.getById(utterance.recordingId)) ?? nil
                    if let recording { recordingCache[utterance.recordingId] = recording }
                    let path = recording?.filePath
                    let exists = path.map { FileManager.default.fileExists(atPath: $0) } ?? false
                    return ReviewItem(utterance: utterance,
                                      recordingTitle: recording?.title ?? "Recording \(utterance.recordingId)",
                                      recordingDate: recording?.createdAt,
                                      audioPath: exists ? path : nil,
                                      speakerDisplayName: resolver.displayName(for: utterance))
                }
            }
            return (items(.pendingReview), items(.autoHidden), items(.autoCorrected),
                    items(.userCorrected), items(.userHidden))
        }.value
        pending = snapshot.0
        autoHidden = snapshot.1
        autoCorrected = snapshot.2
        userCorrected = snapshot.3
        userHidden = snapshot.4
        isLoading = false
    }

    // MARK: - JSON decoding helpers

    private func reasonLabels(_ utterance: Utterance) -> [String] {
        guard let json = utterance.suspicionReasons,
              let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        let names: [String: String] = [
            "boilerplate": "Boilerplate",
            "emptyOrSymbols": "Empty/noise",
            "repetitionLoop": "Repetition loop",
            "silenceFiller": "Silence filler",
            "repetitionSoft": "Repetitive",
            "crossRepetition": "Repeated line",
            "lowTokenProb": "Low confidence",
            "veryLowTokenProb": "Very low confidence",
            "highCharRate": "Too fast",
            "longSparse": "Sparse audio",
            "embeddingDuplicate": "Near-duplicate",
            "scriptOutlier": "Language outlier",
            "knownHallucination": "Known pattern",
            "voiceMismatch": "Voice mismatch",
        ]
        return raw.compactMap { names[$0] ?? $0 }
    }

    private func verifierPayload(_ utterance: Utterance) -> [String: Any]? {
        guard let json = utterance.verifierResult,
              let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func verifierHeard(_ utterance: Utterance) -> String? {
        let heard = verifierPayload(utterance)?["heard"] as? String
        return (heard?.isEmpty == false) ? heard : nil
    }

    /// Short chip label for a failed/never-run audio check. Lines whose result JSON carries an
    /// error and no verdict are re-queued automatically — say so instead of a dead-end "failed".
    private func verifierError(_ utterance: Utterance) -> String? {
        guard let error = verifierPayload(utterance)?["error"] as? String else { return nil }
        switch error {
        case "no_audio": return "audio missing"
        case "verifier_unavailable": return "Gemma model needed"
        case "projector_failed": return "audio check unavailable"
        default:
            return error.localizedCaseInsensitiveContains("cancel")
                ? "check interrupted — retrying"
                : "check failed — retrying"
        }
    }

    private func verifierRawError(_ utterance: Utterance) -> String? {
        verifierPayload(utterance)?["error"] as? String
    }
}
