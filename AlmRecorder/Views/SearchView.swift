import SwiftUI

struct SearchView: View {
    @StateObject private var modelManager = EmbeddingModelManager.shared
    @State private var searchQuery = ""
    @State private var searchMode: SearchMode = .best
    @State private var isSearching = false
    @State private var searchResults: [LibrarySearchHit] = []
    @State private var conversationResults: [LibraryConversationSearchResult] = []
    @State private var activeQuery = ""
    @State private var resultLayout: ResultLayout = .conversations
    @State private var hasSearched = false
    @State private var selectedResult: LibrarySearchHit?
    @State private var presentedResult: LibrarySearchHit?
    @State private var showModelManager = false
    @State private var searchError: String?
    @State private var searchNotice: String?
    @State private var searchTask: Task<Void, Never>?
    /// uuid → global name resolver for the (cross-recording) result cards. Refreshed per search so
    /// renamed/re-clustered speakers show their current global identity, never the per-recording label.
    @State private var speakerResolver = SpeakerNameResolver()
    
    enum SearchMode: String, CaseIterable {
        case best = "Best"
        case keyword = "Keyword"
        case semantic = "Semantic"
        
        var icon: String {
            switch self {
            case .best: return "sparkle.magnifyingglass"
            case .keyword: return "text.magnifyingglass"
            case .semantic: return "brain"
            }
        }

        var libraryMode: LibrarySearchMode {
            switch self {
            case .best: return .hybrid
            case .keyword: return .keyword
            case .semantic: return .semantic
            }
        }
    }

    enum ResultLayout: String, CaseIterable {
        case conversations = "Conversations"
        case moments = "Moments"

        var icon: String {
            switch self {
            case .conversations: return "rectangle.stack"
            case .moments: return "text.quote"
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Search Header
            searchHeader
            
            Divider()
            
            // Content
            if let error = searchError {
                // Error view
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 50))
                        .foregroundColor(.orange)
                    
                    Text("Search Error")
                        .font(.headline)
                    
                    Text(error)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Button("Try Again") {
                        searchError = nil
                        performSearch()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if isSearching {
                searchingView
            } else if !searchResults.isEmpty {
                searchResultsView
            } else if hasSearched {
                noResultsView
            } else {
                emptyStateView
            }
        }
        .sheet(isPresented: $showModelManager) {
            EmbeddingModelManagerView()
        }
        .sheet(item: $presentedResult) { result in
            RecordingDetailSheet(
                recording: result.recording,
                initialUtteranceId: result.field == .transcript ? result.utterance.id : nil,
                initialTimestamp: result.field == .transcript ? result.utterance.startTime : nil,
                initialSearchQuery: activeQuery
            )
        }
        .task {
            consumePendingSearchHandoff()
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }
    
    private var searchHeader: some View {
        VStack(spacing: 16) {
            // Title and model status
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Search Transcriptions")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    HStack(spacing: 8) {
                        if modelManager.isModelLoaded {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                            Text("Best search uses keywords and meaning")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Image(systemName: "checkmark.circle")
                                .foregroundColor(.secondary)
                                .font(.caption)
                            Text("Keyword search ready · semantic model unavailable")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Button("Manage") {
                            showModelManager = true
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
                
                Spacer()
                
                Menu {
                    Picker("Match", selection: $searchMode) {
                        ForEach(SearchMode.allCases, id: \.self) { mode in
                            Label(mode.rawValue, systemImage: mode.icon)
                                .tag(mode)
                        }
                    }
                } label: {
                    Label("Match: \(searchMode.rawValue)", systemImage: searchMode.icon)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Choose how matching moments are retrieved")
            }
            
            // Search bar
            HStack(spacing: 12) {
                Image(systemName: searchMode.icon)
                    .font(.title3)
                    .foregroundColor(.secondary)
                
                TextField("What do you remember talking about?", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit {
                        performSearch()
                    }
                
                if !searchQuery.isEmpty {
                    Button(action: clearSearch) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                
                Button("Search") {
                    performSearch()
                }
                .buttonStyle(.borderedProminent)
                .disabled(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
        }
        .padding()
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 80))
                .foregroundStyle(.secondary)
            
            Text("Search Your Transcriptions")
                .font(.title2)
                .fontWeight(.medium)
            
            Text(searchModeDescription)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            
            // Stats
            if let stats = try? SemanticSearchService.shared.getSearchStats() {
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(stats.totalRecordings) recordings", systemImage: "doc.text")
                    Label("\(stats.totalUtterances) utterances", systemImage: "text.quote")
                    if searchMode != .keyword {
                        Label("\(stats.utterancesWithEmbeddings) indexed (\(stats.formattedCoverage))",
                              systemImage: "brain")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            
            // Embedding Queue Status
            EmbeddingQueueStatusView()
                .frame(maxWidth: 400)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    private var searchingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            
            Text("Searching...")
                .font(.title3)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var searchResultsView: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                if let searchNotice {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                        Text(searchNotice)
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                HStack {
                    Text(resultSummary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()

                    Picker("Result view", selection: $resultLayout) {
                        ForEach(ResultLayout.allCases, id: \.self) { layout in
                            Label(layout.rawValue, systemImage: layout.icon)
                                .tag(layout)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                if resultLayout == .conversations {
                    ForEach(conversationResults) { conversation in
                        ConversationSearchResultCard(
                            result: conversation,
                            query: activeQuery,
                            speakerResolver: speakerResolver,
                            onOpen: openResult
                        )
                    }
                } else {
                    ForEach(Array(momentResults.enumerated()), id: \.element.id) { index, result in
                        SearchResultCard(
                            result: result,
                            rank: index + 1,
                            isSelected: selectedResult?.id == result.id,
                            query: activeQuery,
                            speakerResolver: speakerResolver,
                            onOpen: { openResult(result) }
                        )
                    }

                    if !recordingResults.isEmpty {
                        HStack {
                            Text("Matching recordings")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.top, momentResults.isEmpty ? 0 : 10)
                        .padding(.bottom, 4)

                        ForEach(Array(recordingResults.enumerated()), id: \.element.id) { index, result in
                            SearchResultCard(
                                result: result,
                                rank: momentResults.count + index + 1,
                                isSelected: selectedResult?.id == result.id,
                                query: activeQuery,
                                speakerResolver: speakerResolver,
                                onOpen: { openResult(result) }
                            )
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var momentResults: [LibrarySearchHit] {
        Array(searchResults.filter { $0.field == .transcript }.prefix(50))
    }

    private var recordingResults: [LibrarySearchHit] {
        searchResults.filter { $0.field == .title }
    }

    private var resultSummary: String {
        if resultLayout == .conversations {
            return "\(conversationResults.count) conversation\(conversationResults.count == 1 ? "" : "s")"
        }
        return "\(momentResults.count) moment\(momentResults.count == 1 ? "" : "s")"
    }

    private func openResult(_ result: LibrarySearchHit) {
        selectedResult = result
        presentedResult = result
    }
    
    private func performSearch() {
        let submittedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submittedQuery.isEmpty else { return }

        searchTask?.cancel()
        searchError = nil
        searchNotice = nil
        isSearching = true
        hasSearched = true

        // Refresh the global name map so result cards render names/stable global labels, not the
        // per-recording "Speaker N" stored on each utterance.
        speakerResolver = SpeakerNameResolver(speakers: (try? GRDBSpeakerRepository().getAll()) ?? [])

        let requestedMode = searchMode.libraryMode
        searchTask = Task {
            do {
                let response = try await LibrarySearchService.shared.search(
                    LibrarySearchRequest(
                        query: submittedQuery,
                        mode: requestedMode,
                        limit: 200,
                        allowSemanticFallback: requestedMode == .hybrid
                    )
                )
                guard !Task.isCancelled else { return }
                let contextualHits = (try? LibrarySearchContextLoader().addContext(
                    to: response.hits,
                    neighboringUtterances: 1
                )) ?? response.hits
                let groupedResults = LibrarySearchGrouper.group(
                    contextualHits,
                    limit: 20
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    searchResults = contextualHits
                    conversationResults = groupedResults
                    activeQuery = response.query
                    searchNotice = response.note
                    searchError = nil
                    isSearching = false
                }
            } catch is CancellationError {
                // A newer query owns the visible search state.
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    searchResults = []
                    searchNotice = nil
                    searchError = error.localizedDescription
                    isSearching = false
                }
            }
        }
    }
    
    private func consumePendingSearchHandoff() {
        guard let handoff = AppState.shared.pendingSearch else { return }
        AppState.shared.pendingSearch = nil
        searchQuery = handoff.query
        if handoff.semantic {
            searchMode = .best
        } else {
            searchMode = .keyword
        }
        performSearch()
    }

    private var searchModeDescription: String {
        switch searchMode {
        case .best:
            return "Find exact words and conceptually related moments across all recordings"
        case .keyword:
            return "Find names, phrases, numbers, and exact words in titles and transcripts"
        case .semantic:
            return "Use natural language to find conceptually related transcript moments"
        }
    }

    private var noResultsView: some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("No results")
                .font(.title3.weight(.medium))
            Text("Try fewer words or switch to Best search.")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func clearSearch() {
        searchTask?.cancel()
        searchQuery = ""
        searchResults = []
        conversationResults = []
        activeQuery = ""
        searchError = nil
        searchNotice = nil
        isSearching = false
        hasSearched = false
        selectedResult = nil
    }
}

// MARK: - Conversation Result Card

struct ConversationSearchResultCard: View {
    let result: LibraryConversationSearchResult
    let query: String
    var speakerResolver: SpeakerNameResolver = SpeakerNameResolver()
    let onOpen: (LibrarySearchHit) -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            conversationHeader

            if let bestMoment = result.moments.first {
                expandedMoment(bestMoment.hit)

                if result.moments.count > 1 {
                    additionalMoments
                }
            } else if let titleHit = result.titleHit {
                titleOnlyMatch(titleHit)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(result.recording.title)
    }

    private var conversationHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: result.recording.source.icon)
                .font(.headline)
                .foregroundStyle(result.recording.source.color)
                .frame(width: 32, height: 32)
                .background(result.recording.source.color.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 5) {
                Text(result.recording.title)
                    .font(.headline)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if !participantSummary.isEmpty {
                        Label(participantSummary, systemImage: "person.2")
                    }
                    Label(result.recording.formattedDuration, systemImage: "clock")
                    Text(result.recording.formattedDate)
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 5) {
                if let bestHit = result.bestHit {
                    Text(bestHit.matchLabel)
                        .font(.caption.weight(.medium))
                        .foregroundColor(matchColor(for: bestHit))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(matchColor(for: bestHit).opacity(0.15))
                        .clipShape(Capsule())
                }

                if !result.moments.isEmpty {
                    Text("\(result.moments.count) relevant moment\(result.moments.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func expandedMoment(_ hit: LibrarySearchHit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(hit.contextBefore.enumerated()), id: \.offset) { _, utterance in
                contextLine(utterance, hit: hit, isMatch: false)
            }

            contextLine(hit.utterance, hit: hit, isMatch: true)

            ForEach(Array(hit.contextAfter.enumerated()), id: \.offset) { _, utterance in
                contextLine(utterance, hit: hit, isMatch: false)
            }

            HStack {
                Spacer()
                Button {
                    onOpen(hit)
                } label: {
                    Label(
                        "Open at \(timestamp(hit.utterance.startTime))",
                        systemImage: "arrow.up.right.square"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Open the transcript and position playback at this moment")
            }
        }
    }

    private var additionalMoments: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                Label(
                    isExpanded
                        ? "Hide other moments"
                        : "Show \(visibleAdditionalMoments.count) more moment\(visibleAdditionalMoments.count == 1 ? "" : "s")",
                    systemImage: isExpanded ? "chevron.up" : "chevron.down"
                )
                .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)

            if isExpanded {
                ForEach(visibleAdditionalMoments) { moment in
                    compactMoment(moment.hit)
                }

                if result.moments.count > visibleAdditionalMoments.count + 1 {
                    Text("More matches are available in the Moments view.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.leading, 8)
                }
            }
        }
        .padding(.top, 2)
    }

    private func compactMoment(_ hit: LibrarySearchHit) -> some View {
        Button {
            onOpen(hit)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(timestamp(hit.utterance.startTime))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 52, alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {
                    if let speaker = speakerResolver.displayName(for: hit.utterance) {
                        Text(speaker)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                    Text(SearchTextHighlighter.attributedString(
                        hit.utterance.text,
                        query: query
                    ))
                        .font(.callout)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(8)
            .background(Color.primary.opacity(0.025))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Open at \(timestamp(hit.utterance.startTime))")
    }

    private func titleOnlyMatch(_ hit: LibrarySearchHit) -> some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("The recording title matches your search")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(SearchTextHighlighter.attributedString(
                    result.recording.title,
                    query: query
                ))
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
            }

            Spacer()

            Button {
                onOpen(hit)
            } label: {
                Label("Open recording", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func contextLine(
        _ utterance: Utterance,
        hit: LibrarySearchHit,
        isMatch: Bool
    ) -> some View {
        let color = matchColor(for: hit)
        return HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isMatch ? color : Color.secondary.opacity(0.18))
                .frame(width: isMatch ? 4 : 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if let speaker = speakerResolver.displayName(for: utterance) {
                        Text(speaker)
                            .font(.caption.weight(isMatch ? .semibold : .regular))
                    }
                    Text(utterance.formattedTimeRange)
                        .font(.system(.caption, design: .monospaced))
                }
                .foregroundColor(isMatch ? .primary : .secondary)

                Text(SearchTextHighlighter.attributedString(
                    utterance.text,
                    query: query,
                    highlightColor: isMatch
                        ? NSColor.systemYellow.withAlphaComponent(0.36)
                        : NSColor.systemYellow.withAlphaComponent(0.2)
                ))
                    .font(isMatch ? .body : .callout)
                    .foregroundColor(isMatch ? .primary : .secondary)
                    .textSelection(.enabled)
                    .lineSpacing(2)
            }
        }
        .padding(isMatch ? 10 : 4)
        .background(isMatch ? color.opacity(0.07) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var visibleAdditionalMoments: [LibrarySearchMoment] {
        Array(result.moments.dropFirst().prefix(5))
    }

    private var participantSummary: String {
        var seen: Set<String> = []
        var names: [String] = []
        for moment in result.moments {
            guard let name = speakerResolver.displayName(for: moment.hit.utterance),
                  seen.insert(name).inserted else { continue }
            names.append(name)
        }
        guard !names.isEmpty else { return "" }
        let visible = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? "\(visible) +\(names.count - 3)" : visible
    }

    private func matchColor(for hit: LibrarySearchHit) -> Color {
        switch hit.match {
        case .hybrid: return .purple
        case .keyword: return .blue
        case .semantic: return .teal
        }
    }
}

// MARK: - Search Result Card

struct SearchResultCard: View {
    let result: LibrarySearchHit
    let rank: Int
    let isSelected: Bool
    let query: String
    var speakerResolver: SpeakerNameResolver = SpeakerNameResolver()
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(result.recording.title)
                        .font(.headline)
                        .lineLimit(2)

                    HStack(spacing: 10) {
                        Label(
                            result.recording.source.displayName,
                            systemImage: result.recording.source.icon
                        )
                        Label(result.recording.formattedDuration, systemImage: "clock")
                        Text(result.recording.formattedDate)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                Spacer()

                Text(result.matchLabel)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(matchColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(matchColor.opacity(0.15))
                    .cornerRadius(4)
            }

            if result.field == .title {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Title match")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                    Text(SearchTextHighlighter.attributedString(
                        result.recording.title,
                        query: query
                    ))
                        .font(.body)
                        .textSelection(.enabled)
                }
            } else {
                transcriptContext
            }

            HStack {
                Spacer()

                Button(action: onOpen) {
                    Label(openLabel, systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(openHelp)
            }
        }
        .padding(14)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.1)
                : Color(nsColor: .controlBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Result \(rank), \(result.recording.title)")
        .accessibilityAction(named: openLabel, onOpen)
    }

    private var transcriptContext: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(result.contextBefore.enumerated()), id: \.offset) { _, utterance in
                contextLine(utterance, isMatch: false)
            }

            contextLine(result.utterance, isMatch: true)

            ForEach(Array(result.contextAfter.enumerated()), id: \.offset) { _, utterance in
                contextLine(utterance, isMatch: false)
            }
        }
    }

    private func contextLine(_ utterance: Utterance, isMatch: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isMatch ? matchColor : Color.secondary.opacity(0.18))
                .frame(width: isMatch ? 4 : 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if let speaker = speakerResolver.displayName(for: utterance) {
                        Text(speaker)
                            .font(.caption.weight(isMatch ? .semibold : .regular))
                    }
                    Text(utterance.formattedTimeRange)
                        .font(.system(.caption, design: .monospaced))
                }
                .foregroundColor(isMatch ? .primary : .secondary)

                Text(SearchTextHighlighter.attributedString(
                    utterance.text,
                    query: query,
                    highlightColor: isMatch
                        ? NSColor.systemYellow.withAlphaComponent(0.36)
                        : NSColor.systemYellow.withAlphaComponent(0.2)
                ))
                    .font(isMatch ? .body : .callout)
                    .foregroundColor(isMatch ? .primary : .secondary)
                    .textSelection(.enabled)
                    .lineSpacing(2)
            }
        }
        .padding(isMatch ? 10 : 4)
        .background(isMatch ? matchColor.opacity(0.07) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var openLabel: String {
        result.field == .transcript
            ? "Open at \(timestamp(result.utterance.startTime))"
            : "Open recording"
    }

    private var openHelp: String {
        result.field == .transcript
            ? "Open the transcript and position playback at this moment"
            : "Open the full recording"
    }

    private var matchColor: Color {
        switch result.match {
        case .hybrid: return .purple
        case .keyword: return .blue
        case .semantic: return .teal
        }
    }
}

// MARK: - Helper Functions

private func timestamp(_ time: TimeInterval) -> String {
    guard time.isFinite, time >= 0 else { return "0:00" }
    let total = Int(time)
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let seconds = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
        : String(format: "%d:%02d", minutes, seconds)
}
