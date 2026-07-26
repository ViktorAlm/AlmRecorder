import Foundation
import GRDB

/// Conservative, undoable maintenance for global speaker fragments.
///
/// Live matching prevents most new fragments. This pass handles an existing small/unnamed UUID after
/// new evidence arrives by merging it into a well-established identity only when several independent
/// recording prototypes agree, the winner is clear, names do not conflict, and local clusters in a
/// shared recording do not overlap in time. Ambiguous cases remain separate for review.
enum GlobalSpeakerConsolidator {
    struct Candidate: Equatable {
        let uuid: String
        let name: String?
        let nameSource: String?
        let meanEmbedding: [Float]
        let prototypes: [[Float]]
        let recordingIds: Set<Int64>
        let occurrences: [GlobalSpeakerIdentityStore.LocalOccurrence]

        init(
            uuid: String,
            name: String?,
            nameSource: String?,
            meanEmbedding: [Float],
            prototypes: [[Float]],
            recordingIds: Set<Int64>,
            occurrences: [GlobalSpeakerIdentityStore.LocalOccurrence] = []
        ) {
            self.uuid = uuid
            self.name = name
            self.nameSource = nameSource
            self.meanEmbedding = meanEmbedding
            self.prototypes = prototypes
            self.recordingIds = recordingIds
            self.occurrences = occurrences
        }

        var hasManualName: Bool {
            guard name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return false
            }
            return nameSource == nil || nameSource == "manual"
        }
    }

    struct Decision: Equatable {
        let sourceUUID: String
        let targetUUID: String
        let score: Float
        let margin: Float
        let supportingPrototypeCount: Int
    }

    private struct Scored {
        let candidate: Candidate
        let score: Float
        let support: Int
    }

    static func decision(
        source: Candidate,
        candidates: [Candidate],
        threshold: Float,
        ambiguityMargin: Float
    ) -> Decision? {
        guard !source.prototypes.isEmpty else { return nil }
        let sourceName = normalizedName(source.name)
        let eligible = candidates.filter { target in
            guard target.uuid != source.uuid,
                  target.meanEmbedding.count == source.meanEmbedding.count,
                  target.prototypes.count >= 3,
                  !hasTemporalConflict(source, target)
            else { return false }

            let targetName = normalizedName(target.name)
            if source.hasManualName, target.hasManualName, sourceName != targetName {
                return false
            }
            // Do not automatically fold a substantial identity into another one. This sweep is
            // specifically for small fragments; equal confirmed names are the safe exception.
            let sameConfirmedName = source.hasManualName
                && target.hasManualName
                && sourceName != nil
                && sourceName == targetName
            return sameConfirmedName || source.prototypes.count <= 2
        }
        guard !eligible.isEmpty else { return nil }

        let scored = eligible.map { target -> Scored in
            let prototypeSimilarities = target.prototypes
                .flatMap { targetPrototype in
                    source.prototypes.map {
                        SpeakerUnifier.cosine($0, targetPrototype)
                    }
                }
                .sorted(by: >)
            let robustCount = min(3, prototypeSimilarities.count)
            let robust = robustCount > 0
                ? prototypeSimilarities.prefix(robustCount).reduce(0, +) / Float(robustCount)
                : 0
            let meanSimilarity = SpeakerUnifier.cosine(
                source.meanEmbedding,
                target.meanEmbedding
            )
            let supportFloor = max(0.65, threshold - 0.08)
            return Scored(
                candidate: target,
                score: max(meanSimilarity, robust),
                support: prototypeSimilarities.filter { $0 >= supportFloor }.count
            )
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.candidate.prototypes.count != $1.candidate.prototypes.count {
                return $0.candidate.prototypes.count > $1.candidate.prototypes.count
            }
            return $0.candidate.uuid < $1.candidate.uuid
        }

        guard let winner = scored.first else { return nil }
        let secondBest = scored.dropFirst().first?.score ?? -1
        let requiredMargin = max(0.10, ambiguityMargin)
        guard winner.score >= threshold,
              winner.score - secondBest >= requiredMargin,
              winner.support >= 2
        else { return nil }

        return Decision(
            sourceUUID: source.uuid,
            targetUUID: winner.candidate.uuid,
            score: winner.score,
            margin: winner.score - secondBest,
            supportingPrototypeCount: winner.support
        )
    }

    @discardableResult
    static func consolidate(
        sourceUUID: String,
        configuration: SpeakerPipelineConfiguration
    ) throws -> Decision? {
        let candidates = try GRDBDatabaseManager.shared.read(loadCandidates)
        guard let source = candidates.first(where: { $0.uuid == sourceUUID }) else {
            return nil
        }
        let autoThreshold = max(0.79, configuration.identitySimilarityThreshold + 0.08)
        guard let decision = decision(
            source: source,
            candidates: candidates,
            threshold: autoThreshold,
            ambiguityMargin: configuration.identityAmbiguityMargin
        ) else { return nil }

        _ = try GRDBDatabaseManager.shared.write { db in
            try GlobalSpeakerIdentityStore.link(
                db,
                sourceUUID: decision.sourceUUID,
                targetUUID: decision.targetUUID,
                linkSource: .automatic,
                score: decision.score,
                margin: decision.margin,
                supportingPrototypeCount: decision.supportingPrototypeCount,
                evidenceJSON: #"{"matcher":"automatic-prototype-consensus"}"#
            )
        }
        return decision
    }

    /// Reconsider older isolated fragments whenever fresh recording evidence arrives. The sweep is
    /// bounded so ingestion stays responsive; repeated recordings naturally work through the queue.
    /// Large/established identities are never sources under `decision`, only possible targets.
    @discardableResult
    static func consolidatePending(
        configuration: SpeakerPipelineConfiguration,
        priorityUUIDs: Set<String> = [],
        limit: Int = 24
    ) throws -> [Decision] {
        guard limit > 0 else { return [] }
        let candidates = try GRDBDatabaseManager.shared.read(loadCandidates)
        let sources = candidates
            .filter { $0.prototypes.count <= 2 }
            .sorted {
                let leftPriority = priorityUUIDs.contains($0.uuid)
                let rightPriority = priorityUUIDs.contains($1.uuid)
                if leftPriority != rightPriority { return leftPriority }
                if $0.prototypes.count != $1.prototypes.count {
                    return $0.prototypes.count < $1.prototypes.count
                }
                return $0.uuid < $1.uuid
            }
        let autoThreshold = max(0.79, configuration.identitySimilarityThreshold + 0.08)
        var decisions: [Decision] = []
        for source in sources {
            guard decisions.count < limit,
                  let candidateDecision = decision(
                      source: source,
                      candidates: candidates,
                      threshold: autoThreshold,
                      ambiguityMargin: configuration.identityAmbiguityMargin
                  ) else { continue }
            let linked = try GRDBDatabaseManager.shared.write { db in
                try GlobalSpeakerIdentityStore.link(
                    db,
                    sourceUUID: candidateDecision.sourceUUID,
                    targetUUID: candidateDecision.targetUUID,
                    linkSource: .automatic,
                    score: candidateDecision.score,
                    margin: candidateDecision.margin,
                    supportingPrototypeCount: candidateDecision.supportingPrototypeCount,
                    evidenceJSON: #"{"matcher":"continuous-prototype-consensus"}"#
                )
            }
            if linked != nil {
                decisions.append(candidateDecision)
            }
        }
        return decisions
    }

    /// Experimental batch matcher selected explicitly from Custom settings. Existing global
    /// profiles are must-link components; the graph may only join components, never split one.
    /// Every persisted join still uses the v31 reversible operation log.
    @discardableResult
    static func consolidateEvidenceGraph(
        configuration: SpeakerPipelineConfiguration,
        priorityUUIDs: Set<String> = [],
        limit: Int = 24
    ) throws -> [Decision] {
        guard limit > 0 else { return [] }
        let candidates = try GRDBDatabaseManager.shared.read(loadCandidates)
        let candidatesByUUID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.uuid, $0) })
        let nodes = candidates.flatMap { candidate in
            zip(candidate.prototypes, candidate.occurrences).map { prototype, occurrence in
                GlobalSpeakerBenchmarkNode(
                    id: "\(candidate.uuid):\(occurrence.clusterId)",
                    recordingKey: "recording:\(occurrence.recordingId)",
                    recordingId: occurrence.recordingId,
                    embedding: prototype,
                    spans: occurrence.spans,
                    reliableForIdentity: true,
                    goldSpeakerKey: nil,
                    goldPurity: 0,
                    initialIdentityKey: candidate.uuid
                )
            }
        }
        guard nodes.count >= 2 else { return [] }

        let graph = GlobalSpeakerEvidenceGraph.cluster(
            nodes,
            configuration: .init(
                linkage: .constrainedEvidence,
                threshold: configuration.identitySimilarityThreshold
            )
        )
        let nodesByGraphIdentity = Dictionary(grouping: nodes) {
            graph.assignments[$0.id] ?? $0.id
        }
        var proposed: [Decision] = []
        for graphNodes in nodesByGraphIdentity.values {
            let uuids = Set(graphNodes.compactMap(\.initialIdentityKey))
            guard uuids.count >= 2 else { continue }
            let profiles = uuids.compactMap { candidatesByUUID[$0] }.sorted {
                if $0.hasManualName != $1.hasManualName {
                    return $0.hasManualName && !$1.hasManualName
                }
                if $0.prototypes.count != $1.prototypes.count {
                    return $0.prototypes.count > $1.prototypes.count
                }
                // A freshly observed UUID should be considered first as a source, not made the
                // target merely because it triggered this sweep. Prefer the established profile.
                let leftPriority = priorityUUIDs.contains($0.uuid)
                let rightPriority = priorityUUIDs.contains($1.uuid)
                if leftPriority != rightPriority { return !leftPriority }
                return $0.uuid < $1.uuid
            }
            guard let target = profiles.first else { continue }
            for source in profiles.dropFirst()
            where source.prototypes.count <= 2 && proposed.count < limit {
                let sourceName = normalizedName(source.name)
                let targetName = normalizedName(target.name)
                if source.hasManualName, target.hasManualName, sourceName != targetName {
                    continue
                }
                let scores = target.prototypes.flatMap { targetPrototype in
                    source.prototypes.map {
                        SpeakerUnifier.cosine($0, targetPrototype)
                    }
                }
                .sorted(by: >)
                guard let best = scores.first else { continue }
                let topCount = min(3, scores.count)
                let robustTop = scores.prefix(topCount).reduce(0, +) / Float(topCount)
                let score = (0.70 * best) + (0.30 * robustTop)
                let second = scores.dropFirst().first ?? -1
                proposed.append(
                    Decision(
                        sourceUUID: source.uuid,
                        targetUUID: target.uuid,
                        score: score,
                        margin: best - second,
                        supportingPrototypeCount: scores.filter {
                            $0 >= configuration.identitySimilarityThreshold - 0.15
                        }.count
                    )
                )
            }
        }

        var applied: [Decision] = []
        for decision in proposed {
            let linked = try GRDBDatabaseManager.shared.write { db in
                try GlobalSpeakerIdentityStore.link(
                    db,
                    sourceUUID: decision.sourceUUID,
                    targetUUID: decision.targetUUID,
                    linkSource: .automatic,
                    score: decision.score,
                    margin: decision.margin,
                    supportingPrototypeCount: decision.supportingPrototypeCount,
                    evidenceJSON: #"{"matcher":"continuous-constrained-evidence-graph"}"#
                )
            }
            if linked != nil { applied.append(decision) }
        }
        return applied
    }

    private static func loadCandidates(_ db: Database) throws -> [Candidate] {
        let snapshots = try GlobalSpeakerIdentityStore.loadProfileSnapshots(db)
        let snapshotsByUUID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.uuid, $0) })

        return try Row.fetchAll(
            db,
            sql: """
                SELECT uuid, name, name_source, embedding FROM speakers
                WHERE COALESCE(identity_state, 'active') = 'active'
            """
        ).compactMap { row -> Candidate? in
            guard let uuid: String = row["uuid"],
                  let data: Data = row["embedding"],
                  let snapshot = snapshotsByUUID[uuid] else { return nil }
            let mean = VoiceEmbeddingStore.dataToFloats(data)
            guard mean.count == SpeakerEmbeddingPolicy.dimension else { return nil }
            return Candidate(
                uuid: uuid,
                name: row["name"],
                nameSource: row["name_source"],
                meanEmbedding: mean,
                prototypes: snapshot.prototypes,
                recordingIds: Set(snapshot.occurrences.map(\.recordingId)),
                occurrences: snapshot.occurrences
            )
        }
    }

    private static func hasTemporalConflict(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        let sharedRecordings = lhs.recordingIds.intersection(rhs.recordingIds)
        guard !sharedRecordings.isEmpty else { return false }
        for recordingId in sharedRecordings {
            let left = lhs.occurrences.filter { $0.recordingId == recordingId }
            let right = rhs.occurrences.filter { $0.recordingId == recordingId }
            // Old candidates without span evidence remain conservative.
            if left.isEmpty || right.isEmpty { return true }
            for leftOccurrence in left {
                for rightOccurrence in right
                where SpeakerUnifier.materiallyOverlap(
                    leftOccurrence.spans,
                    rightOccurrence.spans
                ) {
                    return true
                }
            }
        }
        return false
    }

    private static func normalizedName(_ name: String?) -> String? {
        guard let value = name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !value.isEmpty else { return nil }
        return value.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
    }
}
