import XCTest
@testable import AlmRecorder

final class QueueCompletionHandoffTests: XCTestCase {
    private func job(named name: String) -> TranscriptionJob {
        TranscriptionJob(
            audioFilePath: "/tmp/\(name)",
            fileName: name,
            source: .voiceMemos
        )
    }

    func testTerminalCacheHandsCompletedJobToWaiterExactlyOnce() {
        var cache = TerminalTranscriptionJobCache(capacity: 2)
        var completed = job(named: "completed.m4a")
        completed.status = .completed
        completed.transcript = "words" // privacy:allow-synthetic
        completed.recordingId = 42
        cache.store(completed)

        XCTAssertEqual(cache.take(completed.id)?.recordingId, 42)
        XCTAssertNil(cache.take(completed.id))
    }

    func testTerminalCacheEvictsOldestSnapshotAtCapacity() {
        var cache = TerminalTranscriptionJobCache(capacity: 2)
        let first = job(named: "first.m4a")
        let second = job(named: "second.m4a")
        let third = job(named: "third.m4a")
        cache.store(first)
        cache.store(second)
        cache.store(third)

        XCTAssertNil(cache.take(first.id))
        XCTAssertEqual(cache.take(second.id)?.fileName, "second.m4a")
        XCTAssertEqual(cache.take(third.id)?.fileName, "third.m4a")
    }

    func testCompletedChunkProgressNeverRegressesBehindCheckpoint() {
        XCTAssertEqual(
            TranscriptionProgressAccounting.completedChunks(current: 1, reported: 0),
            1
        )
        XCTAssertEqual(
            TranscriptionProgressAccounting.completedChunks(current: 1, reported: 2),
            2
        )
    }

    @MainActor
    func testWaitResultPreservesCompletedRecordingIdentity() throws {
        var completed = job(named: "finished.m4a")
        completed.status = .completed
        completed.transcript = "finished words" // privacy:allow-synthetic
        completed.recordingId = 314

        let result = try XCTUnwrap(TranscriptionQueueManager.waitResult(for: completed))

        XCTAssertEqual(result.0.status, .completed)
        XCTAssertEqual(result.0.transcript, "finished words")
        XCTAssertEqual(result.2, 314)
    }
}
