import Foundation
import GRDB

enum SpeakerProfileSplitError: LocalizedError {
    case speakerNotFound
    case notEnoughLocalClusters
    case invalidAnchor
    case previewOutOfDate
    case noSplitToUndo
    case splitChangedAfterCreation

    var errorDescription: String? {
        switch self {
        case .speakerNotFound:
            return "This speaker profile no longer exists."
        case .notEnoughLocalClusters:
            return "There are not enough distinct voice groups to split."
        case .invalidAnchor:
            return "Choose which group should keep the original speaker profile."
        case .previewOutOfDate:
            return "This profile changed after the preview was made. Re-analyze it before applying the split."
        case .noSplitToUndo:
            return "There is no automatic split to undo."
        case .splitChangedAfterCreation:
            return "This split cannot be undone automatically because one of its new profiles was renamed, mapped, merged, or received additional utterances."
        }
    }
}

/// Bulk repair for a contaminated global speaker profile.
///
/// The important unit is not an individual utterance. It is a recording-local diarizer cluster:
/// `(recording_id, speaker label)`. All utterances in that cluster travel together, including old
/// utterances that predate durable voice embeddings. This turns a 2,000-line repair into clustering
/// tens of local voice centroids.
///
/// Complete linkage is the safe default: every local cluster in a proposed person must match every
/// other cluster. An optional cannot-link constraint also prevents two different local diarizer labels
/// from one recording being folded back together. Neither rule pretends to solve simultaneous speech;
/// overlapping speech needs multi-label diarization and is explicitly called out in the UI.
enum SpeakerProfileSplitter {
    struct Sample: Identifiable, Equatable {
        let utteranceId: Int64
        let text: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let audioPath: String?
        let recordingTitle: String
        let recordingDate: Date

        var id: Int64 { utteranceId }

        var quoteItem: QuoteItem {
            QuoteItem(
                id: Int(utteranceId),
                text: text,
                start: startTime,
                end: endTime,
                audioPath: audioPath,
                recordingTitle: recordingTitle,
                recordingDate: recordingDate
            )
        }
    }

    struct LocalCluster: Identifiable, Equatable {
        let key: String
        let localClusterId: Int64?
        let recordingId: Int64
        let recordingTitle: String
        let recordingDate: Date
        let localLabel: String
        let utteranceIds: [Int64]
        let utteranceCount: Int
        let duration: TimeInterval
        let vectorCount: Int
        let centroid: [Float]?
        let sample: Sample?

        var id: String { key }
    }

    struct Group: Identifiable, Equatable {
        let id: String
        let clusters: [LocalCluster]
        let centroid: [Float]?
        let minimumSimilarity: Float?

        var utteranceIds: [Int64] { clusters.flatMap(\.utteranceIds) }
        var utteranceCount: Int { clusters.reduce(0) { $0 + $1.utteranceCount } }
        var duration: TimeInterval { clusters.reduce(0) { $0 + $1.duration } }
        var vectorCount: Int { clusters.reduce(0) { $0 + $1.vectorCount } }
        var recordingCount: Int { Set(clusters.map(\.recordingId)).count }
        var lacksVoiceprint: Bool { vectorCount == 0 }
        var samples: [Sample] { clusters.compactMap(\.sample) }
    }

    struct Preview: Equatable {
        let sourceSpeakerUUID: String
        let threshold: Float
        let linkage: PersonaLinkage
        let keepLocalLabelsSeparate: Bool
        let groups: [Group]
        let localClusterCount: Int
        let utteranceCount: Int
        let vectorCount: Int
        let duration: TimeInterval

        var vectorCoverage: Double {
            guard utteranceCount > 0 else { return 0 }
            return Double(vectorCount) / Double(utteranceCount)
        }

        var unresolvedGroupCount: Int { groups.filter(\.lacksVoiceprint).count }
        var suggestedAnchorGroupID: String? { groups.max(by: { $0.duration < $1.duration })?.id }
    }

    struct ApplyResult: Equatable {
        let operationID: String
        let createdSpeakerUUIDs: [String]
        let movedUtteranceCount: Int
        let affectedRecordingCount: Int
    }

    struct UndoResult: Equatable {
        let operationID: String
        let removedSpeakerCount: Int
        let restoredUtteranceCount: Int
    }

    private struct ClusterBuilder {
        let localClusterId: Int64?
        let recordingId: Int64
        let recordingTitle: String
        let recordingDate: Date
        let localLabel: String
        var utteranceIds: [Int64] = []
        var duration: TimeInterval = 0
        var vectors: [[Float]] = []
        var sample: Sample?
        var sampleScore: Double = -.infinity

        func build(key: String) -> LocalCluster {
            LocalCluster(
                key: key,
                localClusterId: localClusterId,
                recordingId: recordingId,
                recordingTitle: recordingTitle,
                recordingDate: recordingDate,
                localLabel: localLabel,
                utteranceIds: utteranceIds,
                utteranceCount: utteranceIds.count,
                duration: duration,
                vectorCount: vectors.count,
                centroid: VoiceMath.meanNormalized(vectors),
                sample: sample
            )
        }
    }

    static func migrate(_ db: Database) throws {
        try db.create(table: "speaker_split_operations", ifNotExists: true) { table in
            table.column("id", .text).primaryKey()
            table.column("source_speaker_uuid", .text).notNull()
            table.column("anchor_group_id", .text).notNull()
            table.column("threshold", .double).notNull()
            table.column("linkage", .text).notNull()
            table.column("keep_local_labels_separate", .boolean).notNull()
            table.column("created_at", .datetime).notNull()
            table.column("undone_at", .datetime)
        }
        try db.create(
            index: "idx_speaker_split_operations_source",
            on: "speaker_split_operations",
            columns: ["source_speaker_uuid", "created_at"],
            ifNotExists: true
        )
        try db.create(table: "speaker_split_created_speakers", ifNotExists: true) { table in
            table.column("operation_id", .text).notNull()
                .references("speaker_split_operations", onDelete: .cascade)
            table.column("speaker_uuid", .text).notNull()
            table.primaryKey(["operation_id", "speaker_uuid"])
        }
        try db.create(table: "speaker_split_assignments", ifNotExists: true) { table in
            table.column("operation_id", .text).notNull()
                .references("speaker_split_operations", onDelete: .cascade)
            table.column("utterance_id", .integer).notNull()
                .references("utterances", onDelete: .cascade)
            table.column("previous_speaker_uuid", .text)
            table.column("new_speaker_uuid", .text).notNull()
            table.column("previous_assignment_source", .text)
            table.column("previous_reviewed_at", .datetime)
            table.primaryKey(["operation_id", "utterance_id"])
        }
        try db.create(
            index: "idx_speaker_split_assignments_new_speaker",
            on: "speaker_split_assignments",
            columns: ["new_speaker_uuid"],
            ifNotExists: true
        )
    }

    static func preview(
        sourceSpeakerUUID: String,
        threshold: Float,
        linkage: PersonaLinkage = .complete,
        keepLocalLabelsSeparate: Bool = true
    ) throws -> Preview {
        try GRDBDatabaseManager.shared.read {
            try preview(
                $0,
                sourceSpeakerUUID: sourceSpeakerUUID,
                threshold: threshold,
                linkage: linkage,
                keepLocalLabelsSeparate: keepLocalLabelsSeparate
            )
        }
    }

    static func preview(
        _ db: Database,
        sourceSpeakerUUID: String,
        threshold: Float,
        linkage: PersonaLinkage = .complete,
        keepLocalLabelsSeparate: Bool = true
    ) throws -> Preview {
        guard try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM speakers WHERE uuid = ?)",
            arguments: [sourceSpeakerUUID]
        ) == true else {
            throw SpeakerProfileSplitError.speakerNotFound
        }

        let utteranceColumns = Set(try db.columns(in: "utterances").map(\.name))
        let hasLocalIdentity = try db.tableExists("speaker_global_assignments")
            && utteranceColumns.contains("local_speaker_cluster_id")
            && utteranceColumns.contains("local_speaker_label")
        let localClusterSelect = hasLocalIdentity
            ? "u.local_speaker_cluster_id"
            : "NULL"
        let localLabelSelect = hasLocalIdentity
            ? "COALESCE(u.local_speaker_label, u.speaker, '')"
            : "COALESCE(u.speaker, '')"
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT
                    u.id,
                    u.recording_id,
                    \(localClusterSelect) AS local_cluster_id,
                    \(localLabelSelect) AS local_label,
                    u.start_time,
                    u.end_time,
                    r.title AS recording_title,
                    r.created_at AS recording_date,
                    r.file_path AS audio_path,
                    u.text,
                    v.embedding AS voice_embedding
                FROM utterances u
                JOIN recordings r ON r.id = u.recording_id
                LEFT JOIN utterance_voice_embeddings v ON v.utterance_id = u.id
                WHERE u.speaker_uuid = ?
                ORDER BY u.recording_id, local_label, u.start_time, u.id
            """,
            arguments: [sourceSpeakerUUID]
        )

        var builders: [String: ClusterBuilder] = [:]
        for row in rows {
            let recordingId: Int64 = row["recording_id"]
            let localClusterId: Int64? = row["local_cluster_id"]
            let localLabel: String = row["local_label"]
            let key = localClusterId.map { "cluster:\($0)" }
                ?? clusterKey(recordingId: recordingId, localLabel: localLabel)
            if builders[key] == nil {
                builders[key] = ClusterBuilder(
                    localClusterId: localClusterId,
                    recordingId: recordingId,
                    recordingTitle: row["recording_title"],
                    recordingDate: row["recording_date"],
                    localLabel: localLabel
                )
            }
            guard var builder = builders[key] else { continue }
            let utteranceId: Int64 = row["id"]
            let start: Double = row["start_time"]
            let end: Double = row["end_time"]
            let text: String = row["text"]
            builder.utteranceIds.append(utteranceId)
            let utteranceDuration = max(0, end - start)
            builder.duration += utteranceDuration
            let audioPath: String? = row["audio_path"]
            if let data: Data = row["voice_embedding"] {
                let vector = VoiceEmbeddingStore.dataToFloats(data)
                if vector.count == VoiceEmbeddingStore.dimensions {
                    builder.vectors.append(vector)
                }
            }
            // Prefer a clear, medium-length vector-backed example. The preview only needs a few
            // representative clips per proposed person, not a manual review of every utterance.
            if audioPath?.isEmpty == false, utteranceDuration >= 1.5 {
                let hasVector: Bool = row["voice_embedding"] != nil
                let targetLengthScore = 20 - abs(min(30, utteranceDuration) - 8)
                let score = (hasVector ? 100 : 0) + targetLengthScore + min(20, Double(text.count) / 20)
                if score > builder.sampleScore {
                    builder.sampleScore = score
                    builder.sample = Sample(
                        utteranceId: utteranceId,
                        text: text,
                        startTime: start,
                        endTime: min(end, start + 20),
                        audioPath: audioPath,
                        recordingTitle: row["recording_title"],
                        recordingDate: row["recording_date"]
                    )
                }
            }
            builders[key] = builder
        }

        let clusters = builders
            .map { $0.value.build(key: $0.key) }
            .sorted {
                if $0.recordingDate != $1.recordingDate { return $0.recordingDate < $1.recordingDate }
                if $0.recordingId != $1.recordingId { return $0.recordingId < $1.recordingId }
                return $0.localLabel < $1.localLabel
            }
        guard clusters.count >= 2 else { throw SpeakerProfileSplitError.notEnoughLocalClusters }

        let vectorized = clusters.filter { $0.centroid != nil }
        let unresolved = clusters.filter { $0.centroid == nil }
        var groupedIndices = cluster(
            vectorized,
            threshold: threshold,
            linkage: linkage,
            keepLocalLabelsSeparate: keepLocalLabelsSeparate
        )
        groupedIndices.append(contentsOf: unresolved.map { [$0] })

        let groups = groupedIndices.map(makeGroup).sorted {
            if $0.duration != $1.duration { return $0.duration > $1.duration }
            return $0.id < $1.id
        }

        return Preview(
            sourceSpeakerUUID: sourceSpeakerUUID,
            threshold: threshold,
            linkage: linkage,
            keepLocalLabelsSeparate: keepLocalLabelsSeparate,
            groups: groups,
            localClusterCount: clusters.count,
            utteranceCount: clusters.reduce(0) { $0 + $1.utteranceCount },
            vectorCount: clusters.reduce(0) { $0 + $1.vectorCount },
            duration: clusters.reduce(0) { $0 + $1.duration }
        )
    }

    static func apply(_ preview: Preview, anchorGroupID: String) throws -> ApplyResult {
        try GRDBDatabaseManager.shared.write {
            try apply($0, preview: preview, anchorGroupID: anchorGroupID)
        }
    }

    static func apply(
        _ db: Database,
        preview: Preview,
        anchorGroupID: String,
        now: Date = Date()
    ) throws -> ApplyResult {
        guard preview.groups.count >= 2 else { throw SpeakerProfileSplitError.notEnoughLocalClusters }
        guard preview.groups.contains(where: { $0.id == anchorGroupID }) else {
            throw SpeakerProfileSplitError.invalidAnchor
        }
        guard try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM speakers WHERE uuid = ?)",
            arguments: [preview.sourceSpeakerUUID]
        ) == true else {
            throw SpeakerProfileSplitError.speakerNotFound
        }
        let currentUtteranceCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM utterances WHERE speaker_uuid = ?",
            arguments: [preview.sourceSpeakerUUID]
        ) ?? 0
        guard currentUtteranceCount == preview.utteranceCount else {
            throw SpeakerProfileSplitError.previewOutOfDate
        }

        let operationID = UUID().uuidString
        try db.execute(
            sql: """
                INSERT INTO speaker_split_operations(
                    id, source_speaker_uuid, anchor_group_id, threshold, linkage,
                    keep_local_labels_separate, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                operationID,
                preview.sourceSpeakerUUID,
                anchorGroupID,
                preview.threshold,
                preview.linkage.rawValue,
                preview.keepLocalLabelsSeparate,
                now,
            ]
        )

        if try db.tableExists("speaker_global_assignments"),
           try db.tableExists("speaker_global_split_members") {
            return try applyGlobalIdentitySplit(
                db,
                preview: preview,
                anchorGroupID: anchorGroupID,
                operationID: operationID,
                now: now
            )
        }

        var createdUUIDs: [String] = []
        var movedUtterances = 0
        var affectedRecordings = Set<Int64>()

        for group in preview.groups where group.id != anchorGroupID {
            let newUUID = UUID().uuidString
            createdUUIDs.append(newUUID)
            let embedding = group.centroid ?? Array(repeating: Float(0), count: VoiceEmbeddingStore.dimensions)
            let sourceRecordingId = group.clusters.first?.recordingId
            let lastSeen = group.clusters.map(\.recordingDate).max() ?? now
            let confidence = group.minimumSimilarity ?? (group.vectorCount > 0 ? 0.5 : 0)

            try db.execute(
                sql: """
                    INSERT INTO speakers(
                        uuid, name, embedding, embedding_count, total_duration, utterance_count,
                        created_at, updated_at, last_seen_at, confidence, notes,
                        source_recording_id, name_source
                    ) VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, NULL)
                """,
                arguments: [
                    newUUID,
                    VoiceEmbeddingStore.floatsToData(embedding),
                    group.vectorCount,
                    group.duration,
                    group.utteranceCount,
                    now,
                    now,
                    lastSeen,
                    confidence,
                    sourceRecordingId,
                ]
            )
            try db.execute(
                sql: "INSERT INTO speaker_split_created_speakers(operation_id, speaker_uuid) VALUES (?, ?)",
                arguments: [operationID, newUUID]
            )

            for cluster in group.clusters {
                affectedRecordings.insert(cluster.recordingId)
                for utteranceId in cluster.utteranceIds {
                    guard let row = try Row.fetchOne(
                        db,
                        sql: """
                            SELECT speaker_uuid, speaker_assignment_source, speaker_reviewed_at
                            FROM utterances WHERE id = ? AND speaker_uuid = ?
                        """,
                        arguments: [utteranceId, preview.sourceSpeakerUUID]
                    ) else { continue }
                    let previousUUID: String? = row["speaker_uuid"]
                    let previousSource: String? = row["speaker_assignment_source"]
                    let previousReviewedAt: Date? = row["speaker_reviewed_at"]
                    try db.execute(
                        sql: """
                            INSERT INTO speaker_split_assignments(
                                operation_id, utterance_id, previous_speaker_uuid, new_speaker_uuid,
                                previous_assignment_source, previous_reviewed_at
                            ) VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            operationID,
                            utteranceId,
                            previousUUID,
                            newUUID,
                            previousSource,
                            previousReviewedAt,
                        ]
                    )
                    try db.execute(
                        sql: """
                            UPDATE utterances
                            SET speaker_uuid = ?, speaker_assignment_source = ?, speaker_reviewed_at = NULL
                            WHERE id = ?
                        """,
                        arguments: [newUUID, SpeakerAssignmentSource.model.rawValue, utteranceId]
                    )
                    movedUtterances += 1
                }
            }
        }

        let policy = SpeakerPipelineSettings.shared.activeConfiguration.centroidPolicy
        try refreshSpeaker(db, uuid: preview.sourceSpeakerUUID, policy: policy, now: now)
        for uuid in createdUUIDs {
            try refreshSpeaker(db, uuid: uuid, policy: policy, now: now)
        }
        for recordingId in affectedRecordings {
            try SpeakerGoldReviewStore.invalidateIfReviewed(db, recordingId: recordingId, reviewedAt: now)
        }

        return ApplyResult(
            operationID: operationID,
            createdSpeakerUUIDs: createdUUIDs,
            movedUtteranceCount: movedUtterances,
            affectedRecordingCount: affectedRecordings.count
        )
    }

    static func canUndo(sourceSpeakerUUID: String) -> Bool {
        (try? GRDBDatabaseManager.shared.read {
            try canUndo($0, sourceSpeakerUUID: sourceSpeakerUUID)
        }) ?? false
    }

    static func canUndo(_ db: Database, sourceSpeakerUUID: String) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM speaker_split_operations
                    WHERE source_speaker_uuid = ? AND undone_at IS NULL
                )
            """,
            arguments: [sourceSpeakerUUID]
        ) ?? false
    }

    static func undoLatest(sourceSpeakerUUID: String) throws -> UndoResult {
        try GRDBDatabaseManager.shared.write {
            try undoLatest($0, sourceSpeakerUUID: sourceSpeakerUUID)
        }
    }

    static func undoLatest(
        _ db: Database,
        sourceSpeakerUUID: String,
        now: Date = Date()
    ) throws -> UndoResult {
        guard let operation = try Row.fetchOne(
            db,
            sql: """
                SELECT id FROM speaker_split_operations
                WHERE source_speaker_uuid = ? AND undone_at IS NULL
                ORDER BY created_at DESC LIMIT 1
            """,
            arguments: [sourceSpeakerUUID]
        ) else {
            throw SpeakerProfileSplitError.noSplitToUndo
        }
        let operationID: String = operation["id"]
        let createdUUIDs = try String.fetchAll(
            db,
            sql: """
                SELECT speaker_uuid FROM speaker_split_created_speakers
                WHERE operation_id = ? ORDER BY speaker_uuid
            """,
            arguments: [operationID]
        )

        if try db.tableExists("speaker_global_split_members"),
           try Int.fetchOne(
               db,
               sql: """
                   SELECT COUNT(*) FROM speaker_global_split_members
                   WHERE operation_id = ?
               """,
               arguments: [operationID]
           ) ?? 0 > 0 {
            return try undoGlobalIdentitySplit(
                db,
                sourceSpeakerUUID: sourceSpeakerUUID,
                operationID: operationID,
                createdUUIDs: createdUUIDs,
                now: now
            )
        }

        for uuid in createdUUIDs {
            let extraUtterances = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM utterances u
                    WHERE u.speaker_uuid = ?
                      AND NOT EXISTS(
                          SELECT 1 FROM speaker_split_assignments a
                          WHERE a.operation_id = ? AND a.utterance_id = u.id
                            AND a.new_speaker_uuid = ?
                      )
                """,
                arguments: [uuid, operationID, uuid]
            ) ?? 0
            let userNamed = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM speakers
                        WHERE uuid = ? AND name IS NOT NULL AND name <> ''
                          AND (name_source IS NULL OR name_source = 'manual')
                    )
                """,
                arguments: [uuid]
            ) ?? false
            let manuallyMapped = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM speaker_attendee_mappings
                        WHERE speaker_uuid = ? AND source = 'manual'
                    )
                """,
                arguments: [uuid]
            ) ?? false
            if extraUtterances > 0 || userNamed || manuallyMapped {
                throw SpeakerProfileSplitError.splitChangedAfterCreation
            }
        }

        let assignments = try Row.fetchAll(
            db,
            sql: """
                SELECT a.utterance_id, a.previous_speaker_uuid, a.previous_assignment_source,
                       a.previous_reviewed_at, u.recording_id
                FROM speaker_split_assignments a
                JOIN utterances u ON u.id = a.utterance_id
                WHERE a.operation_id = ?
                ORDER BY a.utterance_id
            """,
            arguments: [operationID]
        )
        var affectedRecordings = Set<Int64>()
        for row in assignments {
            let utteranceId: Int64 = row["utterance_id"]
            let previousUUID: String? = row["previous_speaker_uuid"]
            let previousSource: String? = row["previous_assignment_source"]
            let previousReviewedAt: Date? = row["previous_reviewed_at"]
            let recordingId: Int64 = row["recording_id"]
            affectedRecordings.insert(recordingId)
            try db.execute(
                sql: """
                    UPDATE utterances
                    SET speaker_uuid = ?, speaker_assignment_source = ?, speaker_reviewed_at = ?
                    WHERE id = ?
                """,
                arguments: [previousUUID, previousSource, previousReviewedAt, utteranceId]
            )
        }

        for uuid in createdUUIDs {
            try db.execute(sql: "DELETE FROM speaker_attendee_mappings WHERE speaker_uuid = ?", arguments: [uuid])
            if try db.tableExists("speaker_insights") {
                try db.execute(sql: "DELETE FROM speaker_insights WHERE speaker_uuid = ?", arguments: [uuid])
            }
            try db.execute(sql: "DELETE FROM speakers WHERE uuid = ?", arguments: [uuid])
        }
        try db.execute(
            sql: "UPDATE speaker_split_operations SET undone_at = ? WHERE id = ?",
            arguments: [now, operationID]
        )
        let policy = SpeakerPipelineSettings.shared.activeConfiguration.centroidPolicy
        try refreshSpeaker(db, uuid: sourceSpeakerUUID, policy: policy, now: now)
        for recordingId in affectedRecordings {
            try SpeakerGoldReviewStore.invalidateIfReviewed(db, recordingId: recordingId, reviewedAt: now)
        }

        return UndoResult(
            operationID: operationID,
            removedSpeakerCount: createdUUIDs.count,
            restoredUtteranceCount: assignments.count
        )
    }

    private static func applyGlobalIdentitySplit(
        _ db: Database,
        preview: Preview,
        anchorGroupID: String,
        operationID: String,
        now: Date
    ) throws -> ApplyResult {
        var createdUUIDs: [String] = []
        var movedUtterances = 0
        var affectedRecordings = Set<Int64>()

        for group in preview.groups where group.id != anchorGroupID {
            let newUUID = UUID().uuidString
            createdUUIDs.append(newUUID)
            let embedding = group.centroid
                ?? Array(repeating: Float(0), count: VoiceEmbeddingStore.dimensions)
            let sourceRecordingId = group.clusters.first?.recordingId
            let lastSeen = group.clusters.map(\.recordingDate).max() ?? now
            let confidence = group.minimumSimilarity ?? (group.vectorCount > 0 ? 0.5 : 0)
            try db.execute(
                sql: """
                    INSERT INTO speakers(
                        uuid, name, embedding, embedding_count, total_duration, utterance_count,
                        created_at, updated_at, last_seen_at, confidence, notes,
                        source_recording_id, name_source
                    ) VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, NULL)
                """,
                arguments: [
                    newUUID,
                    VoiceEmbeddingStore.floatsToData(embedding),
                    group.vectorCount,
                    group.duration,
                    group.utteranceCount,
                    now,
                    now,
                    lastSeen,
                    confidence,
                    sourceRecordingId,
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO speaker_split_created_speakers(operation_id, speaker_uuid)
                    VALUES (?, ?)
                """,
                arguments: [operationID, newUUID]
            )

            for cluster in group.clusters {
                guard let clusterId = cluster.localClusterId,
                      let assignment = try Row.fetchOne(
                          db,
                          sql: """
                              SELECT * FROM speaker_global_assignments
                              WHERE local_cluster_id = ? AND speaker_uuid = ?
                          """,
                          arguments: [clusterId, preview.sourceSpeakerUUID]
                      ) else {
                    throw SpeakerProfileSplitError.previewOutOfDate
                }
                let previousUUID: String = assignment["speaker_uuid"]
                let previousState: String = assignment["state"]
                let previousSource: String = assignment["source"]
                let previousConfidence: Double = assignment["confidence"] ?? 0
                try db.execute(
                    sql: """
                        INSERT INTO speaker_global_split_members(
                            operation_id, local_cluster_id,
                            previous_speaker_uuid, previous_state, previous_source,
                            previous_confidence, previous_score, previous_margin,
                            previous_supporting_prototype_count, previous_matcher,
                            previous_evidence_json, previous_operation_id,
                            new_speaker_uuid
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        operationID,
                        clusterId,
                        previousUUID,
                        previousState,
                        previousSource,
                        previousConfidence,
                        assignment["score"] as Double?,
                        assignment["margin"] as Double?,
                        assignment["supporting_prototype_count"] as Int?,
                        assignment["matcher"] as String?,
                        assignment["evidence_json"] as String?,
                        assignment["operation_id"] as Int64?,
                        newUUID,
                    ]
                )

                let utteranceRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, speaker_uuid, speaker_assignment_source, speaker_reviewed_at
                        FROM utterances WHERE local_speaker_cluster_id = ?
                        ORDER BY id
                    """,
                    arguments: [clusterId]
                )
                for row in utteranceRows {
                    let utteranceId: Int64 = row["id"]
                    try db.execute(
                        sql: """
                            INSERT INTO speaker_split_assignments(
                                operation_id, utterance_id, previous_speaker_uuid,
                                new_speaker_uuid, previous_assignment_source,
                                previous_reviewed_at
                            ) VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            operationID,
                            utteranceId,
                            row["speaker_uuid"] as String?,
                            newUUID,
                            row["speaker_assignment_source"] as String?,
                            row["speaker_reviewed_at"] as Date?,
                        ]
                    )
                }
                try GlobalSpeakerIdentityStore.assignLocalCluster(
                    db,
                    clusterId: clusterId,
                    to: newUUID,
                    state: .manual,
                    source: .globalManual,
                    matcher: "user-profile-split",
                    refreshProfiles: false
                )
                movedUtterances += utteranceRows.count
                affectedRecordings.insert(cluster.recordingId)
            }
        }

        try GlobalSpeakerIdentityStore.refreshProfile(
            db,
            uuid: preview.sourceSpeakerUUID
        )
        for uuid in createdUUIDs {
            try GlobalSpeakerIdentityStore.refreshProfile(db, uuid: uuid)
        }
        for recordingId in affectedRecordings {
            try SpeakerGoldReviewStore.invalidateIfReviewed(
                db,
                recordingId: recordingId,
                reviewedAt: now
            )
        }
        return ApplyResult(
            operationID: operationID,
            createdSpeakerUUIDs: createdUUIDs,
            movedUtteranceCount: movedUtterances,
            affectedRecordingCount: affectedRecordings.count
        )
    }

    private static func undoGlobalIdentitySplit(
        _ db: Database,
        sourceSpeakerUUID: String,
        operationID: String,
        createdUUIDs: [String],
        now: Date
    ) throws -> UndoResult {
        for uuid in createdUUIDs {
            let extraClusters = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM speaker_global_assignments a
                    WHERE a.speaker_uuid = ?
                      AND NOT EXISTS(
                          SELECT 1 FROM speaker_global_split_members m
                          WHERE m.operation_id = ?
                            AND m.local_cluster_id = a.local_cluster_id
                            AND m.new_speaker_uuid = ?
                      )
                """,
                arguments: [uuid, operationID, uuid]
            ) ?? 0
            let changedClusters = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM speaker_global_split_members m
                    JOIN speaker_global_assignments a
                      ON a.local_cluster_id = m.local_cluster_id
                    WHERE m.operation_id = ? AND m.new_speaker_uuid = ?
                      AND a.speaker_uuid <> m.new_speaker_uuid
                """,
                arguments: [operationID, uuid]
            ) ?? 0
            let userNamed = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM speakers
                        WHERE uuid = ? AND name IS NOT NULL AND name <> ''
                          AND (name_source IS NULL OR name_source = 'manual')
                    )
                """,
                arguments: [uuid]
            ) ?? false
            let manuallyMapped = try db.tableExists("speaker_attendee_mappings")
                ? (Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM speaker_attendee_mappings
                            WHERE speaker_uuid = ? AND source = 'manual'
                        )
                    """,
                    arguments: [uuid]
                ) ?? false)
                : false
            if extraClusters > 0 || changedClusters > 0 || userNamed || manuallyMapped {
                throw SpeakerProfileSplitError.splitChangedAfterCreation
            }
        }

        let members = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM speaker_global_split_members
                WHERE operation_id = ? ORDER BY local_cluster_id
            """,
            arguments: [operationID]
        )
        var affectedRecordings = Set<Int64>()
        for member in members {
            let clusterId: Int64 = member["local_cluster_id"]
            let previousUUID: String = member["previous_speaker_uuid"]
            let previousState: String = member["previous_state"]
            let previousSource: String = member["previous_source"]
            try db.execute(
                sql: """
                    UPDATE speaker_global_assignments SET
                        speaker_uuid = ?, state = ?, source = ?, confidence = ?,
                        score = ?, margin = ?, supporting_prototype_count = ?,
                        matcher = ?, evidence_json = ?, operation_id = ?, updated_at = ?
                    WHERE local_cluster_id = ?
                """,
                arguments: [
                    previousUUID,
                    previousState,
                    previousSource,
                    member["previous_confidence"] as Double?,
                    member["previous_score"] as Double?,
                    member["previous_margin"] as Double?,
                    member["previous_supporting_prototype_count"] as Int?,
                    member["previous_matcher"] as String?,
                    member["previous_evidence_json"] as String?,
                    member["previous_operation_id"] as Int64?,
                    now,
                    clusterId,
                ]
            )
            try db.execute(
                sql: """
                    UPDATE utterances SET
                        speaker_uuid = ?, speaker_assignment_source = ?
                    WHERE local_speaker_cluster_id = ?
                """,
                arguments: [previousUUID, previousSource, clusterId]
            )
            if let recordingId = try Int64.fetchOne(
                db,
                sql: """
                    SELECT recording_id FROM speaker_local_clusters WHERE id = ?
                """,
                arguments: [clusterId]
            ) {
                affectedRecordings.insert(recordingId)
            }
        }

        let utteranceSnapshots = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM speaker_split_assignments
                WHERE operation_id = ? ORDER BY utterance_id
            """,
            arguments: [operationID]
        )
        for row in utteranceSnapshots {
            let utteranceId: Int64 = row["utterance_id"]
            try db.execute(
                sql: """
                    UPDATE utterances SET
                        speaker_uuid = ?, speaker_assignment_source = ?,
                        speaker_reviewed_at = ?
                    WHERE id = ?
                """,
                arguments: [
                    row["previous_speaker_uuid"] as String?,
                    row["previous_assignment_source"] as String?,
                    row["previous_reviewed_at"] as Date?,
                    utteranceId,
                ]
            )
        }

        for uuid in createdUUIDs {
            if try db.tableExists("speaker_attendee_mappings") {
                try db.execute(
                    sql: "DELETE FROM speaker_attendee_mappings WHERE speaker_uuid = ?",
                    arguments: [uuid]
                )
            }
            if try db.tableExists("speaker_insights") {
                try db.execute(
                    sql: "DELETE FROM speaker_insights WHERE speaker_uuid = ?",
                    arguments: [uuid]
                )
            }
            try db.execute(
                sql: "DELETE FROM speakers WHERE uuid = ?",
                arguments: [uuid]
            )
        }
        try db.execute(
            sql: "UPDATE speaker_split_operations SET undone_at = ? WHERE id = ?",
            arguments: [now, operationID]
        )
        try GlobalSpeakerIdentityStore.refreshProfile(db, uuid: sourceSpeakerUUID)
        for recordingId in affectedRecordings {
            try SpeakerGoldReviewStore.invalidateIfReviewed(
                db,
                recordingId: recordingId,
                reviewedAt: now
            )
        }
        return UndoResult(
            operationID: operationID,
            removedSpeakerCount: createdUUIDs.count,
            restoredUtteranceCount: utteranceSnapshots.count
        )
    }

    private static func cluster(
        _ clusters: [LocalCluster],
        threshold: Float,
        linkage: PersonaLinkage,
        keepLocalLabelsSeparate: Bool
    ) -> [[LocalCluster]] {
        guard !clusters.isEmpty else { return [] }
        var groups = clusters.map { [$0] }

        switch linkage {
        case .single:
            var didMerge = true
            while didMerge {
                didMerge = false
                outer: for left in groups.indices {
                    guard left + 1 < groups.count else { continue }
                    for right in (left + 1)..<groups.count {
                        guard canMerge(
                            groups[left],
                            groups[right],
                            keepLocalLabelsSeparate: keepLocalLabelsSeparate
                        ) else { continue }
                        let best = crossSimilarities(groups[left], groups[right]).max() ?? -1
                        if best >= threshold {
                            groups[left].append(contentsOf: groups[right])
                            groups.remove(at: right)
                            didMerge = true
                            break outer
                        }
                    }
                }
            }
        case .complete:
            while true {
                var best: (left: Int, right: Int, minimum: Float, key: String)?
                for left in groups.indices {
                    guard left + 1 < groups.count else { continue }
                    for right in (left + 1)..<groups.count {
                        guard canMerge(
                            groups[left],
                            groups[right],
                            keepLocalLabelsSeparate: keepLocalLabelsSeparate
                        ) else { continue }
                        let minimum = crossSimilarities(groups[left], groups[right]).min() ?? -1
                        guard minimum >= threshold else { continue }
                        let key = (groups[left] + groups[right]).map(\.key).sorted().joined(separator: "\u{0}")
                        if best == nil
                            || minimum > best!.minimum
                            || (minimum == best!.minimum && key < best!.key) {
                            best = (left, right, minimum, key)
                        }
                    }
                }
                guard let best else { break }
                groups[best.left].append(contentsOf: groups[best.right])
                groups.remove(at: best.right)
            }
        }
        return groups.map { $0.sorted { $0.key < $1.key } }
    }

    private static func canMerge(
        _ left: [LocalCluster],
        _ right: [LocalCluster],
        keepLocalLabelsSeparate: Bool
    ) -> Bool {
        guard keepLocalLabelsSeparate else { return true }
        for lhs in left {
            for rhs in right
            where lhs.recordingId == rhs.recordingId && lhs.localLabel != rhs.localLabel {
                return false
            }
        }
        return true
    }

    private static func crossSimilarities(
        _ left: [LocalCluster],
        _ right: [LocalCluster]
    ) -> [Float] {
        left.flatMap { lhs in
            right.compactMap { rhs in
                guard let a = lhs.centroid, let b = rhs.centroid else { return nil }
                return SpeakerUnifier.cosine(a, b)
            }
        }
    }

    private static func makeGroup(_ clusters: [LocalCluster]) -> Group {
        let sorted = clusters.sorted { $0.key < $1.key }
        let weighted = sorted.compactMap { cluster -> (vector: [Float], weight: Float)? in
            guard let centroid = cluster.centroid else { return nil }
            return (centroid, Float(max(1, cluster.vectorCount)))
        }
        let similarities = sorted.indices.flatMap { left in
            sorted.indices.compactMap { right -> Float? in
                guard right > left,
                      let a = sorted[left].centroid,
                      let b = sorted[right].centroid else { return nil }
                return SpeakerUnifier.cosine(a, b)
            }
        }
        return Group(
            id: sorted.map(\.key).joined(separator: "|"),
            clusters: sorted,
            centroid: VoiceMath.weightedMeanNormalized(weighted),
            minimumSimilarity: similarities.min()
        )
    }

    private static func refreshSpeaker(
        _ db: Database,
        uuid: String,
        policy: SpeakerCentroidPolicy,
        now: Date
    ) throws {
        try db.execute(
            sql: """
                UPDATE speakers SET
                    utterance_count = (
                        SELECT COUNT(*) FROM utterances WHERE speaker_uuid = ?
                    ),
                    total_duration = COALESCE((
                        SELECT SUM(end_time - start_time) FROM utterances WHERE speaker_uuid = ?
                    ), 0),
                    last_seen_at = COALESCE((
                        SELECT MAX(r.created_at)
                        FROM utterances u JOIN recordings r ON r.id = u.recording_id
                        WHERE u.speaker_uuid = ?
                    ), last_seen_at),
                    updated_at = ?
                WHERE uuid = ?
            """,
            arguments: [uuid, uuid, uuid, now, uuid]
        )
        try GRDBSpeakerRepository.recomputeMean(db, uuid: uuid, policy: policy)
    }

    private static func clusterKey(recordingId: Int64, localLabel: String) -> String {
        "\(recordingId)\u{1f}\(localLabel)"
    }
}
