import XCTest
import GRDB
@testable import AlmRecorder

final class LibrarySearchRepositoryTests: XCTestCase {
    func testPhraseRanksAboveAllTokensAndHiddenRowsStayExcluded() throws {
        let queue = try fixtureQueue()

        let results = try queue.read {
            try LibrarySearchRepository.keywordCandidates(
                in: $0,
                query: "customer launch",
                recordingIds: nil,
                speakerIds: [],
                limit: 20
            )
        }

        XCTAssertEqual(results.first?.utterance.id, 10)
        XCTAssertEqual(results.first?.keywordTier, LibrarySearchRepository.phraseTier)
        XCTAssertEqual(results.first?.matchLabel, "Exact phrase")
        XCTAssertTrue(results.contains { $0.utterance.id == 11 })
        XCTAssertFalse(results.contains { $0.utterance.id == 12 })
    }

    func testAnyTokenRelaxationFillsOtherwiseEmptyKeywordLane() throws {
        let queue = try fixtureQueue()

        let results = try queue.read {
            try LibrarySearchRepository.keywordCandidates(
                in: $0,
                query: "customer nonexistent",
                recordingIds: nil,
                speakerIds: [],
                limit: 20
            )
        }

        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy {
            $0.keywordTier == LibrarySearchRepository.relaxedTier
        })
    }

    func testRecordingAndSpeakerFiltersApplyBeforeRanking() throws {
        let queue = try fixtureQueue()

        let results = try queue.read {
            try LibrarySearchRepository.keywordCandidates(
                in: $0,
                query: "launch",
                recordingIds: [2],
                speakerIds: ["speaker-b"],
                limit: 20
            )
        }

        XCTAssertEqual(Set(results.compactMap(\.utterance.id)), [11])
        XCTAssertTrue(results.allSatisfy { $0.recording.id == 2 })
    }

    func testContextLoaderAddsVisibleNeighboringUtterances() throws {
        let queue = try fixtureQueue()

        let results = try queue.read { db in
            let matches = try LibrarySearchRepository.keywordCandidates(
                in: db,
                query: "follow up",
                recordingIds: [2],
                speakerIds: [],
                limit: 20
            )
            return try LibrarySearchContextLoader.addContext(
                to: matches,
                in: db,
                neighboringUtterances: 2
            )
        }

        let target = try XCTUnwrap(results.first { $0.utterance.id == 13 })
        XCTAssertEqual(target.contextBefore.compactMap(\.id), [11])
        XCTAssertFalse(target.contextBefore.contains { $0.id == 12 })
        XCTAssertTrue(target.contextAfter.isEmpty)
    }

    private func fixtureQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE recordings (
                    id INTEGER PRIMARY KEY,
                    title TEXT NOT NULL,
                    file_name TEXT NOT NULL,
                    file_path TEXT,
                    duration DOUBLE,
                    language TEXT,
                    created_at DATETIME NOT NULL,
                    transcribed_at DATETIME,
                    source TEXT NOT NULL,
                    full_transcript TEXT,
                    external_id TEXT,
                    updated_at DATETIME
                );
                CREATE TABLE utterances (
                    id INTEGER PRIMARY KEY,
                    recording_id INTEGER NOT NULL,
                    utterance_index INTEGER NOT NULL,
                    start_time DOUBLE NOT NULL,
                    end_time DOUBLE NOT NULL,
                    speaker TEXT,
                    speaker_uuid TEXT,
                    text TEXT NOT NULL,
                    confidence DOUBLE,
                    has_embedding INTEGER NOT NULL DEFAULT 0,
                    is_hidden INTEGER NOT NULL DEFAULT 0
                );
            """)
            try db.execute(
                sql: """
                    INSERT INTO recordings(
                        id, title, file_name, created_at, source, external_id, updated_at
                    ) VALUES
                        (1, 'Launch Planning', 'launch.m4a', ?, 'recording', 'rec_1', ?),
                        (2, 'Weekly Sync', 'sync.m4a', ?, 'recording', 'rec_2', ?)
                """,
                arguments: [
                    Date(timeIntervalSince1970: 100),
                    Date(timeIntervalSince1970: 100),
                    Date(timeIntervalSince1970: 200),
                    Date(timeIntervalSince1970: 200)
                ]
            )
            try db.execute(sql: """
                INSERT INTO utterances(
                    id, recording_id, utterance_index, start_time, end_time,
                    speaker, speaker_uuid, text, is_hidden
                ) VALUES
                    (10, 1, 0, 0, 3, 'A', 'speaker-a', 'customer launch date confirmed', 0),
                    (11, 2, 0, 0, 3, 'B', 'speaker-b', 'launch update for the customer', 0),
                    (12, 2, 1, 3, 6, 'B', 'speaker-b', 'secret customer launch issue', 1),
                    (13, 2, 2, 6, 9, 'A', 'speaker-a', 'customer follow up', 0)
            """)
            try MCPFTSIndex.install(in: db)
        }
        return queue
    }
}

final class LibrarySearchRankerTests: XCTestCase {
    func testConsensusHitOutranksSingleLaneHits() {
        let keyword = [hit(1), hit(2)]
        let semantic = [hit(2), hit(3)]

        let results = LibrarySearchRanker.fuse(
            keyword: keyword,
            semantic: semantic,
            limit: 10
        )

        XCTAssertEqual(results.map(\.id), ["utterance:2", "utterance:1", "utterance:3"])
        XCTAssertEqual(results.first?.match, .hybrid)
        XCTAssertEqual(results.first?.keywordRank, 2)
        XCTAssertEqual(results.first?.semanticRank, 1)
    }

    func testKeywordOnlyPreservesOrderAndUsesRankScores() {
        let results = LibrarySearchRanker.keywordOnly(
            [hit(4, keywordTier: LibrarySearchRepository.phraseTier), hit(5)],
            limit: 10
        )

        XCTAssertEqual(results.map(\.id), ["utterance:4", "utterance:5"])
        XCTAssertEqual(results.map(\.keywordRank), [1, 2])
        XCTAssertEqual(results.first?.matchLabel, "Exact phrase")
        XCTAssertGreaterThan(results[0].score, results[1].score)
    }

    func testTitleHitHasStableRecordingIdentity() {
        let result = hit(6, field: .title, utteranceId: nil)
        XCTAssertEqual(result.id, "recording:6:title")
        XCTAssertEqual(result.matchLabel, "Title")
    }

    private func hit(
        _ value: Int64,
        field: LibrarySearchField = .transcript,
        utteranceId: Int64? = nil,
        keywordTier: Int? = nil
    ) -> LibrarySearchHit {
        let recording = Recording(
            id: value,
            title: "Recording \(value)",
            fileName: "recording-\(value).m4a",
            filePath: nil,
            duration: 60,
            language: "en",
            createdAt: Date(timeIntervalSince1970: TimeInterval(value)),
            transcribedAt: nil,
            source: .recording,
            fullTranscript: nil,
            metadata: nil
        )
        let utterance = Utterance(
            id: utteranceId ?? (field == .transcript ? value : nil),
            recordingId: value,
            utteranceIndex: 0,
            startTime: 0,
            endTime: 1,
            speaker: nil,
            speakerUuid: nil,
            text: "Result \(value)",
            confidence: nil
        )
        return LibrarySearchHit(
            utterance: utterance,
            recording: recording,
            field: field,
            semanticDistance: nil,
            keywordTier: keywordTier,
            keywordRank: nil,
            semanticRank: nil,
            score: 0
        )
    }
}

final class LibrarySearchGrouperTests: XCTestCase {
    func testNearbyHitsCollapseIntoOneMomentUsingStrongestAnchor() {
        let results = LibrarySearchGrouper.group(
            [
                hit(recordingId: 1, utteranceId: 10, index: 1, start: 10, score: 0.02),
                hit(recordingId: 1, utteranceId: 11, index: 2, start: 15, score: 0.03),
                hit(recordingId: 1, utteranceId: 12, index: 10, start: 100, score: 0.01)
            ],
            limit: 10
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].moments.count, 2)
        XCTAssertEqual(results[0].moments[0].hit.utterance.id, 11)
        XCTAssertEqual(
            Set(results[0].moments[0].matchingHits.compactMap(\.utterance.id)),
            [10, 11]
        )
    }

    func testMissingTimestampsDoNotCollapseDistantUtterances() {
        let results = LibrarySearchGrouper.group(
            [
                hit(recordingId: 1, utteranceId: 10, index: 1, start: 0, score: 0.03),
                hit(recordingId: 1, utteranceId: 11, index: 50, start: 0, score: 0.02)
            ],
            limit: 10
        )

        XCTAssertEqual(results.first?.moments.count, 2)
    }

    func testBestMomentDominatesButIndependentEvidenceAddsBoundedSupport() {
        let results = LibrarySearchGrouper.group(
            [
                hit(recordingId: 1, utteranceId: 10, index: 1, start: 0, score: 0.030),
                hit(recordingId: 2, utteranceId: 20, index: 1, start: 0, score: 0.028),
                hit(recordingId: 2, utteranceId: 21, index: 20, start: 120, score: 0.009),
                hit(recordingId: 3, utteranceId: 30, index: 1, start: 0, score: 0.027)
            ],
            limit: 10
        )

        XCTAssertEqual(results.compactMap(\.recording.id), [1, 2, 3])
        XCTAssertEqual(results[1].score, 0.0298, accuracy: 0.000_001)
    }

    func testTitleBonusIsBoundedAndTitleOnlyGroupsComeLast() {
        let results = LibrarySearchGrouper.group(
            [
                hit(recordingId: 1, utteranceId: 10, index: 1, start: 0, score: 0.02),
                hit(
                    recordingId: 1,
                    utteranceId: nil,
                    index: -1,
                    start: 0,
                    score: 0.50,
                    field: .title
                ),
                hit(
                    recordingId: 2,
                    utteranceId: nil,
                    index: -1,
                    start: 0,
                    score: 0.80,
                    field: .title
                )
            ],
            limit: 10
        )

        XCTAssertEqual(results.compactMap(\.recording.id), [1, 2])
        XCTAssertEqual(results[0].score, 0.022, accuracy: 0.000_001)
        XCTAssertTrue(results[1].isTitleOnly)
    }

    private func hit(
        recordingId: Int64,
        utteranceId: Int64?,
        index: Int,
        start: TimeInterval,
        score: Double,
        field: LibrarySearchField = .transcript
    ) -> LibrarySearchHit {
        let recording = Recording(
            id: recordingId,
            title: "Conversation \(recordingId)",
            fileName: "conversation-\(recordingId).m4a",
            filePath: nil,
            duration: 600,
            language: "en",
            createdAt: Date(timeIntervalSince1970: TimeInterval(recordingId)),
            transcribedAt: nil,
            source: .recording,
            fullTranscript: nil,
            metadata: nil
        )
        let utterance = Utterance(
            id: utteranceId,
            recordingId: recordingId,
            utteranceIndex: index,
            startTime: start,
            endTime: start + 5,
            speaker: "Speaker",
            speakerUuid: "speaker-\(recordingId)",
            text: field == .title ? recording.title : "Matching moment \(utteranceId ?? 0)",
            confidence: nil
        )
        return LibrarySearchHit(
            utterance: utterance,
            recording: recording,
            field: field,
            semanticDistance: nil,
            keywordTier: LibrarySearchRepository.allTokensTier,
            keywordRank: 1,
            semanticRank: nil,
            score: score
        )
    }
}

final class LibrarySearchServiceTests: XCTestCase {
    func testHybridFallsBackToKeywordWhenSemanticIsNotReady() async throws {
        let keywordHit = makeHit(1)
        let service = LibrarySearchService(
            repository: StubKeywordSearch(hits: [keywordHit]),
            semanticSearch: StubSemanticSearch(isReady: false)
        )

        let response = try await service.search(
            LibrarySearchRequest(query: "launch plan", mode: .hybrid, limit: 10)
        )

        XCTAssertEqual(response.actualMode, .keyword)
        XCTAssertEqual(response.hits.map(\.id), ["utterance:1"])
        XCTAssertNotNil(response.note)
    }

    func testExplicitSemanticRequiresReadyModel() async {
        let service = LibrarySearchService(
            repository: StubKeywordSearch(hits: []),
            semanticSearch: StubSemanticSearch(isReady: false)
        )

        do {
            _ = try await service.search(
                LibrarySearchRequest(query: "launch plan", mode: .semantic, limit: 10)
            )
            XCTFail("Expected semantic search to require a model")
        } catch SemanticSearchError.noEmbeddingModel {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHybridFallsBackWhenSemanticExecutionFails() async throws {
        let service = LibrarySearchService(
            repository: StubKeywordSearch(hits: [makeHit(7)]),
            semanticSearch: StubSemanticSearch(
                isReady: true,
                error: StubError.failed
            )
        )

        let response = try await service.search(
            LibrarySearchRequest(query: "launch plan", mode: .hybrid, limit: 10)
        )

        XCTAssertEqual(response.actualMode, .keyword)
        XCTAssertEqual(response.hits.map(\.id), ["utterance:7"])
    }

    func testHybridCombinesInjectedCandidateLanes() async throws {
        let shared = makeHit(2)
        let service = LibrarySearchService(
            repository: StubKeywordSearch(hits: [makeHit(1), shared]),
            semanticSearch: StubSemanticSearch(
                isReady: true,
                hits: [shared, makeHit(3)]
            )
        )

        let response = try await service.search(
            LibrarySearchRequest(query: "launch plan", mode: .hybrid, limit: 10)
        )

        XCTAssertEqual(response.actualMode, .hybrid)
        XCTAssertEqual(response.hits.first?.id, "utterance:2")
        XCTAssertEqual(response.hits.first?.match, .hybrid)
    }

    private func makeHit(_ value: Int64) -> LibrarySearchHit {
        let recording = Recording(
            id: value,
            title: "Recording \(value)",
            fileName: "recording-\(value).m4a",
            filePath: nil,
            duration: 60,
            language: "en",
            createdAt: Date(timeIntervalSince1970: TimeInterval(value)),
            transcribedAt: nil,
            source: .recording,
            fullTranscript: nil,
            metadata: nil
        )
        let utterance = Utterance(
            id: value,
            recordingId: value,
            utteranceIndex: 0,
            startTime: 0,
            endTime: 1,
            speaker: nil,
            speakerUuid: nil,
            text: "Result \(value)",
            confidence: nil
        )
        return LibrarySearchHit(
            utterance: utterance,
            recording: recording,
            field: .transcript,
            semanticDistance: nil,
            keywordTier: LibrarySearchRepository.allTokensTier,
            keywordRank: nil,
            semanticRank: nil,
            score: 0
        )
    }
}

private struct StubKeywordSearch: LibraryKeywordSearching {
    let hits: [LibrarySearchHit]

    func keywordCandidates(
        query: String,
        recordingIds: Set<Int64>?,
        speakerIds: [String],
        limit: Int
    ) throws -> [LibrarySearchHit] {
        Array(hits.prefix(limit))
    }
}

private struct StubSemanticSearch: LibrarySemanticSearching {
    let isReady: Bool
    var hits: [LibrarySearchHit] = []
    var error: Error?

    func candidates(
        query: String,
        recordingIds: Set<Int64>?,
        speakerIds: [String],
        limit: Int,
        forceANN: Bool
    ) async throws -> LibrarySemanticCandidateResponse {
        if let error { throw error }
        return LibrarySemanticCandidateResponse(
            hits: Array(hits.prefix(limit)),
            strategy: .ann,
            complete: true,
            examined: hits.count
        )
    }
}

private enum StubError: Error {
    case failed
}
