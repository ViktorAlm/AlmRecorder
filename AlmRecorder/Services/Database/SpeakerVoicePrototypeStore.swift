import Foundation
import GRDB

/// Recording-level voice prototypes used by cross-recording speaker identification.
///
/// The existing `speaker_embedding_history` table already has the right durable ownership and
/// recording foreign keys. Rows with a non-null `recording_id` are treated as one prototype per
/// `(global speaker, recording, local diarizer label)`. Rows with a null recording id remain legacy
/// observation history and are ignored by the prototype matcher.
enum SpeakerVoicePrototypeStore {
    private struct GroupKey: Hashable {
        let speakerId: Int64
        let recordingId: Int64
        let localLabel: String
    }

    private struct Accumulator {
        var weightedSum: [Float]
        var totalWeight: Float
        var weightedQuality: Float
    }

    static func migrate(_ db: Database) throws {
        guard try db.tableExists("speaker_embedding_history") else { return }
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_speaker_embedding_history_recording
            ON speaker_embedding_history(speaker_id, recording_id)
        """)
        try rebuildAll(db, policy: .qualityDurationWeighted)
    }

    static func loadAll(_ db: Database) throws -> [String: [[Float]]] {
        guard try db.tableExists("speaker_embedding_history") else { return [:] }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT s.uuid, h.embedding
                FROM speaker_embedding_history h
                JOIN speakers s ON s.id = h.speaker_id
                WHERE h.recording_id IS NOT NULL
                ORDER BY s.uuid, h.recording_id, h.id
            """
        )
        var result: [String: [[Float]]] = [:]
        for row in rows {
            guard let uuid: String = row["uuid"],
                  let data: Data = row["embedding"] else { continue }
            let vector = VoiceEmbeddingStore.dataToFloats(data)
            guard vector.count == SpeakerEmbeddingPolicy.dimension else { continue }
            result[uuid, default: []].append(vector)
        }
        return result
    }

    static func rebuildAll(
        _ db: Database,
        policy: SpeakerCentroidPolicy
    ) throws {
        guard try db.tableExists("speaker_embedding_history"),
              try db.tableExists("utterance_voice_embeddings") else { return }
        try db.execute(sql: "DELETE FROM speaker_embedding_history WHERE recording_id IS NOT NULL")
        try insertComputedPrototypes(db, speakerUUID: nil, policy: policy)
    }

    static func rebuild(
        _ db: Database,
        speakerUUID: String,
        policy: SpeakerCentroidPolicy
    ) throws {
        guard try db.tableExists("speaker_embedding_history"),
              try db.tableExists("utterance_voice_embeddings"),
              let speakerId = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM speakers WHERE uuid = ?",
                arguments: [speakerUUID]
              )
        else { return }

        try db.execute(
            sql: """
                DELETE FROM speaker_embedding_history
                WHERE speaker_id = ? AND recording_id IS NOT NULL
            """,
            arguments: [speakerId]
        )
        try insertComputedPrototypes(db, speakerUUID: speakerUUID, policy: policy)
    }

    private static func insertComputedPrototypes(
        _ db: Database,
        speakerUUID: String?,
        policy: SpeakerCentroidPolicy
    ) throws {
        let hasLocalClusters = try db.tableExists("speaker_local_clusters")
        let hasMixedLabels = try db.tableExists("speaker_local_cluster_gold_labels")
        let utteranceColumns = Set(try db.columns(in: "utterances").map(\.name))
        let hasOverlapEvidence = utteranceColumns.contains("speaker_overlap_ratio")
            && utteranceColumns.contains("active_speaker_count")
        var sql = """
            SELECT s.id AS speaker_id,
                   u.recording_id,
                   COALESCE(u.speaker, '') AS local_label,
                   v.embedding,
                   MAX(0.05, u.end_time - u.start_time) AS duration,
                   COALESCE(u.voice_embedding_quality, u.confidence, 0.5) AS quality
            FROM utterance_voice_embeddings v
            JOIN utterances u ON u.id = v.utterance_id
            JOIN speakers s ON s.uuid = u.speaker_uuid
            \(hasLocalClusters ? "LEFT JOIN speaker_local_clusters c ON c.id = u.local_speaker_cluster_id" : "")
            WHERE COALESCE(u.is_hidden, 0) = 0
              AND v.dimensions = ?
        """
        if hasOverlapEvidence {
            sql += """

              AND COALESCE(u.speaker_overlap_ratio, 0) <= 0.05
              AND COALESCE(u.active_speaker_count, 1) <= 1
            """
        }
        if hasLocalClusters {
            sql += """

              AND (
                  c.id IS NULL OR (
                      c.mixture_split_gain IS NULL
                      AND NOT (
                          c.embedding_turn_count > 1
                          AND COALESCE(c.cohesion, 1) < 0.35
                      )
                  )
              )
            """
        }
        if hasMixedLabels {
            sql += """

              AND NOT EXISTS (
                  SELECT 1
                  FROM speaker_local_cluster_gold_labels mixed
                  WHERE mixed.local_cluster_id = u.local_speaker_cluster_id
                    AND mixed.verdict = 'multiple_speakers'
              )
            """
        }
        var arguments: StatementArguments = [SpeakerEmbeddingPolicy.dimension]
        if let speakerUUID {
            sql += " AND s.uuid = ?"
            arguments += [speakerUUID]
        }
        sql += " ORDER BY s.id, u.recording_id, local_label, u.start_time, u.id"

        let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
        var groups: [GroupKey: Accumulator] = [:]
        for row in rows {
            guard let speakerId: Int64 = row["speaker_id"],
                  let recordingId: Int64 = row["recording_id"],
                  let data: Data = row["embedding"] else { continue }
            let vector = normalized(VoiceEmbeddingStore.dataToFloats(data))
            guard vector.count == SpeakerEmbeddingPolicy.dimension else { continue }

            let durationValue: Double = row["duration"] ?? 0.05
            let qualityValue: Double = row["quality"] ?? 0.5
            let duration = Float(durationValue)
            let quality = min(1, max(0.05, Float(qualityValue)))
            let weight: Float
            switch policy {
            case .equalTurns:
                weight = 1
            case .durationWeighted:
                weight = max(0.05, duration)
            case .qualityDurationWeighted:
                weight = max(0.05, duration) * quality
            }

            let key = GroupKey(
                speakerId: speakerId,
                recordingId: recordingId,
                localLabel: row["local_label"] ?? ""
            )
            var accumulator = groups[key] ?? Accumulator(
                weightedSum: [Float](repeating: 0, count: vector.count),
                totalWeight: 0,
                weightedQuality: 0
            )
            for index in vector.indices {
                accumulator.weightedSum[index] += vector[index] * weight
            }
            accumulator.totalWeight += weight
            accumulator.weightedQuality += quality * weight
            groups[key] = accumulator
        }

        for (key, accumulator) in groups.sorted(by: {
            if $0.key.speakerId != $1.key.speakerId {
                return $0.key.speakerId < $1.key.speakerId
            }
            if $0.key.recordingId != $1.key.recordingId {
                return $0.key.recordingId < $1.key.recordingId
            }
            return $0.key.localLabel < $1.key.localLabel
        }) {
            guard accumulator.totalWeight > 0 else { continue }
            let prototype = normalized(accumulator.weightedSum)
            guard prototype.count == SpeakerEmbeddingPolicy.dimension else { continue }
            try db.execute(
                sql: """
                    INSERT INTO speaker_embedding_history(
                        speaker_id, embedding, recording_id, confidence, created_at
                    ) VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    key.speakerId,
                    VoiceEmbeddingStore.floatsToData(prototype),
                    key.recordingId,
                    accumulator.weightedQuality / accumulator.totalWeight,
                    Date(),
                ]
            )
        }
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(Float.zero) { $0 + $1 * $1 })
        guard norm > 0 else { return [] }
        return vector.map { $0 / norm }
    }
}
