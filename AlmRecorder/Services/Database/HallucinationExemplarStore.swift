import Foundation
import GRDB

/// Learned bad-exemplar memory: the normalized texts of CONFIRMED hallucinations, used to find
/// more lines like them (exact match, n-gram overlap, embedding similarity).
///
/// Nothing here is curated or language-specific — the memory only ever contains what was actually
/// found in this library: detector junk (hard structural evidence), verifier "not spoken"
/// verdicts, and user Hides. Negative feedback is first-class: Keep/Undo drains an exemplar's
/// count and eventually deletes it, so a wrong lesson un-learns itself.
///
/// Matching against the memory is always a SOFT signal (it can route a line to the audio check,
/// never auto-hide it) — see TranscriptSuspicionScorer's tier discipline.
enum HallucinationExemplarStore {

    /// Who confirmed the exemplar. Ordered by trust; an exemplar's source only ever upgrades.
    enum Source: String, Comparable {
        case detector, verifier, user

        private var rank: Int {
            switch self {
            case .detector: return 0
            case .verifier: return 1
            case .user: return 2
            }
        }
        static func < (lhs: Source, rhs: Source) -> Bool { lhs.rank < rhs.rank }
    }

    struct Exemplar: Equatable {
        let id: Int64
        let normalizedText: String
        let embedding: Data?
        let occurrences: Int
        let source: Source
    }

    /// Exemplars hold short recurring junk; long unique lines never generalize.
    static let maxWords = 8

    static let tableName = "hallucination_exemplars"

    /// Body of migration v25_hallucination_exemplars (exposed so tests can run it on a bare schema).
    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS \(tableName) (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                normalized_text TEXT NOT NULL UNIQUE,
                embedding BLOB,
                occurrences INTEGER NOT NULL DEFAULT 1,
                source TEXT NOT NULL,
                created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                last_seen_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
        """)
    }

    // MARK: - Learning

    /// Remember a confirmed hallucination. No-op when the exemplar table doesn't exist, the
    /// normalized text is empty, or the line is too long to generalize.
    static func recordBad(_ db: Database, text: String, source: Source) throws {
        guard try db.tableExists(tableName) else { return }
        let normalized = TranscriptSuspicionScorer.normalizedText(text)
        guard !normalized.isEmpty,
              normalized.split(separator: " ").count <= maxWords else { return }

        if let row = try Row.fetchOne(db, sql: "SELECT occurrences, source FROM \(tableName) WHERE normalized_text = ?",
                                      arguments: [normalized]) {
            let existing = Source(rawValue: row["source"] as String) ?? .detector
            try db.execute(sql: """
                UPDATE \(tableName)
                SET occurrences = occurrences + 1, source = ?, last_seen_at = ?
                WHERE normalized_text = ?
            """, arguments: [max(existing, source).rawValue, Date(), normalized])
        } else {
            try db.execute(sql: """
                INSERT INTO \(tableName) (normalized_text, source, occurrences, created_at, last_seen_at)
                VALUES (?, ?, 1, ?, ?)
            """, arguments: [normalized, source.rawValue, Date(), Date()])
        }
    }

    /// Negative feedback: the user kept/restored a line with this text — drain its exemplar.
    static func recordGood(_ db: Database, text: String) throws {
        guard try db.tableExists(tableName) else { return }
        let normalized = TranscriptSuspicionScorer.normalizedText(text)
        guard !normalized.isEmpty else { return }
        try db.execute(sql: "UPDATE \(tableName) SET occurrences = occurrences - 1 WHERE normalized_text = ?",
                       arguments: [normalized])
        try db.execute(sql: "DELETE FROM \(tableName) WHERE normalized_text = ? AND occurrences <= 0",
                       arguments: [normalized])
    }

    // MARK: - Queries

    /// Strongest exemplars first (most often confirmed, most recently seen).
    static func exemplars(_ db: Database, limit: Int = 500) throws -> [Exemplar] {
        guard try db.tableExists(tableName) else { return [] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, normalized_text, embedding, occurrences, source
            FROM \(tableName)
            ORDER BY occurrences DESC, last_seen_at DESC
            LIMIT ?
        """, arguments: [limit])
        return rows.map { row in
            Exemplar(id: row["id"],
                     normalizedText: row["normalized_text"],
                     embedding: row["embedding"],
                     occurrences: row["occurrences"],
                     source: Source(rawValue: row["source"] as String) ?? .detector)
        }
    }

    /// Attach a lazily-computed text embedding (1024-dim) to an exemplar.
    static func setEmbedding(_ db: Database, id: Int64, embedding: Data) throws {
        try db.execute(sql: "UPDATE \(tableName) SET embedding = ? WHERE id = ?",
                       arguments: [embedding, id])
    }
}
