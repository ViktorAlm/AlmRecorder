import XCTest
import GRDB
@testable import AlmRecorder

final class SpeakerBackfillPersistenceSafetyTests: XCTestCase {
    private func makeQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE recordings (
                    id INTEGER PRIMARY KEY,
                    title TEXT NOT NULL DEFAULT 'Recording',
                    file_path TEXT,
                    created_at DATETIME NOT NULL,
                    speaker_review_status TEXT,
                    speaker_reviewed_at DATETIME
                )
                """)
            try db.execute(sql: """
                CREATE TABLE speakers (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    uuid TEXT NOT NULL UNIQUE,
                    name TEXT,
                    name_source TEXT,
                    embedding BLOB NOT NULL,
                    embedding_count INTEGER NOT NULL DEFAULT 1,
                    total_duration REAL NOT NULL DEFAULT 0,
                    utterance_count INTEGER NOT NULL DEFAULT 0,
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL,
                    last_seen_at DATETIME NOT NULL,
                    confidence REAL NOT NULL DEFAULT 1,
                    notes TEXT,
                    source_recording_id INTEGER
                )
                """)
            try db.execute(sql: """
                CREATE TABLE utterances (
                    id INTEGER PRIMARY KEY,
                    recording_id INTEGER NOT NULL REFERENCES recordings(id),
                    speaker TEXT,
                    speaker_uuid TEXT REFERENCES speakers(uuid),
                    start_time REAL NOT NULL,
                    end_time REAL NOT NULL,
                    text TEXT NOT NULL DEFAULT '',
                    voice_embedding_quality REAL,
                    speaker_assignment_source TEXT NOT NULL DEFAULT 'model',
                    speaker_reviewed_at DATETIME,
                    is_hidden INTEGER NOT NULL DEFAULT 0
                )
                """)
            try db.execute(sql: """
                CREATE TABLE utterance_voice_embeddings (
                    utterance_id INTEGER PRIMARY KEY REFERENCES utterances(id),
                    embedding BLOB NOT NULL,
                    dimensions INTEGER NOT NULL,
                    created_at DATETIME NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE app_settings (
                    key TEXT PRIMARY KEY,
                    value TEXT
                )
                """)
        }
        return queue
    }

    private func unitVector(axis: Int) -> [Float] {
        var vector = [Float](repeating: 0, count: SpeakerEmbeddingPolicy.dimension)
        vector[axis] = 1
        return vector
    }

    func testBackfillIsIdempotentAndPreservesTranscriptAndAssignment() throws {
        let queue = try makeQueue()
        try queue.write { db in
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let originalSpeakerEmbedding = unitVector(axis: 0)
            try db.execute(
                sql: "INSERT INTO recordings(id, title, created_at) VALUES (1, 'Call', ?)",
                arguments: [now]
            )
            try db.execute(
                sql: """
                    INSERT INTO speakers(
                        uuid, name, name_source, embedding,
                        created_at, updated_at, last_seen_at
                    ) VALUES ('known-person', 'Known Person', 'manual', ?, ?, ?, ?)
                    """,
                arguments: [
                    VoiceEmbeddingStore.floatsToData(originalSpeakerEmbedding),
                    now, now, now
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO utterances(
                        id, recording_id, speaker, speaker_uuid,
                        start_time, end_time, text, speaker_assignment_source
                    ) VALUES (1, 1, 'Speaker 1', 'known-person', 0, 10,
                              'This transcript must remain untouched.', 'manual')
                    """
            )
            try GlobalSpeakerIdentityStore.migrate(db)

            let clusterID = try XCTUnwrap(Int64.fetchOne(
                db,
                sql: "SELECT id FROM speaker_local_clusters WHERE recording_id = 1"
            ))
            let assignmentBefore = try XCTUnwrap(Row.fetchOne(
                db,
                sql: """
                    SELECT speaker_uuid, state, source
                    FROM speaker_global_assignments
                    WHERE local_cluster_id = ?
                    """,
                arguments: [clusterID]
            ))
            XCTAssertNil(try Data.fetchOne(
                db,
                sql: "SELECT embedding FROM speaker_local_clusters WHERE id = ?",
                arguments: [clusterID]
            ))

            let recoveredEmbedding = unitVector(axis: 1)
            let affected = try GlobalSpeakerIdentityStore.backfillAcousticEvidence(
                db,
                recordingId: 1,
                evidence: [
                    SpeakerIdentityCluster(
                        label: "fresh-speaker",
                        embedding: recoveredEmbedding,
                        spans: [.init(start: 0, end: 9.5)],
                        confidence: 0.91,
                        cohesion: 0.83,
                        embeddingTurnCount: 4
                    )
                ]
            )
            XCTAssertEqual(affected, 1)

            let stored = try XCTUnwrap(Data.fetchOne(
                db,
                sql: "SELECT embedding FROM speaker_local_clusters WHERE id = ?",
                arguments: [clusterID]
            ))
            XCTAssertEqual(VoiceEmbeddingStore.dataToFloats(stored), recoveredEmbedding)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT text FROM utterances WHERE id = 1"),
                "This transcript must remain untouched."
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT speaker_uuid FROM utterances WHERE id = 1"),
                "known-person"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT name FROM speakers WHERE uuid = 'known-person'"),
                "Known Person"
            )

            let assignmentAfter = try XCTUnwrap(Row.fetchOne(
                db,
                sql: """
                    SELECT speaker_uuid, state, source
                    FROM speaker_global_assignments
                    WHERE local_cluster_id = ?
                    """,
                arguments: [clusterID]
            ))
            XCTAssertEqual(assignmentAfter["speaker_uuid"] as String?, assignmentBefore["speaker_uuid"] as String?)
            XCTAssertEqual(assignmentAfter["state"] as String?, assignmentBefore["state"] as String?)
            XCTAssertEqual(assignmentAfter["source"] as String?, assignmentBefore["source"] as String?)

            let secondPass = try GlobalSpeakerIdentityStore.backfillAcousticEvidence(
                db,
                recordingId: 1,
                evidence: [
                    SpeakerIdentityCluster(
                        label: "different-retry",
                        embedding: unitVector(axis: 2),
                        spans: [.init(start: 0, end: 10)]
                    )
                ]
            )
            XCTAssertEqual(secondPass, 0)
            let storedAfterRetry = try XCTUnwrap(Data.fetchOne(
                db,
                sql: "SELECT embedding FROM speaker_local_clusters WHERE id = ?",
                arguments: [clusterID]
            ))
            XCTAssertEqual(VoiceEmbeddingStore.dataToFloats(storedAfterRetry), recoveredEmbedding)
        }
    }
}
