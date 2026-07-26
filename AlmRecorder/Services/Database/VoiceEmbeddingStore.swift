import Foundation
import GRDB

/// Durable per-utterance VOICE embedding storage (256-dim WeSpeaker from FluidAudio).
///
/// Mirrors `EmbeddingPersistence` (the TEXT-embedding store) but needs NO vectorlite: voice
/// comparisons are per-speaker, small-N, and done in-memory with cosine. Keyed by utterance id
/// with `ON DELETE CASCADE`, so vectors disappear when their utterance does.
enum VoiceEmbeddingStore {
    /// WeSpeaker / FluidAudio voice-embedding size (matches `SpeakerEmbeddingPolicy.dimension`).
    static let dimensions = 256

    /// Create the durable table. Idempotent; safe on every launch.
    static func createSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS utterance_voice_embeddings (
                utterance_id INTEGER PRIMARY KEY
                    REFERENCES utterances(id) ON DELETE CASCADE,
                embedding BLOB NOT NULL,
                dimensions INTEGER NOT NULL DEFAULT \(dimensions),
                created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
        """)
    }

    /// Persist one utterance's voice embedding (upsert). Validates the 256-dim chokepoint so a
    /// stray-dimension vector can't poison later cosine comparisons.
    static func store(_ db: Database, utteranceId: Int64, embedding: [Float]) throws {
        try SpeakerEmbeddingPolicy.validate(embedding)
        try db.execute(
            sql: "INSERT OR REPLACE INTO utterance_voice_embeddings(utterance_id, embedding, dimensions) VALUES (?, ?, ?)",
            arguments: [utteranceId, floatsToData(embedding), embedding.count]
        )
    }

    /// Persist many in one transaction. Skips entries that fail the dimension guard.
    static func storeBatch(_ db: Database, _ pairs: [(utteranceId: Int64, embedding: [Float])]) throws {
        for p in pairs {
            guard p.embedding.count == dimensions else { continue }
            try db.execute(
                sql: "INSERT OR REPLACE INTO utterance_voice_embeddings(utterance_id, embedding, dimensions) VALUES (?, ?, ?)",
                arguments: [p.utteranceId, floatsToData(p.embedding), p.embedding.count]
            )
        }
    }

    /// Load one utterance's voice embedding, or nil if none stored.
    static func load(_ db: Database, utteranceId: Int64) throws -> [Float]? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT embedding FROM utterance_voice_embeddings WHERE utterance_id = ?",
            arguments: [utteranceId]
        ) else { return nil }
        let data: Data = row["embedding"]
        return dataToFloats(data)
    }

    /// Load all stored voice embeddings for a speaker's utterances (JOIN on current `speaker_uuid`).
    static func loadForSpeaker(_ db: Database, uuid: String) throws -> [(utteranceId: Int64, embedding: [Float])] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT v.utterance_id AS uid, v.embedding AS emb
                FROM utterance_voice_embeddings v
                JOIN utterances u ON u.id = v.utterance_id
                WHERE u.speaker_uuid = ?
            """,
            arguments: [uuid]
        )
        return rows.compactMap { row in
            guard let uid: Int64 = row["uid"], let data: Data = row["emb"] else { return nil }
            return (uid, dataToFloats(data))
        }
    }

    static func loadWeightedForSpeaker(
        _ db: Database,
        uuid: String,
        policy: SpeakerCentroidPolicy
    ) throws -> [(embedding: [Float], weight: Float)] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT v.embedding AS emb,
                       MAX(0.05, u.end_time - u.start_time) AS duration,
                       COALESCE(u.voice_embedding_quality, u.confidence, 0.5) AS quality
                FROM utterance_voice_embeddings v
                JOIN utterances u ON u.id = v.utterance_id
                WHERE u.speaker_uuid = ? AND COALESCE(u.is_hidden, 0) = 0
            """,
            arguments: [uuid]
        )
        return rows.compactMap { row in
            guard let data: Data = row["emb"] else { return nil }
            let durationValue: Double = row["duration"] ?? 0.05
            let qualityValue: Double = row["quality"] ?? 0.5
            let duration = Float(durationValue)
            let quality = min(1, max(0.05, Float(qualityValue)))
            let weight: Float
            switch policy {
            case .equalTurns: weight = 1
            case .durationWeighted: weight = duration
            case .qualityDurationWeighted: weight = duration * quality
            }
            return (dataToFloats(data), weight)
        }
    }

    /// Number of utterances (for a recording) that already have a stored voice embedding — for backfill progress.
    static func storedCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM utterance_voice_embeddings") ?? 0
    }

    // MARK: - Float <-> Data

    static func floatsToData(_ floats: [Float]) -> Data {
        floats.withUnsafeBytes { Data($0) }
    }

    static func dataToFloats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

/// Small vector helpers for voice-embedding math (mean recompute + analysis).
enum VoiceMath {
    static func normalized(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(Float.zero) { $0 + $1 * $1 })
        guard norm > 0 else { return [] }
        return vector.map { $0 / norm }
    }

    /// Average a set of equal-length vectors and L2-normalize the result.
    /// Returns nil if there are no usable vectors or the average is the zero vector.
    static func meanNormalized(_ vectors: [[Float]]) -> [Float]? {
        guard let dim = vectors.first(where: { !$0.isEmpty })?.count, dim > 0 else { return nil }
        var sum = [Float](repeating: 0, count: dim)
        var n = 0
        for v in vectors where v.count == dim {
            for i in 0..<dim { sum[i] += v[i] }
            n += 1
        }
        guard n > 0 else { return nil }
        var mean = sum.map { $0 / Float(n) }
        let norm = (mean.reduce(0) { $0 + $1 * $1 }).squareRoot()
        guard norm > 0 else { return nil }
        mean = mean.map { $0 / norm }
        return mean
    }


    static func weightedMeanNormalized(_ weightedVectors: [(vector: [Float], weight: Float)]) -> [Float]? {
        guard let dimension = weightedVectors.first(where: { !$0.vector.isEmpty })?.vector.count,
              dimension > 0 else { return nil }
        var sum = [Float](repeating: 0, count: dimension)
        var totalWeight: Float = 0
        for item in weightedVectors where item.vector.count == dimension && item.weight > 0 {
            let norm = sqrt(item.vector.reduce(Float.zero) { $0 + $1 * $1 })
            guard norm > 0 else { continue }
            for index in sum.indices {
                sum[index] += (item.vector[index] / norm) * item.weight
            }
            totalWeight += item.weight
        }
        guard totalWeight > 0 else { return nil }
        for index in sum.indices { sum[index] /= totalWeight }
        let norm = sqrt(sum.reduce(Float.zero) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        for index in sum.indices { sum[index] /= norm }
        return sum
    }
}
