import SwiftUI

/// Rich profile for one speaker ("person"): who they are (AI summary), what they've said (quotes),
/// when/where you met them (meetings + recordings), and stats/relationships. Editing (rename, link
/// email, notes) lives in the header. Heavy transcript/timeline browsing is delegated to the existing
/// `EnhancedSpeakerDetailView` via "View all".
struct PersonProfileView: View {
    let speaker: SpeakerProfile
    @ObservedObject var viewModel: SpeakerManagementViewModel

    @State private var editedName: String
    @State private var notes: String
    @State private var linkedEmail: String?
    @State private var linkedName: String?
    @State private var isOwner = false

    @State private var insights: GRDBSpeakerInsightsRepository.SpeakerInsights?
    @State private var isGenerating = false
    @State private var autoTried = false
    @State private var suggestion: IdentityInference?

    @State private var meetings: [(meeting: Meeting, confidence: RecordingMeeting.MatchConfidence)] = []
    @State private var recordings: [SpeakerRecordingRow] = []
    @State private var coAppearances: [(speaker: SpeakerProfile, shared: Int)] = []
    @State private var talkStats: SpeakerTalkStats.Stats?
    @State private var allItems: [QuoteItem] = []
    @State private var quoteSearch = ""
    @State private var totalQuotes = 0
    @State private var searchMode: QuoteSearchMode = .words
    @State private var displayLimit = 20
    @State private var semanticItems: [QuoteItem] = []
    @State private var isSearchingSemantic = false
    @State private var semanticError: String?
    @StateObject private var quotePlayer = QuotePlayerViewModel()

    // Voice-QA: per-utterance voice vectors + speaker means/names → suspect verdicts + reassign ranking.
    @State private var verdicts: [Int: UtteranceVoiceVerdict] = [:]
    @State private var vecById: [Int: [Float]] = [:]
    @State private var speakerMeans: [String: [Float]] = [:]
    @State private var speakerNames: [String: String] = [:]

    @State private var showLinkEmail = false
    @State private var emailInput = ""
    @State private var showMerge = false
    @State private var showSplit = false
    @State private var mergeCandidates: [SpeakerProfile] = []
    @State private var mergeSearch = ""
    @State private var showAssign = false
    @State private var showModelManager = false
    @State private var nameSaveTask: Task<Void, Never>?
    @State private var aiGuess: AIIdentityGuess?
    @State private var isGuessing = false
    @State private var aiGuessError: String?
    @State private var mergeError: String?

    enum QuoteSearchMode: String, CaseIterable, Identifiable {
        case words = "Words"
        case meaning = "Meaning"
        case review = "Review"
        var id: String { rawValue }
    }

    /// Called after edits that change the list (rename / link email) so the parent list can refresh.
    private let onChange: () -> Void

    private let speakerRepo = GRDBSpeakerRepository()
    private let attendeeRepo = GRDBSpeakerAttendeeRepository()

    init(speaker: SpeakerProfile, viewModel: SpeakerManagementViewModel, onChange: @escaping () -> Void = {}) {
        self.speaker = speaker
        _viewModel = ObservedObject(wrappedValue: viewModel)
        self.onChange = onChange
        _editedName = State(initialValue: speaker.name ?? "")
        _notes = State(initialValue: speaker.notes ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard
                if let suggestion { suggestionBanner(suggestion) }
                aiIdentitySection
                aboutCard
                statsCard
                talkStyleCard
                meetingsCard
                quotesCard
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(speaker.displayName)
        .task { await loadAll() }
        .onDisappear { saveProfile() }
        .alert("Link email", isPresented: $showLinkEmail) {
            TextField("Email address", text: $emailInput)
            Button("Cancel", role: .cancel) {}
            Button("Link") { linkEmail(emailInput) }
        } message: {
            Text("Associate an email address with \(speaker.displayName).")
        }
        .sheet(isPresented: $showMerge) { mergeSheet }
        .sheet(isPresented: $showSplit) {
            SpeakerProfileSplitView(speaker: speaker) {
                onChange()
            }
        }
        .sheet(isPresented: $showAssign) { assignSheet }
        .alert("Couldn’t merge", isPresented: Binding(get: { mergeError != nil }, set: { if !$0 { mergeError = nil } })) {
            Button("OK", role: .cancel) { mergeError = nil }
        } message: {
            Text(mergeError ?? "")
        }
        .sheet(isPresented: $showModelManager, onDismiss: { Task { await loadAll() } }) {
            VStack(spacing: 0) {
                HStack {
                    Text("Models").font(.headline)
                    Spacer()
                    Button("Done") { showModelManager = false }.keyboardShortcut(.cancelAction)
                }
                .padding(12)
                Divider()
                ModelManagerView(focusGemmaText: true)
            }
            .frame(minWidth: 720, minHeight: 700)
            // Opaque sheet — without this the macOS-26 glass lets the People list bleed through behind it,
            // which read as "elements all over the place".
            .background(Color(NSColor.windowBackgroundColor))
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                Circle()
                    .fill(speaker.avatarColor)
                    .frame(width: 64, height: 64)
                    .overlay(Text(speaker.initials).font(.title).foregroundColor(.white).fontWeight(.semibold))

                VStack(alignment: .leading, spacing: 8) {
                    TextField("Name", text: $editedName)
                        .font(.title2.weight(.bold))
                        .textFieldStyle(.plain)
                        .onSubmit { saveProfile() }
                        .onChange(of: editedName) { _ in scheduleNameSave() }

                    HStack(spacing: 8) {
                        if let email = linkedEmail, !email.isEmpty {
                            Label(email, systemImage: "envelope.fill")
                                .font(.callout)
                                .foregroundColor(.secondary)
                            Menu {
                                Button("Change email…") { emailInput = email; showLinkEmail = true }
                                Button("Unlink", role: .destructive) { unlinkEmail() }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        } else {
                            Button {
                                emailInput = ""
                                showLinkEmail = true
                            } label: {
                                Label("Link email", systemImage: "envelope.badge")
                            }
                            .buttonStyle(.link)
                        }
                    }

                    HStack(spacing: 16) {
                        Label("\(speaker.utteranceCount) utterances", systemImage: "text.bubble")
                        Label(formatDuration(speaker.totalDuration), systemImage: "clock")
                        Label("Last seen \(speaker.lastSeenFormatted)", systemImage: "calendar")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                Spacer()
                if isOwner {
                    Label("You", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Capsule())
                        .help("This voice is set as the device owner")
                } else {
                    Button {
                        setAsOwner()
                    } label: {
                        Label("Set as me", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Use this voice as your identity; this does not merge speakers")
                }
                Button {
                    showSplit = true
                } label: {
                    Label("Split", systemImage: "person.2.badge.gearshape")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Automatically split a mixed speaker profile in bulk")
                Menu {
                    Menu {
                        let targets = moveTargets
                        if targets.isEmpty {
                            Text("No other people")
                        } else {
                            ForEach(targets.prefix(12), id: \.uuid) { person in
                                Button(person.displayName) { assignToExisting(person) }
                            }
                            Divider()
                            Button("Search all people…") { showAssign = true }
                        }
                    } label: {
                        Label("Move this into…", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    Button { showMerge = true } label: {
                        Label("Merge another person into this…", systemImage: "arrow.triangle.merge")
                    }
                    if isOwner {
                        Divider()
                        Button("This is not me", role: .destructive) {
                            OwnerIdentityService.shared.setOwnerVoice(nil)
                            isOwner = false
                            onChange()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More actions")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Notes").font(.caption).foregroundColor(.secondary)
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(minHeight: 50, maxHeight: 100)
                    .padding(6)
                    .background(Color(NSColor.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            }
        }
        .cardStyle()
    }

    // MARK: - About (AI)

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("About this person", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                if isGenerating {
                    ProgressView().controlSize(.small)
                } else if LLMTextService.shared.isAvailable {
                    // Only offer Generate/Refresh once a text model exists — otherwise it's a dead button
                    // next to the "Get Gemma" prompt below, which read as broken.
                    Button(insights == nil ? "Generate" : "Refresh") { generate() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            if let insights, !insights.summary.isEmpty {
                Text(insights.summary)
                    .font(.body)
                    .foregroundColor(.primary)
                if !insights.topics.isEmpty {
                    chipsRow(insights.topics.map { ($0, Color.accentColor) })
                }
            } else if isGenerating {
                Text("Reading what they've said…")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else if !LLMTextService.shared.isAvailable {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Install a text model (Gemma) to generate an AI profile.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Button { showModelManager = true } label: {
                        Label("Get Gemma…", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else {
                Text("No profile yet. Generate a summary of who this person is and what they discuss, from their quotes.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
        .cardStyle()
    }

    // MARK: - Stats & relationships

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Stats & relationships", systemImage: "chart.bar.xaxis").font(.headline)

            VStack(spacing: 8) {
                StatRow(label: "Total speaking time", value: formatDuration(speaker.totalDuration))
                StatRow(label: "Utterances", value: "\(speaker.utteranceCount)")
                StatRow(label: "Recordings", value: "\(recordings.count)")
                StatRow(label: "Meetings", value: "\(meetings.count)")
                StatRow(label: "First seen", value: speaker.firstSeen.formatted(date: .abbreviated, time: .omitted))
                StatRow(label: "Last seen", value: speaker.lastSeen.formatted(date: .abbreviated, time: .omitted))
            }

            if !coAppearances.isEmpty {
                Divider()
                Text("Frequently with").font(.caption).foregroundColor(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(coAppearances, id: \.speaker.uuid) { entry in
                            NavigationLink {
                                PersonProfileView(speaker: entry.speaker, viewModel: viewModel)
                            } label: {
                                coAppearanceChip(entry.speaker, shared: entry.shared)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .cardStyle()
    }

    // MARK: - Talking style (fun stats)

    private var talkStyleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Talking style", systemImage: "waveform.and.mic").font(.headline)

            if let stats = talkStats {
                VStack(spacing: 8) {
                    if let wpm = stats.wordsPerMinute {
                        StatRow(label: "Speaking pace", value: "\(Int(wpm.rounded())) words/min")
                    }
                    if let share = stats.avgWordShare {
                        StatRow(label: "Share of words", value: "\(Int((share * 100).rounded()))% avg per recording")
                    }
                    if let share = stats.avgTimeShare {
                        StatRow(label: "Share of talk time", value: "\(Int((share * 100).rounded()))% avg per recording")
                    }
                    if stats.vocabularySize > 0 {
                        StatRow(label: "Vocabulary", value: "\(stats.vocabularySize.formatted()) distinct words")
                    }
                    if let monologue = stats.longestMonologue {
                        StatRow(label: "Longest monologue", value: monologueText(monologue))
                    }
                }

                if !stats.signatureWords.isEmpty {
                    Divider()
                    Text("Signature words — used far more than anyone else they talk with")
                        .font(.caption).foregroundColor(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(stats.signatureWords, id: \.word) { signature in
                                Text(signature.word)
                                    .font(.callout)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color.indigo.opacity(0.15)))
                                    .foregroundColor(.indigo)
                                    .help("Said \(signature.count) times")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.6)
                    Text("Crunching the numbers…").font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .cardStyle()
    }

    private func monologueText(_ monologue: SpeakerTalkStats.Monologue) -> String {
        let duration = formatDuration(monologue.duration)
        if let title = recordings.first(where: { $0.id == monologue.recordingId })?.title {
            return "\(duration) in \(title)"
        }
        return duration
    }

    // MARK: - Meetings & recordings

    private var meetingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Meetings & recordings", systemImage: "calendar.badge.clock").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Meetings").font(.subheadline.weight(.semibold))
                if meetings.isEmpty {
                    Text("No linked calendar meetings.").font(.callout).foregroundColor(.secondary)
                } else {
                    ForEach(meetings, id: \.meeting.id) { entry in
                        meetingRow(entry.meeting, confidence: entry.confidence)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Recordings").font(.subheadline.weight(.semibold))
                if recordings.isEmpty {
                    Text("No recordings yet.").font(.callout).foregroundColor(.secondary)
                } else {
                    ForEach(recordings, id: \.id) { rec in
                        recordingRow(rec)
                    }
                }
            }
        }
        .cardStyle()
    }

    // MARK: - Quotes (what they've said) — words + meaning search, paginated

    private var currentItems: [QuoteItem] {
        switch searchMode {
        case .words:
            let q = quoteSearch.trimmingCharacters(in: .whitespaces)
            return q.isEmpty ? allItems : allItems.filter { $0.text.localizedCaseInsensitiveContains(q) }
        case .meaning:
            return semanticItems
        case .review:
            return allItems
                .filter { verdicts[$0.id]?.isSuspect == true }
                .sorted { (verdicts[$0.id]?.suspectScore ?? 0) > (verdicts[$1.id]?.suspectScore ?? 0) }
        }
    }

    private var displayedItems: [QuoteItem] { Array(currentItems.prefix(displayLimit)) }

    private var quotesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("What they've said", systemImage: "quote.bubble").font(.headline)
                Spacer()
                if totalQuotes > 0 {
                    NavigationLink {
                        EnhancedSpeakerDetailView(speaker: speaker, viewModel: viewModel)
                    } label: { Text("Open timeline →") }
                    .buttonStyle(.link)
                }
            }

            Picker("", selection: $searchMode) {
                ForEach(QuoteSearchMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: searchMode) { _ in displayLimit = 20 }

            if searchMode != .review {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField(searchMode == .words ? "Search their exact words…" : "Describe what you're looking for…", text: $quoteSearch)
                        .textFieldStyle(.plain)
                        .onSubmit { if searchMode == .meaning { runSemanticSearch() } }
                        .onChange(of: quoteSearch) { _ in if searchMode == .words { displayLimit = 20 } }
                    if isSearchingSemantic { ProgressView().controlSize(.small) }
                    if !quoteSearch.isEmpty {
                        Button { quoteSearch = ""; semanticItems = []; semanticError = nil; displayLimit = 20 } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    if searchMode == .meaning {
                        Button("Search") { runSemanticSearch() }
                            .controlSize(.small)
                            .disabled(quoteSearch.trimmingCharacters(in: .whitespaces).isEmpty || isSearchingSemantic)
                    }
                }
                .padding(8)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
            } else {
                let n = allItems.filter { verdicts[$0.id]?.isSuspect == true }.count
                Text(n == 0
                     ? "No lines flagged."
                     : "\(n) line\(n == 1 ? "" : "s") may be mis-assigned — use the menu on a line to move it to the right person.")
                    .font(.caption).foregroundColor(.secondary)
            }

            if let semanticError, searchMode == .meaning {
                Text(semanticError).font(.caption).foregroundColor(.orange)
            }

            if allItems.isEmpty {
                Text("No quotes yet.").font(.callout).foregroundColor(.secondary)
            } else if displayedItems.isEmpty {
                Text(emptyQuotesMessage).font(.callout).foregroundColor(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(displayedItems) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .top, spacing: 4) {
                                QuoteRow(item: item, player: quotePlayer)
                                reassignMenu(for: item)
                                    .padding(.top, 7).padding(.trailing, 8)
                            }
                            .utteranceActions(utteranceId: Int64(item.id), text: item.text) {
                                Task { await loadAll() }
                            }
                            if let v = verdicts[item.id], v.isSuspect {
                                HStack(spacing: 5) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.caption2).foregroundColor(.orange)
                                    Text(flagText(v)).font(.caption2).foregroundColor(.orange)
                                    Spacer()
                                }
                                .padding(.leading, 42).padding(.bottom, 6)
                            }
                        }
                        if item.id != displayedItems.last?.id {
                            Divider().padding(.leading, 42)
                        }
                    }
                }
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack {
                    Text(countLabel).font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    if currentItems.count > displayLimit {
                        Button("Show \(min(20, currentItems.count - displayLimit)) more") { displayLimit += 20 }
                            .controlSize(.small)
                    }
                }
            }
        }
        .cardStyle()
    }

    private var emptyQuotesMessage: String {
        switch searchMode {
        case .meaning:
            return quoteSearch.isEmpty ? "Type a phrase and search by meaning." : "No close matches."
        case .review:
            return vecById.isEmpty
                ? "Run “Rebuild Voice Fingerprints” in Settings to enable review."
                : "No lines look mis-assigned. ✅"
        case .words:
            return "No quotes match “\(quoteSearch)”."
        }
    }

    private var countLabel: String {
        let shown = displayedItems.count
        let total = currentItems.count
        if searchMode == .words && quoteSearch.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Showing \(shown) of \(totalQuotes)"
        }
        return "\(shown) of \(total) match\(total == 1 ? "" : "es")"
    }

    // MARK: - Rows / chips

    private func meetingRow(_ meeting: Meeting, confidence: RecordingMeeting.MatchConfidence) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "calendar")
                .foregroundColor(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 8) {
                    Text(meeting.formattedDate).font(.caption).foregroundColor(.secondary)
                    if let loc = meeting.location, !loc.isEmpty {
                        Label(loc, systemImage: "mappin.and.ellipse")
                            .font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer()
            confidenceBadge(confidence)
        }
        .padding(.vertical, 3)
    }

    private func recordingRow(_ rec: SpeakerRecordingRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .foregroundColor(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.title).fontWeight(.medium).lineLimit(1)
                Text(rec.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Text(formatDuration(rec.speakerDuration))
                .font(.caption).foregroundColor(.secondary).monospacedDigit()
        }
        .padding(.vertical, 3)
    }

    private func coAppearanceChip(_ person: SpeakerProfile, shared: Int) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(person.avatarColor)
                .frame(width: 22, height: 22)
                .overlay(Text(person.initials).font(.system(size: 9, weight: .bold)).foregroundColor(.white))
            Text(person.displayName).font(.caption).lineLimit(1)
            Text("\(shared)").font(.caption2).foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.1))
        .clipShape(Capsule())
    }

    private func confidenceBadge(_ confidence: RecordingMeeting.MatchConfidence) -> some View {
        let (text, color): (String, Color) = {
            switch confidence {
            case .matched: return ("Matched", .green)
            case .suggested: return ("Suggested", .orange)
            case .possible: return ("Possible", .gray)
            }
        }()
        return Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }

    private func chipsRow(_ items: [(String, Color)]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(item.0)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(item.1.opacity(0.15))
                        .foregroundColor(item.1)
                        .clipShape(Capsule())
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Actions / loading

    private func loadAll() async {
        isOwner = OwnerIdentityService.shared.ownerVoiceUuid == speaker.uuid
        insights = SpeakerInsightsService.shared.existing(uuid: speaker.uuid)
        if let mapping = attendeeRepo.getAttendeeForSpeaker(uuid: speaker.uuid) {
            linkedEmail = mapping.attendeeEmail
            linkedName = mapping.attendeeName
        }

        // Cross-meeting identity suggestion for this voice — only when it isn't already user-named
        // (covers both unnamed voices and auto-applied "inferred" names awaiting confirmation).
        suggestion = speakerRepo.hasUserAssignedName(uuid: speaker.uuid)
            ? nil
            : IdentityInferenceCoordinator.shared.inference(forVoice: speaker.uuid)

        // Everything heavy (utterances, voice vectors, all-speaker means, meetings) runs OFF the main
        // thread so opening a talkative person doesn't freeze the UI.
        let loaded = await Self.loadHeavy(uuid: speaker.uuid)
        meetings = loaded.meetings
        recordings = loaded.recordings
        coAppearances = loaded.coAppearances
        allItems = loaded.items
        totalQuotes = loaded.totalQuotes
        vecById = loaded.vecById
        speakerMeans = loaded.means
        speakerNames = loaded.names
        verdicts = loaded.verdicts

        // Auto-generate a profile the first time we open someone who has enough on record.
        if insights == nil, !autoTried, LLMTextService.shared.isAvailable, totalQuotes >= 3 {
            autoTried = true
            generate()
        }

        // Talking-style stats: tokenizes every utterance of every recording they appear in,
        // so it runs detached and the card fills in when ready.
        let uuid = speaker.uuid
        talkStats = await Task.detached(priority: .userInitiated) { () -> SpeakerTalkStats.Stats? in
            guard let slice = try? GRDBUtteranceRepository().getTalkSlice(speakerUuid: uuid) else { return nil }
            return SpeakerTalkStats.compute(for: uuid, in: slice)
        }.value

        // Preload the people list so the "Move this into…" submenu is ready.
        loadMergeCandidates()
    }

    private func generate() {
        guard !isGenerating else { return }
        isGenerating = true
        Task {
            try? await SpeakerInsightsService.shared.generateAndPersist(speakerUuid: speaker.uuid, force: true)
            insights = SpeakerInsightsService.shared.existing(uuid: speaker.uuid)
            isGenerating = false
        }
    }

    /// Semantic ("meaning") search: embed the query and rank this speaker's utterances by vector
    /// similarity, restricted to the recordings they appear in (then filtered to this speaker).
    private func runSemanticSearch() {
        let q = quoteSearch.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { semanticItems = []; return }
        isSearchingSemantic = true
        semanticError = nil
        let recIds = recordings.map { $0.id }
        let uuid = speaker.uuid
        Task {
            do {
                let emb = try await EmbeddingService.shared.generateEmbedding(for: q)
                let results = recIds.isEmpty
                    ? []
                    : try GRDBUtteranceRepository().searchSimilarInRecordings(embedding: emb, recordingIds: recIds, limit: 80)
                let mine: [QuoteItem] = results
                    .filter { $0.utterance.speakerUuid == uuid }
                    .compactMap { r in
                        guard let uid = r.utterance.id else { return nil }
                        return QuoteItem(
                            id: Int(uid),
                            text: r.utterance.text,
                            start: r.utterance.startTime,
                            end: r.utterance.endTime,
                            audioPath: (r.recording.filePath?.isEmpty == false) ? r.recording.filePath : nil,
                            recordingTitle: r.recording.title,
                            recordingDate: r.recording.createdAt
                        )
                    }
                await MainActor.run {
                    semanticItems = mine
                    displayLimit = 20
                    isSearchingSemantic = false
                }
            } catch {
                await MainActor.run {
                    isSearchingSemantic = false
                    semanticError = "Meaning search needs the embedding model (Settings → Models)."
                }
            }
        }
    }

    // MARK: - Voice QA (review + reassign)

    /// Bundle of everything a profile loads from the DB.
    private struct Loaded {
        var meetings: [(meeting: Meeting, confidence: RecordingMeeting.MatchConfidence)] = []
        var recordings: [SpeakerRecordingRow] = []
        var coAppearances: [(speaker: SpeakerProfile, shared: Int)] = []
        var items: [QuoteItem] = []
        var totalQuotes = 0
        var vecById: [Int: [Float]] = [:]
        var means: [String: [Float]] = [:]
        var names: [String: String] = [:]
        var verdicts: [Int: UtteranceVoiceVerdict] = [:]
    }

    /// All the heavy DB work for a profile, computed off the main thread (GRDB's DatabaseQueue is
    /// thread-safe). Reads utterances + voice vectors + every speaker's mean directly — not via the
    /// @MainActor view model — and runs the suspect analysis, so the UI never blocks on a talkative
    /// speaker (up to thousands of utterances × 256-dim vectors).
    private static func loadHeavy(uuid: String) async -> Loaded {
        await Task.detached(priority: .userInitiated) {
            let speakerRepo = GRDBSpeakerRepository()
            var out = Loaded()
            out.meetings = (try? speakerRepo.getMeetingsForSpeaker(uuid: uuid)) ?? []
            out.recordings = (try? speakerRepo.getRecordingsForSpeaker(uuid: uuid)) ?? []
            out.coAppearances = ((try? speakerRepo.getCoAppearances(uuid: uuid)) ?? [])
                .map { (speaker: $0.speaker.toProfile(), shared: $0.sharedRecordings) }

            let rows = (try? speakerRepo.getUtterancesForSpeaker(uuid: uuid)) ?? []
            out.items = rows.map { r in
                QuoteItem(
                    id: Int(r.utterance.id),
                    text: r.utterance.text,
                    start: r.utterance.startTime,
                    end: r.utterance.endTime,
                    audioPath: (r.audioPath?.isEmpty == false) ? r.audioPath : nil,
                    recordingTitle: r.recordingTitle,
                    recordingDate: r.utterance.recordingDate
                )
            }
            out.totalQuotes = out.items.count

            let myVecs = (try? GRDBDatabaseManager.shared.read {
                try VoiceEmbeddingStore.loadForSpeaker($0, uuid: uuid)
            }) ?? []
            for v in myVecs { out.vecById[Int(v.utteranceId)] = v.embedding }

            for s in (try? speakerRepo.getAll()) ?? [] {
                let arr = s.embeddingArray
                if arr.count == VoiceEmbeddingStore.dimensions { out.means[s.uuid] = arr }
                out.names[s.uuid] = (s.name?.isEmpty == false) ? s.name! : "Speaker \(s.uuid.prefix(8))"
            }

            let list = UtteranceVoiceAnalysis.analyze(
                utterances: out.vecById.map { (utteranceId: $0.key, vec: $0.value) },
                ownUuid: uuid,
                means: out.means
            )
            out.verdicts = Dictionary(uniqueKeysWithValues: list.map { ($0.utteranceId, $0) })
            return out
        }.value
    }

    /// The "⋯" menu on each quote: other speakers ranked by voice closeness to reassign the
    /// line, plus mark-as-trash (right-click the row to edit its text).
    private func reassignMenu(for item: QuoteItem) -> some View {
        Menu {
            let cands = candidates(for: item.id)
            if cands.isEmpty {
                Text("No other speakers")
            } else {
                ForEach(cands, id: \.uuid) { c in
                    Button {
                        reassign(utteranceId: item.id, toUUID: c.uuid, label: c.name)
                    } label: {
                        Text(c.sim >= 0 ? "\(c.name)  ·  \(Int((c.sim * 100).rounded()))%" : c.name)
                    }
                }
            }
            Divider()
            Button(role: .destructive) {
                Task {
                    await UtteranceActionService.markTrash(utteranceId: Int64(item.id))
                    await loadAll()
                    onChange()
                }
            } label: {
                Label("Mark as trash", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle").foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Reassign this line to another speaker, or mark it as a transcription error")
    }

    /// Other speakers ranked by how close this utterance's voice is to each (best first). Falls back
    /// to an alphabetical list when the line has no stored voice vector yet.
    private func candidates(for utteranceId: Int) -> [(uuid: String, name: String, sim: Float)] {
        if let vec = vecById[utteranceId], !speakerMeans.isEmpty {
            return UtteranceVoiceAnalysis.rankCandidates(vec: vec, means: speakerMeans)
                .filter { $0.uuid != speaker.uuid }
                .prefix(8)
                .map { (uuid: $0.uuid, name: speakerNames[$0.uuid] ?? "Speaker", sim: $0.sim) }
        }
        return speakerNames
            .filter { $0.key != speaker.uuid }
            .sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
            .prefix(12)
            .map { (uuid: $0.key, name: $0.value, sim: Float(-1)) }
    }

    private func reassign(utteranceId: Int, toUUID: String, label: String) {
        Task {
            try? speakerRepo.reassignUtterance(utteranceId: Int64(utteranceId), toUUID: toUUID, label: label)
            await loadAll()
            onChange()
        }
    }

    private func flagText(_ v: UtteranceVoiceVerdict) -> String {
        if let other = v.nearestOtherUuid, v.nearestOtherSim > v.selfSim {
            return "Sounds more like \(speakerNames[other] ?? "someone else")"
        }
        return "Doesn't match \(speaker.displayName)'s voice"
    }

    // MARK: - Merge

    private var mergeSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Merge into \(speaker.displayName)").font(.headline)
                Spacer()
                Button("Done") { showMerge = false }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search people", text: $mergeSearch).textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(10)
            Text("Link that global voice profile to \(speaker.displayName) across every recording. Recording-local clusters and embeddings are preserved, and the link can be undone.")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12)
            List {
                ForEach(filteredMergeCandidates) { cand in
                    Button { mergeInto(cand) } label: {
                        HStack(spacing: 10) {
                            Circle().fill(cand.avatarColor).frame(width: 26, height: 26)
                                .overlay(Text(cand.initials).font(.system(size: 10, weight: .bold)).foregroundColor(.white))
                            Text(cand.displayName)
                            Spacer()
                            Text("\(cand.utteranceCount)").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
        .onAppear { loadMergeCandidates() }
    }

    private var filteredMergeCandidates: [SpeakerProfile] {
        let q = mergeSearch.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return mergeCandidates }
        return mergeCandidates.filter {
            $0.displayName.localizedCaseInsensitiveContains(q) || $0.uuid.localizedCaseInsensitiveContains(q)
        }
    }

    /// Targets for the "Move this into…" submenu — named people first (the usual case), then by talk time.
    private var moveTargets: [SpeakerProfile] {
        mergeCandidates.sorted {
            let an = ($0.name?.isEmpty == false), bn = ($1.name?.isEmpty == false)
            if an != bn { return an }
            return $0.totalDuration > $1.totalDuration
        }
    }

    private func loadMergeCandidates() {
        let uuid = speaker.uuid
        Task {
            let cands = await Task.detached(priority: .userInitiated) {
                ((try? GRDBSpeakerRepository().getSpeakersWithStats(includeEmpty: true)) ?? [])
                    .filter { $0.uuid != uuid }
            }.value
            mergeCandidates = cands
        }
    }

    /// Fold `other` into THIS speaker (this one stays primary, keeping its name/identity).
    private func mergeInto(_ other: SpeakerProfile) {
        showMerge = false
        runMerge(primary: speaker.uuid, secondary: other.uuid,
                 describe: "\(other.displayName) → \(speaker.displayName)")
    }

    // MARK: - Assign to an existing person (fold THIS voice into someone you already have)

    private var assignSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Assign \(speaker.displayName) to…").font(.headline)
                Spacer()
                Button("Cancel") { showAssign = false }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search people", text: $mergeSearch).textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(10)
            Text("Link this global voice profile across all recordings. The target keeps their name; every recording-local cluster remains intact so the link is reversible.")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12)
            List {
                ForEach(filteredMergeCandidates) { cand in
                    Button { assignToExisting(cand) } label: {
                        HStack(spacing: 10) {
                            Circle().fill(cand.avatarColor).frame(width: 26, height: 26)
                                .overlay(Text(cand.initials).font(.system(size: 10, weight: .bold)).foregroundColor(.white))
                            Text(cand.displayName)
                            Spacer()
                            Text("\(cand.utteranceCount)").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
        .onAppear { loadMergeCandidates() }
    }

    /// Fold THIS speaker into an existing person (that person stays primary and keeps their name).
    private func assignToExisting(_ target: SpeakerProfile) {
        showAssign = false
        runMerge(primary: target.uuid, secondary: speaker.uuid,
                 describe: "\(speaker.displayName) → \(target.displayName)")
    }

    /// Single funnel for both merge directions. Runs the merge, surfaces any failure (the old call sites
    /// used `try?`, so a broken merge — e.g. the missing `SpeakerMergeHistory` CodingKeys — failed silently),
    /// and on success triggers the parent reload, which reselects a valid person since `secondary` is gone.
    private func runMerge(primary: String, secondary: String, describe: String) {
        guard primary != secondary else { return }
        Task {
            do {
                try GRDBSpeakerRepository().mergeSpeakersWithHistory(
                    primaryUUID: primary, secondaryUUIDs: [secondary],
                    mergeHistoryRepo: SpeakerMergeHistoryRepository())
                VoxtralLogger.shared.info("[Merge] \(describe) (\(secondary) → \(primary))")
                onChange()
            } catch {
                VoxtralLogger.shared.error("[Merge] failed \(describe): \(error)")
                mergeError = "Couldn’t merge \(describe).\n\(error.localizedDescription)"
            }
        }
    }

    // MARK: - Identity suggestion

    /// "Might be <Name>" banner driven by the cross-meeting inference engine. Shown for voices that aren't
    /// user-named yet, so the suggestion appears right on the person's page.
    private func suggestionBanner(_ inf: IdentityInference) -> some View {
        let pct = Int((inf.score * 100).rounded())
        let confident = inf.confidence >= .likely
        let tierText: String = {
            switch inf.confidence {
            case .forced: return "Certain"
            case .strong: return "High"
            case .likely: return "Likely"
            case .weak:   return "Possible"
            }
        }()
        let accent: Color = confident ? .orange : .secondary
        return HStack(spacing: 12) {
            Image(systemName: "sparkles").foregroundColor(accent)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Might be \(inf.attendeeName)").font(.subheadline.weight(.semibold))
                    Text("\(tierText) · \(pct)%")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(accent.opacity(0.18))
                        .foregroundColor(accent)
                        .clipShape(Capsule())
                }
                Text(inf.reason).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Confirm") { confirmSuggestion(inf) }.buttonStyle(.borderedProminent).controlSize(.small)
            Button("Not them") { dismissSuggestion(inf) }.controlSize(.small)
        }
        .padding(12)
        .background((confident ? Color.orange : Color.gray).opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func confirmSuggestion(_ inf: IdentityInference) {
        IdentityInferenceCoordinator.shared.confirm(inf)
        editedName = inf.attendeeName
        linkedName = inf.attendeeName
        if let email = inf.attendeeEmail, !email.isEmpty { linkedEmail = email }
        suggestion = nil
        onChange()
    }

    private func dismissSuggestion(_ inf: IdentityInference) {
        IdentityInferenceCoordinator.shared.reject(speakerUuid: inf.speakerUuid, attendeeName: inf.attendeeName)
        suggestion = nil
        onChange()
    }

    // MARK: - AI identity guess (Gemma): reason over attendees + what the voice says

    @ViewBuilder
    private var aiIdentitySection: some View {
        if (speaker.name?.isEmpty ?? true), LLMTextService.shared.isAvailable {
            if let g = aiGuess {
                HStack(spacing: 12) {
                    Image(systemName: "wand.and.stars").foregroundColor(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("AI thinks: \(g.name)").font(.subheadline.weight(.semibold))
                            Text("\(g.confidence)%").font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.purple.opacity(0.18)).foregroundColor(.purple).clipShape(Capsule())
                        }
                        if !g.reason.isEmpty { Text(g.reason).font(.caption).foregroundColor(.secondary) }
                    }
                    Spacer()
                    Button("Confirm") { confirmAIGuess(g) }.buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Dismiss") { aiGuess = nil }.controlSize(.small)
                }
                .padding(12).background(Color.purple.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 10))
            } else if isGuessing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Asking AI who this is…").font(.callout).foregroundColor(.secondary)
                }
                .padding(.horizontal, 4)
            } else {
                HStack(spacing: 10) {
                    Button { guessWithAI() } label: { Label("Ask AI who this is", systemImage: "wand.and.stars") }
                        .buttonStyle(.bordered).controlSize(.small)
                    if let e = aiGuessError { Text(e).font(.caption).foregroundColor(.orange) }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func guessWithAI() {
        guard !isGuessing else { return }
        isGuessing = true
        aiGuessError = nil

        var seen = Set<String>()
        var candidates: [MeetingAttendee] = []
        for (m, _) in meetings {
            for a in m.parsedParticipants {
                let key = (a.email?.isEmpty == false ? a.email! : a.name).lowercased()
                if !key.isEmpty, seen.insert(key).inserted { candidates.append(a) }
            }
        }
        let quotes = allItems.sorted { $0.text.count > $1.text.count }.prefix(20).map(\.text)

        Task {
            do {
                let g = try await Self.runAIGuess(candidates: candidates, quotes: Array(quotes))
                await MainActor.run {
                    aiGuess = g
                    if g == nil { aiGuessError = "No clear match from the meeting attendees." }
                    isGuessing = false
                }
            } catch {
                await MainActor.run { aiGuessError = "Couldn't run the AI guess."; isGuessing = false }
            }
        }
    }

    private static func runAIGuess(candidates: [MeetingAttendee], quotes: [String]) async throws -> AIIdentityGuess? {
        guard !candidates.isEmpty, !quotes.isEmpty else { return nil }
        let candList = candidates.map { c -> String in
            let nm = c.name.trimmingCharacters(in: .whitespaces).isEmpty ? (c.email ?? "?") : c.name
            let em = (c.email?.isEmpty == false) ? " <\(c.email!)>" : ""
            return "- \(nm)\(em)"
        }.joined(separator: "\n")
        let quoteText = quotes.prefix(20).map { String($0.prefix(200)) }.joined(separator: "\n- ")
        let prompt = """
        You identify who a recurring meeting speaker is. Below are the people who attended this speaker's meetings, and a sample of things this speaker said. Decide which attendee is most likely THIS speaker (use self-introductions, how others address them, their role/topics). Reply with a SINGLE JSON object and nothing else:
        {"name": "<attendee name or email from the list>", "email": "<their email, or empty>", "confidence": <0-100>, "reason": "<one short sentence>"}
        If none plausibly match, reply {"name":"","email":"","confidence":0,"reason":"no clear match"}.

        Attendees:
        \(candList)

        What this speaker said:
        - \(quoteText)
        """
        let raw = try await LLMTextService.shared.generateText(prompt: prompt, maxTokens: 256)
        return AIIdentityGuess.parse(from: raw)
    }

    private func confirmAIGuess(_ g: AIIdentityGuess) {
        IdentityInferenceCoordinator.shared.confirm(speakerUuid: speaker.uuid, attendeeName: g.name, attendeeEmail: g.email)
        editedName = g.name
        if let e = g.email, !e.isEmpty { linkedEmail = e }
        aiGuess = nil
        onChange()
    }

    private func saveProfile() {
        let trimmed = editedName.trimmingCharacters(in: .whitespaces)
        let newName = trimmed.isEmpty ? nil : trimmed
        // Skip when nothing changed — otherwise merely opening an auto-named person and leaving would
        // silently promote their inferred name to manual (and drop the "inferred" badge).
        if newName == speaker.name && notes == (speaker.notes ?? "") { return }
        var updated = speaker
        updated.name = newName
        updated.notes = notes
        Task { await viewModel.updateSpeaker(updated); onChange() }
    }

    /// Debounced save so the list (and DB) reflect a rename ~0.6s after you stop typing — no need to
    /// press Return or navigate away.
    private func scheduleNameSave() {
        nameSaveTask?.cancel()
        nameSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            saveProfile()
        }
    }

    private func linkEmail(_ email: String) {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let name = editedName.trimmingCharacters(in: .whitespaces)
        let attendeeName = name.isEmpty ? speaker.displayName : name
        try? attendeeRepo.setMapping(speakerUuid: speaker.uuid, attendeeName: attendeeName, attendeeEmail: trimmed, source: .manual)
        // Promote the name onto the speaker too — the People list shows `speakers.name`, not the mapping, so
        // without this a name set while linking an email never appeared (it lived only in the mapping).
        if !name.isEmpty { try? speakerRepo.setName(uuid: speaker.uuid, name: attendeeName, source: "manual") }
        linkedEmail = trimmed
        linkedName = attendeeName
        onChange()
    }

    private func unlinkEmail() {
        try? attendeeRepo.removeMappingsForSpeaker(uuid: speaker.uuid)
        linkedEmail = nil
        linkedName = nil
        onChange()
    }

    /// Explicit owner confirmation is stronger than an inferred calendar-contact guess. Repair only
    /// inferred mappings here; a manually linked contact remains user-owned and must be changed explicitly.
    private func setAsOwner() {
        let owner = OwnerIdentityService.shared.currentOwner()
        OwnerIdentityService.shared.setOwnerVoice(speaker.uuid)

        if attendeeRepo.getAttendeeForSpeaker(uuid: speaker.uuid)?.source == .inferred {
            try? attendeeRepo.removeMappingsForSpeaker(uuid: speaker.uuid)
            linkedEmail = nil
            linkedName = nil

            if let email = owner.email?.trimmingCharacters(in: .whitespacesAndNewlines),
               !email.isEmpty {
                let enteredName = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
                let attendeeName = enteredName.isEmpty
                    ? (owner.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? speaker.displayName)
                    : enteredName
                try? attendeeRepo.setMapping(
                    speakerUuid: speaker.uuid,
                    attendeeName: attendeeName,
                    attendeeEmail: email,
                    source: .manual
                )
                linkedEmail = email
                linkedName = attendeeName
            }
        }

        isOwner = true
        onChange()
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "0s"
    }
}

// MARK: - AI identity guess result

private struct AIIdentityGuess: Equatable {
    let name: String
    let email: String?
    let confidence: Int
    let reason: String

    /// Tolerant: pull the first {...} block out of the model output and decode it.
    static func parse(from output: String) -> AIIdentityGuess? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let data = String(output[start...end]).data(using: .utf8) else { return nil }
        struct Raw: Decodable { let name: String?; let email: String?; let confidence: Int?; let reason: String? }
        guard let r = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        let name = (r.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let email = (r.email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return AIIdentityGuess(name: name, email: email.isEmpty ? nil : email,
                               confidence: max(0, min(100, r.confidence ?? 0)),
                               reason: (r.reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Card styling

private extension View {
    func cardStyle() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
    }
}
