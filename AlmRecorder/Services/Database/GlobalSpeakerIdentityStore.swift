import Foundation
import GRDB

/// Persistent separation between immutable recording-local voice clusters and global people.
///
/// `utterances.speaker_uuid` remains a denormalized projection for the existing UI/search queries.
/// The source of truth is `speaker_global_assignments`: global linking changes that assignment and
/// refreshes the projection, but never deletes a local cluster or its embedding evidence.
enum GlobalSpeakerIdentityStore {
    struct AssignmentInput: Sendable {
        let speakerUUID: String
        let state: GlobalSpeakerAssignmentState
        let source: SpeakerAssignmentSource
        let confidence: Float
        let score: Float?
        let margin: Float?
        let supportingPrototypeCount: Int?
        let matcher: String?
        let evidenceJSON: String?
    }

    struct CandidateEvidence: Sendable {
        let candidateUUID: String
        let rank: Int
        let score: Float
        let bestPrototypeScore: Float
        let margin: Float?
        let supportingPrototypeCount: Int
        let eligible: Bool
        let rejectionReason: String?
    }

    struct LocalOccurrence: Equatable, Sendable {
        let clusterId: Int64
        let recordingId: Int64
        let spans: [SpeakerIdentityTimeSpan]
    }

    struct ProfileSnapshot: Equatable, Sendable {
        let uuid: String
        let prototypes: [[Float]]
        let trustedPrototypeCount: Int
        let occurrences: [LocalOccurrence]
    }

    private struct CodableSpan: Codable {
        let start: TimeInterval
        let end: TimeInterval
    }

    static func migrate(_ db: Database) throws {
        let utteranceColumns = Set(try db.columns(in: "utterances").map(\.name))
        if !utteranceColumns.contains("local_speaker_label") {
            try db.alter(table: "utterances") {
                $0.add(column: "local_speaker_label", .text)
            }
        }
        if !utteranceColumns.contains("local_speaker_cluster_id") {
            try db.alter(table: "utterances") {
                $0.add(column: "local_speaker_cluster_id", .integer)
            }
        }

        let speakerColumns = Set(try db.columns(in: "speakers").map(\.name))
        if !speakerColumns.contains("canonical_uuid") {
            try db.alter(table: "speakers") {
                $0.add(column: "canonical_uuid", .text)
            }
        }
        if !speakerColumns.contains("identity_state") {
            try db.alter(table: "speakers") {
                $0.add(column: "identity_state", .text)
                    .notNull().defaults(to: "active")
            }
        }

        try db.create(table: "speaker_local_clusters", ifNotExists: true) { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("recording_id", .integer).notNull()
                .references("recordings", onDelete: .cascade)
            table.column("local_key", .text).notNull()
            table.column("local_label", .text).notNull()
            table.column("embedding", .blob)
            table.column("confidence", .double).notNull().defaults(to: 0)
            table.column("cohesion", .double)
            table.column("embedding_turn_count", .integer).notNull().defaults(to: 0)
            table.column("mixture_split_gain", .double)
            table.column("mixture_centroid_similarity", .double)
            table.column("spans_json", .text)
            table.column("created_at", .datetime).notNull()
            table.column("updated_at", .datetime).notNull()
            table.uniqueKey(["recording_id", "local_key"])
        }
        try db.create(
            index: "idx_speaker_local_clusters_recording_label",
            on: "speaker_local_clusters",
            columns: ["recording_id", "local_label"],
            ifNotExists: true
        )

        try db.create(table: "speaker_global_link_operations", ifNotExists: true) { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("source_speaker_uuid", .text).notNull()
            table.column("target_speaker_uuid", .text).notNull()
            table.column("link_source", .text).notNull()
            table.column("status", .text).notNull().defaults(to: "active")
            table.column("score", .double)
            table.column("margin", .double)
            table.column("supporting_prototype_count", .integer)
            table.column("evidence_json", .text)
            table.column("owner_moved", .boolean).notNull().defaults(to: false)
            table.column("created_at", .datetime).notNull()
            table.column("undone_at", .datetime)
        }
        try db.create(
            index: "idx_global_link_operations_target_status",
            on: "speaker_global_link_operations",
            columns: ["target_speaker_uuid", "status"],
            ifNotExists: true
        )

        try db.create(table: "speaker_global_assignments", ifNotExists: true) { table in
            table.column("local_cluster_id", .integer).primaryKey()
                .references("speaker_local_clusters", onDelete: .cascade)
            table.column("speaker_uuid", .text).notNull()
                .references("speakers", column: "uuid")
            table.column("state", .text).notNull()
            table.column("source", .text).notNull()
            table.column("confidence", .double).notNull().defaults(to: 0)
            table.column("score", .double)
            table.column("margin", .double)
            table.column("supporting_prototype_count", .integer)
            table.column("matcher", .text)
            table.column("evidence_json", .text)
            table.column("operation_id", .integer)
                .references("speaker_global_link_operations", onDelete: .setNull)
            table.column("created_at", .datetime).notNull()
            table.column("updated_at", .datetime).notNull()
        }
        try db.create(
            index: "idx_global_assignments_speaker",
            on: "speaker_global_assignments",
            columns: ["speaker_uuid", "state"],
            ifNotExists: true
        )

        try db.create(table: "speaker_global_link_members", ifNotExists: true) { table in
            table.column("operation_id", .integer).notNull()
                .references("speaker_global_link_operations", onDelete: .cascade)
            table.column("local_cluster_id", .integer).notNull()
                .references("speaker_local_clusters", onDelete: .cascade)
            table.column("previous_speaker_uuid", .text).notNull()
            table.column("previous_state", .text).notNull()
            table.column("previous_source", .text).notNull()
            table.primaryKey(["operation_id", "local_cluster_id"])
        }

        // A from-scratch reconciliation may split one legacy identity and merge several others in
        // the same atomic run. These tables snapshot every assignment and speaker projection so
        // the whole run can be undone without deleting immutable local-cluster evidence.
        try db.create(table: "speaker_reconciliation_runs", ifNotExists: true) { table in
            table.column("id", .text).primaryKey()
            table.column("status", .text).notNull().defaults(to: "active")
            table.column("matcher", .text).notNull()
            table.column("calibration_pair_count", .integer).notNull()
            table.column("held_out_pair_count", .integer).notNull()
            table.column("changed_cluster_count", .integer).notNull().defaults(to: 0)
            table.column("created_identity_count", .integer).notNull().defaults(to: 0)
            table.column("created_at", .datetime).notNull()
            table.column("undone_at", .datetime)
        }
        try db.create(table: "speaker_reconciliation_members", ifNotExists: true) { table in
            table.column("run_id", .text).notNull()
                .references("speaker_reconciliation_runs", onDelete: .cascade)
            table.column("local_cluster_id", .integer).notNull()
                .references("speaker_local_clusters", onDelete: .cascade)
            table.column("previous_speaker_uuid", .text).notNull()
            table.column("previous_state", .text).notNull()
            table.column("previous_source", .text).notNull()
            table.column("previous_confidence", .double).notNull()
            table.column("previous_score", .double)
            table.column("previous_margin", .double)
            table.column("previous_supporting_prototype_count", .integer)
            table.column("previous_matcher", .text)
            table.column("previous_evidence_json", .text)
            table.column("previous_operation_id", .integer)
            table.column("target_speaker_uuid", .text).notNull()
            table.primaryKey(["run_id", "local_cluster_id"])
        }
        try db.create(table: "speaker_reconciliation_speakers", ifNotExists: true) { table in
            table.column("run_id", .text).notNull()
                .references("speaker_reconciliation_runs", onDelete: .cascade)
            table.column("speaker_uuid", .text).notNull()
            table.column("previous_identity_state", .text)
            table.column("previous_canonical_uuid", .text)
            table.column("was_created", .boolean).notNull().defaults(to: false)
            table.primaryKey(["run_id", "speaker_uuid"])
        }
        let assignmentColumns = Set(
            try db.columns(in: "speaker_global_assignments").map(\.name)
        )
        if !assignmentColumns.contains("reconciliation_run_id") {
            try db.alter(table: "speaker_global_assignments") {
                $0.add(column: "reconciliation_run_id", .text)
            }
        }

        try db.create(table: "speaker_global_candidates", ifNotExists: true) { table in
            table.column("local_cluster_id", .integer).notNull()
                .references("speaker_local_clusters", onDelete: .cascade)
            table.column("candidate_speaker_uuid", .text).notNull()
                .references("speakers", column: "uuid")
            table.column("rank", .integer).notNull()
            table.column("score", .double).notNull()
            table.column("best_prototype_score", .double).notNull()
            table.column("margin", .double)
            table.column("supporting_prototype_count", .integer).notNull()
            table.column("eligible", .boolean).notNull()
            table.column("rejection_reason", .text)
            table.column("created_at", .datetime).notNull()
            table.primaryKey(["local_cluster_id", "candidate_speaker_uuid"])
        }

        // Split operations predate the local/global separation. This companion snapshot makes a
        // profile split restore assignment rows instead of reconstructing/deleting local evidence.
        try db.create(table: "speaker_global_split_members", ifNotExists: true) { table in
            table.column("operation_id", .text).notNull()
            table.column("local_cluster_id", .integer).notNull()
                .references("speaker_local_clusters", onDelete: .cascade)
            table.column("previous_speaker_uuid", .text).notNull()
            table.column("previous_state", .text).notNull()
            table.column("previous_source", .text).notNull()
            table.column("previous_confidence", .double).notNull().defaults(to: 0)
            table.column("previous_score", .double)
            table.column("previous_margin", .double)
            table.column("previous_supporting_prototype_count", .integer)
            table.column("previous_matcher", .text)
            table.column("previous_evidence_json", .text)
            table.column("previous_operation_id", .integer)
            table.column("new_speaker_uuid", .text).notNull()
            table.primaryKey(["operation_id", "local_cluster_id"])
        }
        try db.create(
            index: "idx_global_split_members_new_speaker",
            on: "speaker_global_split_members",
            columns: ["new_speaker_uuid"],
            ifNotExists: true
        )

        try backfillLegacyAssignments(db)
        try db.execute(
            sql: "CREATE INDEX IF NOT EXISTS idx_utterances_local_speaker_cluster ON utterances(local_speaker_cluster_id)"
        )
    }

    /// Upsert the actual diarizer clusters before utterance insertion. Returns label → stable local ID.
    @discardableResult
    static func register(
        _ db: Database,
        recordingId: Int64,
        clusters: [SpeakerIdentityCluster],
        assignments: [String: AssignmentInput],
        candidates: [String: [CandidateEvidence]] = [:]
    ) throws -> [String: Int64] {
        var result: [String: Int64] = [:]
        for cluster in clusters {
            let clusterId = try upsertCluster(
                db,
                recordingId: recordingId,
                localKey: cluster.label,
                localLabel: cluster.label,
                embedding: cluster.embedding,
                confidence: cluster.confidence,
                cohesion: cluster.cohesion,
                embeddingTurnCount: cluster.embeddingTurnCount,
                mixtureSplitGain: cluster.mixtureSplitGain,
                mixtureCentroidSimilarity: cluster.mixtureCentroidSimilarity,
                spans: cluster.spans
            )
            result[cluster.label] = clusterId
            if let assignment = assignments[cluster.label] {
                try upsertAssignment(db, clusterId: clusterId, input: assignment)
            }
            try recordCandidates(db, clusterId: clusterId, candidates: candidates[cluster.label] ?? [])
        }
        return result
    }

    /// Attach newly inserted utterances to pre-registered clusters, and create conservative legacy
    /// clusters for any fallback transcription path that did not register in advance.
    static func reconcileRecording(
        _ db: Database,
        recordingId: Int64
    ) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT
                    COALESCE(local_speaker_label, speaker, '') AS local_label,
                    speaker_uuid,
                    MIN(start_time) AS first_start,
                    MAX(end_time) AS last_end,
                    MAX(CASE WHEN speaker_assignment_source IN (?, ?) THEN 1 ELSE 0 END) AS is_manual
                FROM utterances
                WHERE recording_id = ?
                  AND (speaker IS NOT NULL OR speaker_uuid IS NOT NULL OR local_speaker_label IS NOT NULL)
                GROUP BY COALESCE(local_speaker_label, speaker, ''), speaker_uuid
            """,
            arguments: [
                SpeakerAssignmentSource.manual.rawValue,
                SpeakerAssignmentSource.globalManual.rawValue,
                recordingId
            ]
        )

        for row in rows {
            let label: String = row["local_label"] ?? ""
            let speakerUUID: String? = row["speaker_uuid"]
            let localKey = label.isEmpty
                ? "uuid:\(speakerUUID ?? "unknown")"
                : label
            let existingId = try Int64.fetchOne(
                db,
                sql: """
                    SELECT id FROM speaker_local_clusters
                    WHERE recording_id = ? AND local_key = ?
                """,
                arguments: [recordingId, localKey]
            )
            let spans = try utteranceSpans(
                db,
                recordingId: recordingId,
                label: label,
                speakerUUID: speakerUUID
            )
            let clusterId: Int64
            if let existingId {
                // `resolveClusters` already stored the centroid built from every diarizer turn,
                // plus cohesion/mixture evidence. ASR-aligned utterance vectors are only a
                // fallback and must not overwrite that higher-fidelity enrollment evidence.
                clusterId = existingId
            } else {
                clusterId = try upsertCluster(
                    db,
                    recordingId: recordingId,
                    localKey: localKey,
                    localLabel: label,
                    embedding: try meanVoiceEmbedding(
                        db,
                        recordingId: recordingId,
                        label: label,
                        speakerUUID: speakerUUID
                    ),
                    confidence: 0,
                    cohesion: nil,
                    embeddingTurnCount: spans.count,
                    mixtureSplitGain: nil,
                    mixtureCentroidSimilarity: nil,
                    spans: spans
                )
            }

            try db.execute(
                sql: """
                    UPDATE utterances SET
                        local_speaker_label = COALESCE(local_speaker_label, speaker, ?),
                        local_speaker_cluster_id = ?
                    WHERE recording_id = ?
                      AND COALESCE(local_speaker_label, speaker, '') = ?
                      AND ((speaker_uuid = ?) OR (speaker_uuid IS NULL AND ? IS NULL))
                      AND (local_speaker_cluster_id IS NULL OR local_speaker_cluster_id = ?)
                """,
                arguments: [
                    label, clusterId, recordingId, label,
                    speakerUUID, speakerUUID, existingId
                ]
            )

            if let speakerUUID,
               try Int.fetchOne(
                   db,
                   sql: "SELECT COUNT(*) FROM speaker_global_assignments WHERE local_cluster_id = ?",
                   arguments: [clusterId]
               ) == 0 {
                let isManual: Int = row["is_manual"] ?? 0
                try upsertAssignment(
                    db,
                    clusterId: clusterId,
                    input: AssignmentInput(
                        speakerUUID: speakerUUID,
                        state: isManual == 1 ? .manual : .legacy,
                        source: isManual == 1 ? .globalManual : .model,
                        confidence: isManual == 1 ? 1 : 0.5,
                        score: nil,
                        margin: nil,
                        supportingPrototypeCount: nil,
                        matcher: "recording-reconciliation",
                        evidenceJSON: nil
                    )
                )
            }
        }
    }

    static func loadProfileEvidence(_ db: Database) throws -> [SpeakerIdentityProfileEvidence] {
        let snapshots = try loadProfileSnapshots(db)
        let meansByUUID: [String: [Float]] = Dictionary(
            uniqueKeysWithValues: try Row.fetchAll(
                db,
                sql: """
                    SELECT uuid, embedding FROM speakers
                    WHERE COALESCE(identity_state, 'active') = 'active'
                """
            ).compactMap { row in
                guard let uuid: String = row["uuid"],
                      let data: Data = row["embedding"] else { return nil }
                let vector = VoiceEmbeddingStore.dataToFloats(data)
                guard vector.count == SpeakerEmbeddingPolicy.dimension else { return nil }
                return (uuid, vector)
            }
        )
        return snapshots.compactMap { snapshot in
            let mean = VoiceMath.meanNormalized(snapshot.prototypes) ?? meansByUUID[snapshot.uuid]
            guard let mean else { return nil }
            return SpeakerIdentityProfileEvidence(
                uuid: snapshot.uuid,
                meanEmbedding: mean,
                prototypes: snapshot.prototypes
            )
        }
    }

    static func loadProfileSnapshots(_ db: Database) throws -> [ProfileSnapshot] {
        let reliablePredicate = try reliableClusterPredicate(db, alias: "c")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT
                    a.speaker_uuid,
                    a.state,
                    c.id AS cluster_id,
                    c.recording_id,
                    c.embedding,
                    c.spans_json
                FROM speaker_global_assignments a
                JOIN speaker_local_clusters c ON c.id = a.local_cluster_id
                JOIN speakers s ON s.uuid = a.speaker_uuid
                WHERE c.embedding IS NOT NULL
                  AND COALESCE(s.identity_state, 'active') = 'active'
                  AND \(reliablePredicate)
                ORDER BY a.speaker_uuid, c.recording_id, c.id
            """
        )
        struct Accumulator {
            var prototypes: [[Float]] = []
            var trusted = 0
            var occurrences: [LocalOccurrence] = []
        }
        var grouped: [String: Accumulator] = [:]
        for row in rows {
            guard let uuid: String = row["speaker_uuid"],
                  let data: Data = row["embedding"],
                  let clusterId: Int64 = row["cluster_id"],
                  let recordingId: Int64 = row["recording_id"] else { continue }
            let vector = VoiceEmbeddingStore.dataToFloats(data)
            guard vector.count == SpeakerEmbeddingPolicy.dimension else { continue }
            let stateRaw: String = row["state"] ?? GlobalSpeakerAssignmentState.legacy.rawValue
            let state = GlobalSpeakerAssignmentState(rawValue: stateRaw) ?? .legacy
            var value = grouped[uuid] ?? Accumulator()
            value.prototypes.append(vector)
            if state.isTrustedEnrollment { value.trusted += 1 }
            value.occurrences.append(
                LocalOccurrence(
                    clusterId: clusterId,
                    recordingId: recordingId,
                    spans: decodeSpans(row["spans_json"])
                )
            )
            grouped[uuid] = value
        }
        return grouped.map {
            ProfileSnapshot(
                uuid: $0.key,
                prototypes: $0.value.prototypes,
                trustedPrototypeCount: $0.value.trusted,
                occurrences: $0.value.occurrences
            )
        }
        .sorted { $0.uuid < $1.uuid }
    }

    /// Reversible global link. Local cluster rows and source speaker metadata are retained.
    @discardableResult
    static func link(
        _ db: Database,
        sourceUUID: String,
        targetUUID: String,
        linkSource: GlobalSpeakerLinkSource,
        score: Float? = nil,
        margin: Float? = nil,
        supportingPrototypeCount: Int? = nil,
        evidenceJSON: String? = nil
    ) throws -> Int64? {
        let source = try canonicalUUID(db, uuid: sourceUUID)
        let target = try canonicalUUID(db, uuid: targetUUID)
        guard source != target else { return nil }
        guard try speakerExists(db, uuid: source),
              try speakerExists(db, uuid: target) else { return nil }

        let assignments = try Row.fetchAll(
            db,
            sql: """
                SELECT local_cluster_id, speaker_uuid, state, source
                FROM speaker_global_assignments
                WHERE speaker_uuid = ?
            """,
            arguments: [source]
        )
        guard !assignments.isEmpty else { return nil }

        let ownerUUID = try db.tableExists("app_settings")
            ? String.fetchOne(
                db,
                sql: "SELECT value FROM app_settings WHERE key = 'owner.speakerUuid'"
            )
            : nil
        let ownerMoved = ownerUUID == source
        try db.execute(
            sql: """
                INSERT INTO speaker_global_link_operations (
                    source_speaker_uuid, target_speaker_uuid, link_source, status,
                    score, margin, supporting_prototype_count, evidence_json,
                    owner_moved, created_at
                ) VALUES (?, ?, ?, 'active', ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                source, target, linkSource.rawValue, score, margin,
                supportingPrototypeCount, evidenceJSON, ownerMoved, Date()
            ]
        )
        let operationId = db.lastInsertedRowID
        if linkSource == .manual,
           try db.tableExists("speaker_pair_gold_labels") {
            try SpeakerPairGoldStore.recordManualGlobalMerge(
                db,
                sourceUUID: source,
                targetUUID: target,
                operationID: operationId
            )
        }
        let assignmentState: GlobalSpeakerAssignmentState =
            linkSource == .manual ? .manual : .automatic
        let assignmentSource: SpeakerAssignmentSource =
            linkSource == .manual ? .globalManual : .globalAutomatic

        for row in assignments {
            guard let clusterId: Int64 = row["local_cluster_id"],
                  let previousUUID: String = row["speaker_uuid"],
                  let previousState: String = row["state"],
                  let previousSource: String = row["source"] else { continue }
            try db.execute(
                sql: """
                    INSERT INTO speaker_global_link_members (
                        operation_id, local_cluster_id, previous_speaker_uuid,
                        previous_state, previous_source
                    ) VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    operationId, clusterId, previousUUID, previousState, previousSource
                ]
            )
            try db.execute(
                sql: """
                    UPDATE speaker_global_assignments SET
                        speaker_uuid = ?, state = ?, source = ?,
                        score = ?, margin = ?, supporting_prototype_count = ?,
                        matcher = ?, evidence_json = ?, operation_id = ?, updated_at = ?
                        , reconciliation_run_id = NULL
                    WHERE local_cluster_id = ?
                """,
                arguments: [
                    target, assignmentState.rawValue, assignmentSource.rawValue,
                    score, margin, supportingPrototypeCount,
                    "global-link-v31", evidenceJSON, operationId, Date(), clusterId
                ]
            )
            try db.execute(
                sql: """
                    UPDATE utterances SET
                        speaker_uuid = ?, speaker_assignment_source = ?
                    WHERE local_speaker_cluster_id = ?
                """,
                arguments: [target, assignmentSource.rawValue, clusterId]
            )
        }

        try db.execute(
            sql: """
                UPDATE speakers SET
                    identity_state = 'alias', canonical_uuid = ?, updated_at = ?
                WHERE uuid = ?
            """,
            arguments: [target, Date(), source]
        )
        if ownerMoved, try db.tableExists("app_settings") {
            try db.execute(
                sql: "UPDATE app_settings SET value = ? WHERE key = 'owner.speakerUuid'",
                arguments: [target]
            )
        }
        try refreshProfile(db, uuid: target)
        return operationId
    }

    /// Undo the latest active global link for a source alias. Assignments changed after the link
    /// (for example, a later manual correction) are not overwritten.
    @discardableResult
    static func undoLatestLink(
        _ db: Database,
        sourceUUID: String
    ) throws -> Bool {
        guard let operation = try Row.fetchOne(
            db,
            sql: """
                SELECT * FROM speaker_global_link_operations
                WHERE source_speaker_uuid = ? AND status = 'active'
                ORDER BY created_at DESC, id DESC
                LIMIT 1
            """,
            arguments: [sourceUUID]
        ), let operationId: Int64 = operation["id"],
           let targetUUID: String = operation["target_speaker_uuid"] else {
            return false
        }

        let members = try Row.fetchAll(
            db,
            sql: "SELECT * FROM speaker_global_link_members WHERE operation_id = ?",
            arguments: [operationId]
        )
        var restoredCount = 0
        for row in members {
            guard let clusterId: Int64 = row["local_cluster_id"],
                  let previousUUID: String = row["previous_speaker_uuid"],
                  let previousState: String = row["previous_state"],
                  let previousSource: String = row["previous_source"] else { continue }
            let currentOperation = try Int64.fetchOne(
                db,
                sql: """
                    SELECT operation_id FROM speaker_global_assignments
                    WHERE local_cluster_id = ?
                """,
                arguments: [clusterId]
            )
            guard currentOperation == operationId else { continue }
            try db.execute(
                sql: """
                    UPDATE speaker_global_assignments SET
                        speaker_uuid = ?, state = ?, source = ?,
                        operation_id = NULL, updated_at = ?
                    WHERE local_cluster_id = ?
                """,
                arguments: [
                    previousUUID, previousState, previousSource, Date(), clusterId
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
            restoredCount += 1
        }
        guard restoredCount > 0 else { return false }
        try db.execute(
            sql: """
                UPDATE speakers SET
                    identity_state = 'active', canonical_uuid = NULL, updated_at = ?
                WHERE uuid = ?
            """,
            arguments: [Date(), sourceUUID]
        )
        let ownerMoved: Bool = operation["owner_moved"] ?? false
        if ownerMoved, try db.tableExists("app_settings") {
            try db.execute(
                sql: "UPDATE app_settings SET value = ? WHERE key = 'owner.speakerUuid'",
                arguments: [sourceUUID]
            )
        }
        try db.execute(
            sql: """
                UPDATE speaker_global_link_operations
                SET status = 'undone', undone_at = ?
                WHERE id = ?
            """,
            arguments: [Date(), operationId]
        )
        if try db.tableExists("speaker_pair_gold_labels") {
            try SpeakerPairGoldStore.deleteDerivedLabels(
                db,
                actionID: "global-merge:\(operationId)"
            )
        }
        try refreshProfile(db, uuid: sourceUUID)
        try refreshProfile(db, uuid: targetUUID)
        return true
    }

    static func activeLinkOperation(
        _ db: Database,
        sourceUUID: String
    ) throws -> Int64? {
        try Int64.fetchOne(
            db,
            sql: """
                SELECT id FROM speaker_global_link_operations
                WHERE source_speaker_uuid = ? AND status = 'active'
                ORDER BY created_at DESC, id DESC LIMIT 1
            """,
            arguments: [sourceUUID]
        )
    }

    /// Assign one complete recording-local cluster to a global person. This is the operation behind
    /// "change this speaker in this call"; it never touches a similarly named cluster in another call.
    static func assignLocalCluster(
        _ db: Database,
        clusterId: Int64,
        to targetUUID: String,
        displayLabel: String? = nil,
        state: GlobalSpeakerAssignmentState = .manual,
        source: SpeakerAssignmentSource = .globalManual,
        matcher: String = "user-local-cluster",
        refreshProfiles: Bool = true,
        goldActionID: String? = nil
    ) throws {
        let target = try canonicalUUID(db, uuid: targetUUID)
        guard try speakerExists(db, uuid: target) else { return }
        let oldUUID = try String.fetchOne(
            db,
            sql: """
                SELECT speaker_uuid FROM speaker_global_assignments
                WHERE local_cluster_id = ?
            """,
            arguments: [clusterId]
        )
        try upsertAssignment(
            db,
            clusterId: clusterId,
            input: AssignmentInput(
                speakerUUID: target,
                state: state,
                source: source,
                confidence: state == .manual || state == .gold ? 1 : 0.9,
                score: nil,
                margin: nil,
                supportingPrototypeCount: nil,
                matcher: matcher,
                evidenceJSON: nil
            )
        )
        if let displayLabel {
            try db.execute(
                sql: """
                    UPDATE utterances SET
                        speaker_uuid = ?, speaker = ?,
                        speaker_assignment_source = ?, speaker_reviewed_at = ?
                    WHERE local_speaker_cluster_id = ?
                """,
                arguments: [target, displayLabel, source.rawValue, Date(), clusterId]
            )
        } else {
            try db.execute(
                sql: """
                    UPDATE utterances SET
                        speaker_uuid = ?, speaker_assignment_source = ?,
                        speaker_reviewed_at = ?
                    WHERE local_speaker_cluster_id = ?
                """,
                arguments: [target, source.rawValue, Date(), clusterId]
            )
        }
        if (state == .manual || state == .gold),
           source == .globalManual,
           oldUUID != target,
           try db.tableExists("speaker_pair_gold_labels") {
            let labelSource: SpeakerPairGoldSource =
                matcher == "user-profile-split" ? .profileSplit : .manualAssignment
            try SpeakerPairGoldStore.recordManualAssignment(
                db,
                clusterID: clusterId,
                previousUUID: oldUUID,
                targetUUID: target,
                source: labelSource,
                actionID: goldActionID ?? "local-assignment:\(UUID().uuidString)"
            )
        }
        if refreshProfiles {
            try refreshProfile(db, uuid: target)
            if let oldUUID, oldUUID != target {
                try refreshProfile(db, uuid: oldUUID)
            }
        }
    }

    /// Correct exactly one transcript line. The line becomes a child local fragment with its own
    /// global assignment, preserving the original diarizer cluster for every unaffected line.
    static func assignUtterance(
        _ db: Database,
        utteranceId: Int64,
        to targetUUID: String,
        displayLabel: String?
    ) throws {
        let target = try canonicalUUID(db, uuid: targetUUID)
        guard var row = try Row.fetchOne(
            db,
            sql: """
                SELECT id, recording_id, start_time, end_time, speaker,
                       local_speaker_label, local_speaker_cluster_id, speaker_uuid
                FROM utterances WHERE id = ?
            """,
            arguments: [utteranceId]
        ), let recordingId: Int64 = row["recording_id"] else { return }

        if (row["local_speaker_cluster_id"] as Int64?) == nil {
            try reconcileRecording(db, recordingId: recordingId)
            guard let refreshed = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, recording_id, start_time, end_time, speaker,
                           local_speaker_label, local_speaker_cluster_id, speaker_uuid
                    FROM utterances WHERE id = ?
                """,
                arguments: [utteranceId]
            ) else { return }
            row = refreshed
        }

        let oldClusterId: Int64? = row["local_speaker_cluster_id"]
        let oldUUID: String? = row["speaker_uuid"]
        let localLabel: String =
            row["local_speaker_label"] ?? row["speaker"] ?? "Speaker"
        let start: Double = row["start_time"] ?? 0
        let end: Double = row["end_time"] ?? start
        let embedding = try utteranceVoiceEmbedding(db, utteranceId: utteranceId)
        let childClusterId = try upsertCluster(
            db,
            recordingId: recordingId,
            localKey: "manual-utterance:\(utteranceId)",
            localLabel: localLabel,
            embedding: embedding,
            confidence: 1,
            cohesion: 1,
            embeddingTurnCount: embedding == nil ? 0 : 1,
            mixtureSplitGain: nil,
            mixtureCentroidSimilarity: nil,
            spans: [SpeakerIdentityTimeSpan(start: start, end: end)]
        )

        try db.execute(
            sql: """
                UPDATE utterances SET
                    local_speaker_cluster_id = ?,
                    speaker_uuid = ?, speaker = COALESCE(?, speaker),
                    speaker_assignment_source = ?, speaker_reviewed_at = ?
                WHERE id = ?
            """,
            arguments: [
                childClusterId, target, displayLabel,
                SpeakerAssignmentSource.globalManual.rawValue, Date(), utteranceId
            ]
        )
        try assignLocalCluster(
            db,
            clusterId: childClusterId,
            to: target,
            displayLabel: displayLabel,
            state: .manual,
            source: .globalManual,
            matcher: "user-single-utterance-split"
        )
        if oldUUID != target,
           try db.tableExists("speaker_pair_gold_labels") {
            try SpeakerPairGoldStore.recordManualAssignment(
                db,
                clusterID: childClusterId,
                previousUUID: oldUUID,
                targetUUID: target,
                source: .manualAssignment,
                actionID: "utterance-assignment:\(utteranceId)"
            )
        }
        if let oldClusterId, oldClusterId != childClusterId {
            try refreshLocalClusterEvidence(db, clusterId: oldClusterId)
        }
        if let oldUUID, oldUUID != targetUUID {
            try refreshProfile(db, uuid: oldUUID)
        }
    }

    static func refreshProfile(_ db: Database, uuid: String) throws {
        let reliablePredicate = try reliableClusterPredicate(db, alias: "c")
        let embeddings = try Row.fetchAll(
            db,
            sql: """
                SELECT c.embedding
                FROM speaker_global_assignments a
                JOIN speaker_local_clusters c ON c.id = a.local_cluster_id
                WHERE a.speaker_uuid = ? AND c.embedding IS NOT NULL
                  AND \(reliablePredicate)
                ORDER BY c.recording_id, c.id
            """,
            arguments: [uuid]
        ).compactMap { row -> [Float]? in
            guard let data: Data = row["embedding"] else { return nil }
            let vector = VoiceEmbeddingStore.dataToFloats(data)
            return vector.count == SpeakerEmbeddingPolicy.dimension ? vector : nil
        }
        if let mean = VoiceMath.meanNormalized(embeddings) {
            try db.execute(
                sql: """
                    UPDATE speakers SET
                        embedding = ?, embedding_count = ?,
                        confidence = MAX(confidence, 0.55),
                        updated_at = ?
                    WHERE uuid = ?
                """,
                arguments: [
                    VoiceEmbeddingStore.floatsToData(mean), embeddings.count, Date(), uuid
                ]
            )
        } else {
            // `speakers.embedding` is NOT NULL in the production schema. Retain the historical
            // bytes for reversibility/UI, but make this profile ineligible for automatic matching
            // until a clean local cluster is enrolled and refreshes it above.
            try db.execute(
                sql: """
                    UPDATE speakers SET
                        embedding_count = 0,
                        confidence = MIN(confidence, 0.49),
                        updated_at = ?
                    WHERE uuid = ?
                """,
                arguments: [Date(), uuid]
            )
        }
        try db.execute(
            sql: """
                UPDATE speakers SET
                    utterance_count = (
                        SELECT COUNT(*) FROM utterances WHERE speaker_uuid = ?
                    ),
                    total_duration = COALESCE((
                        SELECT SUM(
                            CASE WHEN end_time > start_time
                                 THEN end_time - start_time ELSE 0 END
                        )
                        FROM utterances WHERE speaker_uuid = ?
                    ), 0),
                    last_seen_at = COALESCE((
                        SELECT MAX(r.created_at)
                        FROM utterances u
                        JOIN recordings r ON r.id = u.recording_id
                        WHERE u.speaker_uuid = ?
                    ), last_seen_at),
                    updated_at = ?
                WHERE uuid = ?
            """,
            arguments: [uuid, uuid, uuid, Date(), uuid]
        )
    }

    // MARK: - Private

    /// One contaminated local cluster must never become enrollment evidence for every future
    /// recording. Human mixed labels are hard exclusions; conservative automatic mixture evidence
    /// is excluded until it is split or reviewed.
    private static func reliableClusterPredicate(
        _ db: Database,
        alias: String
    ) throws -> String {
        var clauses = [
            "\(alias).mixture_split_gain IS NULL",
            "NOT (\(alias).embedding_turn_count > 1 AND COALESCE(\(alias).cohesion, 1) < 0.35)",
        ]
        if try db.tableExists("speaker_local_cluster_gold_labels") {
            clauses.append("""
                NOT EXISTS (
                    SELECT 1
                    FROM speaker_local_cluster_gold_labels mixed
                    WHERE mixed.local_cluster_id = \(alias).id
                      AND mixed.verdict = 'multiple_speakers'
                )
                """)
        }
        return clauses.joined(separator: "\n AND ")
    }

    private static func backfillLegacyAssignments(_ db: Database) throws {
        guard try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM speaker_local_clusters"
        ) == 0 else { return }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT
                    u.recording_id,
                    COALESCE(u.speaker, '') AS local_label,
                    u.speaker_uuid,
                    MAX(CASE WHEN u.speaker_assignment_source IN (?, ?) THEN 1 ELSE 0 END)
                        AS is_manual,
                    MAX(CASE WHEN r.speaker_review_status = 'gold' THEN 1 ELSE 0 END)
                        AS is_gold
                FROM utterances u
                JOIN recordings r ON r.id = u.recording_id
                WHERE u.speaker IS NOT NULL OR u.speaker_uuid IS NOT NULL
                GROUP BY u.recording_id, COALESCE(u.speaker, ''), u.speaker_uuid
                ORDER BY u.recording_id, local_label, u.speaker_uuid
            """,
            arguments: [
                SpeakerAssignmentSource.manual.rawValue,
                SpeakerAssignmentSource.globalManual.rawValue
            ]
        )
        for row in rows {
            guard let recordingId: Int64 = row["recording_id"] else { continue }
            let label: String = row["local_label"] ?? ""
            let speakerUUID: String? = row["speaker_uuid"]
            let key = "legacy|\(label)|\(speakerUUID ?? "-")"
            let spans = try utteranceSpans(
                db,
                recordingId: recordingId,
                label: label,
                speakerUUID: speakerUUID
            )
            let clusterId = try upsertCluster(
                db,
                recordingId: recordingId,
                localKey: key,
                localLabel: label,
                embedding: try meanVoiceEmbedding(
                    db,
                    recordingId: recordingId,
                    label: label,
                    speakerUUID: speakerUUID
                ),
                confidence: 0.5,
                cohesion: nil,
                embeddingTurnCount: spans.count,
                mixtureSplitGain: nil,
                mixtureCentroidSimilarity: nil,
                spans: spans
            )
            try db.execute(
                sql: """
                    UPDATE utterances SET
                        local_speaker_label = COALESCE(local_speaker_label, speaker, ?),
                        local_speaker_cluster_id = ?
                    WHERE recording_id = ?
                      AND COALESCE(speaker, '') = ?
                      AND ((speaker_uuid = ?) OR (speaker_uuid IS NULL AND ? IS NULL))
                """,
                arguments: [
                    label, clusterId, recordingId, label, speakerUUID, speakerUUID
                ]
            )
            if let speakerUUID {
                let isManual: Int = row["is_manual"] ?? 0
                let isGold: Int = row["is_gold"] ?? 0
                try upsertAssignment(
                    db,
                    clusterId: clusterId,
                    input: AssignmentInput(
                        speakerUUID: speakerUUID,
                        state: isGold == 1 ? .gold : (isManual == 1 ? .manual : .legacy),
                        source: isManual == 1 ? .globalManual : .model,
                        confidence: isManual == 1 ? 1 : 0.5,
                        score: nil,
                        margin: nil,
                        supportingPrototypeCount: nil,
                        matcher: "v31-legacy-import",
                        evidenceJSON: nil
                    )
                )
            }
        }
    }

    private static func upsertCluster(
        _ db: Database,
        recordingId: Int64,
        localKey: String,
        localLabel: String,
        embedding: [Float]?,
        confidence: Float,
        cohesion: Float?,
        embeddingTurnCount: Int,
        mixtureSplitGain: Float?,
        mixtureCentroidSimilarity: Float?,
        spans: [SpeakerIdentityTimeSpan]
    ) throws -> Int64 {
        let now = Date()
        let embeddingData = embedding.flatMap {
            $0.count == SpeakerEmbeddingPolicy.dimension
                ? VoiceEmbeddingStore.floatsToData(VoiceMath.normalized($0))
                : nil
        }
        try db.execute(
            sql: """
                INSERT INTO speaker_local_clusters (
                    recording_id, local_key, local_label, embedding, confidence,
                    cohesion, embedding_turn_count, mixture_split_gain,
                    mixture_centroid_similarity, spans_json, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(recording_id, local_key) DO UPDATE SET
                    local_label = excluded.local_label,
                    embedding = COALESCE(excluded.embedding, speaker_local_clusters.embedding),
                    confidence = MAX(speaker_local_clusters.confidence, excluded.confidence),
                    cohesion = COALESCE(excluded.cohesion, speaker_local_clusters.cohesion),
                    embedding_turn_count = MAX(
                        speaker_local_clusters.embedding_turn_count,
                        excluded.embedding_turn_count
                    ),
                    mixture_split_gain = COALESCE(
                        excluded.mixture_split_gain,
                        speaker_local_clusters.mixture_split_gain
                    ),
                    mixture_centroid_similarity = COALESCE(
                        excluded.mixture_centroid_similarity,
                        speaker_local_clusters.mixture_centroid_similarity
                    ),
                    spans_json = COALESCE(excluded.spans_json, speaker_local_clusters.spans_json),
                    updated_at = excluded.updated_at
            """,
            arguments: [
                recordingId, localKey, localLabel, embeddingData, confidence,
                cohesion, embeddingTurnCount, mixtureSplitGain,
                mixtureCentroidSimilarity, encodeSpans(spans), now, now
            ]
        )
        guard let id = try Int64.fetchOne(
            db,
            sql: """
                SELECT id FROM speaker_local_clusters
                WHERE recording_id = ? AND local_key = ?
            """,
            arguments: [recordingId, localKey]
        ) else {
            throw NSError(
                domain: "GlobalSpeakerIdentityStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create local speaker cluster"]
            )
        }
        return id
    }

    private static func upsertAssignment(
        _ db: Database,
        clusterId: Int64,
        input: AssignmentInput
    ) throws {
        let now = Date()
        try db.execute(
            sql: """
                INSERT INTO speaker_global_assignments (
                    local_cluster_id, speaker_uuid, state, source, confidence,
                    score, margin, supporting_prototype_count, matcher,
                    evidence_json, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(local_cluster_id) DO UPDATE SET
                    speaker_uuid = excluded.speaker_uuid,
                    state = excluded.state,
                    source = excluded.source,
                    confidence = excluded.confidence,
                    score = excluded.score,
                    margin = excluded.margin,
                    supporting_prototype_count = excluded.supporting_prototype_count,
                    matcher = excluded.matcher,
                    evidence_json = excluded.evidence_json,
                    operation_id = NULL,
                    reconciliation_run_id = NULL,
                    updated_at = excluded.updated_at
            """,
            arguments: [
                clusterId, input.speakerUUID, input.state.rawValue, input.source.rawValue,
                input.confidence, input.score, input.margin, input.supportingPrototypeCount,
                input.matcher, input.evidenceJSON, now, now
            ]
        )
    }

    private static func recordCandidates(
        _ db: Database,
        clusterId: Int64,
        candidates: [CandidateEvidence]
    ) throws {
        try db.execute(
            sql: "DELETE FROM speaker_global_candidates WHERE local_cluster_id = ?",
            arguments: [clusterId]
        )
        for candidate in candidates {
            try db.execute(
                sql: """
                    INSERT INTO speaker_global_candidates (
                        local_cluster_id, candidate_speaker_uuid, rank, score,
                        best_prototype_score, margin, supporting_prototype_count,
                        eligible, rejection_reason, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    clusterId, candidate.candidateUUID, candidate.rank, candidate.score,
                    candidate.bestPrototypeScore, candidate.margin,
                    candidate.supportingPrototypeCount, candidate.eligible,
                    candidate.rejectionReason, Date()
                ]
            )
        }
    }

    private static func meanVoiceEmbedding(
        _ db: Database,
        recordingId: Int64,
        label: String,
        speakerUUID: String?
    ) throws -> [Float]? {
        guard try db.tableExists("utterance_voice_embeddings") else { return nil }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT e.embedding, COALESCE(u.voice_embedding_quality, 1.0) AS quality
                FROM utterances u
                JOIN utterance_voice_embeddings e ON e.utterance_id = u.id
                WHERE u.recording_id = ?
                  AND COALESCE(u.local_speaker_label, u.speaker, '') = ?
                  AND ((u.speaker_uuid = ?) OR (u.speaker_uuid IS NULL AND ? IS NULL))
                ORDER BY u.start_time, u.id
            """,
            arguments: [recordingId, label, speakerUUID, speakerUUID]
        )
        let weighted = rows.compactMap { row -> (vector: [Float], weight: Float)? in
            guard let data: Data = row["embedding"] else { return nil }
            let vector = VoiceEmbeddingStore.dataToFloats(data)
            guard vector.count == SpeakerEmbeddingPolicy.dimension else { return nil }
            let qualityValue: Double = row["quality"] ?? 1
            let quality = Float(qualityValue)
            return (vector, max(0.05, quality))
        }
        return VoiceMath.weightedMeanNormalized(weighted)
    }

    private static func utteranceVoiceEmbedding(
        _ db: Database,
        utteranceId: Int64
    ) throws -> [Float]? {
        guard try db.tableExists("utterance_voice_embeddings"),
              let data = try Data.fetchOne(
                  db,
                  sql: """
                      SELECT embedding FROM utterance_voice_embeddings
                      WHERE utterance_id = ?
                  """,
                  arguments: [utteranceId]
              ) else { return nil }
        let vector = VoiceEmbeddingStore.dataToFloats(data)
        return vector.count == SpeakerEmbeddingPolicy.dimension ? vector : nil
    }

    private static func refreshLocalClusterEvidence(
        _ db: Database,
        clusterId: Int64
    ) throws {
        let utteranceRows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, start_time, end_time
                FROM utterances
                WHERE local_speaker_cluster_id = ?
                ORDER BY start_time, end_time, id
            """,
            arguments: [clusterId]
        )
        let spans = utteranceRows.compactMap { row -> SpeakerIdentityTimeSpan? in
            guard let start: Double = row["start_time"],
                  let end: Double = row["end_time"] else { return nil }
            return SpeakerIdentityTimeSpan(start: start, end: end)
        }
        var vectors: [[Float]] = []
        if try db.tableExists("utterance_voice_embeddings") {
            vectors = try Row.fetchAll(
                db,
                sql: """
                    SELECT e.embedding
                    FROM utterances u
                    JOIN utterance_voice_embeddings e ON e.utterance_id = u.id
                    WHERE u.local_speaker_cluster_id = ?
                    ORDER BY u.start_time, u.id
                """,
                arguments: [clusterId]
            ).compactMap { row in
                guard let data: Data = row["embedding"] else { return nil }
                let vector = VoiceEmbeddingStore.dataToFloats(data)
                return vector.count == SpeakerEmbeddingPolicy.dimension ? vector : nil
            }
        }
        let mean = VoiceMath.meanNormalized(vectors)
        try db.execute(
            sql: """
                UPDATE speaker_local_clusters SET
                    embedding = ?, embedding_turn_count = ?,
                    spans_json = ?, updated_at = ?
                WHERE id = ?
            """,
            arguments: [
                mean.map(VoiceEmbeddingStore.floatsToData),
                vectors.count,
                encodeSpans(spans),
                Date(),
                clusterId
            ]
        )
    }

    private static func utteranceSpans(
        _ db: Database,
        recordingId: Int64,
        label: String,
        speakerUUID: String?
    ) throws -> [SpeakerIdentityTimeSpan] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT start_time, end_time
                FROM utterances
                WHERE recording_id = ?
                  AND COALESCE(local_speaker_label, speaker, '') = ?
                  AND ((speaker_uuid = ?) OR (speaker_uuid IS NULL AND ? IS NULL))
                ORDER BY start_time, end_time, id
            """,
            arguments: [recordingId, label, speakerUUID, speakerUUID]
        ).compactMap { row in
            guard let start: Double = row["start_time"],
                  let end: Double = row["end_time"] else { return nil }
            return SpeakerIdentityTimeSpan(start: start, end: end)
        }
    }

    private static func encodeSpans(_ spans: [SpeakerIdentityTimeSpan]) -> String? {
        guard !spans.isEmpty,
              let data = try? JSONEncoder().encode(
                  spans.map { CodableSpan(start: $0.start, end: $0.end) }
              ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeSpans(_ json: String?) -> [SpeakerIdentityTimeSpan] {
        guard let json,
              let data = json.data(using: .utf8),
              let spans = try? JSONDecoder().decode([CodableSpan].self, from: data)
        else { return [] }
        return spans.map { SpeakerIdentityTimeSpan(start: $0.start, end: $0.end) }
    }

    private static func canonicalUUID(_ db: Database, uuid: String) throws -> String {
        var current = uuid
        var visited: Set<String> = []
        while visited.insert(current).inserted,
              let next = try String.fetchOne(
                  db,
                  sql: """
                      SELECT canonical_uuid FROM speakers
                      WHERE uuid = ? AND identity_state = 'alias'
                  """,
                  arguments: [current]
              ), !next.isEmpty {
            current = next
        }
        return current
    }

    private static func speakerExists(_ db: Database, uuid: String) throws -> Bool {
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM speakers WHERE uuid = ?",
            arguments: [uuid]
        ) == 1
    }
}
