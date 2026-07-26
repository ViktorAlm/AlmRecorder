import Foundation
import GRDB

/// Durable storage for utterance embeddings.
///
/// vectorlite keeps its HNSW index in memory only, so the `utterance_vectors` virtual
/// table starts empty on every launch and any vectors inserted during a session are lost
/// when the process exits. This type persists the raw embedding vectors in an ordinary
/// table (`utterance_embeddings`) and re-hydrates the in-memory index at startup, so
/// semantic search survives a restart.
enum EmbeddingPersistence {
    /// Embedding dimensionality (Qwen3-Embedding-0.6B -> 1024).
    static let dimensions = 1024

    /// Create the durable embeddings table. Idempotent; safe to call on every launch.
    static func createSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS utterance_embeddings (
                utterance_id INTEGER PRIMARY KEY
                    REFERENCES utterances(id) ON DELETE CASCADE,
                embedding BLOB NOT NULL,
                dimensions INTEGER NOT NULL DEFAULT \(dimensions),
                created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
        """)
    }

    /// Persist one embedding durably AND insert it into the live in-memory index so it is
    /// immediately searchable within the current session.
    static func store(_ db: Database, utteranceId: Int64, embedding: Data) throws {
        // Durable store is an ordinary table - upsert is fine.
        try db.execute(
            sql: "INSERT OR REPLACE INTO utterance_embeddings(utterance_id, embedding, dimensions) VALUES (?, ?, ?)",
            arguments: [utteranceId, embedding, dimensions]
        )
        // vectorlite virtual tables do NOT support INSERT OR REPLACE on an existing rowid
        // (they error "row N already exists"), so delete any prior entry, then insert.
        try insertIntoIndex(db, utteranceId: utteranceId, embedding: embedding)
    }

    /// Insert (replacing any prior entry) one vector into the in-memory vectorlite index.
    /// Internal so UtteranceReviewStore.unhide can restore a hidden line's searchability.
    static func insertIntoIndex(_ db: Database, utteranceId: Int64, embedding: Data) throws {
        try db.execute(sql: "DELETE FROM utterance_vectors WHERE rowid = ?", arguments: [utteranceId])
        try db.execute(
            sql: "INSERT INTO utterance_vectors(rowid, embedding) VALUES (?, ?)",
            arguments: [utteranceId, embedding]
        )
    }

    /// Rebuild the in-memory vectorlite index from the durable table.
    /// Called once on launch after the `utterance_vectors` virtual table is (re)created.
    /// Soft-hidden utterances (transcript cleanup) keep their durable embedding but stay out
    /// of the live index so they never surface in semantic search.
    /// - Returns: the number of embeddings loaded into the index.
    @discardableResult
    static func hydrateIndex(_ db: Database) throws -> Int {
        let rows = try Row.fetchAll(db, sql: """
            SELECT ue.utterance_id, ue.embedding
            FROM utterance_embeddings ue
            JOIN utterances u ON u.id = ue.utterance_id AND u.is_hidden = 0
        """)
        for row in rows {
            let utteranceId: Int64 = row["utterance_id"]
            let embedding: Data = row["embedding"]
            // delete-then-insert keeps hydration idempotent even if called twice.
            try insertIntoIndex(db, utteranceId: utteranceId, embedding: embedding)
        }
        return rows.count
    }

    /// Make `utterances.has_embedding` reflect exactly what is persisted in
    /// `utterance_embeddings`. This is the safeguard against the original bug, where flags
    /// said "embedded" while no durable vector existed, so generateMissingEmbeddings skipped
    /// utterances that actually needed embedding.
    /// - Returns: (embedded, total) utterance counts after reconciliation.
    @discardableResult
    static func reconcileFlags(_ db: Database) throws -> (embedded: Int, total: Int) {
        try db.execute(sql: """
            UPDATE utterances
            SET has_embedding = CASE
                WHEN id IN (SELECT utterance_id FROM utterance_embeddings) THEN 1 ELSE 0
            END
        """)
        let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM utterances") ?? 0
        let embedded = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM utterances WHERE has_embedding = 1") ?? 0
        return (embedded, total)
    }
}
