import Foundation
import Combine

/// Service for performing semantic search on transcriptions
class SemanticSearchService: ObservableObject {
    static let shared = SemanticSearchService()
    private let logger = VoxtralLogger.shared
    
    // MARK: - Published Properties
    @Published var isSearching = false
    @Published var searchResults: [UtteranceSearchResult] = []
    @Published var searchError: String?
    
    // MARK: - Private Properties
    private let utteranceRepo = GRDBUtteranceRepository()
    private let recordingRepo = GRDBRecordingRepository()
    private let embeddingService = EmbeddingService.shared
    private let requestGate = SemanticSearchRequestGate()
    
    private init() {}
    
    // MARK: - Search Methods
    
    /// Perform semantic search with a query
    /// - Parameters:
    ///   - query: The search query text
    ///   - limit: Maximum number of results to return
    ///   - threshold: Similarity threshold (0-1, lower is more similar)
    func semanticSearch(
        query: String,
        limit: Int = 20,
        threshold: Float? = nil,
        loadModelIfNeeded: Bool = true,
        publishResults: Bool = true
    ) async throws -> [UtteranceSearchResult] {
        logger.info("[SemanticSearch] === SEMANTIC SEARCH START ===")
        logger.info("[SemanticSearch] Query length: \(query.count) chars")
        logger.info("[SemanticSearch] Limit: \(limit), Threshold: \(threshold?.description ?? "none")")
        
        // Ensure default model is loaded
        if loadModelIfNeeded && !EmbeddingModelManager.shared.isModelLoaded {
            logger.info("[SemanticSearch] Model not loaded, ensuring default model...")
            await EmbeddingModelManager.shared.ensureDefaultModel()
        }
        
        guard EmbeddingModelManager.shared.isModelLoaded else {
            logger.error("[SemanticSearch] === SEARCH FAILED ===")
            logger.error("[SemanticSearch] No embedding model loaded")
            logger.error("[SemanticSearch] Current model: \(EmbeddingModelManager.shared.currentModel)")
            throw SemanticSearchError.noEmbeddingModel
        }

        let requestId = UUID()
        guard await requestGate.acquire(requestId) else { return [] }
        defer { Task { await self.requestGate.release(requestId) } }
        
        logger.info("[SemanticSearch] Using model: \(EmbeddingModelManager.shared.currentModel)")
        
        await MainActor.run {
            isSearching = true
            searchError = nil
        }
        
        defer {
            Task { @MainActor in
                isSearching = false
            }
        }
        
        // Acquire GPU — highest non-dictation priority; preempts background/transcription work.
        // If the search task was cancelled while waiting, bail rather than embed the query without
        // the lock (which would reopen the concurrent-residency window).
        guard await GPUResourceManager.shared.acquire(.search) else {
            await MainActor.run { searchError = nil }
            return []
        }
        var holdsGPU = true

        do {
            // Generate embedding for query
            logger.info("[SemanticSearch] Generating embedding for query...")
            let embeddingStartTime = Date()
            let queryEmbedding = try await embeddingService.generateEmbedding(for: query)
            let embeddingTime = Date().timeIntervalSince(embeddingStartTime)
            logger.info("[SemanticSearch] Embedding generated in \(String(format: "%.2f", embeddingTime))s")
            logger.info("[SemanticSearch] Embedding size: \(queryEmbedding.count) bytes")

            // Release GPU before DB query (no GPU needed for vector search)
            await MainActor.run { GPUResourceManager.shared.release(.search) }
            holdsGPU = false

            // Search for similar utterances
            logger.info("[SemanticSearch] Searching for similar utterances...")
            let searchStartTime = Date()
            let results = try utteranceRepo.searchSimilar(
                embedding: queryEmbedding,
                limit: limit,
                threshold: threshold
            )
            let searchTime = Date().timeIntervalSince(searchStartTime)

            logger.info("[SemanticSearch] Search completed in \(String(format: "%.2f", searchTime))s")
            logger.info("[SemanticSearch] Found \(results.count) results")
            if !results.isEmpty {
                logger.info("[SemanticSearch] Best match distance: \(String(format: "%.4f", results[0].distance))")
                logger.info("[SemanticSearch] Worst match distance: \(String(format: "%.4f", results[results.count-1].distance))")
                logger.info("[SemanticSearch] Best match relevance: \(String(format: "%.2f", results[0].relevanceScore))")
            }
            logger.info("[SemanticSearch] === SEMANTIC SEARCH COMPLETE ===")

            if publishResults {
                await MainActor.run {
                    self.searchResults = results
                }
            }

            return results

        } catch {
            logger.error("[SemanticSearch] === SEARCH FAILED ===")
            logger.error("[SemanticSearch] Error: \(error)")
            logger.error("[SemanticSearch] Error type: \(type(of: error))")
            logger.error("[SemanticSearch] Query length: \(query.count) chars")
            logger.error("[SemanticSearch] Model: \(EmbeddingModelManager.shared.currentModel)")

            if holdsGPU {
                await MainActor.run { GPUResourceManager.shared.release(.search) }
            }

            let errorMessage = error.localizedDescription
            await MainActor.run {
                self.searchError = errorMessage
            }
            throw error
        }
    }
    
    /// Search within specific recordings
    func searchInRecordings(
        query: String,
        recordingIds: [Int64],
        limit: Int = 20,
        loadModelIfNeeded: Bool = true,
        speakerIds: [String] = [],
        forceANN: Bool = false,
        publishResults: Bool = true
    ) async throws -> GRDBUtteranceRepository.ScopedVectorSearchResult {
        logger.info("[SemanticSearch] === RECORDING SEARCH START ===")
        logger.info("[SemanticSearch] Query length: \(query.count) chars")
        logger.info("[SemanticSearch] Recording IDs: \(recordingIds)")
        logger.info("[SemanticSearch] Limit: \(limit)")
        
        // Ensure default model is loaded
        if loadModelIfNeeded && !EmbeddingModelManager.shared.isModelLoaded {
            logger.info("[SemanticSearch] Model not loaded, ensuring default model...")
            await EmbeddingModelManager.shared.ensureDefaultModel()
        }
        
        guard EmbeddingModelManager.shared.isModelLoaded else {
            logger.error("[SemanticSearch] === SEARCH FAILED ===")
            logger.error("[SemanticSearch] No embedding model loaded")
            throw SemanticSearchError.noEmbeddingModel
        }
        
        guard !recordingIds.isEmpty else {
            logger.error("[SemanticSearch] === SEARCH FAILED ===")
            logger.error("[SemanticSearch] No recording IDs specified")
            throw SemanticSearchError.noRecordingsSpecified
        }

        let requestId = UUID()
        guard await requestGate.acquire(requestId) else {
            return .init(
                results: [],
                complete: false,
                strategy: .ann,
                eligibleIndexedCount: 0,
                examinedCandidateCount: 0
            )
        }
        defer { Task { await self.requestGate.release(requestId) } }
        
        await MainActor.run {
            isSearching = true
            searchError = nil
        }
        
        defer {
            Task { @MainActor in
                isSearching = false
            }
        }

        // Scoped semantic search still generates an embedding, so it participates in
        // the same foreground GPU arbitration as global search.
        guard await GPUResourceManager.shared.acquire(.search) else {
            return .init(
                results: [],
                complete: false,
                strategy: .ann,
                eligibleIndexedCount: 0,
                examinedCandidateCount: 0
            )
        }
        var holdsGPU = true
        
        do {
            // Generate embedding for query
            logger.info("[SemanticSearch] Generating embedding for query...")
            let embeddingStartTime = Date()
            let queryEmbedding = try await embeddingService.generateEmbedding(for: query)
            let embeddingTime = Date().timeIntervalSince(embeddingStartTime)
            logger.info("[SemanticSearch] Embedding generated in \(String(format: "%.2f", embeddingTime))s")

            await MainActor.run { GPUResourceManager.shared.release(.search) }
            holdsGPU = false
            
            // Search within specified recordings
            logger.info("[SemanticSearch] Searching within \(recordingIds.count) recordings...")
            let searchStartTime = Date()
            try Task.checkCancellation()
            let searchResult = try utteranceRepo.searchSimilarInRecordingsDetailed(
                embedding: queryEmbedding,
                recordingIds: recordingIds,
                limit: limit,
                speakerIds: speakerIds,
                forceANN: forceANN
            )
            let searchTime = Date().timeIntervalSince(searchStartTime)
            
            logger.info("[SemanticSearch] Search completed in \(String(format: "%.2f", searchTime))s")
            logger.info("[SemanticSearch] Found \(searchResult.results.count) results | complete=\(searchResult.complete)")
            logger.info("[SemanticSearch] === RECORDING SEARCH COMPLETE ===")
            
            if publishResults {
                await MainActor.run {
                    self.searchResults = searchResult.results
                }
            }
            
            return searchResult
            
        } catch {
            logger.error("[SemanticSearch] === SEARCH FAILED ===")
            logger.error("[SemanticSearch] Error: \(error)")
            logger.error("[SemanticSearch] Query length: \(query.count) chars")
            logger.error("[SemanticSearch] Recording IDs: \(recordingIds)")

            if holdsGPU {
                await MainActor.run { GPUResourceManager.shared.release(.search) }
            }
            
            let errorMessage = error.localizedDescription
            await MainActor.run {
                self.searchError = errorMessage
            }
            throw error
        }
    }
    
    /// Traditional text search (fallback when embeddings not available)
    func textSearch(query: String, limit: Int = 20) throws -> [Utterance] {
        logger.info("[SemanticSearch] Text search | queryChars=\(query.count) limit=\(limit)")
        do {
            let results = try utteranceRepo.searchByText(query: query, limit: limit)
            logger.info("[SemanticSearch] Text search found \(results.count) results")
            return results
        } catch {
            logger.error("[SemanticSearch] Text search failed: \(error)")
            throw error
        }
    }
    
    /// Clear search results
    func clearResults() {
        searchResults = []
        searchError = nil
    }
    
    // MARK: - Helper Methods
    
    /// Check if semantic search is available
    var isSemanticSearchAvailable: Bool {
        EmbeddingModelManager.shared.isModelLoaded
    }
    
    /// Get search statistics
    func getSearchStats() throws -> SearchStats {
        logger.info("[SemanticSearch] Getting search statistics...")
        do {
            let totalUtterances = try utteranceRepo.count()
            let utterancesWithEmbeddings = try utteranceRepo.countWithEmbeddings()
            let totalRecordings = try recordingRepo.count()
            
            let stats = SearchStats(
                totalRecordings: totalRecordings,
                totalUtterances: totalUtterances,
                utterancesWithEmbeddings: utterancesWithEmbeddings,
                embeddingCoverage: Double(utterancesWithEmbeddings) / Double(max(totalUtterances, 1))
            )
            
            logger.info("[SemanticSearch] Stats: \(totalRecordings) recordings, \(totalUtterances) utterances, \(utterancesWithEmbeddings) with embeddings (\(stats.formattedCoverage))")
            return stats
        } catch {
            logger.error("[SemanticSearch] Failed to get stats: \(error)")
            throw error
        }
    }
    
    /// Process unprocessed recordings in the background
    func processUnindexedRecordings() async {
        logger.info("[SemanticSearch] Starting background processing of unindexed recordings...")
        let processor = UtteranceProcessor()
        await processor.processUnprocessedRecordings()
        logger.info("[SemanticSearch] Background processing complete")
    }
    
    /// Generate missing embeddings for existing utterances
    func generateMissingEmbeddings() async {
        logger.info("[SemanticSearch] Starting generation of missing embeddings...")
        let processor = UtteranceProcessor()
        await processor.generateMissingEmbeddings()
        logger.info("[SemanticSearch] Missing embeddings generation complete")
    }
}

actor SemanticSearchRequestGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var holder: UUID?
    private var waiters: [Waiter] = []
    private var cancelled: Set<UUID> = []

    func acquire(_ id: UUID) async -> Bool {
        if Task.isCancelled { return false }
        if holder == nil {
            holder = id
            return true
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if cancelled.remove(id) != nil || Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release(_ id: UUID) {
        guard holder == id else { return }
        holder = nil
        grantNext()
    }

    private func cancel(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: false)
        } else if holder != id {
            cancelled.insert(id)
        }
    }

    private func grantNext() {
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            if cancelled.remove(waiter.id) != nil {
                waiter.continuation.resume(returning: false)
                continue
            }
            holder = waiter.id
            waiter.continuation.resume(returning: true)
            return
        }
    }
}

// MARK: - Supporting Types

struct SearchStats {
    let totalRecordings: Int
    let totalUtterances: Int
    let utterancesWithEmbeddings: Int
    let embeddingCoverage: Double
    
    var formattedCoverage: String {
        String(format: "%.1f%%", embeddingCoverage * 100)
    }
}

enum SemanticSearchError: LocalizedError {
    case noEmbeddingModel
    case noRecordingsSpecified
    case searchFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .noEmbeddingModel:
            return "No embedding model loaded. Please download a model first."
        case .noRecordingsSpecified:
            return "No recordings specified for search"
        case .searchFailed(let reason):
            return "Search failed: \(reason)"
        }
    }
}
