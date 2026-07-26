import Foundation
import GRDB

/// Repository for managing utterances with GRDB and vectorlite HNSW search
class GRDBUtteranceRepository {
    private let logger = VoxtralLogger.shared
    private let db = GRDBDatabaseManager.shared
    
    // MARK: - CRUD Operations
    
    /// All non-hidden utterances of every recording the speaker appears in (other speakers'
    /// lines included — the talk-stats engine needs them for shares/monologues). Pure query
    /// core, testable against an in-memory DatabaseQueue.
    static func talkSlice(_ db: Database, speakerUuid: String) throws -> [SpeakerTalkStats.Utterance] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT recording_id, speaker_uuid, start_time, end_time, text
                FROM utterances
                WHERE is_hidden = 0
                  AND recording_id IN (
                      SELECT DISTINCT recording_id FROM utterances
                      WHERE speaker_uuid = ? AND is_hidden = 0
                  )
                ORDER BY recording_id, start_time
            """,
            arguments: [speakerUuid]
        )
        return rows.map { row in
            SpeakerTalkStats.Utterance(
                recordingId: row["recording_id"],
                speakerUuid: row["speaker_uuid"],
                start: row["start_time"],
                end: row["end_time"],
                text: row["text"] ?? ""
            )
        }
    }

    /// Instance wrapper used by the app.
    func getTalkSlice(speakerUuid: String) throws -> [SpeakerTalkStats.Utterance] {
        try db.read { try Self.talkSlice($0, speakerUuid: speakerUuid) }
    }

    /// Create a new utterance
    func create(_ utterance: Utterance) throws -> Int64 {
        try db.write { db in
            try Self.insert(db, utterance)
            return db.lastInsertedRowID
        }
    }

    private static func insert(_ db: Database, _ utterance: Utterance) throws {
        try db.execute(
            sql: """
                INSERT INTO utterances (
                    recording_id, utterance_index, start_time, end_time,
                    speaker, speaker_uuid, text, confidence,
                    original_text, text_source, is_hidden, asr_min_p, asr_low_frac,
                    suspicion, suspicion_reasons, review_status, verifier_result, reviewed_at,
                    audio_source, speaker_assignment_source, speaker_reviewed_at, voice_embedding_quality,
                    speaker_overlap_ratio, active_speaker_count, overlapping_speaker_labels_json,
                    local_speaker_label, local_speaker_cluster_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                utterance.recordingId,
                utterance.utteranceIndex,
                utterance.startTime,
                utterance.endTime,
                utterance.speaker,
                utterance.speakerUuid,
                utterance.text,
                utterance.confidence,
                utterance.originalText,
                utterance.textSource,
                utterance.isHidden,
                utterance.asrMinP,
                utterance.asrLowFrac,
                utterance.suspicion,
                utterance.suspicionReasons,
                utterance.reviewStatus,
                utterance.verifierResult,
                utterance.reviewedAt,
                utterance.audioSource,
                utterance.speakerAssignmentSource,
                utterance.speakerReviewedAt,
                utterance.voiceEmbeddingQuality,
                utterance.speakerOverlapRatio,
                utterance.activeSpeakerCount,
                utterance.overlappingSpeakerLabelsJSON,
                utterance.localSpeakerLabel ?? utterance.speaker,
                utterance.localSpeakerClusterId
            ]
        )
    }

    /// Get utterances for a recording. Soft-hidden lines (transcript cleanup) are excluded
    /// unless explicitly requested — display, export, and meeting-merge all want visible only.
    func getByRecording(id: Int64, includeHidden: Bool = false) throws -> [Utterance] {
        try db.read { db in
            try UtteranceReviewStore.fetchUtterances(db, recordingId: id, includeHidden: includeHidden)
        }
    }
    
    /// Delete utterances for a recording
    func deleteByRecording(id: Int64) throws {
        try db.write { db in
            // Get utterance IDs first, then delete from vector index one by one
            // (vectorlite virtual tables don't support subqueries in DELETE)
            let utteranceIds = try Int64.fetchAll(
                db,
                sql: "SELECT id FROM utterances WHERE recording_id = ?",
                arguments: [id]
            )
            for uid in utteranceIds {
                try db.execute(
                    sql: "DELETE FROM utterance_vectors WHERE rowid = ?",
                    arguments: [uid]
                )
            }

            // Delete utterances
            try db.execute(
                sql: "DELETE FROM utterances WHERE recording_id = ?",
                arguments: [id]
            )
        }
    }
    
    // MARK: - Batch Operations
    
    /// Create multiple utterances in a transaction
    func createBatch(_ utterances: [Utterance]) throws -> [Int64] {
        try db.inTransaction { db in
            var ids: [Int64] = []
            for utterance in utterances {
                try Self.insert(db, utterance)
                ids.append(db.lastInsertedRowID)
            }
            return ids
        }
    }

    /// Atomically replace one recording's utterances after a successful re-transcription.
    ///
    /// The old transcript remains queryable for the entire (potentially hours-long) ASR pass.
    /// Only when every replacement row validates and inserts do we commit the deletion. A failed
    /// insert rolls the SQLite transaction back, leaving the previous transcript untouched.
    func replaceBatchForRetranscription(
        recordingId: Int64,
        utterances: [Utterance],
        voiceEmbeddings: [(offset: Int, embedding: [Float])],
        replacementRecording: Recording
    ) throws -> (ids: [Int64], carriedOver: Set<Int64>) {
        try db.inTransaction { db in
            try Self.replaceBatchForRetranscription(
                db,
                recordingId: recordingId,
                utterances: utterances,
                voiceEmbeddings: voiceEmbeddings,
                replacementRecording: replacementRecording
            )
        }
    }

    /// Transaction body split out for deterministic rollback tests.
    static func replaceBatchForRetranscription(
        _ db: Database,
        recordingId: Int64,
        utterances: [Utterance],
        voiceEmbeddings: [(offset: Int, embedding: [Float])],
        replacementRecording: Recording
    ) throws -> (ids: [Int64], carriedOver: Set<Int64>) {
        _ = try RetranscribeCarryover.snapshot(db, recordingId: recordingId)

        // vectorlite virtual tables do not support the subquery form of DELETE.
        let oldIDs = try Int64.fetchAll(
            db,
            sql: "SELECT id FROM utterances WHERE recording_id = ?",
            arguments: [recordingId]
        )
        for id in oldIDs {
            try db.execute(
                sql: "DELETE FROM utterance_vectors WHERE rowid = ?",
                arguments: [id]
            )
        }
        try db.execute(
            sql: "DELETE FROM utterances WHERE recording_id = ?",
            arguments: [recordingId]
        )

        var ids: [Int64] = []
        ids.reserveCapacity(utterances.count)
        for utterance in utterances {
            try Self.insert(db, utterance)
            ids.append(db.lastInsertedRowID)
        }
        for item in voiceEmbeddings where ids.indices.contains(item.offset) {
            try VoiceEmbeddingStore.store(
                db,
                utteranceId: ids[item.offset],
                embedding: item.embedding
            )
        }

        let fresh = zip(ids, utterances).map { id, utterance in
            RetranscribeCarryover.NewUtterance(
                id: id,
                text: utterance.text,
                startTime: utterance.startTime,
                endTime: utterance.endTime
            )
        }
        let carriedOver = try RetranscribeCarryover.reapply(
            db,
            recordingId: recordingId,
            newUtterances: fresh
        )

        // Commit the display transcript and utterance rows together. Any failure above or here
        // rolls everything back, including the carryover snapshot.
        try GRDBRecordingRepository.update(db, replacementRecording)
        return (ids, carriedOver)
    }

    // MARK: - Transcript Cleanup / Review

    func hideUtterance(_ utteranceId: Int64, status: UtteranceReviewStatus, verifierResultJSON: String? = nil) throws {
        try db.write { db in
            try UtteranceReviewStore.hide(db, utteranceId: utteranceId, status: status, verifierResultJSON: verifierResultJSON)
        }
    }

    func unhideUtterance(_ utteranceId: Int64) throws {
        try db.write { db in try UtteranceReviewStore.unhide(db, utteranceId: utteranceId) }
    }

    func applyCorrection(utteranceId: Int64, newText: String, source: UtteranceTextSource,
                         status: UtteranceReviewStatus, verifierResultJSON: String? = nil) throws {
        try db.write { db in
            try UtteranceReviewStore.applyCorrection(db, utteranceId: utteranceId, newText: newText,
                                                     source: source, status: status,
                                                     verifierResultJSON: verifierResultJSON)
        }
    }

    func revertUtteranceText(_ utteranceId: Int64) throws {
        try db.write { db in try UtteranceReviewStore.revertText(db, utteranceId: utteranceId) }
    }

    func setReviewStatus(utteranceId: Int64, status: UtteranceReviewStatus?, verifierResultJSON: String? = nil) throws {
        try db.write { db in
            try UtteranceReviewStore.setReviewStatus(db, utteranceId: utteranceId, status: status,
                                                     verifierResultJSON: verifierResultJSON)
        }
    }

    func updateDetection(_ updates: [UtteranceReviewStore.DetectionUpdate]) throws {
        try db.write { db in try UtteranceReviewStore.updateDetection(db, updates) }
    }

    func countPendingReview() throws -> Int {
        try db.read { db in try UtteranceReviewStore.countPendingReview(db) }
    }

    /// Utterances in a given review state, newest recordings first (review-inbox feed).
    /// Includes hidden rows — the auto-hidden section of the inbox needs them.
    func utterances(withReviewStatus status: UtteranceReviewStatus, limit: Int = 200) throws -> [Utterance] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM utterances
                WHERE review_status = ?
                ORDER BY recording_id DESC, utterance_index
                LIMIT ?
            """, arguments: [status.rawValue, limit])
            return rows.compactMap { Utterance(row: $0) }
        }
    }

    /// Regenerate the recording's full_transcript from its visible utterances.
    func rebuildFullTranscript(recordingId: Int64) throws {
        try db.write { db in try UtteranceReviewStore.rebuildFullTranscript(db, recordingId: recordingId) }
    }
    
    // MARK: - Embedding Operations
    
    /// Store embedding durably (so it survives a restart) and in the live vectorlite index.
    func storeEmbedding(utteranceId: Int64, embedding: Data) throws {
        try db.write { db in
            try EmbeddingPersistence.store(db, utteranceId: utteranceId, embedding: embedding)
            try db.execute(
                sql: "UPDATE utterances SET has_embedding = 1 WHERE id = ?",
                arguments: [utteranceId]
            )
        }
    }

    /// Store multiple embeddings in batch (durable + live index).
    func storeEmbeddingsBatch(_ embeddings: [(utteranceId: Int64, embedding: Data)]) throws {
        try db.inTransaction { db in
            for (id, embedding) in embeddings {
                try EmbeddingPersistence.store(db, utteranceId: id, embedding: embedding)
                try db.execute(
                    sql: "UPDATE utterances SET has_embedding = 1 WHERE id = ?",
                    arguments: [id]
                )
            }
        }
    }

    /// Store one utterance's 256-dim VOICE embedding (separate durable store, no vectorlite).
    func storeVoiceEmbedding(utteranceId: Int64, embedding: [Float]) throws {
        try db.write { db in try VoiceEmbeddingStore.store(db, utteranceId: utteranceId, embedding: embedding) }
    }

    /// Store many utterance voice embeddings in one transaction.
    func storeVoiceEmbeddingsBatch(_ pairs: [(utteranceId: Int64, embedding: [Float])]) throws {
        try db.write { db in try VoiceEmbeddingStore.storeBatch(db, pairs) }
    }

    // MARK: - Vector Search
    
    /// Search for similar utterances using HNSW
    func searchSimilar(
        embedding: Data,
        limit: Int = 20,
        threshold: Float? = nil
    ) throws -> [UtteranceSearchResult] {
        try db.read { db in
            // Use vectorlite HNSW search (always available)
            return try searchWithVectorlite(db: db, embedding: embedding, limit: limit, threshold: threshold)
        }
    }
    
    /// Search for similar utterances within specific recordings
    enum VectorSearchStrategy: String {
        case exactFiltered = "exact_filtered"
        case ann
    }

    struct ScopedVectorSearchResult {
        let results: [UtteranceSearchResult]
        let complete: Bool
        let strategy: VectorSearchStrategy
        let eligibleIndexedCount: Int
        let examinedCandidateCount: Int
    }

    func searchSimilarInRecordings(
        embedding: Data,
        recordingIds: [Int64],
        limit: Int = 20,
        threshold: Float? = nil
    ) throws -> [UtteranceSearchResult] {
        try searchSimilarInRecordingsDetailed(
            embedding: embedding,
            recordingIds: recordingIds,
            limit: limit,
            threshold: threshold
        ).results
    }

    func searchSimilarInRecordingsDetailed(
        embedding: Data,
        recordingIds: [Int64],
        limit: Int = 20,
        threshold: Float? = nil,
        speakerIds: [String] = [],
        forceANN: Bool = false
    ) throws -> ScopedVectorSearchResult {
        try db.read { db in
            guard !recordingIds.isEmpty else {
                return ScopedVectorSearchResult(
                    results: [],
                    complete: true,
                    strategy: .ann,
                    eligibleIndexedCount: 0,
                    examinedCandidateCount: 0
                )
            }
            let ids = recordingIds.map { String($0) }.joined(separator: ",")
            let speakerPlaceholders = speakerIds.map { _ in "?" }.joined(separator: ",")
            let eligibleCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM utterance_embeddings ue
                    JOIN utterances u ON u.id = ue.utterance_id
                    WHERE u.is_hidden = 0 AND u.recording_id IN (\(ids))
                    \(speakerIds.isEmpty ? "" : "AND u.speaker_uuid IN (\(speakerPlaceholders))")
                """,
                arguments: StatementArguments(speakerIds)
            ) ?? 0
            guard eligibleCount > 0 else {
                return ScopedVectorSearchResult(
                    results: [],
                    complete: true,
                    strategy: forceANN ? .ann : .exactFiltered,
                    eligibleIndexedCount: 0,
                    examinedCandidateCount: 0
                )
            }

            // A constrained exact scan is both faster than repeatedly widening HNSW for small
            // filtered sets and guarantees the actual nearest eligible neighbors.
            if !forceANN, eligibleCount <= 20_000 {
                return ScopedVectorSearchResult(
                    results: try searchDurableEmbeddingsExactly(
                        db: db,
                        embedding: embedding,
                        recordingIds: recordingIds,
                        limit: limit,
                        threshold: threshold,
                        speakerIds: speakerIds
                    ),
                    complete: true,
                    strategy: .exactFiltered,
                    eligibleIndexedCount: eligibleCount,
                    examinedCandidateCount: eligibleCount
                )
            }

            let globalIndexedCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM utterance_embeddings ue
                    JOIN utterances u ON u.id = ue.utterance_id
                    WHERE u.is_hidden = 0
                """
            ) ?? 0
            let ceiling = min(globalIndexedCount, max(5_000, limit * 200))
            var candidateLimit = min(globalIndexedCount, max(200, limit * 8))
            var results: [UtteranceSearchResult] = []
            while candidateLimit > 0 {
                results = try searchWithVectorliteInRecordings(
                    db: db,
                    embedding: embedding,
                    recordingIds: recordingIds,
                    limit: limit,
                    candidateLimit: candidateLimit,
                    threshold: threshold,
                    speakerIds: speakerIds
                )
                if results.count >= limit || candidateLimit >= globalIndexedCount {
                    return ScopedVectorSearchResult(
                        results: results,
                        complete: true,
                        strategy: .ann,
                        eligibleIndexedCount: eligibleCount,
                        examinedCandidateCount: candidateLimit
                    )
                }
                if candidateLimit >= ceiling { break }
                candidateLimit = min(ceiling, candidateLimit * 2)
            }
            return ScopedVectorSearchResult(
                results: results,
                complete: false,
                strategy: .ann,
                eligibleIndexedCount: eligibleCount,
                examinedCandidateCount: candidateLimit
            )
        }
    }
    
    // MARK: - Private Methods
    
    private func searchWithVectorlite(
        db: Database,
        embedding: Data,
        limit: Int,
        threshold: Float?
    ) throws -> [UtteranceSearchResult] {
        // Embedding is already in blob format (Data), use it directly

        // Perform KNN search with ef=100 for good accuracy
        let sql = """
            SELECT
                u.*,
                r.id as r_id, r.title as r_title, r.file_name as r_file_name,
                r.file_path as r_file_path, r.duration as r_duration,
                r.language as r_language, r.created_at as r_created_at,
                r.transcribed_at as r_transcribed_at, r.source as r_source,
                r.full_transcript as r_full_transcript, r.metadata as r_metadata,
                r.external_id as r_external_id, r.updated_at as r_updated_at,
                v.distance as distance
            FROM (
                SELECT rowid, distance
                FROM utterance_vectors
                WHERE knn_search(embedding, knn_param(?, ?, 100))
                \(threshold != nil ? "AND distance <= ?" : "")
            ) v
            JOIN utterances u ON v.rowid = u.id AND u.is_hidden = 0
            JOIN recordings r ON u.recording_id = r.id
            ORDER BY v.distance
            LIMIT ?
        """
        
        // Build arguments array with proper types
        var args: [DatabaseValueConvertible?] = []
        args.append(embedding)
        args.append(limit)
        if let threshold = threshold {
            args.append(threshold)
        }
        args.append(limit)
        
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        
        return rows.compactMap { row -> UtteranceSearchResult? in
            guard let utterance = Utterance(row: row) else { return nil }
            
            let rId: Int64? = row["r_id"]
            let rTitle: String? = row["r_title"]
            let rFileName: String? = row["r_file_name"]
            let rFilePath: String? = row["r_file_path"]
            let rDuration: TimeInterval? = row["r_duration"]
            let rLanguage: String? = row["r_language"]
            let rCreatedAt: Date? = row["r_created_at"]
            let rTranscribedAt: Date? = row["r_transcribed_at"]
            let rSource: String? = row["r_source"]
            let rFullTranscript: String? = row["r_full_transcript"]

            var recording = Recording(
                id: rId,
                title: rTitle ?? "",
                fileName: rFileName ?? "",
                filePath: rFilePath,
                duration: rDuration,
                language: rLanguage,
                createdAt: rCreatedAt ?? Date(),
                transcribedAt: rTranscribedAt,
                source: Recording.RecordingSource(rawValue: rSource ?? "recording") ?? .recording,
                fullTranscript: rFullTranscript,
                metadata: nil
            )
            recording.externalId = row["r_external_id"]
            recording.updatedAt = row["r_updated_at"]

            let distanceValue: Double? = row["distance"]
            let distance = Float(distanceValue ?? 2.0)
            let relevanceScore = 1.0 - (distance / 2.0)

            return UtteranceSearchResult(
                utterance: utterance,
                recording: recording,
                distance: distance,
                relevanceScore: relevanceScore
            )
        }
    }

    private func searchWithVectorliteInRecordings(
        db: Database,
        embedding: Data,
        recordingIds: [Int64],
        limit: Int,
        candidateLimit: Int,
        threshold: Float?,
        speakerIds: [String]
    ) throws -> [UtteranceSearchResult] {
        // Embedding is already in blob format (Data), use it directly
        
        // Build recording IDs list
        let recordingIdsList = recordingIds.map { String($0) }.joined(separator: ",")
        let speakerPlaceholders = speakerIds.map { _ in "?" }.joined(separator: ",")

        // Perform KNN search filtered by recordings, ef=100 for good accuracy
        let sql = """
            SELECT
                u.*,
                r.id as r_id, r.title as r_title, r.file_name as r_file_name,
                r.file_path as r_file_path, r.duration as r_duration,
                r.language as r_language, r.created_at as r_created_at,
                r.transcribed_at as r_transcribed_at, r.source as r_source,
                r.full_transcript as r_full_transcript, r.metadata as r_metadata,
                r.external_id as r_external_id, r.updated_at as r_updated_at,
                v.distance as distance
            FROM (
                SELECT rowid, distance
                FROM utterance_vectors
                WHERE knn_search(embedding, knn_param(?, ?, 100))
                \(threshold != nil ? "AND distance <= ?" : "")
            ) v
            JOIN utterances u ON v.rowid = u.id AND u.is_hidden = 0
            JOIN recordings r ON u.recording_id = r.id
            WHERE u.recording_id IN (\(recordingIdsList))
              \(speakerIds.isEmpty ? "" : "AND u.speaker_uuid IN (\(speakerPlaceholders))")
            ORDER BY v.distance
            LIMIT ?
        """
        
        // Build arguments array with proper types
        var args: [DatabaseValueConvertible?] = []
        args.append(embedding)
        args.append(candidateLimit)
        if let threshold = threshold {
            args.append(threshold)
        }
        args.append(contentsOf: speakerIds)
        args.append(limit)
        
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        
        return rows.compactMap { row -> UtteranceSearchResult? in
            guard let utterance = Utterance(row: row) else { return nil }
            
            let rId: Int64? = row["r_id"]
            let rTitle: String? = row["r_title"]
            let rFileName: String? = row["r_file_name"]
            let rFilePath: String? = row["r_file_path"]
            let rDuration: TimeInterval? = row["r_duration"]
            let rLanguage: String? = row["r_language"]
            let rCreatedAt: Date? = row["r_created_at"]
            let rTranscribedAt: Date? = row["r_transcribed_at"]
            let rSource: String? = row["r_source"]
            let rFullTranscript: String? = row["r_full_transcript"]

            var recording = Recording(
                id: rId,
                title: rTitle ?? "",
                fileName: rFileName ?? "",
                filePath: rFilePath,
                duration: rDuration,
                language: rLanguage,
                createdAt: rCreatedAt ?? Date(),
                transcribedAt: rTranscribedAt,
                source: Recording.RecordingSource(rawValue: rSource ?? "recording") ?? .recording,
                fullTranscript: rFullTranscript,
                metadata: nil
            )
            recording.externalId = row["r_external_id"]
            recording.updatedAt = row["r_updated_at"]

            let distanceValue: Double? = row["distance"]
            let distance = Float(distanceValue ?? 2.0)
            let relevanceScore = 1.0 - (distance / 2.0)

            return UtteranceSearchResult(
                utterance: utterance,
                recording: recording,
                distance: distance,
                relevanceScore: relevanceScore
            )
        }
    }

    private func searchDurableEmbeddingsExactly(
        db: Database,
        embedding: Data,
        recordingIds: [Int64],
        limit: Int,
        threshold: Float?,
        speakerIds: [String]
    ) throws -> [UtteranceSearchResult] {
        let query = Self.floatArray(from: embedding)
        guard query.count == EmbeddingPersistence.dimensions else { return [] }
        let queryNorm = sqrt(query.reduce(Float.zero) { $0 + $1 * $1 })
        guard queryNorm > 0 else { return [] }
        let recordingIdsList = recordingIds.map(String.init).joined(separator: ",")
        let speakerPlaceholders = speakerIds.map { _ in "?" }.joined(separator: ",")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT
                    u.*,
                    r.id as r_id, r.title as r_title, r.file_name as r_file_name,
                    r.file_path as r_file_path, r.duration as r_duration,
                    r.language as r_language, r.created_at as r_created_at,
                    r.transcribed_at as r_transcribed_at, r.source as r_source,
                    r.full_transcript as r_full_transcript, r.metadata as r_metadata,
                    r.external_id as r_external_id, r.updated_at as r_updated_at,
                    ue.embedding as durable_embedding
                FROM utterance_embeddings ue
                JOIN utterances u ON u.id = ue.utterance_id AND u.is_hidden = 0
                JOIN recordings r ON r.id = u.recording_id
                WHERE u.recording_id IN (\(recordingIdsList))
                \(speakerIds.isEmpty ? "" : "AND u.speaker_uuid IN (\(speakerPlaceholders))")
            """,
            arguments: StatementArguments(speakerIds)
        )
        var scored: [(row: Row, distance: Float)] = []
        scored.reserveCapacity(rows.count)
        for row in rows {
            let data: Data = row["durable_embedding"]
            let vector = Self.floatArray(from: data)
            guard vector.count == query.count else { continue }
            var dot = Float.zero
            var vectorNormSquared = Float.zero
            for index in query.indices {
                dot += query[index] * vector[index]
                vectorNormSquared += vector[index] * vector[index]
            }
            let vectorNorm = sqrt(vectorNormSquared)
            guard vectorNorm > 0 else { continue }
            let cosine = max(-1, min(1, dot / (queryNorm * vectorNorm)))
            let distance = 1 - cosine
            if let threshold, distance > threshold { continue }
            scored.append((row, distance))
        }
        scored.sort { $0.distance < $1.distance }
        return scored.prefix(limit).compactMap { item in
            guard let utterance = Utterance(row: item.row) else { return nil }
            let rId: Int64? = item.row["r_id"]
            let rTitle: String? = item.row["r_title"]
            let rFileName: String? = item.row["r_file_name"]
            let rFilePath: String? = item.row["r_file_path"]
            let rDuration: TimeInterval? = item.row["r_duration"]
            let rLanguage: String? = item.row["r_language"]
            let rCreatedAt: Date? = item.row["r_created_at"]
            let rTranscribedAt: Date? = item.row["r_transcribed_at"]
            let rSource: String? = item.row["r_source"]
            let rFullTranscript: String? = item.row["r_full_transcript"]
            var recording = Recording(
                id: rId,
                title: rTitle ?? "",
                fileName: rFileName ?? "",
                filePath: rFilePath,
                duration: rDuration,
                language: rLanguage,
                createdAt: rCreatedAt ?? Date(),
                transcribedAt: rTranscribedAt,
                source: Recording.RecordingSource(rawValue: rSource ?? "recording") ?? .recording,
                fullTranscript: rFullTranscript,
                metadata: nil
            )
            recording.externalId = item.row["r_external_id"]
            recording.updatedAt = item.row["r_updated_at"]
            return UtteranceSearchResult(
                utterance: utterance,
                recording: recording,
                distance: item.distance,
                relevanceScore: 1 - (item.distance / 2)
            )
        }
    }

    private static func floatArray(from data: Data) -> [Float] {
        guard data.count.isMultiple(of: MemoryLayout<Float>.size) else { return [] }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }
    
    /// Convert Data to float array
    private func dataToFloatArray(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        var floats = Array<Float>(repeating: 0, count: count)
        _ = floats.withUnsafeMutableBufferPointer { buffer in
            data.copyBytes(to: buffer)
        }
        return floats
    }
    
    // MARK: - Text Search
    
    /// Traditional text search
    func searchByText(query: String, limit: Int = 20) throws -> [Utterance] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM utterances
                    WHERE text LIKE ? AND is_hidden = 0
                    ORDER BY recording_id, utterance_index
                    LIMIT ?
                """,
                arguments: ["%\(query)%", limit]
            )
            
            let results = rows.compactMap { row -> Utterance? in
                let utterance = Utterance(row: row)
                if utterance == nil {
                    logger.error("[GRDBUtteranceRepository] Failed to parse utterance from row: \(row.description)")
                }
                return utterance
            }
            
            logger.info("[GRDBUtteranceRepository] Text search for '\(query)' found \(rows.count) rows, parsed \(results.count) utterances")
            return results
        }
    }
    
    // MARK: - Query by Recording

    /// Get utterances for a specific recording (visible only by default — see getByRecording).
    func getByRecordingId(_ recordingId: Int64, includeHidden: Bool = false) throws -> [Utterance] {
        try getByRecording(id: recordingId, includeHidden: includeHidden)
    }
    
    // MARK: - Statistics
    
    /// Get total number of utterances
    func count() throws -> Int {
        try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM utterances") ?? 0
        }
    }
    
    /// Get number of utterances with embeddings
    func countWithEmbeddings() throws -> Int {
        try db.read { db in
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM utterances WHERE has_embedding = 1") ?? 0
        }
    }
    
    /// Get utterances without embeddings for a recording
    func getUtterancesWithoutEmbeddings(recordingId: Int64, limit: Int = 100) throws -> [Utterance] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM utterances
                    WHERE recording_id = ? AND has_embedding = 0
                    ORDER BY utterance_index
                    LIMIT ?
                """,
                arguments: [recordingId, limit]
            )
            
            return rows.compactMap { Utterance(row: $0) }
        }
    }
    
    /// Check if utterance has embedding
    func hasEmbedding(utteranceId: Int64) throws -> Bool {
        try db.read { db in
            let val = try Int.fetchOne(
                db,
                sql: "SELECT has_embedding FROM utterances WHERE id = ?",
                arguments: [utteranceId]
            ) ?? 0
            return val != 0
        }
    }
}

// MARK: - GRDB Row Init

extension Utterance {
    /// Initialize from GRDB Row using typed subscripts
    init?(row: Row) {
        let recordingId: Int64? = row["recording_id"]
        let utteranceIndex: Int? = row["utterance_index"]
        let startTime: TimeInterval? = row["start_time"]
        let endTime: TimeInterval? = row["end_time"]
        let text: String? = row["text"]
        guard let recordingId, let utteranceIndex, let startTime, let endTime, let text else {
            return nil
        }

        let id: Int64? = row["id"]
        self.id = id
        self.recordingId = recordingId
        self.utteranceIndex = utteranceIndex
        self.startTime = startTime
        self.endTime = endTime
        let speaker: String? = row["speaker"]
        self.speaker = speaker
        let speakerUuid: String? = row["speaker_uuid"]
        self.speakerUuid = speakerUuid
        self.text = text
        let confidence: Float? = row["confidence"]
        self.confidence = confidence

        let hasEmbeddingInt: Int? = row["has_embedding"]
        self.hasEmbedding = (hasEmbeddingInt ?? 0) != 0

        // Cleanup provenance columns (v24); absent on pre-migration rows ⇒ pristine defaults.
        let originalText: String? = row["original_text"]
        self.originalText = originalText
        let textSource: String? = row["text_source"]
        self.textSource = textSource ?? "asr"
        let isHiddenInt: Int? = row["is_hidden"]
        self.isHidden = (isHiddenInt ?? 0) != 0
        let asrMinP: Float? = row["asr_min_p"]
        self.asrMinP = asrMinP
        let asrLowFrac: Float? = row["asr_low_frac"]
        self.asrLowFrac = asrLowFrac
        let suspicion: Double? = row["suspicion"]
        self.suspicion = suspicion
        let suspicionReasons: String? = row["suspicion_reasons"]
        self.suspicionReasons = suspicionReasons
        let reviewStatus: String? = row["review_status"]
        self.reviewStatus = reviewStatus
        let verifierResult: String? = row["verifier_result"]
        self.verifierResult = verifierResult
        let reviewedAt: Date? = row["reviewed_at"]
        self.reviewedAt = reviewedAt
    }
}
