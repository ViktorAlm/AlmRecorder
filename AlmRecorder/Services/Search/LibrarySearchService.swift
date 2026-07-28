import Foundation
import GRDB

enum LibrarySearchMode: String, CaseIterable, Sendable {
    case hybrid
    case keyword
    case semantic
    case ann
}

enum LibrarySearchField: String, Sendable {
    case transcript
    case title
}

enum LibrarySearchMatch: String, Sendable {
    case keyword
    case semantic
    case hybrid
}

struct LibrarySearchRequest: Sendable {
    let query: String
    var mode: LibrarySearchMode = .hybrid
    var limit: Int = 50
    var recordingIds: Set<Int64>? = nil
    var speakerIds: [String] = []
    var allowSemanticFallback = true
    var forceANN = false
}

struct LibrarySearchHit: Identifiable {
    let utterance: Utterance
    let recording: Recording
    let field: LibrarySearchField
    let semanticDistance: Float?
    let keywordTier: Int?
    let keywordRank: Int?
    let semanticRank: Int?
    let score: Double
    var contextBefore: [Utterance] = []
    var contextAfter: [Utterance] = []

    var id: String {
        if let utteranceId = utterance.id {
            return "utterance:\(utteranceId)"
        }
        return "recording:\(recording.id ?? 0):\(field.rawValue)"
    }

    var match: LibrarySearchMatch {
        switch (keywordRank, semanticRank) {
        case (.some, .some): return .hybrid
        case (.some, .none): return .keyword
        case (.none, .some): return .semantic
        case (.none, .none): return .keyword
        }
    }

    var matchLabel: String {
        if field == .title { return "Title" }
        switch match {
        case .hybrid: return "Words + meaning"
        case .keyword:
            return keywordTier == LibrarySearchRepository.phraseTier
                ? "Exact phrase"
                : "Keyword"
        case .semantic: return "Meaning"
        }
    }
}

struct LibrarySearchResponse {
    let query: String
    let requestedMode: LibrarySearchMode
    let actualMode: LibrarySearchMode
    let hits: [LibrarySearchHit]
    let semanticStrategy: GRDBUtteranceRepository.VectorSearchStrategy?
    let complete: Bool
    let semanticCandidatesExamined: Int
    let note: String?
}

enum LibrarySearchError: LocalizedError {
    case emptyQuery
    case invalidLimit

    var errorDescription: String? {
        switch self {
        case .emptyQuery:
            return "Enter something to search for."
        case .invalidLimit:
            return "Search result limit must be greater than zero."
        }
    }
}

enum LibrarySearchRanker {
    static let reciprocalRankConstant = 60

    static func keywordOnly(
        _ hits: [LibrarySearchHit],
        limit: Int
    ) -> [LibrarySearchHit] {
        Array(hits.prefix(limit).enumerated().map { index, hit in
            copy(
                hit,
                keywordRank: index + 1,
                semanticRank: nil,
                score: reciprocalScore(rank: index + 1)
            )
        })
    }

    static func semanticOnly(
        _ hits: [LibrarySearchHit],
        limit: Int
    ) -> [LibrarySearchHit] {
        Array(hits.prefix(limit).enumerated().map { index, hit in
            copy(
                hit,
                keywordRank: nil,
                semanticRank: index + 1,
                score: reciprocalScore(rank: index + 1)
            )
        })
    }

    static func fuse(
        keyword: [LibrarySearchHit],
        semantic: [LibrarySearchHit],
        limit: Int
    ) -> [LibrarySearchHit] {
        var byIdentity: [String: LibrarySearchHit] = [:]

        for (index, hit) in keyword.enumerated() {
            let rank = index + 1
            byIdentity[hit.id] = copy(
                hit,
                keywordRank: rank,
                semanticRank: nil,
                score: reciprocalScore(rank: rank)
            )
        }

        for (index, semanticHit) in semantic.enumerated() {
            let rank = index + 1
            let contribution = reciprocalScore(rank: rank)
            if let keywordHit = byIdentity[semanticHit.id] {
                byIdentity[semanticHit.id] = LibrarySearchHit(
                    utterance: semanticHit.utterance,
                    recording: semanticHit.recording,
                    field: keywordHit.field,
                    semanticDistance: semanticHit.semanticDistance,
                    keywordTier: keywordHit.keywordTier,
                    keywordRank: keywordHit.keywordRank,
                    semanticRank: rank,
                    score: keywordHit.score + contribution
                )
            } else {
                byIdentity[semanticHit.id] = copy(
                    semanticHit,
                    keywordRank: nil,
                    semanticRank: rank,
                    score: contribution
                )
            }
        }

        return Array(
            byIdentity.values.sorted(by: stableResultOrder).prefix(limit)
        )
    }

    private static func reciprocalScore(rank: Int) -> Double {
        1.0 / Double(reciprocalRankConstant + rank)
    }

    private static func stableResultOrder(
        _ lhs: LibrarySearchHit,
        _ rhs: LibrarySearchHit
    ) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        let lhsBestRank = min(lhs.keywordRank ?? .max, lhs.semanticRank ?? .max)
        let rhsBestRank = min(rhs.keywordRank ?? .max, rhs.semanticRank ?? .max)
        if lhsBestRank != rhsBestRank { return lhsBestRank < rhsBestRank }
        if lhs.recording.createdAt != rhs.recording.createdAt {
            return lhs.recording.createdAt > rhs.recording.createdAt
        }
        return lhs.id < rhs.id
    }

    private static func copy(
        _ hit: LibrarySearchHit,
        keywordRank: Int?,
        semanticRank: Int?,
        score: Double
    ) -> LibrarySearchHit {
        LibrarySearchHit(
            utterance: hit.utterance,
            recording: hit.recording,
            field: hit.field,
            semanticDistance: hit.semanticDistance,
            keywordTier: hit.keywordTier,
            keywordRank: keywordRank,
            semanticRank: semanticRank,
            score: score,
            contextBefore: hit.contextBefore,
            contextAfter: hit.contextAfter
        )
    }
}

final class LibrarySearchContextLoader {
    private let database: GRDBDatabaseManager

    init(database: GRDBDatabaseManager = .shared) {
        self.database = database
    }

    func addContext(
        to hits: [LibrarySearchHit],
        neighboringUtterances: Int = 1
    ) throws -> [LibrarySearchHit] {
        try database.read {
            try Self.addContext(
                to: hits,
                in: $0,
                neighboringUtterances: neighboringUtterances
            )
        }
    }

    static func addContext(
        to hits: [LibrarySearchHit],
        in db: Database,
        neighboringUtterances: Int = 1
    ) throws -> [LibrarySearchHit] {
        guard neighboringUtterances > 0 else { return hits }
        let targets = hits.compactMap { hit -> (String, Int64, Int)? in
            guard hit.field == .transcript, hit.utterance.id != nil else { return nil }
            return (hit.id, hit.utterance.recordingId, hit.utterance.utteranceIndex)
        }
        guard !targets.isEmpty else { return hits }

        let values = targets.map { _ in "(?, ?, ?)" }.joined(separator: ",")
        var arguments: [DatabaseValueConvertible?] = []
        for (identity, recordingId, utteranceIndex) in targets {
            arguments.append(identity)
            arguments.append(recordingId)
            arguments.append(utteranceIndex)
        }
        arguments.append(neighboringUtterances)
        arguments.append(neighboringUtterances)

        let rows = try Row.fetchAll(
            db,
            sql: """
                WITH search_targets(result_identity, recording_id, utterance_index) AS (
                    VALUES \(values)
                )
                SELECT
                    search_targets.result_identity AS search_result_identity,
                    search_targets.utterance_index AS search_target_index,
                    u.*
                FROM search_targets
                JOIN utterances u
                  ON u.recording_id = search_targets.recording_id
                 AND u.utterance_index BETWEEN
                     search_targets.utterance_index - ?
                     AND search_targets.utterance_index + ?
                WHERE u.is_hidden = 0
                  AND u.utterance_index != search_targets.utterance_index
                ORDER BY search_targets.result_identity, u.utterance_index
            """,
            arguments: StatementArguments(arguments)
        )

        var neighboringRows: [String: [(targetIndex: Int, utterance: Utterance)]] = [:]
        for row in rows {
            guard let identity: String = row["search_result_identity"],
                  let targetIndex: Int = row["search_target_index"],
                  let utterance = Utterance(row: row) else { continue }
            neighboringRows[identity, default: []].append((targetIndex, utterance))
        }

        return hits.map { hit in
            guard let rows = neighboringRows[hit.id] else { return hit }
            var enriched = hit
            enriched.contextBefore = rows
                .filter { $0.utterance.utteranceIndex < $0.targetIndex }
                .map(\.utterance)
            enriched.contextAfter = rows
                .filter { $0.utterance.utteranceIndex > $0.targetIndex }
                .map(\.utterance)
            return enriched
        }
    }
}

protocol LibraryKeywordSearching {
    func keywordCandidates(
        query: String,
        recordingIds: Set<Int64>?,
        speakerIds: [String],
        limit: Int
    ) throws -> [LibrarySearchHit]
}

final class LibrarySearchRepository: LibraryKeywordSearching {
    static let phraseTier = 3
    static let allTokensTier = 2
    static let relaxedTier = 1

    private struct LexicalCandidate {
        let hit: LibrarySearchHit
        let bm25: Double
    }

    private let database: GRDBDatabaseManager

    init(database: GRDBDatabaseManager = .shared) {
        self.database = database
    }

    func keywordCandidates(
        query: String,
        recordingIds: Set<Int64>?,
        speakerIds: [String],
        limit: Int
    ) throws -> [LibrarySearchHit] {
        try database.read {
            try Self.keywordCandidates(
                in: $0,
                query: query,
                recordingIds: recordingIds,
                speakerIds: speakerIds,
                limit: limit
            )
        }
    }

    static func keywordCandidates(
        in db: Database,
        query: String,
        recordingIds: Set<Int64>?,
        speakerIds: [String],
        limit: Int
    ) throws -> [LibrarySearchHit] {
        guard limit > 0 else { return [] }
        if let recordingIds, recordingIds.isEmpty { return [] }

        guard let phrase = FTS5Pattern(matchingPhrase: query),
              let allTokens = FTS5Pattern(matchingAllTokensIn: query) else {
            throw LibrarySearchError.emptyQuery
        }

        var byIdentity: [String: LexicalCandidate] = [:]

        func merge(_ candidates: [LexicalCandidate]) {
            for candidate in candidates {
                if let current = byIdentity[candidate.hit.id] {
                    let currentTier = current.hit.keywordTier ?? 0
                    let newTier = candidate.hit.keywordTier ?? 0
                    if newTier > currentTier
                        || (newTier == currentTier && candidate.bm25 < current.bm25) {
                        byIdentity[candidate.hit.id] = candidate
                    }
                } else {
                    byIdentity[candidate.hit.id] = candidate
                }
            }
        }

        merge(try Self.transcriptCandidates(
            db,
            pattern: phrase,
            tier: Self.phraseTier,
            recordingIds: recordingIds,
            speakerIds: speakerIds,
            limit: limit
        ))
        if speakerIds.isEmpty {
            merge(try Self.titleCandidates(
                db,
                pattern: phrase,
                tier: Self.phraseTier,
                recordingIds: recordingIds,
                limit: limit
            ))
        }
        merge(try Self.transcriptCandidates(
            db,
            pattern: allTokens,
            tier: Self.allTokensTier,
            recordingIds: recordingIds,
            speakerIds: speakerIds,
            limit: limit
        ))
        if speakerIds.isEmpty {
            merge(try Self.titleCandidates(
                db,
                pattern: allTokens,
                tier: Self.allTokensTier,
                recordingIds: recordingIds,
                limit: limit
            ))
        }

        if byIdentity.count < limit,
           let anyTokens = FTS5Pattern(matchingAnyTokenIn: query) {
            merge(try Self.transcriptCandidates(
                db,
                pattern: anyTokens,
                tier: Self.relaxedTier,
                recordingIds: recordingIds,
                speakerIds: speakerIds,
                limit: limit
            ))
            if speakerIds.isEmpty {
                merge(try Self.titleCandidates(
                    db,
                    pattern: anyTokens,
                    tier: Self.relaxedTier,
                    recordingIds: recordingIds,
                    limit: limit
                ))
            }
        }

        return Array(
            byIdentity.values.sorted(by: Self.lexicalOrder).prefix(limit).map(\.hit)
        )
    }

    private static func transcriptCandidates(
        _ db: Database,
        pattern: FTS5Pattern,
        tier: Int,
        recordingIds: Set<Int64>?,
        speakerIds: [String],
        limit: Int
    ) throws -> [LexicalCandidate] {
        let recordingIdList = recordingIds.map { Array($0).sorted() }
        let recordingClause = recordingIdList.map {
            "AND u.recording_id IN (\($0.map { _ in "?" }.joined(separator: ",")))"
        } ?? ""
        let speakerClause = speakerIds.isEmpty
            ? ""
            : "AND u.speaker_uuid IN (\(speakerIds.map { _ in "?" }.joined(separator: ",")))"

        var arguments: [DatabaseValueConvertible?] = [pattern]
        arguments.append(contentsOf: recordingIdList ?? [])
        arguments.append(contentsOf: speakerIds)
        arguments.append(limit)

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT
                    u.*,
                    r.id AS search_r_id, r.title AS search_r_title,
                    r.file_name AS search_r_file_name, r.file_path AS search_r_file_path,
                    r.duration AS search_r_duration, r.language AS search_r_language,
                    r.created_at AS search_r_created_at,
                    r.transcribed_at AS search_r_transcribed_at,
                    r.source AS search_r_source,
                    r.full_transcript AS search_r_full_transcript,
                    r.external_id AS search_r_external_id,
                    r.updated_at AS search_r_updated_at,
                    bm25(utterance_fts) AS search_fts_rank
                FROM utterance_fts
                JOIN utterances u ON u.id = utterance_fts.rowid
                JOIN recordings r ON r.id = u.recording_id
                WHERE utterance_fts MATCH ?
                  AND u.is_hidden = 0
                  \(recordingClause)
                  \(speakerClause)
                ORDER BY search_fts_rank, r.created_at DESC, u.utterance_index
                LIMIT ?
            """,
            arguments: StatementArguments(arguments)
        )

        return rows.compactMap { row in
            guard let utterance = Utterance(row: row),
                  let recording = Self.recording(from: row) else { return nil }
            let rank: Double = row["search_fts_rank"] ?? 0
            return LexicalCandidate(
                hit: LibrarySearchHit(
                    utterance: utterance,
                    recording: recording,
                    field: .transcript,
                    semanticDistance: nil,
                    keywordTier: tier,
                    keywordRank: nil,
                    semanticRank: nil,
                    score: 0
                ),
                bm25: rank
            )
        }
    }

    private static func titleCandidates(
        _ db: Database,
        pattern: FTS5Pattern,
        tier: Int,
        recordingIds: Set<Int64>?,
        limit: Int
    ) throws -> [LexicalCandidate] {
        let recordingIdList = recordingIds.map { Array($0).sorted() }
        let recordingClause = recordingIdList.map {
            "AND r.id IN (\($0.map { _ in "?" }.joined(separator: ",")))"
        } ?? ""
        var arguments: [DatabaseValueConvertible?] = [pattern]
        arguments.append(contentsOf: recordingIdList ?? [])
        arguments.append(limit)

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT r.*, bm25(recording_title_fts, 5.0) AS search_fts_rank
                FROM recording_title_fts
                JOIN recordings r ON r.id = recording_title_fts.rowid
                WHERE recording_title_fts MATCH ?
                  \(recordingClause)
                ORDER BY search_fts_rank, r.created_at DESC
                LIMIT ?
            """,
            arguments: StatementArguments(arguments)
        )

        return rows.compactMap { row in
            guard let recording = Recording(row: row), let recordingId = recording.id else {
                return nil
            }
            let rank: Double = row["search_fts_rank"] ?? 0
            let titleUtterance = Utterance(
                id: nil,
                recordingId: recordingId,
                utteranceIndex: -1,
                startTime: 0,
                endTime: 0,
                speaker: nil,
                speakerUuid: nil,
                text: recording.title,
                confidence: nil
            )
            return LexicalCandidate(
                hit: LibrarySearchHit(
                    utterance: titleUtterance,
                    recording: recording,
                    field: .title,
                    semanticDistance: nil,
                    keywordTier: tier,
                    keywordRank: nil,
                    semanticRank: nil,
                    score: 0
                ),
                bm25: rank
            )
        }
    }

    private static func lexicalOrder(_ lhs: LexicalCandidate, _ rhs: LexicalCandidate) -> Bool {
        let lhsTier = lhs.hit.keywordTier ?? 0
        let rhsTier = rhs.hit.keywordTier ?? 0
        if lhsTier != rhsTier { return lhsTier > rhsTier }
        if lhs.hit.field != rhs.hit.field { return lhs.hit.field == .title }
        if lhs.bm25 != rhs.bm25 { return lhs.bm25 < rhs.bm25 }
        if lhs.hit.recording.createdAt != rhs.hit.recording.createdAt {
            return lhs.hit.recording.createdAt > rhs.hit.recording.createdAt
        }
        return lhs.hit.id < rhs.hit.id
    }

    private static func recording(from row: Row) -> Recording? {
        let id: Int64? = row["search_r_id"]
        guard let id else { return nil }
        let title: String = row["search_r_title"] ?? ""
        let fileName: String = row["search_r_file_name"] ?? ""
        let filePath: String? = row["search_r_file_path"]
        let duration: TimeInterval? = row["search_r_duration"]
        let language: String? = row["search_r_language"]
        let createdAt: Date = row["search_r_created_at"] ?? Date()
        let transcribedAt: Date? = row["search_r_transcribed_at"]
        let sourceRaw: String = row["search_r_source"] ?? "recording"
        let fullTranscript: String? = row["search_r_full_transcript"]

        var recording = Recording(
            id: id,
            title: title,
            fileName: fileName,
            filePath: filePath,
            duration: duration,
            language: language,
            createdAt: createdAt,
            transcribedAt: transcribedAt,
            source: Recording.RecordingSource(rawValue: sourceRaw) ?? .recording,
            fullTranscript: fullTranscript,
            metadata: nil
        )
        recording.externalId = row["search_r_external_id"]
        recording.updatedAt = row["search_r_updated_at"]
        return recording
    }
}

struct LibrarySemanticCandidateResponse {
    let hits: [LibrarySearchHit]
    let strategy: GRDBUtteranceRepository.VectorSearchStrategy
    let complete: Bool
    let examined: Int
}

protocol LibrarySemanticSearching {
    var isReady: Bool { get }

    func candidates(
        query: String,
        recordingIds: Set<Int64>?,
        speakerIds: [String],
        limit: Int,
        forceANN: Bool
    ) async throws -> LibrarySemanticCandidateResponse
}

final class DefaultLibrarySemanticSearchProvider: LibrarySemanticSearching {
    private let semanticSearch: SemanticSearchService

    init(semanticSearch: SemanticSearchService = .shared) {
        self.semanticSearch = semanticSearch
    }

    var isReady: Bool {
        EmbeddingModelManager.shared.isModelLoaded
    }

    func candidates(
        query: String,
        recordingIds: Set<Int64>?,
        speakerIds: [String],
        limit: Int,
        forceANN: Bool
    ) async throws -> LibrarySemanticCandidateResponse {
        let result: (
            hits: [UtteranceSearchResult],
            strategy: GRDBUtteranceRepository.VectorSearchStrategy,
            complete: Bool,
            examined: Int
        )
        if let recordingIds {
            let detailed = try await semanticSearch.searchInRecordings(
                query: query,
                recordingIds: Array(recordingIds),
                limit: limit,
                loadModelIfNeeded: false,
                speakerIds: speakerIds,
                forceANN: forceANN,
                publishResults: false
            )
            result = (
                detailed.results,
                detailed.strategy,
                detailed.complete,
                detailed.examinedCandidateCount
            )
        } else {
            let hits = try await semanticSearch.semanticSearch(
                query: query,
                limit: limit,
                loadModelIfNeeded: false,
                publishResults: false
            )
            result = (hits, .ann, true, limit)
        }

        return LibrarySemanticCandidateResponse(
            hits: result.hits.map {
                LibrarySearchHit(
                    utterance: $0.utterance,
                    recording: $0.recording,
                    field: .transcript,
                    semanticDistance: $0.distance,
                    keywordTier: nil,
                    keywordRank: nil,
                    semanticRank: nil,
                    score: 0
                )
            },
            strategy: result.strategy,
            complete: result.complete,
            examined: result.examined
        )
    }
}

final class LibrarySearchService {
    static let shared = LibrarySearchService()

    private let repository: any LibraryKeywordSearching
    private let semanticSearch: any LibrarySemanticSearching

    init(
        repository: any LibraryKeywordSearching = LibrarySearchRepository(),
        semanticSearch: any LibrarySemanticSearching = DefaultLibrarySemanticSearchProvider()
    ) {
        self.repository = repository
        self.semanticSearch = semanticSearch
    }

    func search(_ request: LibrarySearchRequest) async throws -> LibrarySearchResponse {
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw LibrarySearchError.emptyQuery }
        guard request.limit > 0 else { throw LibrarySearchError.invalidLimit }
        try Task.checkCancellation()

        let candidateLimit = min(max(request.limit * 3, 50), 500)
        let needsKeyword = request.mode == .keyword || request.mode == .hybrid
        let needsSemantic = request.mode == .semantic
            || request.mode == .ann
            || request.mode == .hybrid

        let keyword = needsKeyword
            ? try repository.keywordCandidates(
                query: query,
                recordingIds: request.recordingIds,
                speakerIds: request.speakerIds,
                limit: candidateLimit
            )
            : []

        guard needsSemantic else {
            return LibrarySearchResponse(
                query: query,
                requestedMode: request.mode,
                actualMode: .keyword,
                hits: LibrarySearchRanker.keywordOnly(keyword, limit: request.limit),
                semanticStrategy: nil,
                complete: true,
                semanticCandidatesExamined: 0,
                note: nil
            )
        }

        guard semanticSearch.isReady else {
            if request.mode == .hybrid, request.allowSemanticFallback {
                return LibrarySearchResponse(
                    query: query,
                    requestedMode: request.mode,
                    actualMode: .keyword,
                    hits: LibrarySearchRanker.keywordOnly(keyword, limit: request.limit),
                    semanticStrategy: nil,
                    complete: true,
                    semanticCandidatesExamined: 0,
                    note: "Showing keyword results because semantic search is not ready."
                )
            }
            throw SemanticSearchError.noEmbeddingModel
        }

        do {
            let semanticResult = try await semanticSearch.candidates(
                query: query,
                recordingIds: request.recordingIds,
                speakerIds: request.speakerIds,
                limit: candidateLimit,
                forceANN: request.forceANN || request.mode == .ann
            )
            try Task.checkCancellation()

            let hits: [LibrarySearchHit]
            switch request.mode {
            case .hybrid:
                hits = LibrarySearchRanker.fuse(
                    keyword: keyword,
                    semantic: semanticResult.hits,
                    limit: request.limit
                )
            case .semantic, .ann:
                hits = LibrarySearchRanker.semanticOnly(
                    semanticResult.hits,
                    limit: request.limit
                )
            case .keyword:
                hits = LibrarySearchRanker.keywordOnly(keyword, limit: request.limit)
            }

            return LibrarySearchResponse(
                query: query,
                requestedMode: request.mode,
                actualMode: request.mode,
                hits: hits,
                semanticStrategy: semanticResult.strategy,
                complete: semanticResult.complete,
                semanticCandidatesExamined: semanticResult.examined,
                note: nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if request.mode == .hybrid, request.allowSemanticFallback {
                return LibrarySearchResponse(
                    query: query,
                    requestedMode: request.mode,
                    actualMode: .keyword,
                    hits: LibrarySearchRanker.keywordOnly(keyword, limit: request.limit),
                    semanticStrategy: nil,
                    complete: true,
                    semanticCandidatesExamined: 0,
                    note: "Showing keyword results because semantic search was unavailable."
                )
            }
            throw error
        }
    }
}
