import Foundation
import GRDB

enum SpeakerPairGoldVerdict: String, Codable, CaseIterable, Sendable {
    case samePerson = "same_person"
    case differentPeople = "different_people"
    case mixedOrUnclear = "mixed_or_unclear"
    case unsure

    var isScored: Bool {
        self == .samePerson || self == .differentPeople
    }
}

/// Keeps calibration data separate from the safety set used to decide whether an automatic
/// reconciler is allowed to touch People. The partition is recording-based: every pair involving
/// a held-out recording stays held out, so the same recording never leaks into model fitting.
enum SpeakerPairGoldRole: String, Codable, Sendable {
    case development
    case heldOut = "held_out"

    var displayName: String {
        switch self {
        case .development: return "Calibration"
        case .heldOut: return "Held-out safety"
        }
    }
}

enum SpeakerPairGoldSource: String, Codable, Sendable {
    case pairReview = "pair_review"
    case manualGlobalMerge = "manual_global_merge"
    case manualAssignment = "manual_assignment"
    case profileSplit = "profile_split"
    case conversationGold = "conversation_gold"
}

enum SpeakerLocalClusterGoldVerdict: String, Codable, Sendable {
    case multipleSpeakers = "multiple_speakers"
}

struct SpeakerPairVoiceSample: Identifiable, Equatable, Sendable {
    let id: Int64
    let recordingId: Int64
    let recordingTitle: String
    let audioPath: String
    let utteranceId: Int64
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let currentSpeakerUUID: String?
    let currentSpeakerName: String?
    let embedding: [Float]
    let spans: [SpeakerIdentityTimeSpan]
    let potentiallyMixed: Bool
}

struct SpeakerPairReviewCandidate: Identifiable, Equatable, Sendable {
    let left: SpeakerPairVoiceSample
    let right: SpeakerPairVoiceSample
    let similarity: Float
    let score: Double
    let reason: String
    let goldRole: SpeakerPairGoldRole

    var id: String { Self.key(left.id, right.id) }

    static func key(_ lhs: Int64, _ rhs: Int64) -> String {
        "\(min(lhs, rhs)):\(max(lhs, rhs))"
    }
}

struct SpeakerPairGoldCounts: Equatable, Sendable {
    var samePerson = 0
    var differentPeople = 0
    var mixedOrUnclear = 0
    var unsure = 0

    var scored: Int { samePerson + differentPeople }
    var reviewed: Int { scored + mixedOrUnclear + unsure }
}

struct SpeakerPairGoldMetrics: Codable, Equatable, Sendable {
    let evaluatedPairCount: Int
    let samePersonPairCount: Int
    let differentPeoplePairCount: Int
    let correctPairCount: Int
    let accuracy: Double?
    let falseMergePairs: Int
    let falseSplitPairs: Int
}

struct SpeakerPairGoldCandidateReport: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let threshold: Float?
    let metrics: SpeakerPairGoldMetrics
}

struct SpeakerPairGoldBenchmarkReport: Codable, Equatable, Sendable {
    let revision: String
    let candidates: [SpeakerPairGoldCandidateReport]
}

struct SpeakerPairReviewWorkspace: Equatable, Sendable {
    let counts: SpeakerPairGoldCounts
    let developmentCounts: SpeakerPairGoldCounts
    let heldOutCounts: SpeakerPairGoldCounts
    let multipleSpeakerClipCount: Int
    let candidates: [SpeakerPairReviewCandidate]
    let benchmark: SpeakerPairGoldBenchmarkReport?
    let reconciliationShadow: GlobalSpeakerReconciliationShadowReport?
    let revision: String
}

struct SpeakerPairGoldLabel: Equatable, Sendable {
    let leftClusterId: Int64
    let rightClusterId: Int64
    let verdict: SpeakerPairGoldVerdict
    let role: SpeakerPairGoldRole
    let source: SpeakerPairGoldSource
    let sourceActionID: String?
    let updatedAt: Date

    init(
        leftClusterId: Int64,
        rightClusterId: Int64,
        verdict: SpeakerPairGoldVerdict,
        role: SpeakerPairGoldRole = .development,
        source: SpeakerPairGoldSource = .pairReview,
        sourceActionID: String? = nil,
        updatedAt: Date
    ) {
        self.leftClusterId = leftClusterId
        self.rightClusterId = rightClusterId
        self.verdict = verdict
        self.role = role
        self.source = source
        self.sourceActionID = sourceActionID
        self.updatedAt = updatedAt
    }

    var key: String {
        SpeakerPairReviewCandidate.key(leftClusterId, rightClusterId)
    }
}

struct SpeakerLocalClusterGoldLabel: Equatable, Sendable {
    let localClusterId: Int64
    let verdict: SpeakerLocalClusterGoldVerdict
    let updatedAt: Date
}

/// Direct human constraints for the global-speaker layer.
///
/// These labels never merge or split People records. They are an independent gold source used to
/// rank future questions and score global clustering without requiring a full transcript review.
enum SpeakerPairGoldStore {
    static func migrate(_ db: Database) throws {
        try db.create(table: "speaker_pair_gold_labels", ifNotExists: true) { table in
            table.column("left_local_cluster_id", .integer).notNull()
                .references("speaker_local_clusters", onDelete: .cascade)
            table.column("right_local_cluster_id", .integer).notNull()
                .references("speaker_local_clusters", onDelete: .cascade)
            table.column("verdict", .text).notNull()
            table.column("created_at", .datetime).notNull()
            table.column("updated_at", .datetime).notNull()
            table.primaryKey(["left_local_cluster_id", "right_local_cluster_id"])
            table.check(
                Column("left_local_cluster_id") < Column("right_local_cluster_id")
            )
        }
        try db.create(
            index: "idx_speaker_pair_gold_verdict",
            on: "speaker_pair_gold_labels",
            columns: ["verdict", "updated_at"],
            ifNotExists: true
        )
        let pairColumns = Set(try db.columns(in: "speaker_pair_gold_labels").map(\.name))
        if !pairColumns.contains("dataset_role") {
            try db.alter(table: "speaker_pair_gold_labels") {
                $0.add(column: "dataset_role", .text)
                    .notNull()
                    .defaults(to: SpeakerPairGoldRole.development.rawValue)
            }
            // Backfill the pre-partition labels deterministically by recording. Any pair touching
            // a held-out recording is held out, preventing endpoint/session leakage.
            let localClusterColumns = Set(
                try db.columns(in: "speaker_local_clusters").map(\.name)
            )
            if localClusterColumns.contains("recording_id") {
                try db.execute(
                    sql: """
                        UPDATE speaker_pair_gold_labels
                        SET dataset_role = ?
                        WHERE EXISTS (
                            SELECT 1
                            FROM speaker_local_clusters c
                            WHERE c.id IN (
                                speaker_pair_gold_labels.left_local_cluster_id,
                                speaker_pair_gold_labels.right_local_cluster_id
                            )
                              AND ABS(c.recording_id) % 5 = 0
                        )
                    """,
                    arguments: [SpeakerPairGoldRole.heldOut.rawValue]
                )
            }
        }
        if !pairColumns.contains("label_source") {
            try db.alter(table: "speaker_pair_gold_labels") {
                $0.add(column: "label_source", .text)
                    .notNull()
                    .defaults(to: SpeakerPairGoldSource.pairReview.rawValue)
            }
        }
        if !pairColumns.contains("source_action_id") {
            try db.alter(table: "speaker_pair_gold_labels") {
                $0.add(column: "source_action_id", .text)
            }
        }
        try db.create(
            index: "idx_speaker_pair_gold_source_action",
            on: "speaker_pair_gold_labels",
            columns: ["label_source", "source_action_id"],
            ifNotExists: true
        )
        try db.create(table: "speaker_local_cluster_gold_labels", ifNotExists: true) { table in
            table.column("local_cluster_id", .integer).primaryKey()
                .references("speaker_local_clusters", onDelete: .cascade)
            table.column("verdict", .text).notNull()
            table.column("created_at", .datetime).notNull()
            table.column("updated_at", .datetime).notNull()
        }
        try db.create(
            index: "idx_speaker_local_cluster_gold_verdict",
            on: "speaker_local_cluster_gold_labels",
            columns: ["verdict", "updated_at"],
            ifNotExists: true
        )
    }

    static func loadWorkspace(limit: Int = 80) throws -> SpeakerPairReviewWorkspace {
        _ = FileAccessManager.shared.getVoiceMemosURL()
        return try GRDBDatabaseManager.shared.read { db in
            try loadWorkspace(db, limit: limit)
        }
    }

    static func loadBenchmark() throws -> SpeakerPairGoldBenchmarkReport? {
        try GRDBDatabaseManager.shared.read { db in
            guard try db.tableExists("speaker_pair_gold_labels") else { return nil }
            let mixedClusterIDs = Set(
                try loadClusterLabels(db)
                    .filter { $0.verdict == .multipleSpeakers }
                    .map(\.localClusterId)
            )
            let labels = try loadLabels(db).filter {
                !mixedClusterIDs.contains($0.leftClusterId)
                    && !mixedClusterIDs.contains($0.rightClusterId)
            }
            return benchmark(
                samples: try loadSamples(db).filter {
                    !mixedClusterIDs.contains($0.id)
                },
                labels: labels
            )
        }
    }

    static func loadWorkspace(
        _ db: Database,
        limit: Int = 80
    ) throws -> SpeakerPairReviewWorkspace {
        guard try db.tableExists("speaker_pair_gold_labels") else {
            return SpeakerPairReviewWorkspace(
                counts: SpeakerPairGoldCounts(),
                developmentCounts: SpeakerPairGoldCounts(),
                heldOutCounts: SpeakerPairGoldCounts(),
                multipleSpeakerClipCount: 0,
                candidates: [],
                benchmark: nil,
                reconciliationShadow: nil,
                revision: ""
            )
        }
        let samples = try loadSamples(db)
        let labels = try loadLabels(db)
        let clusterLabels = try loadClusterLabels(db)
        let multipleSpeakerClusterIDs = Set(
            clusterLabels
                .filter { $0.verdict == .multipleSpeakers }
                .map(\.localClusterId)
        )
        let identitySamples = samples.filter {
            !multipleSpeakerClusterIDs.contains($0.id) && !$0.potentiallyMixed
        }
        let identityLabels = labels.filter {
            !multipleSpeakerClusterIDs.contains($0.leftClusterId)
                && !multipleSpeakerClusterIDs.contains($0.rightClusterId)
        }
        let totalCounts = counts(identityLabels)
        let developmentCounts = counts(identityLabels.filter { $0.role == .development })
        let heldOutCounts = counts(identityLabels.filter { $0.role == .heldOut })
        let benchmark = benchmark(samples: identitySamples, labels: identityLabels)
        return SpeakerPairReviewWorkspace(
            counts: totalCounts,
            developmentCounts: developmentCounts,
            heldOutCounts: heldOutCounts,
            multipleSpeakerClipCount: multipleSpeakerClusterIDs.count,
            candidates: rank(
                samples: identitySamples,
                reviewedPairKeys: Set(labels.map(\.key)),
                limit: limit,
                heldOutCounts: heldOutCounts
            ),
            benchmark: benchmark,
            reconciliationShadow: try GlobalSpeakerLibraryReconciliation.shadowReport(db),
            revision: revision(labels, clusterLabels: clusterLabels)
        )
    }

    static func save(
        leftClusterId: Int64,
        rightClusterId: Int64,
        verdict: SpeakerPairGoldVerdict,
        role: SpeakerPairGoldRole? = nil,
        source: SpeakerPairGoldSource = .pairReview,
        sourceActionID: String? = nil
    ) throws {
        try GRDBDatabaseManager.shared.write { db in
            try save(
                db,
                    leftClusterId: leftClusterId,
                    rightClusterId: rightClusterId,
                    verdict: verdict,
                    role: role,
                    source: source,
                    sourceActionID: sourceActionID
            )
        }
    }

    static func save(
        _ db: Database,
        leftClusterId: Int64,
        rightClusterId: Int64,
        verdict: SpeakerPairGoldVerdict,
        role: SpeakerPairGoldRole? = nil,
        source: SpeakerPairGoldSource = .pairReview,
        sourceActionID: String? = nil,
        now: Date = Date()
    ) throws {
        let left = min(leftClusterId, rightClusterId)
        let right = max(leftClusterId, rightClusterId)
        guard left != right else { return }
        let resolvedRole = try role ?? roleForPair(
            db,
            leftClusterId: left,
            rightClusterId: right
        )
        try db.execute(
            sql: """
                INSERT INTO speaker_pair_gold_labels (
                    left_local_cluster_id, right_local_cluster_id,
                    verdict, dataset_role, label_source, source_action_id,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(left_local_cluster_id, right_local_cluster_id) DO UPDATE SET
                    verdict = excluded.verdict,
                    dataset_role = excluded.dataset_role,
                    label_source = excluded.label_source,
                    source_action_id = excluded.source_action_id,
                    updated_at = excluded.updated_at
            """,
            arguments: [
                left,
                right,
                verdict.rawValue,
                resolvedRole.rawValue,
                source.rawValue,
                sourceActionID,
                now,
                now,
            ]
        )
    }

    /// Convert an explicit global People merge into development gold. Existing pair-review labels
    /// always win; one user action contributes a bounded, recording-diverse set instead of an
    /// unbounded Cartesian product.
    static func recordManualGlobalMerge(
        _ db: Database,
        sourceUUID: String,
        targetUUID: String,
        operationID: Int64,
        now: Date = Date()
    ) throws {
        let sourceClusters = try reliableClusters(db, speakerUUID: sourceUUID)
        let targetClusters = try reliableClusters(db, speakerUUID: targetUUID)
        let actionID = "global-merge:\(operationID)"
        var inserted = 0
        for source in sourceClusters {
            for target in targetClusters
            where source.recordingID != target.recordingID {
                guard inserted < 12 else { return }
                if try insertDerivedLabel(
                    db,
                    leftClusterID: source.id,
                    rightClusterID: target.id,
                    verdict: .samePerson,
                    source: .manualGlobalMerge,
                    actionID: actionID,
                    now: now
                ) {
                    inserted += 1
                }
            }
        }
    }

    /// Convert “this local voice belongs to that person” into positive evidence against clean
    /// target examples and negative evidence against the clean profile it was removed from.
    static func recordManualAssignment(
        _ db: Database,
        clusterID: Int64,
        previousUUID: String?,
        targetUUID: String,
        source: SpeakerPairGoldSource = .manualAssignment,
        actionID: String,
        now: Date = Date()
    ) throws {
        guard let moved = try reliableCluster(db, id: clusterID) else { return }
        // A later correction supersedes derived evidence for this endpoint. Direct pair-review
        // labels are never deleted or overwritten.
        try db.execute(
            sql: """
                DELETE FROM speaker_pair_gold_labels
                WHERE label_source IN (?, ?)
                  AND (left_local_cluster_id = ? OR right_local_cluster_id = ?)
            """,
            arguments: [
                SpeakerPairGoldSource.manualAssignment.rawValue,
                SpeakerPairGoldSource.profileSplit.rawValue,
                clusterID,
                clusterID,
            ]
        )

        let targetExamples = try reliableClusters(db, speakerUUID: targetUUID)
            .filter { $0.id != clusterID && $0.recordingID != moved.recordingID }
        for target in targetExamples.prefix(3) {
            _ = try insertDerivedLabel(
                db,
                leftClusterID: clusterID,
                rightClusterID: target.id,
                verdict: .samePerson,
                source: source,
                actionID: actionID,
                now: now
            )
        }
        if let previousUUID, previousUUID != targetUUID {
            let previousExamples = try reliableClusters(db, speakerUUID: previousUUID)
                .filter { $0.id != clusterID && $0.recordingID != moved.recordingID }
            for previous in previousExamples.prefix(3) {
                _ = try insertDerivedLabel(
                    db,
                    leftClusterID: clusterID,
                    rightClusterID: previous.id,
                    verdict: .differentPeople,
                    source: source,
                    actionID: actionID,
                    now: now
                )
            }
        }
    }

    static func deleteDerivedLabels(
        _ db: Database,
        actionID: String
    ) throws {
        try db.execute(
            sql: """
                DELETE FROM speaker_pair_gold_labels
                WHERE source_action_id = ? AND label_source <> ?
            """,
            arguments: [actionID, SpeakerPairGoldSource.pairReview.rawValue]
        )
    }

    /// A fully reviewed conversation yields definite within-call Same/Different relations. These
    /// inherit the recording-based partition, so a held-out recording contributes only safety
    /// examples and never leaks into calibration.
    static func recordConversationGold(
        _ db: Database,
        recordingID: Int64,
        now: Date = Date()
    ) throws {
        let actionID = "conversation-gold:\(recordingID)"
        try deleteDerivedLabels(db, actionID: actionID)
        let clusters = try Row.fetchAll(
            db,
            sql: """
                SELECT c.id, c.recording_id, a.speaker_uuid
                FROM speaker_local_clusters c
                JOIN speaker_global_assignments a ON a.local_cluster_id = c.id
                LEFT JOIN speaker_local_cluster_gold_labels mixed
                  ON mixed.local_cluster_id = c.id
                 AND mixed.verdict = 'multiple_speakers'
                WHERE c.recording_id = ?
                  AND c.embedding IS NOT NULL
                  AND c.mixture_split_gain IS NULL
                  AND NOT (
                      c.embedding_turn_count > 1
                      AND COALESCE(c.cohesion, 1) < 0.35
                  )
                  AND mixed.local_cluster_id IS NULL
                ORDER BY c.id
            """,
            arguments: [recordingID]
        ).compactMap { row -> (id: Int64, uuid: String)? in
            guard let id: Int64 = row["id"],
                  let uuid: String = row["speaker_uuid"] else { return nil }
            return (id, uuid)
        }
        let role = try roleForPair(
            db,
            leftClusterId: clusters.first?.id ?? 0,
            rightClusterId: clusters.last?.id ?? 0
        )
        var inserted = 0
        for leftIndex in clusters.indices {
            guard leftIndex + 1 < clusters.count else { continue }
            for rightIndex in (leftIndex + 1)..<clusters.count {
                guard inserted < 24 else { return }
                if try insertDerivedLabel(
                    db,
                    leftClusterID: clusters[leftIndex].id,
                    rightClusterID: clusters[rightIndex].id,
                    verdict: clusters[leftIndex].uuid == clusters[rightIndex].uuid
                        ? .samePerson
                        : .differentPeople,
                    role: role,
                    source: .conversationGold,
                    actionID: actionID,
                    now: now
                ) {
                    inserted += 1
                }
            }
        }
    }

    static func delete(leftClusterId: Int64, rightClusterId: Int64) throws {
        try GRDBDatabaseManager.shared.write { db in
            try db.execute(
                sql: """
                    DELETE FROM speaker_pair_gold_labels
                    WHERE left_local_cluster_id = ? AND right_local_cluster_id = ?
                """,
                arguments: [
                    min(leftClusterId, rightClusterId),
                    max(leftClusterId, rightClusterId),
                ]
            )
        }
    }

    static func markMultipleSpeakers(
        pairLeftClusterId: Int64,
        pairRightClusterId: Int64,
        mixedClusterId: Int64
    ) throws {
        try GRDBDatabaseManager.shared.write { db in
            try markMultipleSpeakers(
                db,
                pairLeftClusterId: pairLeftClusterId,
                pairRightClusterId: pairRightClusterId,
                mixedClusterId: mixedClusterId
            )
        }
    }

    static func markMultipleSpeakers(
        _ db: Database,
        pairLeftClusterId: Int64,
        pairRightClusterId: Int64,
        mixedClusterId: Int64,
        now: Date = Date()
    ) throws {
        precondition(
            mixedClusterId == pairLeftClusterId || mixedClusterId == pairRightClusterId,
            "The multi-speaker cluster must be one side of the reviewed pair."
        )
        try save(
            db,
            leftClusterId: pairLeftClusterId,
            rightClusterId: pairRightClusterId,
            verdict: .mixedOrUnclear,
            now: now
        )
        try db.execute(
            sql: """
                INSERT INTO speaker_local_cluster_gold_labels (
                    local_cluster_id, verdict, created_at, updated_at
                ) VALUES (?, ?, ?, ?)
                ON CONFLICT(local_cluster_id) DO UPDATE SET
                    verdict = excluded.verdict,
                    updated_at = excluded.updated_at
            """,
            arguments: [
                mixedClusterId,
                SpeakerLocalClusterGoldVerdict.multipleSpeakers.rawValue,
                now,
                now,
            ]
        )

        // The label is operational immediately: remove this cluster from the person's enrollment
        // centroid and legacy prototype history instead of waiting for the next transcription.
        if try db.tableExists("speaker_global_assignments"),
           let speakerUUID = try String.fetchOne(
               db,
               sql: """
                   SELECT speaker_uuid FROM speaker_global_assignments
                   WHERE local_cluster_id = ?
               """,
               arguments: [mixedClusterId]
           ) {
            try GlobalSpeakerIdentityStore.refreshProfile(db, uuid: speakerUUID)
            try SpeakerVoicePrototypeStore.rebuild(
                db,
                speakerUUID: speakerUUID,
                policy: .qualityDurationWeighted
            )
        }
    }

    static func undo(
        leftClusterId: Int64,
        rightClusterId: Int64,
        mixedClusterId: Int64?
    ) throws {
        try GRDBDatabaseManager.shared.write { db in
            try undo(
                db,
                leftClusterId: leftClusterId,
                rightClusterId: rightClusterId,
                mixedClusterId: mixedClusterId
            )
        }
    }

    static func undo(
        _ db: Database,
        leftClusterId: Int64,
        rightClusterId: Int64,
        mixedClusterId: Int64?
    ) throws {
        let affectedSpeakerUUID: String?
        if let mixedClusterId,
           try db.tableExists("speaker_global_assignments") {
            affectedSpeakerUUID = try String.fetchOne(
                db,
                sql: """
                    SELECT speaker_uuid FROM speaker_global_assignments
                    WHERE local_cluster_id = ?
                """,
                arguments: [mixedClusterId]
            )
        } else {
            affectedSpeakerUUID = nil
        }
        try db.execute(
            sql: """
                DELETE FROM speaker_pair_gold_labels
                WHERE left_local_cluster_id = ? AND right_local_cluster_id = ?
            """,
            arguments: [
                min(leftClusterId, rightClusterId),
                max(leftClusterId, rightClusterId),
            ]
        )
        if let mixedClusterId {
            try db.execute(
                sql: """
                    DELETE FROM speaker_local_cluster_gold_labels
                    WHERE local_cluster_id = ?
                """,
                arguments: [mixedClusterId]
            )
        }
        if let affectedSpeakerUUID {
            try GlobalSpeakerIdentityStore.refreshProfile(
                db,
                uuid: affectedSpeakerUUID
            )
            try SpeakerVoicePrototypeStore.rebuild(
                db,
                speakerUUID: affectedSpeakerUUID,
                policy: .qualityDurationWeighted
            )
        }
    }

    static func revision(_ db: Database) throws -> String {
        guard try db.tableExists("speaker_pair_gold_labels") else { return "" }
        return revision(
            try loadLabels(db),
            clusterLabels: try loadClusterLabels(db)
        )
    }

    private static func loadSamples(_ db: Database) throws -> [SpeakerPairVoiceSample] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT c.id AS cluster_id,
                       c.recording_id,
                       c.embedding,
                       c.embedding_turn_count,
                       c.cohesion,
                       c.mixture_split_gain,
                       c.spans_json,
                       COALESCE(assigned.canonical_uuid, a.speaker_uuid) AS speaker_uuid,
                       COALESCE(canonical.name, assigned.name) AS speaker_name,
                       r.title AS recording_title,
                       r.file_path,
                       u.id AS utterance_id,
                       u.start_time,
                       u.end_time,
                       u.text
                FROM speaker_local_clusters c
                JOIN recordings r ON r.id = c.recording_id
                LEFT JOIN speaker_global_assignments a ON a.local_cluster_id = c.id
                LEFT JOIN speakers assigned ON assigned.uuid = a.speaker_uuid
                LEFT JOIN speakers canonical
                  ON canonical.uuid = COALESCE(assigned.canonical_uuid, a.speaker_uuid)
                JOIN utterances u ON u.id = (
                    SELECT u2.id
                    FROM utterances u2
                    WHERE u2.local_speaker_cluster_id = c.id
                      AND COALESCE(u2.is_hidden, 0) = 0
                      AND u2.end_time > u2.start_time
                    ORDER BY
                      CASE
                        WHEN COALESCE(u2.speaker_overlap_ratio, 0) <= 0.05
                         AND COALESCE(u2.active_speaker_count, 1) <= 1 THEN 0
                        ELSE 1
                      END,
                      COALESCE(u2.speaker_overlap_ratio, 0),
                      CASE
                        WHEN u2.end_time - u2.start_time BETWEEN 1.5 AND 15 THEN 0
                        ELSE 1
                      END,
                      MIN(u2.end_time - u2.start_time, 12) DESC,
                      u2.id
                    LIMIT 1
                )
                WHERE c.embedding IS NOT NULL
                  AND TRIM(COALESCE(r.file_path, '')) != ''
                ORDER BY c.id
            """
        )
        return rows.compactMap { row in
            guard let clusterId: Int64 = row["cluster_id"],
                  let recordingId: Int64 = row["recording_id"],
                  let embeddingData: Data = row["embedding"],
                  let utteranceId: Int64 = row["utterance_id"],
                  let path: String = row["file_path"],
                  FileManager.default.fileExists(atPath: path)
            else { return nil }
            let embedding = VoiceEmbeddingStore.dataToFloats(embeddingData)
            guard embedding.count == VoiceEmbeddingStore.dimensions else { return nil }
            let start: Double = row["start_time"] ?? 0
            let rawEnd: Double = row["end_time"] ?? start
            let turnCount: Int = row["embedding_turn_count"] ?? 0
            let cohesion: Double? = row["cohesion"]
            let splitGain: Double? = row["mixture_split_gain"]
            let spans: [SpeakerIdentityTimeSpan]
            if let json: String = row["spans_json"],
               let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([CodableTimeSpan].self, from: data) {
                spans = decoded.map { SpeakerIdentityTimeSpan(start: $0.start, end: $0.end) }
            } else {
                spans = []
            }
            let playbackWindow = playbackWindow(start: start, end: rawEnd)
            return SpeakerPairVoiceSample(
                id: clusterId,
                recordingId: recordingId,
                recordingTitle: row["recording_title"] ?? "Untitled recording",
                audioPath: path,
                utteranceId: utteranceId,
                startTime: playbackWindow.lowerBound,
                endTime: playbackWindow.upperBound,
                text: row["text"] ?? "",
                currentSpeakerUUID: row["speaker_uuid"],
                currentSpeakerName: row["speaker_name"],
                embedding: embedding,
                spans: spans,
                potentiallyMixed: splitGain != nil
                    || (turnCount > 1 && (cohesion ?? 1) < 0.35)
            )
        }
    }

    /// The query already prefers 1.5–15 second utterances. Do not impose a second playback cap:
    /// it can stop a longer fallback utterance in the middle of a word or sentence.
    static func playbackWindow(
        start: TimeInterval,
        end: TimeInterval
    ) -> Range<TimeInterval> {
        let safeStart = max(0, start)
        return safeStart..<max(safeStart + 0.2, end)
    }

    private struct ReliableCluster {
        let id: Int64
        let recordingID: Int64
    }

    private static func reliableCluster(
        _ db: Database,
        id: Int64
    ) throws -> ReliableCluster? {
        try reliableClusters(db, clusterID: id).first
    }

    private static func reliableClusters(
        _ db: Database,
        speakerUUID: String? = nil,
        clusterID: Int64? = nil
    ) throws -> [ReliableCluster] {
        var predicates = [
            "c.embedding IS NOT NULL",
            "c.mixture_split_gain IS NULL",
            "NOT (c.embedding_turn_count > 1 AND COALESCE(c.cohesion, 1) < 0.35)",
            "mixed.local_cluster_id IS NULL",
        ]
        var arguments: StatementArguments = []
        if let speakerUUID {
            predicates.append("a.speaker_uuid = ?")
            arguments += [speakerUUID]
        }
        if let clusterID {
            predicates.append("c.id = ?")
            arguments += [clusterID]
        }
        return try Row.fetchAll(
            db,
            sql: """
                SELECT c.id, c.recording_id
                FROM speaker_local_clusters c
                JOIN speaker_global_assignments a ON a.local_cluster_id = c.id
                LEFT JOIN speaker_local_cluster_gold_labels mixed
                  ON mixed.local_cluster_id = c.id
                 AND mixed.verdict = 'multiple_speakers'
                WHERE \(predicates.joined(separator: " AND "))
                ORDER BY c.recording_id, c.id
            """,
            arguments: arguments
        ).compactMap { row in
            guard let id: Int64 = row["id"],
                  let recordingID: Int64 = row["recording_id"] else { return nil }
            return ReliableCluster(id: id, recordingID: recordingID)
        }
    }

    @discardableResult
    private static func insertDerivedLabel(
        _ db: Database,
        leftClusterID: Int64,
        rightClusterID: Int64,
        verdict: SpeakerPairGoldVerdict,
        role: SpeakerPairGoldRole = .development,
        source: SpeakerPairGoldSource,
        actionID: String,
        now: Date
    ) throws -> Bool {
        let left = min(leftClusterID, rightClusterID)
        let right = max(leftClusterID, rightClusterID)
        guard left != right else { return false }
        try db.execute(
            sql: """
                INSERT INTO speaker_pair_gold_labels (
                    left_local_cluster_id, right_local_cluster_id,
                    verdict, dataset_role, label_source, source_action_id,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(left_local_cluster_id, right_local_cluster_id) DO NOTHING
            """,
            arguments: [
                left,
                right,
                verdict.rawValue,
                role.rawValue,
                source.rawValue,
                actionID,
                now,
                now,
            ]
        )
        return db.changesCount > 0
    }

    private static func loadLabels(_ db: Database) throws -> [SpeakerPairGoldLabel] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT left_local_cluster_id, right_local_cluster_id, verdict,
                       dataset_role, label_source, source_action_id, updated_at
                FROM speaker_pair_gold_labels
                ORDER BY updated_at, left_local_cluster_id, right_local_cluster_id
            """
        ).compactMap { row in
            guard let left: Int64 = row["left_local_cluster_id"],
                  let right: Int64 = row["right_local_cluster_id"],
                  let raw: String = row["verdict"],
                  let verdict = SpeakerPairGoldVerdict(rawValue: raw)
            else { return nil }
            return SpeakerPairGoldLabel(
                leftClusterId: left,
                rightClusterId: right,
                verdict: verdict,
                role: SpeakerPairGoldRole(
                    rawValue: row["dataset_role"] ?? ""
                ) ?? .development,
                source: SpeakerPairGoldSource(
                    rawValue: row["label_source"] ?? ""
                ) ?? .pairReview,
                sourceActionID: row["source_action_id"],
                updatedAt: row["updated_at"] ?? .distantPast
            )
        }
    }

    private static func loadClusterLabels(
        _ db: Database
    ) throws -> [SpeakerLocalClusterGoldLabel] {
        guard try db.tableExists("speaker_local_cluster_gold_labels") else { return [] }
        return try Row.fetchAll(
            db,
            sql: """
                SELECT local_cluster_id, verdict, updated_at
                FROM speaker_local_cluster_gold_labels
                ORDER BY updated_at, local_cluster_id
            """
        ).compactMap { row in
            guard let clusterId: Int64 = row["local_cluster_id"],
                  let raw: String = row["verdict"],
                  let verdict = SpeakerLocalClusterGoldVerdict(rawValue: raw)
            else { return nil }
            return SpeakerLocalClusterGoldLabel(
                localClusterId: clusterId,
                verdict: verdict,
                updatedAt: row["updated_at"] ?? .distantPast
            )
        }
    }

    private struct ProfileGroup {
        let key: String
        let samples: [SpeakerPairVoiceSample]
        let centroid: [Float]
    }

    private struct RankedProfilePair {
        let left: ProfileGroup
        let right: ProfileGroup
        let similarity: Float
    }

    static func rank(
        samples: [SpeakerPairVoiceSample],
        reviewedPairKeys: Set<String>,
        limit: Int,
        heldOutCounts: SpeakerPairGoldCounts? = nil
    ) -> [SpeakerPairReviewCandidate] {
        guard limit > 0 else { return [] }
        // A Same/Different question is undefined when either side contains several people.
        // Mixed-cluster predictions belong in the segmentation-repair queue, never the identity
        // queue, even if their centroid happens to look similar to a known voice.
        let reliableSamples = samples.filter { !$0.potentiallyMixed }
        let grouped = Dictionary(grouping: reliableSamples) {
            $0.currentSpeakerUUID ?? "isolated:\($0.id)"
        }
        let profiles: [ProfileGroup] = grouped.compactMap { key, values in
            VoiceMath.meanNormalized(values.map(\.embedding)).map {
                ProfileGroup(key: key, samples: values, centroid: $0)
            }
        }

        var proposed: [SpeakerPairReviewCandidate] = []

        // One or two leave-one-recording-out questions per current identity expose false merges
        // without allowing a 100-call identity to consume the entire queue.
        for profile in profiles where profile.samples.count >= 2 {
            let outliers = profile.samples.sorted {
                SpeakerUnifier.cosine($0.embedding, profile.centroid)
                    < SpeakerUnifier.cosine($1.embedding, profile.centroid)
            }
            for outlier in outliers.prefix(2) {
                let anchors = profile.samples
                    .filter {
                        $0.id != outlier.id && $0.recordingId != outlier.recordingId
                    }
                    .sorted {
                        SpeakerUnifier.cosine($0.embedding, profile.centroid)
                            > SpeakerUnifier.cosine($1.embedding, profile.centroid)
                    }
                guard let anchor = anchors.first else { continue }
                let similarity = SpeakerUnifier.cosine(outlier.embedding, anchor.embedding)
                appendCandidate(
                    left: outlier,
                    right: anchor,
                    similarity: similarity,
                    score: 92 + Double(max(0, 0.72 - similarity)) * 130,
                    reason: "One current identity varies across recordings",
                    reviewedPairKeys: reviewedPairKeys,
                    to: &proposed
                )
            }
        }

        // Compare profile centroids first (hundreds), then inspect only the best local examples.
        // This avoids an O(local-cluster²) scan over thousands of stored clusters.
        var profilePairs: [RankedProfilePair] = []
        for leftIndex in profiles.indices {
            guard leftIndex + 1 < profiles.count else { continue }
            for rightIndex in (leftIndex + 1)..<profiles.count {
                let left = profiles[leftIndex]
                let right = profiles[rightIndex]
                profilePairs.append(
                    RankedProfilePair(
                        left: left,
                        right: right,
                        similarity: SpeakerUnifier.cosine(left.centroid, right.centroid)
                    )
                )
            }
        }

        for pair in profilePairs.sorted(by: { $0.similarity > $1.similarity }).prefix(700) {
            let leftPool = pair.left.samples.sorted {
                SpeakerUnifier.cosine($0.embedding, pair.right.centroid)
                    > SpeakerUnifier.cosine($1.embedding, pair.right.centroid)
            }.prefix(4)
            let rightPool = pair.right.samples.sorted {
                SpeakerUnifier.cosine($0.embedding, pair.left.centroid)
                    > SpeakerUnifier.cosine($1.embedding, pair.left.centroid)
            }.prefix(4)
            let localPairs = leftPool.flatMap { left in
                rightPool.compactMap { right
                    -> (SpeakerPairVoiceSample, SpeakerPairVoiceSample, Float)? in
                    guard left.recordingId != right.recordingId else { return nil }
                    return (
                        left,
                        right,
                        SpeakerUnifier.cosine(left.embedding, right.embedding)
                    )
                }
            }
            guard let best = localPairs.max(by: { $0.2 < $1.2 }) else { continue }
            appendCandidate(
                left: best.0,
                right: best.1,
                similarity: best.2,
                score: 58 + Double(max(0, best.2 - 0.30)) * 120,
                reason: "Different current identities have similar voice evidence",
                reviewedPairKeys: reviewedPairKeys,
                to: &proposed
            )
        }

        var seen: Set<String> = []
        var usage: [Int64: Int] = [:]
        var result: [SpeakerPairReviewCandidate] = []
        for candidate in proposed.sorted(by: {
            candidateOrder($0, $1, heldOutCounts: heldOutCounts)
        }) {
            guard !seen.contains(candidate.id),
                  usage[candidate.left.id, default: 0] < 3,
                  usage[candidate.right.id, default: 0] < 3
            else { continue }
            seen.insert(candidate.id)
            usage[candidate.left.id, default: 0] += 1
            usage[candidate.right.id, default: 0] += 1
            result.append(candidate)
            if result.count == limit { break }
        }
        return result
    }

    private static func appendCandidate(
        left: SpeakerPairVoiceSample,
        right: SpeakerPairVoiceSample,
        similarity: Float,
        score: Double,
        reason: String,
        reviewedPairKeys: Set<String>,
        to result: inout [SpeakerPairReviewCandidate]
    ) {
        let key = SpeakerPairReviewCandidate.key(left.id, right.id)
        guard left.id != right.id, !reviewedPairKeys.contains(key) else { return }
        let ordered = left.id < right.id ? (left, right) : (right, left)
        result.append(
            SpeakerPairReviewCandidate(
                left: ordered.0,
                right: ordered.1,
                similarity: similarity,
                score: score,
                reason: reason,
                goldRole: roleForPair(left.recordingId, right.recordingId)
            )
        )
    }

    private static func candidateOrder(
        _ lhs: SpeakerPairReviewCandidate,
        _ rhs: SpeakerPairReviewCandidate,
        heldOutCounts: SpeakerPairGoldCounts?
    ) -> Bool {
        let leftPriority = heldOutPriority(lhs, counts: heldOutCounts)
        let rightPriority = heldOutPriority(rhs, counts: heldOutCounts)
        if leftPriority != rightPriority { return leftPriority > rightPriority }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.id < rhs.id
    }

    /// Fill the independent safety set before asking lower-value calibration questions. Current
    /// assignments are only a queue heuristic: the developer still supplies the actual verdict.
    private static func heldOutPriority(
        _ candidate: SpeakerPairReviewCandidate,
        counts: SpeakerPairGoldCounts?
    ) -> Int {
        guard let counts, candidate.goldRole == .heldOut else { return 0 }
        let needsSame = counts.samePerson < 3
        let needsDifferent = counts.differentPeople < 3
        let predictedSame = candidate.left.currentSpeakerUUID != nil
            && candidate.left.currentSpeakerUUID == candidate.right.currentSpeakerUUID
        if needsDifferent && !predictedSame { return 3 }
        if needsSame && predictedSame { return 3 }
        if needsSame || needsDifferent { return 2 }
        return 0
    }

    private static func counts(_ labels: [SpeakerPairGoldLabel]) -> SpeakerPairGoldCounts {
        labels.reduce(into: SpeakerPairGoldCounts()) { result, label in
            switch label.verdict {
            case .samePerson: result.samePerson += 1
            case .differentPeople: result.differentPeople += 1
            case .mixedOrUnclear: result.mixedOrUnclear += 1
            case .unsure: result.unsure += 1
            }
        }
    }

    private static func revision(
        _ labels: [SpeakerPairGoldLabel],
        clusterLabels: [SpeakerLocalClusterGoldLabel]
    ) -> String {
        guard !labels.isEmpty || !clusterLabels.isEmpty else { return "" }
        let totals = counts(labels)
        let latest = (
            labels.map(\.updatedAt.timeIntervalSince1970)
                + clusterLabels.map(\.updatedAt.timeIntervalSince1970)
        ).max() ?? 0
        return [
            "\(labels.count)",
            "\(latest)",
            "\(totals.samePerson)",
            "\(totals.differentPeople)",
            "\(totals.mixedOrUnclear)",
            "\(totals.unsure)",
            "\(clusterLabels.count)",
            "\(labels.filter { $0.role == .heldOut }.count)",
        ].joined(separator: ":")
    }

    static func benchmark(
        samples: [SpeakerPairVoiceSample],
        labels: [SpeakerPairGoldLabel]
    ) -> SpeakerPairGoldBenchmarkReport? {
        let scored = labels.filter(\.verdict.isScored)
        guard !scored.isEmpty else { return nil }
        let samplesById = Dictionary(uniqueKeysWithValues: samples.map { ($0.id, $0) })
        let endpointIDs = Set(
            scored.flatMap { [$0.leftClusterId, $0.rightClusterId] }
        )
        let endpointSamples = endpointIDs.compactMap { samplesById[$0] }
        guard !endpointSamples.isEmpty else { return nil }
        let nodes = endpointSamples.map {
            GlobalSpeakerBenchmarkNode(
                id: "cluster:\($0.id)",
                recordingKey: "recording:\($0.recordingId)",
                recordingId: $0.recordingId,
                embedding: $0.embedding,
                spans: $0.spans,
                reliableForIdentity: !$0.potentiallyMixed,
                goldSpeakerKey: nil,
                goldPurity: 0
            )
        }

        func report(
            id: String,
            name: String,
            threshold: Float?,
            assignments: [String: String],
            labels evaluationLabels: [SpeakerPairGoldLabel]? = nil
        ) -> SpeakerPairGoldCandidateReport {
            SpeakerPairGoldCandidateReport(
                id: id,
                name: name,
                threshold: threshold,
                metrics: evaluate(
                    labels: evaluationLabels ?? scored,
                    assignments: assignments
                )
            )
        }

        let productionAssignments = Dictionary(uniqueKeysWithValues: endpointSamples.map {
            (
                "cluster:\($0.id)",
                $0.currentSpeakerUUID ?? "isolated:\($0.id)"
            )
        })
        var candidates = [
            report(
                id: "current-production",
                name: "Current People assignments",
                threshold: nil,
                assignments: productionAssignments
            ),
            report(
                id: "never-merge",
                name: "Never merge",
                threshold: nil,
                assignments: Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.id) })
            ),
        ]
        for threshold: Float in [0.42, 0.46, 0.50, 0.54] {
            let graph = GlobalSpeakerEvidenceGraph.cluster(
                nodes,
                configuration: .init(
                    linkage: .constrainedEvidence,
                    threshold: threshold
                )
            )
            candidates.append(
                report(
                    id: "evidence-\(Int(threshold * 100))",
                    name: "Evidence graph",
                    threshold: threshold,
                    assignments: graph.assignments
                )
            )
        }
        let development = scored.filter { $0.role == .development }
        let heldOut = scored.filter { $0.role == .heldOut }
        let calibrationExamples = development.map {
            GlobalSpeakerCalibrationExample(
                leftNodeID: "cluster:\($0.leftClusterId)",
                rightNodeID: "cluster:\($0.rightClusterId)",
                samePerson: $0.verdict == .samePerson
            )
        }
        let calibratedModel = GlobalSpeakerReconciler.fit(
            nodes: nodes,
            examples: calibrationExamples
        )
        let constraints = development.map {
            GlobalSpeakerReconciliationConstraint(
                "cluster:\($0.leftClusterId)",
                "cluster:\($0.rightClusterId)",
                kind: $0.verdict == .samePerson ? .mustLink : .cannotLink
            )
        }
        let reconciled = GlobalSpeakerReconciler.reconcile(
            nodes: nodes,
            model: calibratedModel,
            constraints: constraints
        )
        candidates.append(
            report(
                id: "calibrated-constrained-development",
                name: calibratedModel.isLearned
                    ? "Calibrated + constraints · development"
                    : "Constraints + fallback score · development",
                threshold: 0.88,
                assignments: reconciled.assignments,
                labels: development
            )
        )
        if !heldOut.isEmpty {
            candidates.append(
                report(
                    id: "calibrated-constrained-held-out",
                    name: calibratedModel.isLearned
                        ? "Calibrated + constraints · held-out"
                        : "Fallback score · held-out",
                    threshold: 0.88,
                    assignments: reconciled.assignments,
                    labels: heldOut
                )
            )
        }
        return SpeakerPairGoldBenchmarkReport(
            revision: revision(labels, clusterLabels: []),
            candidates: candidates
        )
    }

    private static func evaluate(
        labels: [SpeakerPairGoldLabel],
        assignments: [String: String]
    ) -> SpeakerPairGoldMetrics {
        var sameCount = 0
        var differentCount = 0
        var correct = 0
        var falseMerge = 0
        var falseSplit = 0
        for label in labels {
            guard label.verdict.isScored,
                  let left = assignments["cluster:\(label.leftClusterId)"],
                  let right = assignments["cluster:\(label.rightClusterId)"]
            else { continue }
            let predictedSame = left == right
            switch label.verdict {
            case .samePerson:
                sameCount += 1
                if predictedSame { correct += 1 } else { falseSplit += 1 }
            case .differentPeople:
                differentCount += 1
                if predictedSame { falseMerge += 1 } else { correct += 1 }
            case .mixedOrUnclear, .unsure:
                break
            }
        }
        let total = sameCount + differentCount
        return SpeakerPairGoldMetrics(
            evaluatedPairCount: total,
            samePersonPairCount: sameCount,
            differentPeoplePairCount: differentCount,
            correctPairCount: correct,
            accuracy: total > 0 ? Double(correct) / Double(total) : nil,
            falseMergePairs: falseMerge,
            falseSplitPairs: falseSplit
        )
    }

    static func roleForPair(
        _ leftRecordingId: Int64,
        _ rightRecordingId: Int64
    ) -> SpeakerPairGoldRole {
        isHeldOutRecording(leftRecordingId) || isHeldOutRecording(rightRecordingId)
            ? .heldOut
            : .development
    }

    private static func roleForPair(
        _ db: Database,
        leftClusterId: Int64,
        rightClusterId: Int64
    ) throws -> SpeakerPairGoldRole {
        let columns = Set(try db.columns(in: "speaker_local_clusters").map(\.name))
        guard columns.contains("recording_id") else { return .development }
        let recordingIDs = try Int64.fetchAll(
            db,
            sql: """
                SELECT recording_id
                FROM speaker_local_clusters
                WHERE id IN (?, ?)
            """,
            arguments: [leftClusterId, rightClusterId]
        )
        return recordingIDs.contains(where: isHeldOutRecording) ? .heldOut : .development
    }

    private static func isHeldOutRecording(_ recordingId: Int64) -> Bool {
        abs(recordingId) % 5 == 0
    }

    private struct CodableTimeSpan: Codable {
        let start: TimeInterval
        let end: TimeInterval
    }
}
