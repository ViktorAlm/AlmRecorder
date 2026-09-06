import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RecordingDetailSheet: View {
    let recording: Recording
    let initialUtteranceId: Int64?
    let initialTimestamp: TimeInterval?
    let initialSearchQuery: String?

    init(
        recording: Recording,
        initialUtteranceId: Int64? = nil,
        initialTimestamp: TimeInterval? = nil,
        initialSearchQuery: String? = nil
    ) {
        self.recording = recording
        self.initialUtteranceId = initialUtteranceId
        self.initialTimestamp = initialTimestamp
        self.initialSearchQuery = initialSearchQuery
    }

    @Environment(\.dismiss) var dismiss

    @State private var editableTitle: String = ""
    @State private var utterances: [Utterance] = []
    @State private var isLoadingUtterances = false
    @State private var copyFeedback = false
    @State private var showRetranscribeConfirm = false
    @State private var isRetranscribing = false
    @State private var retranscribeStatus = ""

    // Playback + inline speaker editing
    @StateObject private var player = RecordingPlayerViewModel()
    @State private var allSpeakers: [Speaker] = []
    @State private var renameUuid: String? = nil
    @State private var renameLabel: String = ""
    @State private var renameText: String = ""
    @State private var showRename = false
    @State private var showMeeting = false
    @State private var editingUtteranceId: Int64?
    @State private var editingText: String = ""
    @State private var speakerReviewStatus: RecordingSpeakerReviewStatus?
    @State private var showSpeakerGoldReview = false
    @State private var speakerGoldMessage: String?
    @State private var didApplyInitialSearchFocus = false
    @State private var focusedSearchUtteranceId: Int64?

    // Transcript cleanup: soft-hidden lines + manual cleanup pass
    @State private var hiddenUtterances: [Utterance] = []
    @State private var showHiddenLines = false
    @ObservedObject private var cleanupQueue = TranscriptCleanupQueueManager.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            // Full-recording player (play / scrub / jump to any line)
            if recording.filePath != nil {
                RecordingPlayerBar(player: player)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color(nsColor: .controlBackgroundColor))
            }

            Divider()

            // Content
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // LLM-generated summary + topics
                        insightsSection

                        if let recordingId = recording.id {
                            MCPRecordingPrivacyView(recordingId: recordingId)
                        }

                        // Tags (includes generated tags)
                        tagsSection

                        Divider()

                        // Transcript
                        transcriptSection
                    }
                    .padding(20)
                }
                .onAppear {
                    applyInitialSearchFocus(using: proxy)
                }
                .onChange(of: utterances.count) {
                    applyInitialSearchFocus(using: proxy)
                }
            }

            Divider()

            // Export bar
            exportBar
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 560, idealHeight: 720)
        .onAppear {
            editableTitle = recording.title
            loadUtterances()
            loadSpeakers()
            loadSpeakerReviewStatus()
            if let path = recording.filePath {
                player.load(path: path)
                if let initialTimestamp {
                    player.seek(to: initialTimestamp, autoplay: false)
                }
            }
        }
        .onDisappear { player.stop(); saveTitleIfChanged() }
        .sheet(isPresented: $showMeeting) {
            MeetingTranscriptView(recording: recording)
        }
        .alert("Rename Speaker", isPresented: $showRename) {
            TextField("Speaker name", text: $renameText)
            Button("Cancel", role: .cancel) { }
            Button("Save") { commitRename() }
        } message: {
            Text("Renames this speaker everywhere they appear.")
        }
        .alert("Re-transcribe Recording?", isPresented: $showRetranscribeConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Re-transcribe", role: .destructive) {
                retranscribeRecording()
            }
        } message: {
            Text("This will replace the current transcript and speaker assignments with a fresh transcription.")
        }
        .confirmationDialog(
            "Speaker-label review",
            isPresented: $showSpeakerGoldReview,
            titleVisibility: .visible
        ) {
            Button("All visible speaker labels are correct") { confirmSpeakerGold() }
            Button("Speaker labels need correction", role: .destructive) {
                markSpeakerLabelsIncorrect()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Confirm only after checking the whole conversation. This creates identity/WDER gold, not hand-corrected speaker-boundary timing for strict DER.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            // Source icon
            Image(systemName: recording.source.icon)
                .font(.title2)
                .foregroundStyle(sourceColor)
                .frame(width: 40, height: 40)
                .background(sourceColor.opacity(0.12))
                .cornerRadius(10)

            // Title and metadata
            VStack(alignment: .leading, spacing: 4) {
                TextField("Title", text: $editableTitle)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .textFieldStyle(.plain)
                    .onSubmit { saveTitleIfChanged() }

                HStack(spacing: 12) {
                    Label(recording.source.displayName, systemImage: recording.source.icon)

                    Label(recording.formattedDuration, systemImage: "clock")

                    Label(recording.formattedDate, systemImage: "calendar")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            // Dismiss button
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Insights Section

    private var insightsSection: some View {
        Group {
            if let metadata = recording.metadata,
               (metadata.summary?.isEmpty == false) || (metadata.topics?.isEmpty == false) {
                VStack(alignment: .leading, spacing: 10) {
                    if let summary = metadata.summary, !summary.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles").font(.caption).foregroundColor(.purple)
                            Text("Summary").font(.subheadline).fontWeight(.medium).foregroundColor(.secondary)
                        }
                        Text(summary)
                            .font(.body)
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color.purple.opacity(0.06))
                            .cornerRadius(10)
                    }
                    if let topics = metadata.topics, !topics.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(topics, id: \.self) { topic in
                                    Text(topic)
                                        .font(.caption2)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.purple.opacity(0.12))
                                        .cornerRadius(8)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Persist an edited title. Claiming a title (≠ filename) stops the insights pipeline overwriting it.
    private func saveTitleIfChanged() {
        let trimmed = editableTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != recording.title, let id = recording.id else { return }
        let repo = GRDBRecordingRepository()
        do {
            guard let existing = try repo.getById(id) else { return }
            let updated = Recording(
                id: existing.id, title: trimmed, fileName: existing.fileName, filePath: existing.filePath,
                duration: existing.duration, language: existing.language, createdAt: existing.createdAt,
                transcribedAt: existing.transcribedAt, source: existing.source,
                fullTranscript: existing.fullTranscript, metadata: existing.metadata
            )
            try repo.update(updated)
        } catch {
            print("[RecordingDetailSheet] Failed to save title: \(error)")
        }
    }

    // MARK: - Tags Section

    private var tagsSection: some View {
        Group {
            if let recordingId = recording.id {
                TagEditorView(recordingId: recordingId)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tags")
                        .font(.headline)
                    Text("Save recording to add tags")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Transcript Section

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "text.alignleft")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Transcript")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)

                Spacer()

                if isLoadingUtterances {
                    ProgressView()
                        .scaleEffect(0.6)
                }

                speakerGoldButton
            }

            if let speakerGoldMessage {
                Text(speakerGoldMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if MeetingTranscriptView.isMeetingTrack(recording.fileName) {
                Button(action: { showMeeting = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "person.2.wave.2.fill").foregroundStyle(.purple)
                        Text("View full meeting (Me + Them)").fontWeight(.medium)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                    }
                    .padding(12)
                    .background(Color.purple.opacity(0.1))
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }

            if !utterances.isEmpty || !hiddenUtterances.isEmpty {
                // Show utterances with speaker labels
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(utterances, id: \.id) { utterance in
                        utteranceRow(utterance)
                    }
                    hiddenLinesSection
                }
            } else if let transcript = recording.fullTranscript, !transcript.isEmpty {
                // Show plain transcript
                Text(transcript)
                    .font(.body)
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(10)
            } else {
                // No transcript
                VStack(spacing: 8) {
                    Image(systemName: "text.badge.xmark")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.4))

                    Text("No transcript available")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            }
        }
    }

    // MARK: - Hidden lines (transcript cleanup)

    /// Footer listing soft-hidden lines (auto-detected hallucinations). Ghosted, with one-click
    /// restore — hiding is never destructive.
    @ViewBuilder
    private var hiddenLinesSection: some View {
        if !hiddenUtterances.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation { showHiddenLines.toggle() }
                } label: {
                    Label("\(hiddenUtterances.count) hidden line\(hiddenUtterances.count == 1 ? "" : "s") — \(showHiddenLines ? "hide" : "show")",
                          systemImage: showHiddenLines ? "eye.slash" : "eye")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Lines detected as hallucinated filler and hidden from the transcript")

                if showHiddenLines {
                    ForEach(hiddenUtterances, id: \.id) { utterance in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(utterance.formattedTimeRange).font(.caption2).foregroundColor(.secondary)
                                Text(utterance.text).font(.callout).foregroundColor(.secondary).italic()
                            }
                            Spacer()
                            Button("Unhide") { unhideLine(utterance) }
                                .controlSize(.small)
                        }
                        .padding(10)
                        .background(Color.primary.opacity(0.02))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4])))
                        .cornerRadius(8)
                    }
                }
            }
        }
    }

    // MARK: - Utterance Row

    private func utteranceRow(_ utterance: Utterance) -> some View {
        let isCurrent = player.isLoaded
            && player.currentTime >= utterance.startTime
            && player.currentTime < max(utterance.endTime, utterance.startTime + 0.01)
        let isSearchTarget = focusedSearchUtteranceId == utterance.id
        let hasAudio = recording.filePath != nil

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                speakerMenu(for: utterance)

                Text(utterance.formattedTimeRange)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                cleanupBadges(for: utterance)

                if isSearchTarget {
                    Label("Search result", systemImage: "magnifyingglass")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Capsule())
                }

                Spacer()

                Button {
                    editingUtteranceId = utterance.id
                    editingText = utterance.text
                } label: {
                    Image(systemName: "pencil").font(.system(size: 14)).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Edit this line")

                Button {
                    trashLine(utterance)
                } label: {
                    Image(systemName: "trash").font(.system(size: 13)).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Mark as trash — hides the line and teaches the cleanup to find similar ones")

                if hasAudio {
                    Button {
                        if isCurrent && player.isPlaying { player.pause() }
                        else { player.seek(to: utterance.startTime) }
                    } label: {
                        Image(systemName: (isCurrent && player.isPlaying) ? "pause.circle.fill" : "play.circle")
                            .font(.system(size: 18))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("Play from here")
                }
            }

            if editingUtteranceId == utterance.id {
                VStack(alignment: .trailing, spacing: 6) {
                    TextEditor(text: $editingText)
                        .font(.body)
                        .frame(minHeight: 60)
                        .padding(6)
                        .background(Color(NSColor.textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor.opacity(0.4)))
                    HStack(spacing: 8) {
                        Button("Cancel") { editingUtteranceId = nil }
                            .controlSize(.small)
                            .keyboardShortcut(.cancelAction)
                        Button("Save") { saveUtteranceEdit(utterance) }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                Text(
                    isSearchTarget
                        ? SearchTextHighlighter.attributedString(
                            utterance.text,
                            query: initialSearchQuery ?? ""
                        )
                        : AttributedString(utterance.text)
                )
                    .font(.body)
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .lineSpacing(3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (isCurrent || isSearchTarget)
                ? Color.accentColor.opacity(isCurrent ? 0.14 : 0.09)
                : Color.primary.opacity(0.03)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    (isCurrent || isSearchTarget)
                        ? Color.accentColor.opacity(0.5)
                        : Color.clear,
                    lineWidth: 1
                )
        )
        .cornerRadius(8)
        .id(transcriptAnchor(for: utterance))
        .contentShape(Rectangle())
        .onTapGesture {
            if hasAudio { player.seek(to: utterance.startTime) }
        }
        // Right-click: Edit line… / Re-transcribe line / Mark as trash.
        .utteranceActions(utteranceId: utterance.id, text: utterance.text) {
            loadUtterances()
        }
    }

    /// Cleanup provenance for one line: an "edited" capsule (verifier or user rewrote the text;
    /// menu shows the original and offers revert) and an orange dot for lines awaiting review.
    @ViewBuilder
    private func cleanupBadges(for utterance: Utterance) -> some View {
        if utterance.textSource != "asr", utterance.originalText != nil {
            Menu {
                if let original = utterance.originalText {
                    Text("Original: “\(original)”")
                }
                Button("Revert to original") { revertLine(utterance) }
            } label: {
                Text(utterance.textSource == "verifier" ? "fixed" : "edited")
                    .font(.caption2.bold())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.teal.opacity(0.18))
                    .foregroundColor(.teal)
                    .clipShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(utterance.textSource == "verifier" ? "Rewritten from the audio by the verifier" : "Manually edited")
        }
        if utterance.reviewStatus == UtteranceReviewStatus.pendingReview.rawValue {
            Circle()
                .fill(Color.orange)
                .frame(width: 7, height: 7)
                .help("The audio check wasn't sure about this line — see the Review inbox")
        }
    }

    private func revertLine(_ utterance: Utterance) {
        guard let id = utterance.id, let recId = recording.id else { return }
        Task {
            await Task.detached {
                try? GRDBUtteranceRepository().revertUtteranceText(id)
                try? GRDBUtteranceRepository().rebuildFullTranscript(recordingId: recId)
            }.value
            loadUtterances()
        }
    }

    private func unhideLine(_ utterance: Utterance) {
        guard let id = utterance.id, let recId = recording.id else { return }
        Task {
            await Task.detached {
                try? GRDBUtteranceRepository().unhideUtterance(id)
                try? GRDBUtteranceRepository().rebuildFullTranscript(recordingId: recId)
            }.value
            loadUtterances()
            loadSpeakerReviewStatus()
        }
    }

    private func trashLine(_ utterance: Utterance) {
        guard let id = utterance.id else { return }
        Task {
            await UtteranceActionService.markTrash(utteranceId: id)
            loadUtterances()
            loadSpeakerReviewStatus()
        }
    }

    /// Speaker chip that opens a rename / reassign menu. Reassign is scoped to this recording;
    /// rename updates the speaker record (and its label) everywhere.
    private func speakerMenu(for utterance: Utterance) -> some View {
        let label = speakerResolver.displayName(for: utterance) ?? "Unknown"
        let color = speakerColor(for: utterance.speakerUuid ?? label)
        let others = allSpeakers.filter { $0.uuid != utterance.speakerUuid }

        return Menu {
            Button {
                renameUuid = utterance.speakerUuid
                renameLabel = label
                renameText = currentName(for: utterance)
                showRename = true
            } label: { Label("Rename…", systemImage: "pencil") }

            if !others.isEmpty {
                Divider()
                Menu("Reassign this line") {
                    ForEach(others, id: \.uuid) { sp in
                        Button {
                            reassignLine(utterance, to: sp)
                        } label: {
                            Text(sp.name ?? "Speaker \(sp.uuid.prefix(4))")
                        }
                    }
                }
                Menu("Reassign this local voice in this call") {
                    ForEach(others, id: \.uuid) { sp in
                        Button {
                            reassignAll(utterance, to: sp)
                        } label: {
                            Text(sp.name ?? "Speaker \(sp.uuid.prefix(4))")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(label)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(color)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .foregroundColor(color.opacity(0.7))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .cornerRadius(5)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Export Bar

    private var exportBar: some View {
        HStack {
            // Re-transcribe button
            if isRetranscribing {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text(retranscribeStatus.isEmpty ? "Re-transcribing..." : retranscribeStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Button(action: { showRetranscribeConfirm = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption)
                        Text("Re-transcribe")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.06))
                    .foregroundColor(.primary)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .help("Re-run transcription and speaker diarization")
            }

            // Transcript cleanup: auto-hide hard-evidence junk and route uncertain lines to review.
            if isCleanupRunningForThisRecording {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text(cleanupQueue.currentStatus.isEmpty ? "Cleaning up…" : cleanupQueue.currentStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            } else {
                Button(action: enqueueCleanup) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.caption)
                        Text("Clean up transcript")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.06))
                    .foregroundColor(.primary)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(utterances.isEmpty && hiddenUtterances.isEmpty)
                .help("Detect likely hallucinated lines; uncertain cases go to Transcript review")
            }

            Spacer()

            Button(action: copyTranscript) {
                HStack(spacing: 4) {
                    Image(systemName: copyFeedback ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                    Text(copyFeedback ? "Copied" : "Copy")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(copyFeedback ? Color.green.opacity(0.15) : Color.primary.opacity(0.06))
                .foregroundColor(copyFeedback ? .green : .primary)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(recording.fullTranscript == nil && utterances.isEmpty)

            Menu {
                ForEach(TranscriptExporter.Format.allCases) { fmt in
                    Button(fmt.label) { exportTranscript(fmt) }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up").font(.caption)
                    Text("Export").font(.caption).fontWeight(.medium)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.06))
                .foregroundColor(.primary)
                .cornerRadius(8)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(utterances.isEmpty)
            .help("Export the transcript (txt / md / srt / vtt)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Actions

    private func applyInitialSearchFocus(using proxy: ScrollViewProxy) {
        guard !didApplyInitialSearchFocus,
              initialUtteranceId != nil || initialTimestamp != nil,
              !utterances.isEmpty else { return }

        let target = initialUtteranceId.flatMap { utteranceId in
            utterances.first { $0.id == utteranceId }
        } ?? initialTimestamp.flatMap { timestamp in
            utterances.min {
                abs($0.startTime - timestamp) < abs($1.startTime - timestamp)
            }
        }
        guard let target else { return }

        focusedSearchUtteranceId = target.id
        didApplyInitialSearchFocus = true
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(transcriptAnchor(for: target), anchor: .center)
            }
        }
    }

    private func transcriptAnchor(for utterance: Utterance) -> String {
        if let id = utterance.id {
            return "recording-detail-utterance-\(id)"
        }
        return "recording-detail-index-\(utterance.utteranceIndex)"
    }

    private func loadUtterances() {
        guard let recordingId = recording.id else { return }
        isLoadingUtterances = true

        Task {
            do {
                let loaded = try GRDBUtteranceRepository().getByRecordingId(recordingId, includeHidden: true)
                await MainActor.run {
                    utterances = loaded.filter { !$0.isHidden }
                    hiddenUtterances = loaded.filter { $0.isHidden }
                    isLoadingUtterances = false
                }
            } catch {
                await MainActor.run {
                    utterances = []
                    hiddenUtterances = []
                    isLoadingUtterances = false
                }
                print("[RecordingDetailSheet] Failed to load utterances: \(error)")
            }
        }
    }

    private func loadSpeakers() {
        Task {
            let speakers = (try? GRDBSpeakerRepository().getAll()) ?? []
            await MainActor.run { allSpeakers = speakers }
        }
    }

    private func loadSpeakerReviewStatus() {
        guard let recordingId = recording.id else { return }
        Task {
            let status: RecordingSpeakerReviewStatus?
            do {
                status = try GRDBRecordingRepository().getById(recordingId)
                    .flatMap(\.speakerReviewStatus)
                    .flatMap(RecordingSpeakerReviewStatus.init(rawValue:))
            } catch {
                status = nil
            }
            await MainActor.run {
                speakerReviewStatus = status
            }
        }
    }

    @ViewBuilder
    private var speakerGoldButton: some View {
        Button { showSpeakerGoldReview = true } label: {
            switch speakerReviewStatus {
            case .gold:
                Label("Speaker gold", systemImage: "checkmark.seal.fill").foregroundColor(.green)
            case .needsCorrection:
                Label("Needs correction", systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange)
            case .inProgress, .complete:
                Label("Review in progress", systemImage: "person.wave.2").foregroundColor(.blue)
            case nil:
                Label("Review speaker labels", systemImage: "checkmark.seal").foregroundColor(.secondary)
            }
        }
        .font(.callout.weight(.medium))
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(recording.id == nil || utterances.isEmpty)
        .help("Mark this conversation correct or needing correction for the private speaker test set")
    }

    private func confirmSpeakerGold() {
        guard let recordingId = recording.id else { return }
        speakerGoldMessage = nil
        Task {
            do {
                try GRDBRecordingRepository().setSpeakerReviewStatus(id: recordingId, status: .gold)
                await MainActor.run {
                    speakerReviewStatus = .gold
                    loadUtterances()
                }
            } catch {
                await MainActor.run { speakerGoldMessage = error.localizedDescription }
            }
        }
    }

    private func markSpeakerLabelsIncorrect() {
        guard let recordingId = recording.id else { return }
        speakerGoldMessage = nil
        Task {
            do {
                try GRDBRecordingRepository().setSpeakerReviewStatus(
                    id: recordingId,
                    status: .needsCorrection
                )
                await MainActor.run { speakerReviewStatus = .needsCorrection }
            } catch {
                await MainActor.run { speakerGoldMessage = error.localizedDescription }
            }
        }
    }

    /// uuid → global name resolver over the recording's speakers. Used for the chip label, export,
    /// and copy so they all show the canonical identity instead of the stale local "Speaker N".
    private var speakerResolver: SpeakerNameResolver { SpeakerNameResolver(speakers: allSpeakers) }

    /// The speaker's actual stored name (empty when unnamed) — used to SEED the rename field, so the
    /// user edits a real name rather than the "Speaker <uuid8>" placeholder.
    private func currentName(for utterance: Utterance) -> String {
        allSpeakers.first { $0.uuid == utterance.speakerUuid }?.name ?? ""
    }

    private var isCleanupRunningForThisRecording: Bool {
        guard let recId = recording.id else { return false }
        if cleanupQueue.currentJob?.recordingId == recId { return true }
        return cleanupQueue.jobs.contains { $0.recordingId == recId && ($0.status == .pending || $0.status == .processing) }
    }

    private func enqueueCleanup() {
        guard let recId = recording.id else { return }
        TranscriptCleanupQueueManager.shared.enqueue(
            recordingId: recId,
            recordingTitle: recording.title,
            mode: .manual,
            force: true,
            priority: .high
        )
    }

    /// Correct one mistaken diarization assignment without moving the rest of the source cluster.
    private func reassignLine(_ utterance: Utterance, to target: Speaker) {
        guard let id = utterance.id else { return }
        let newLabel = target.name ?? "Speaker \(target.uuid.prefix(8))"
        Task {
            do {
                let speakerRepo = GRDBSpeakerRepository()
                try speakerRepo.reassignUtterance(
                    utteranceId: id,
                    toUUID: target.uuid,
                    label: newLabel
                )
                await MainActor.run {
                    speakerGoldMessage = nil
                    speakerReviewStatus = .inProgress
                    loadUtterances()
                    loadSpeakers()
                }
            } catch {
                await MainActor.run { speakerGoldMessage = error.localizedDescription }
            }
        }
    }

    /// Reassign every line from this recording-level cluster to another existing speaker.
    private func reassignAll(_ utterance: Utterance, to target: Speaker) {
        guard let recId = recording.id, let utteranceId = utterance.id else { return }
        let newLabel = target.name ?? "Speaker \(target.uuid.prefix(8))"
        Task {
            do {
                try GRDBDatabaseManager.shared.write { db in
                    let reviewedAt = Date()
                    if try db.tableExists("speaker_global_assignments") {
                        var clusterId = utterance.localSpeakerClusterId
                        if clusterId == nil {
                            try GlobalSpeakerIdentityStore.reconcileRecording(
                                db,
                                recordingId: recId
                            )
                            clusterId = try Int64.fetchOne(
                                db,
                                sql: """
                                    SELECT local_speaker_cluster_id FROM utterances
                                    WHERE id = ?
                                """,
                                arguments: [utteranceId]
                            )
                        }
                        if let clusterId {
                            try GlobalSpeakerIdentityStore.assignLocalCluster(
                                db,
                                clusterId: clusterId,
                                to: target.uuid,
                                displayLabel: newLabel
                            )
                        }
                    } else if let src = utterance.speakerUuid {
                        try db.execute(
                            sql: """
                                UPDATE utterances SET
                                    speaker_uuid = ?, speaker = ?,
                                    speaker_assignment_source = ?, speaker_reviewed_at = ?
                                WHERE recording_id = ? AND speaker_uuid = ?
                            """,
                            arguments: [target.uuid, newLabel, SpeakerAssignmentSource.manual.rawValue,
                                        reviewedAt, recId, src])
                    } else if let lbl = utterance.speaker {
                        try db.execute(
                            sql: """
                                UPDATE utterances SET
                                    speaker_uuid = ?, speaker = ?,
                                    speaker_assignment_source = ?, speaker_reviewed_at = ?
                                WHERE recording_id = ? AND speaker = ?
                            """,
                            arguments: [target.uuid, newLabel, SpeakerAssignmentSource.manual.rawValue,
                                        reviewedAt, recId, lbl])
                    }
                    try SpeakerGoldReviewStore.markInProgress(db, recordingId: recId)
                }
                await MainActor.run {
                    speakerGoldMessage = nil
                    speakerReviewStatus = .inProgress
                    loadUtterances()
                    loadSpeakers()
                }
            } catch {
                await MainActor.run { speakerGoldMessage = error.localizedDescription }
            }
        }
    }

    /// Rename the speaker record (global) and sync the denormalized label on its utterances.
    private func commitRename() {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let recId = recording.id else { return }
        let uuid = renameUuid
        let oldLabel = renameLabel
        Task {
            if let uuid = uuid {
                try? GRDBSpeakerRepository().updateName(uuid: uuid, name: name)
                try? GRDBDatabaseManager.shared.write { db in
                    try db.execute(sql: "UPDATE utterances SET speaker = ? WHERE speaker_uuid = ?",
                                   arguments: [name, uuid])
                }
            } else {
                // No speaker record (legacy/unlabeled) — just relabel this recording's utterances.
                try? GRDBDatabaseManager.shared.write { db in
                    try db.execute(sql: "UPDATE utterances SET speaker = ? WHERE recording_id = ? AND speaker = ?",
                                   arguments: [name, recId, oldLabel])
                }
            }
            await MainActor.run { loadUtterances(); loadSpeakers() }
        }
    }

    /// Persist an inline transcript edit through the cleanup-provenance primitive: the original
    /// ASR text is preserved (revertible), text_source becomes 'user', the stale semantic embedding
    /// is purged (durable + live index) for re-embedding, and the recording's full_transcript is
    /// rebuilt from the visible lines. The DB write runs off the main thread.
    private func saveUtteranceEdit(_ utterance: Utterance) {
        guard let id = utterance.id else { editingUtteranceId = nil; return }
        let newText = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        editingUtteranceId = nil
        guard !newText.isEmpty, newText != utterance.text else { return }
        let recId = utterance.recordingId
        Task {
            await Task.detached {
                try? GRDBDatabaseManager.shared.write { db in
                    try UtteranceReviewStore.applyCorrection(db, utteranceId: id, newText: newText,
                                                             source: .user, status: .userCorrected)
                    try UtteranceReviewStore.rebuildFullTranscript(db, recordingId: recId)
                }
            }.value
            loadUtterances()
        }
    }

    /// Build the transcript in the chosen format from the real utterances and write it via a save panel.
    private func exportTranscript(_ format: TranscriptExporter.Format) {
        let lines = TranscriptExporter.lines(from: utterances, resolver: speakerResolver)
        guard !lines.isEmpty else { return }
        let content = TranscriptExporter.export(lines, format: format, title: recording.title)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(safeFileName(recording.title)).\(format.ext)"
        panel.allowedContentTypes = [format.utType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("[RecordingDetailSheet] Export failed: \(error)")
        }
    }

    private func safeFileName(_ s: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = s.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "transcript" : cleaned
    }

    private func copyTranscript() {
        let text: String
        if !utterances.isEmpty {
            let resolver = speakerResolver
            text = utterances.map { utterance in
                let speaker = resolver.displayName(for: utterance).map { "\($0): " } ?? ""
                return "\(speaker)\(utterance.text)"
            }.joined(separator: "\n\n")
        } else {
            text = recording.fullTranscript ?? ""
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        withAnimation {
            copyFeedback = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                copyFeedback = false
            }
        }
    }

    private func retranscribeRecording() {
        isRetranscribing = true
        retranscribeStatus = "Adding to queue..."

        let job = TranscriptionQueueManager.shared.addRetranscribeJob(recording: recording)
        if job != nil {
            if let id = recording.id {
                try? GRDBRecordingRepository().setSpeakerReviewStatus(id: id, status: .inProgress)
            }
            retranscribeStatus = "Queued with high priority"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                dismiss()
            }
        } else {
            retranscribeStatus = "Failed to queue"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                isRetranscribing = false
                retranscribeStatus = ""
            }
        }
    }

    // MARK: - Helpers

    private var sourceColor: Color { recording.source.color }

    private func speakerColor(for identifier: String) -> Color {
        Color.speakerColor(for: identifier)
    }
}
