import Foundation
import GRDB
import Accelerate

/// Repository for managing speaker data in GRDB database
class GRDBSpeakerRepository {
    private let db = GRDBDatabaseManager.shared
    private let logger = VoxtralLogger.shared
    
    // MARK: - Create
    
    /// Create a new speaker
    func create(
        uuid: String,
        name: String? = nil,
        embedding: [Float],
        confidence: Float = 1.0,
        notes: String? = nil,
        sourceRecordingId: Int64? = nil
    ) throws -> Int64 {
        // Chokepoint guard: the identity DB must hold a single embedding dimension, or
        // cross-recording cosine matching silently breaks (see SpeakerEmbeddingPolicy).
        try SpeakerEmbeddingPolicy.validate(embedding)
        logger.info("[GRDBSpeakerRepository] Creating speaker | uuid=\(uuid) name=\(name ?? "nil")")

        // Convert embedding to Data
        let embeddingData = embedding.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return Data()
            }
            return Data(bytes: baseAddress, count: bytes.count)
        }

        return try db.write { db in
            let sql = """
                INSERT INTO speakers (
                    uuid, name, embedding, confidence, notes,
                    source_recording_id, created_at, updated_at, last_seen_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """

            let now = Date()
            try db.execute(
                sql: sql,
                arguments: [uuid, name, embeddingData, confidence, notes, sourceRecordingId, now, now, now]
            )

            return db.lastInsertedRowID
        }
    }
    
    // MARK: - Read
    
    /// Get speaker by UUID
    func getByUUID(_ uuid: String) throws -> Speaker? {
        try db.read { db in
            try Speaker.fetchOne(db, sql: "SELECT * FROM speakers WHERE uuid = ?", arguments: [uuid])
        }
    }
    
    /// Get speaker by ID
    func getById(_ id: Int64) throws -> Speaker? {
        try db.read { db in
            try Speaker.fetchOne(db, key: id)
        }
    }
    
    /// Get all speakers
    func getAll() throws -> [Speaker] {
        try db.read { db in
            let hasIdentityState = try db.columns(in: "speakers")
                .contains { $0.name == "identity_state" }
            let sql = hasIdentityState
                ? """
                    SELECT * FROM speakers
                    WHERE COALESCE(identity_state, 'active') = 'active'
                    ORDER BY last_seen_at DESC
                  """
                : "SELECT * FROM speakers ORDER BY last_seen_at DESC"
            return try Speaker.fetchAll(db, sql: sql)
        }
    }
    
    /// Find similar speakers by embedding
    func findSimilarSpeakers(
        to embedding: [Float],
        threshold: Float = 0.7,
        limit: Int = 10
    ) throws -> [(speaker: Speaker, similarity: Float)] {
        
        let speakers = try db.read { db in
            let hasIdentityState = try db.columns(in: "speakers")
                .contains { $0.name == "identity_state" }
            return try Speaker.fetchAll(
                db,
                sql: hasIdentityState
                    ? "SELECT * FROM speakers WHERE COALESCE(identity_state, 'active') = 'active'"
                    : "SELECT * FROM speakers"
            )
        }
        
        var matches: [(Speaker, Float)] = []
        
        for speaker in speakers {
            let similarity = calculateCosineSimilarity(embedding, speaker.embeddingArray)
            if similarity >= threshold {
                matches.append((speaker, similarity))
            }
        }
        
        // Sort by similarity and limit
        matches.sort { $0.1 > $1.1 }
        return Array(matches.prefix(limit))
    }
    
    // MARK: - Update
    
    /// Update speaker
    func update(_ speaker: Speaker) throws {
        try db.write { db in
            var updatedSpeaker = speaker
            updatedSpeaker.updatedAt = Date()
            try updatedSpeaker.update(db)
        }
    }
    
    /// Update speaker name
    func updateName(uuid: String, name: String?) throws {
        try db.write { db in
            let sql = "UPDATE speakers SET name = ?, updated_at = ? WHERE uuid = ?"
            try db.execute(sql: sql, arguments: [name, Date(), uuid])
        }
    }

    /// Set the speaker's name together with its provenance. The identity-inference engine auto-names with
    /// `source = "inferred"`; a user confirmation uses `"manual"`. (`name_source` added in v21.)
    func setName(uuid: String, name: String?, source: String?) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE speakers SET name = ?, name_source = ?, updated_at = ? WHERE uuid = ?",
                arguments: [name, source, Date(), uuid]
            )
        }
    }

    /// True when the speaker carries a name the inference engine must not overwrite — i.e. a user-assigned
    /// name. Legacy names (set before name_source existed, so `name_source IS NULL`) count as user-assigned;
    /// only `name_source = 'inferred'` is fair game to replace or clear.
    func hasUserAssignedName(uuid: String) -> Bool {
        (try? db.read { db -> Bool in
            guard let row = try Row.fetchOne(db, sql: "SELECT name, name_source FROM speakers WHERE uuid = ?", arguments: [uuid]) else {
                return false
            }
            let name: String? = row["name"]
            let source: String? = row["name_source"]
            return (name?.isEmpty == false) && source != "inferred"
        }) ?? false
    }

    /// Undo an auto-applied (inferred) name: clear it only if it was inferred, leaving user names untouched.
    func clearInferredName(uuid: String) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE speakers SET name = NULL, name_source = NULL, updated_at = ? WHERE uuid = ? AND name_source = 'inferred'",
                arguments: [Date(), uuid]
            )
        }
    }

    /// Tombstone a voice the user explicitly rejected an inference for: clears any inferred name and marks
    /// it so the engine stops auto-proposing identities for it (`name_source = 'rejected'`). A later manual
    /// rename clears the tombstone.
    func markInferenceRejected(uuid: String) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE speakers SET name = NULL, name_source = 'rejected', updated_at = ? WHERE uuid = ?",
                arguments: [Date(), uuid]
            )
        }
    }

    /// Voices the user has tombstoned (`name_source = 'rejected'`) — excluded from inference.
    func rejectedVoiceUuids() -> Set<String> {
        (try? db.read { db in
            try String.fetchAll(db, sql: "SELECT uuid FROM speakers WHERE name_source = 'rejected'")
        }).map(Set.init) ?? []
    }

    /// Voices whose current name was auto-applied by the inference engine (`name_source = 'inferred'`) —
    /// shown with an "inferred" badge so they're visually distinct from user-confirmed names.
    func inferredNamedVoiceUuids() -> Set<String> {
        (try? db.read { db in
            try String.fetchAll(db, sql: "SELECT uuid FROM speakers WHERE name_source = 'inferred'")
        }).map(Set.init) ?? []
    }
    
    /// Update speaker statistics
    func updateStatistics(
        uuid: String,
        addDuration: TimeInterval? = nil,
        addUtteranceCount: Int? = nil,
        newEmbedding: [Float]? = nil,
        confidence: Float? = nil
    ) throws {
        try db.write { db in
            // Get current speaker
            guard var speaker = try Speaker.fetchOne(db, sql: "SELECT * FROM speakers WHERE uuid = ?", arguments: [uuid]) else {
                throw GRDBError.recordNotFound
            }
            
            // Update statistics
            if let duration = addDuration {
                speaker.totalDuration += duration
            }
            
            if let count = addUtteranceCount {
                speaker.utteranceCount += count
            }
            
            if let embedding = newEmbedding {
                // Average with existing embedding
                let currentEmbedding = speaker.embeddingArray
                var averagedEmbedding: [Float] = []
                
                for i in 0..<min(currentEmbedding.count, embedding.count) {
                    let weight = Float(speaker.embeddingCount)
                    averagedEmbedding.append((currentEmbedding[i] * weight + embedding[i]) / (weight + 1))
                }
                
                speaker.embedding = averagedEmbedding.withUnsafeBytes { bytes in
                    guard let baseAddress = bytes.baseAddress else {
                        return Data()
                    }
                    return Data(bytes: baseAddress, count: bytes.count)
                }
                speaker.embeddingCount += 1
            }
            
            if let conf = confidence {
                // Update confidence with weighted average
                let weight = Float(speaker.embeddingCount - 1)
                speaker.confidence = (speaker.confidence * weight + conf) / Float(speaker.embeddingCount)
            }
            
            speaker.updatedAt = Date()
            speaker.lastSeenAt = Date()
            
            try speaker.update(db)
            
            // Store embedding in history if provided
            if let embedding = newEmbedding {
                try db.execute(
                    sql: """
                        INSERT INTO speaker_embedding_history (
                            speaker_id, embedding, confidence, created_at
                        ) VALUES (?, ?, ?, ?)
                    """,
                    arguments: [
                        speaker.id,
                        embedding.withUnsafeBytes { bytes in
                            guard let baseAddress = bytes.baseAddress else {
                                return Data()
                            }
                            return Data(bytes: baseAddress, count: bytes.count)
                        },
                        confidence ?? 1.0,
                        Date()
                    ]
                )
            }
        }
    }
    
    // MARK: - Delete
    
    /// Delete speaker by UUID, taking its attendee mappings with it (so nothing dangles).
    func delete(uuid: String) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM speakers WHERE uuid = ?", arguments: [uuid])
            try db.execute(sql: "DELETE FROM speaker_attendee_mappings WHERE speaker_uuid = ?", arguments: [uuid])
        }
    }

    /// A speaker the user has explicitly identified: a user-assigned name (manual provenance, or a legacy
    /// name from before `name_source` existed, i.e. NULL) OR a manual attendee mapping. Automatic cleanup
    /// must NEVER cull these — doing so can silently destroy user work when placeholder cleanup removes
    /// a manually identified voice and orphans its mapping.
    static let userIdentifiedSpeakerSQL = """
        ((name IS NOT NULL AND name <> '' AND (name_source IS NULL OR name_source = 'manual'))
         OR uuid IN (SELECT speaker_uuid FROM speaker_attendee_mappings WHERE source = 'manual'))
        """

    /// Delete speakers not referenced by any utterance — but keep any the user has identified, and clean up
    /// mappings left dangling by this or any earlier deletion. Static-over-`Database` for testability.
    @discardableResult
    static func deleteOrphaned(_ db: Database) throws -> Int {
        let hasIdentityState = try db.columns(in: "speakers")
            .contains { $0.name == "identity_state" }
        let aliasProtection = hasIdentityState
            ? "AND COALESCE(identity_state, 'active') <> 'alias'"
            : ""
        try db.execute(sql: """
            DELETE FROM speakers
            WHERE uuid NOT IN (SELECT DISTINCT speaker_uuid FROM utterances WHERE speaker_uuid IS NOT NULL)
              AND NOT \(userIdentifiedSpeakerSQL)
              \(aliasProtection)
        """)
        let deleted = db.changesCount
        try db.execute(sql: "DELETE FROM speaker_attendee_mappings WHERE speaker_uuid NOT IN (SELECT uuid FROM speakers)")
        return deleted
    }

    @discardableResult
    func deleteOrphaned() throws -> Int {
        try db.write { try Self.deleteOrphaned($0) }
    }

    /// Merge multiple speakers into one
    func mergeSpeakers(sourceUUIDs: [String], targetUUID: String) throws {
        try db.write { db in
            if try db.tableExists("speaker_global_assignments") {
                for sourceUUID in sourceUUIDs where sourceUUID != targetUUID {
                    try GlobalSpeakerIdentityStore.link(
                        db,
                        sourceUUID: sourceUUID,
                        targetUUID: targetUUID,
                        linkSource: .manual
                    )
                }
                return
            }
            // Update all utterances to use target speaker
            for sourceUUID in sourceUUIDs where sourceUUID != targetUUID {
                let sql = "UPDATE utterances SET speaker_uuid = ? WHERE speaker_uuid = ?"
                try db.execute(sql: sql, arguments: [targetUUID, sourceUUID])
                
                // Delete source speaker + its mappings (target keeps its own identity; don't orphan rows)
                try db.execute(sql: "DELETE FROM speakers WHERE uuid = ?", arguments: [sourceUUID])
                try db.execute(sql: "DELETE FROM speaker_attendee_mappings WHERE speaker_uuid = ?", arguments: [sourceUUID])
            }
            
            // Update target speaker statistics
            let sql = """
                UPDATE speakers 
                SET utterance_count = (
                    SELECT COUNT(*) FROM utterances WHERE speaker_uuid = ?
                ),
                updated_at = ?
                WHERE uuid = ?
            """
            try db.execute(sql: sql, arguments: [targetUUID, Date(), targetUUID])
            try Self.recomputeMean(
                db,
                uuid: targetUUID,
                policy: SpeakerPipelineSettings.shared.activeConfiguration.centroidPolicy
            )
        }
    }
    
    // MARK: - Query Methods

    /// Get all speakers that appeared in a specific recording
    func getSpeakersForRecording(recordingId: Int64) throws -> [(speaker: Speaker, duration: TimeInterval)] {
        try db.read { db in
            let rows = try Row.fetchAll(db,
                sql: """
                    SELECT s.*, SUM(u.end_time - u.start_time) as recording_duration
                    FROM speakers s
                    JOIN utterances u ON u.speaker_uuid = s.uuid
                    WHERE u.recording_id = ?
                    GROUP BY s.uuid
                    ORDER BY recording_duration DESC
                """,
                arguments: [recordingId]
            )
            return rows.compactMap { row in
                guard let speaker = try? Speaker(row: row) else { return nil }
                let duration: Double = row["recording_duration"] ?? 0
                return (speaker, duration)
            }
        }
    }

    /// Get all utterances for a speaker, joined with recording details
    func getUtterancesForSpeaker(uuid: String) throws -> [(utterance: SpeakerUtteranceRow, recordingTitle: String, audioPath: String?)] {
        try db.read { try Self.utterancesForSpeaker($0, uuid: uuid) }
    }

    /// Calendar meetings connected to a speaker via the recordings they appear in.
    /// Each meeting appears once, collapsed to its strongest match confidence, newest first.
    func getMeetingsForSpeaker(uuid: String) throws -> [(meeting: Meeting, confidence: RecordingMeeting.MatchConfidence)] {
        try db.read { try Self.meetingsForSpeaker($0, uuid: uuid) }
    }

    /// Other speakers who frequently appear in the same recordings as this speaker.
    func getCoAppearances(uuid: String, limit: Int = 8) throws -> [(speaker: Speaker, sharedRecordings: Int)] {
        try db.read { try Self.coAppearances($0, uuid: uuid, limit: limit) }
    }

    // MARK: - People Page Query Cores
    //
    // These are `static` over a `Database` so they can be unit-tested against an in-memory
    // DatabaseQueue (see SpeakerQueriesTests), independent of the fixed-path shared manager.

    /// All utterances for a speaker joined with recording title/path/date, newest recording first.
    static func utterancesForSpeaker(_ db: Database, uuid: String) throws -> [(utterance: SpeakerUtteranceRow, recordingTitle: String, audioPath: String?)] {
        let rows = try Row.fetchAll(db,
            sql: """
                SELECT
                    u.id, u.text, u.start_time, u.end_time, u.speaker_uuid, u.recording_id,
                    r.title as recording_title, r.file_path as audio_path, r.created_at as recording_date
                FROM utterances u
                JOIN recordings r ON u.recording_id = r.id
                WHERE u.speaker_uuid = ?
                ORDER BY r.created_at DESC, u.start_time ASC
            """,
            arguments: [uuid]
        )
        return rows.compactMap { row in
            guard let id: Int64 = row["id"],
                  let text: String = row["text"],
                  let startTime: Double = row["start_time"],
                  let endTime: Double = row["end_time"] else { return nil }
            let recordingId: Int64 = row["recording_id"] ?? 0
            let title: String = row["recording_title"] ?? "Unknown"
            let audioPath: String? = row["audio_path"]
            let recordingDate: Date = row["recording_date"] ?? Date()
            let utterance = SpeakerUtteranceRow(
                id: id, text: text, startTime: startTime, endTime: endTime,
                speakerUUID: uuid, recordingId: recordingId, recordingDate: recordingDate
            )
            return (utterance, title, audioPath)
        }
    }

    /// Distinct meetings connected to a speaker (via the recordings they appear in), each collapsed
    /// to its strongest match confidence, newest meeting first. Dismissed links are excluded.
    static func meetingsForSpeaker(_ db: Database, uuid: String) throws -> [(meeting: Meeting, confidence: RecordingMeeting.MatchConfidence)] {
        let rows = try Row.fetchAll(db,
            sql: """
                SELECT m.*,
                    MAX(CASE rm.match_confidence
                            WHEN 'matched' THEN 2
                            WHEN 'suggested' THEN 1
                            ELSE 0 END) AS conf_rank
                FROM meetings m
                JOIN recording_meetings rm ON rm.meeting_id = m.id AND rm.is_dismissed = 0
                WHERE rm.recording_id IN (
                    SELECT DISTINCT recording_id FROM utterances WHERE speaker_uuid = ?
                )
                GROUP BY m.id
                ORDER BY m.start_date DESC
            """,
            arguments: [uuid]
        )
        return rows.compactMap { row in
            guard let meeting = Meeting(row: row) else { return nil }
            let rank: Int = row["conf_rank"] ?? 2
            let confidence: RecordingMeeting.MatchConfidence = rank >= 2 ? .matched : (rank == 1 ? .suggested : .possible)
            return (meeting, confidence)
        }
    }

    /// Other speakers who share recordings with this speaker, ordered by shared-recording count desc.
    static func coAppearances(_ db: Database, uuid: String, limit: Int = 8) throws -> [(speaker: Speaker, sharedRecordings: Int)] {
        let rows = try Row.fetchAll(db,
            sql: """
                SELECT s.*, COUNT(DISTINCT u.recording_id) AS shared
                FROM utterances u
                JOIN speakers s ON s.uuid = u.speaker_uuid
                WHERE u.recording_id IN (
                    SELECT DISTINCT recording_id FROM utterances WHERE speaker_uuid = ?
                )
                AND u.speaker_uuid <> ?
                GROUP BY u.speaker_uuid
                ORDER BY shared DESC, s.last_seen_at DESC
                LIMIT ?
            """,
            arguments: [uuid, uuid, limit]
        )
        return rows.compactMap { row in
            guard let speaker = try? Speaker(row: row) else { return nil }
            let shared: Int = row["shared"] ?? 0
            return (speaker, shared)
        }
    }

    /// All speakers as profiles with stats computed LIVE from utterances (utterance count, talk time,
    /// last seen) — the cached `speakers.utterance_count`/`total_duration` columns are frequently stale
    /// (0) after diarization/merges, so we never trust them for display. Sorted by real talk volume.
    /// When `includeEmpty` is false, speakers with no utterances (over-split noise) are dropped.
    static func speakersWithStats(_ db: Database, includeEmpty: Bool) throws -> [SpeakerProfile] {
        let having = includeEmpty ? "" : "HAVING real_count > 0"
        let rows = try Row.fetchAll(db,
            sql: """
                SELECT s.*,
                    COUNT(u.id) AS real_count,
                    COALESCE(SUM(u.end_time - u.start_time), 0) AS real_duration,
                    MAX(r.created_at) AS real_last_seen
                FROM speakers s
                LEFT JOIN utterances u ON u.speaker_uuid = s.uuid
                LEFT JOIN recordings r ON r.id = u.recording_id
                GROUP BY s.uuid
                \(having)
                ORDER BY real_count DESC, s.name IS NULL, s.name COLLATE NOCASE ASC
            """
        )
        return rows.compactMap { row in
            guard let speaker = try? Speaker(row: row) else { return nil }
            var profile = speaker.toProfile()
            profile.utteranceCount = row["real_count"] ?? 0
            profile.totalDuration = row["real_duration"] ?? 0
            if let last: Date = row["real_last_seen"] { profile.lastSeen = last }
            return profile
        }
    }

    /// Speakers with live-computed stats (see `speakersWithStats`). Excludes empty speakers by default.
    func getSpeakersWithStats(includeEmpty: Bool = false) throws -> [SpeakerProfile] {
        try db.read { try Self.speakersWithStats($0, includeEmpty: includeEmpty) }
    }

    /// Get recordings where a speaker appears
    func getRecordingsForSpeaker(uuid: String, limit: Int = 50) throws -> [SpeakerRecordingRow] {
        try db.read { db in
            let rows = try Row.fetchAll(db,
                sql: """
                    SELECT DISTINCT
                        r.id, r.title, r.created_at, r.file_path,
                        COUNT(u.id) as utterance_count,
                        SUM(u.end_time - u.start_time) as speaker_duration
                    FROM recordings r
                    JOIN utterances u ON u.recording_id = r.id
                    WHERE u.speaker_uuid = ?
                    GROUP BY r.id
                    ORDER BY r.created_at DESC
                    LIMIT ?
                """,
                arguments: [uuid, limit]
            )
            return rows.compactMap { row in
                guard let id: Int64 = row["id"],
                      let title: String = row["title"],
                      let createdAt: Date = row["created_at"] else { return nil }
                let filePath: String? = row["file_path"]
                let utteranceCount: Int = row["utterance_count"] ?? 0
                let speakerDuration: Double = row["speaker_duration"] ?? 0
                return SpeakerRecordingRow(
                    id: id, title: title, createdAt: createdAt,
                    filePath: filePath, utteranceCount: utteranceCount,
                    speakerDuration: speakerDuration
                )
            }
        }
    }

    /// Get all speakers that have no name assigned
    func getUnnamedSpeakers() throws -> [Speaker] {
        try db.read { db in
            let hasIdentityState = try db.columns(in: "speakers")
                .contains { $0.name == "identity_state" }
            let active = hasIdentityState
                ? " AND COALESCE(identity_state, 'active') = 'active'"
                : ""
            return try Speaker.fetchAll(
                db,
                sql: """
                    SELECT * FROM speakers
                    WHERE name IS NULL \(active)
                    ORDER BY last_seen_at DESC
                """
            )
        }
    }

    /// Merge speakers with history tracking for undo support
    func mergeSpeakersWithHistory(
        primaryUUID: String,
        secondaryUUIDs: [String],
        mergeHistoryRepo: SpeakerMergeHistoryRepository,
        mergedBy: String = "manual"
    ) throws {
        for secondaryUUID in secondaryUUIDs where secondaryUUID != primaryUUID {
            // Get secondary speaker data before merge
            guard let secondarySpeaker = try getByUUID(secondaryUUID) else { continue }

            // Get utterance IDs for undo support
            let utteranceIds: [Int64] = try db.read { db in
                try Int64.fetchAll(db,
                    sql: "SELECT id FROM utterances WHERE speaker_uuid = ?",
                    arguments: [secondaryUUID]
                )
            }

            // Record merge history
            let profile = secondarySpeaker.toProfile()
            try mergeHistoryRepo.recordMerge(
                primaryUUID: primaryUUID,
                mergedSpeaker: profile,
                utteranceIds: utteranceIds,
                mergedBy: mergedBy
            )

            // The v31 identity layer changes only the local-cluster projection. The source profile
            // remains as a reversible alias; older databases retain the legacy fallback.
            try db.write { database in
                if try database.tableExists("speaker_global_assignments") {
                    try GlobalSpeakerIdentityStore.link(
                        database,
                        sourceUUID: secondaryUUID,
                        targetUUID: primaryUUID,
                        linkSource: mergedBy.hasPrefix("automatic") ? .automatic : .manual,
                        evidenceJSON: #"{"origin":"merge-with-history"}"#
                    )
                } else {
                    try database.execute(
                        sql: "UPDATE utterances SET speaker_uuid = ? WHERE speaker_uuid = ?",
                        arguments: [primaryUUID, secondaryUUID]
                    )
                    try database.execute(
                        sql: "DELETE FROM speakers WHERE uuid = ?",
                        arguments: [secondaryUUID]
                    )
                    try database.execute(
                        sql: "DELETE FROM speaker_attendee_mappings WHERE speaker_uuid = ?",
                        arguments: [secondaryUUID]
                    )
                }
            }
        }
    }

    // MARK: - Voice mean + per-utterance reassignment

    /// Recompute a speaker's mean voice embedding as the L2-normalized average of its utterances'
    /// stored voice vectors. No-op when the speaker has no stored vectors (keeps the legacy mean).
    /// Static over `Database` for testability (see VoiceEmbeddingTests).
    static func recomputeMean(
        _ db: Database,
        uuid: String,
        policy: SpeakerCentroidPolicy = .equalTurns
    ) throws {
        if try db.tableExists("speaker_global_assignments"),
           try Int.fetchOne(
               db,
               sql: """
                   SELECT COUNT(*) FROM speaker_global_assignments
                   WHERE speaker_uuid = ?
               """,
               arguments: [uuid]
           ) ?? 0 > 0 {
            try GlobalSpeakerIdentityStore.refreshProfile(db, uuid: uuid)
            return
        }
        let weighted: [(vector: [Float], weight: Float)]
        if policy == .equalTurns {
            weighted = try VoiceEmbeddingStore.loadForSpeaker(db, uuid: uuid)
                .map { ($0.embedding, 1) }
        } else {
            weighted = try VoiceEmbeddingStore.loadWeightedForSpeaker(db, uuid: uuid, policy: policy)
                .map { (vector: $0.embedding, weight: $0.weight) }
        }
        guard let mean = VoiceMath.weightedMeanNormalized(weighted) else { return }
        try db.execute(
            sql: "UPDATE speakers SET embedding = ?, embedding_count = ?, updated_at = ? WHERE uuid = ?",
            arguments: [VoiceEmbeddingStore.floatsToData(mean), weighted.count, Date(), uuid]
        )
        if try db.tableExists("speaker_voice_prototypes") {
            try SpeakerVoicePrototypeStore.rebuild(db, speakerUUID: uuid, policy: policy)
        }
    }

    func recomputeMean(uuid: String, policy: SpeakerCentroidPolicy = .equalTurns) throws {
        try db.write { try Self.recomputeMean($0, uuid: uuid, policy: policy) }
    }

    /// Reassign a single utterance to another speaker and recompute both speakers' means so voice
    /// matching stays correct. Static core for testability.
    static func reassignUtterance(_ db: Database, utteranceId: Int64, toUUID: String, label: String?) throws {
        if try db.tableExists("speaker_global_assignments") {
            let recordingId = try Int64.fetchOne(
                db,
                sql: "SELECT recording_id FROM utterances WHERE id = ?",
                arguments: [utteranceId]
            )
            try GlobalSpeakerIdentityStore.assignUtterance(
                db,
                utteranceId: utteranceId,
                to: toUUID,
                displayLabel: label
            )
            if let recordingId {
                try SpeakerGoldReviewStore.markInProgress(db, recordingId: recordingId)
            }
            return
        }
        let oldUUID = try String.fetchOne(db, sql: "SELECT speaker_uuid FROM utterances WHERE id = ?", arguments: [utteranceId])
        let recordingId = try Int64.fetchOne(
            db,
            sql: "SELECT recording_id FROM utterances WHERE id = ?",
            arguments: [utteranceId]
        )
        try db.execute(
            sql: "UPDATE utterances SET speaker_uuid = ?, speaker = ?, speaker_assignment_source = ?, speaker_reviewed_at = ? WHERE id = ?",
            arguments: [toUUID, label, SpeakerAssignmentSource.manual.rawValue, Date(), utteranceId]
        )
        let policy = SpeakerPipelineSettings.shared.activeConfiguration.centroidPolicy
        try recomputeMean(db, uuid: toUUID, policy: policy)
        if let oldUUID, oldUUID != toUUID { try recomputeMean(db, uuid: oldUUID, policy: policy) }
        if let recordingId {
            try SpeakerGoldReviewStore.markInProgress(db, recordingId: recordingId)
        }
    }

    func reassignUtterance(utteranceId: Int64, toUUID: String, label: String? = nil) throws {
        try db.write { try Self.reassignUtterance($0, utteranceId: utteranceId, toUUID: toUUID, label: label) }
    }

    // MARK: - Helper Methods
    
    private func calculateCosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(a.count))
        vDSP_dotpr(a, 1, a, 1, &normA, vDSP_Length(a.count))
        vDSP_dotpr(b, 1, b, 1, &normB, vDSP_Length(b.count))

        let denominator = sqrt(normA) * sqrt(normB)
        return denominator > 0 ? dotProduct / denominator : 0
    }
}

// MARK: - Speaker Model

struct Speaker: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "speakers"
    
    var id: Int64?
    var uuid: String
    var name: String?
    var embedding: Data
    var embeddingCount: Int
    var totalDuration: TimeInterval
    var utteranceCount: Int
    var createdAt: Date
    var updatedAt: Date
    var lastSeenAt: Date
    var confidence: Float
    var notes: String?
    var sourceRecordingId: Int64?

    // MARK: - Column mapping for snake_case database columns
    enum CodingKeys: String, CodingKey {
        case id
        case uuid
        case name
        case embedding
        case embeddingCount = "embedding_count"
        case totalDuration = "total_duration"
        case utteranceCount = "utterance_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastSeenAt = "last_seen_at"
        case confidence
        case notes
        case sourceRecordingId = "source_recording_id"
    }
    
    // Computed property to get embedding as Float array
    var embeddingArray: [Float] {
        embedding.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: Float.self))
        }
    }

    /// Convert database record to UI model
    func toProfile() -> SpeakerProfile {
        SpeakerProfile(
            id: id.map { Int($0) },
            uuid: uuid,
            name: name,
            notes: notes,
            averageEmbedding: embeddingArray,
            totalDuration: totalDuration,
            utteranceCount: utteranceCount,
            firstSeen: createdAt,
            lastSeen: lastSeenAt,
            confidence: confidence,
            sourceRecordingId: sourceRecordingId.map { Int($0) }
        )
    }
}

// MARK: - Lightweight Row Types

struct SpeakerUtteranceRow {
    let id: Int64
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let speakerUUID: String
    let recordingId: Int64
    let recordingDate: Date

    var duration: TimeInterval { endTime - startTime }
}

struct SpeakerRecordingRow {
    let id: Int64
    let title: String
    let createdAt: Date
    let filePath: String?
    let utteranceCount: Int
    let speakerDuration: TimeInterval
}

// MARK: - GRDB Error Extension

enum GRDBError: LocalizedError {
    case recordNotFound
    
    var errorDescription: String? {
        switch self {
        case .recordNotFound:
            return "Record not found in database"
        }
    }
}
