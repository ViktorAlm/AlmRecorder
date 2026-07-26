import SwiftUI

struct SearchView: View {
    @StateObject private var searchService = SemanticSearchService.shared
    @StateObject private var modelManager = EmbeddingModelManager.shared
    @State private var searchQuery = ""
    @State private var searchMode: SearchMode = .semantic
    @State private var isSearching = false
    @State private var selectedResult: UtteranceSearchResult?
    @State private var showModelManager = false
    @State private var searchError: String?
    /// uuid → global name resolver for the (cross-recording) result cards. Refreshed per search so
    /// renamed/re-clustered speakers show their current global identity, never the per-recording label.
    @State private var speakerResolver = SpeakerNameResolver()
    
    enum SearchMode: String, CaseIterable {
        case semantic = "Semantic"
        case text = "Text"
        
        var icon: String {
            switch self {
            case .semantic: return "brain"
            case .text: return "magnifyingglass"
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
            } else if searchQuery.isEmpty && searchService.searchResults.isEmpty {
                emptyStateView
            } else if searchService.isSearching {
                searchingView
            } else {
                searchResultsView
            }
        }
        .sheet(isPresented: $showModelManager) {
            EmbeddingModelManagerView()
        }
        .task {
            // Check if we have embeddings available
            await checkEmbeddingStatus()
            // After the status check so the no-model semantic→text fallback has already run.
            consumePendingSearchHandoff()
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
                            Text("Model: \(modelManager.currentModel)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Text("No embedding model loaded")
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
                
                // Search mode picker
                Picker("Search Mode", selection: $searchMode) {
                    ForEach(SearchMode.allCases, id: \.self) { mode in
                        Label(mode.rawValue, systemImage: mode.icon)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .disabled(!modelManager.isModelLoaded && searchMode == .semantic)
            }
            
            // Search bar
            HStack(spacing: 12) {
                Image(systemName: searchMode.icon)
                    .font(.title3)
                    .foregroundColor(.secondary)
                
                TextField("Search for anything...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit {
                        performSearch()
                    }
                
                if !searchQuery.isEmpty {
                    Button(action: { searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                
                Button("Search") {
                    performSearch()
                }
                .buttonStyle(.borderedProminent)
                .disabled(searchQuery.isEmpty || (searchMode == .semantic && !modelManager.isModelLoaded))
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
            
            Text(searchMode == .semantic ? 
                 "Use natural language to find relevant content across all your recordings" :
                 "Search for exact text matches in your transcriptions")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            
            // Stats
            if let stats = try? searchService.getSearchStats() {
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(stats.totalRecordings) recordings", systemImage: "doc.text")
                    Label("\(stats.totalUtterances) utterances", systemImage: "text.quote")
                    if searchMode == .semantic {
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
                HStack {
                    Text("\(searchService.searchResults.count) results")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                
                ForEach(Array(searchService.searchResults.enumerated()), id: \.element.utterance.id) { index, result in
                    SearchResultCard(
                        result: result,
                        rank: index + 1,
                        isSelected: selectedResult?.utterance.id == result.utterance.id,
                        speakerResolver: speakerResolver
                    )
                    .onTapGesture {
                        selectedResult = result
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }
    
    private func performSearch() {
        guard !searchQuery.isEmpty else { return }

        // Clear previous error
        searchError = nil

        // Refresh the global name map so result cards render names/stable global labels, not the
        // per-recording "Speaker N" stored on each utterance.
        speakerResolver = SpeakerNameResolver(speakers: (try? GRDBSpeakerRepository().getAll()) ?? [])

        Task {
            if searchMode == .semantic {
                do {
                    _ = try await searchService.semanticSearch(
                        query: searchQuery,
                        limit: 50
                    )
                    await MainActor.run {
                        searchError = nil
                    }
                } catch {
                    print("Search error: \(error)")
                    await MainActor.run {
                        searchError = "Semantic search failed: \(error.localizedDescription)"
                    }
                }
            } else {
                // Text search
                do {
                    let utterances = try GRDBUtteranceRepository().searchByText(
                        query: searchQuery,
                        limit: 50
                    )
                    
                    print("[SearchView] Found \(utterances.count) utterances for query: '\(searchQuery)'")
                    
                    // Convert to search results format
                    var results: [UtteranceSearchResult] = []
                    for utterance in utterances {
                        if let recording = try? GRDBRecordingRepository().getById(utterance.recordingId) {
                            results.append(UtteranceSearchResult(
                                utterance: utterance,
                                recording: recording,
                                distance: 0,
                                relevanceScore: 1.0
                            ))
                        }
                    }
                    
                    print("[SearchView] Converted to \(results.count) search results")
                    
                    await MainActor.run {
                        searchService.searchResults = results
                        searchError = nil
                        if utterances.isEmpty {
                            searchError = "No results found for '\(searchQuery)'"
                        }
                    }
                } catch {
                    print("Text search error: \(error)")
                    await MainActor.run {
                        searchError = "Text search failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
    
    private func consumePendingSearchHandoff() {
        guard let handoff = AppState.shared.pendingSearch else { return }
        AppState.shared.pendingSearch = nil
        searchQuery = handoff.query
        if handoff.semantic {
            searchMode = modelManager.isModelLoaded ? .semantic : .text
        } else {
            searchMode = .text
        }
        performSearch()
    }

    private func checkEmbeddingStatus() async {
        if !modelManager.isModelLoaded {
            // Try to ensure default model
            await modelManager.ensureDefaultModel()
            
            // If still no model and semantic mode, switch to text
            if !modelManager.isModelLoaded && searchMode == .semantic {
                searchMode = .text
            }
        }
    }
}

// MARK: - Search Result Card

struct SearchResultCard: View {
    let result: UtteranceSearchResult
    let rank: Int
    let isSelected: Bool
    var speakerResolver: SpeakerNameResolver = SpeakerNameResolver()

    var body: some View {
        VStack(spacing: 0) {
            // Rank badge and metadata header
            HStack {
                // Rank badge
                Text("#\(rank)")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(rankColor(for: rank))
                    .clipShape(Circle())
                
                VStack(alignment: .leading, spacing: 2) {
                    Label(result.recording.fileName, systemImage: recordingSourceIcon(for: result.recording))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(result.recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.8))
                }
                
                Spacer()
                
                if result.relevanceScore > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.bar.fill")
                            .font(.caption2)
                        Text("\(Int(result.relevanceScore * 100))%")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundColor(scoreColor(for: result.relevanceScore))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(scoreColor(for: result.relevanceScore).opacity(0.15))
                    .cornerRadius(4)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            
            // Use TranscriptSegmentView for the utterance
            TranscriptSegmentView(
                utterance: result.utterance,
                displayMode: .card,
                audioPath: result.recording.filePath,
                currentSpeaker: nil,
                speakerResolver: speakerResolver
            )
        }
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
    }
}

// MARK: - Helper Functions

private func rankColor(for rank: Int) -> Color {
    switch rank {
    case 1: return .gold
    case 2: return .silver
    case 3: return .bronze
    default: return .gray
    }
}

private func scoreColor(for score: Float) -> Color {
    if score > 0.8 {
        return .green
    } else if score > 0.6 {
        return .orange
    } else {
        return .red
    }
}

private func recordingSourceIcon(for recording: Recording) -> String {
    switch recording.source {
    case .recording:
        return "mic.fill"
    case .imported:
        return "doc.fill"
    case .voiceMemos:
        return "mic.badge.plus"
    }
}

// (gold/silver/bronze now live in Views/Support/ColorPalette.swift)
