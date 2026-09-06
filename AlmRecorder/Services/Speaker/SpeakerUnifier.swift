import Foundation

struct SpeakerIdentityTimeSpan: Codable, Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval

    var duration: TimeInterval { max(0, end - start) }
}

/// One local diarization cluster from a recording. Keeping the actual turn spans lets the global
/// matcher distinguish harmless over-segmentation from two people who genuinely speak at once.
struct SpeakerIdentityCluster: Equatable, Sendable {
    let label: String
    let embedding: [Float]
    let spans: [SpeakerIdentityTimeSpan]
    let confidence: Float
    /// Lower-quartile cosine from the cluster's turn embeddings to its centroid. A low value means
    /// the local label is internally inconsistent and must not be trusted as global enrollment.
    let cohesion: Float
    let embeddingTurnCount: Int
    let mixtureSplitGain: Float?
    let mixtureCentroidSimilarity: Float?

    init(
        label: String,
        embedding: [Float],
        spans: [SpeakerIdentityTimeSpan] = [],
        confidence: Float = 1,
        cohesion: Float = 1,
        embeddingTurnCount: Int = 1,
        mixtureSplitGain: Float? = nil,
        mixtureCentroidSimilarity: Float? = nil
    ) {
        self.label = label
        self.embedding = embedding
        self.spans = spans
        self.confidence = confidence
        self.cohesion = cohesion
        self.embeddingTurnCount = embeddingTurnCount
        self.mixtureSplitGain = mixtureSplitGain
        self.mixtureCentroidSimilarity = mixtureCentroidSimilarity
    }

    var duration: TimeInterval { spans.reduce(0) { $0 + $1.duration } }

    /// Raw offline chunk embeddings below this cohesion are usually a mixed local label. Legacy
    /// callers that have only one already-collapsed embedding remain eligible because they provide
    /// no dispersion evidence either way.
    var isReliableForGlobalIdentity: Bool {
        embeddingTurnCount <= 1
            || (cohesion >= 0.35 && mixtureSplitGain == nil)
    }
}

/// Stable global identity evidence. `meanEmbedding` preserves the old centroid behavior while
/// `prototypes` gives every recording one equal vote, avoiding domination by a single long call.
struct SpeakerIdentityProfileEvidence: Equatable, Sendable {
    let uuid: String
    let meanEmbedding: [Float]
    let prototypes: [[Float]]
}

/// Cross-file speaker unification. Decides, for a recording's per-file speaker clusters, which are an
/// already-known speaker and which are new — by selectable greedy or globally optimal cosine
/// matching with an optional ambiguity margin.
///
/// Pure and deterministic: the DB create/update side effects live in the caller. Legacy matchers retain
/// strict within-file distinctness. The multi-prototype matcher can reuse an identity for an over-split
/// local cluster, but only when the two local timelines do not materially overlap.
struct SpeakerUnifier {
    /// Result of matching one per-file speaker cluster against the known speaker set.
    /// (Nested to avoid colliding with the wizard's global `SpeakerAssignment`.)
    enum Match: Equatable {
        case existing(uuid: String)
        case new
    }

    /// Minimum cosine similarity to treat two embeddings as the same speaker. Defaults to FluidAudio's
    /// own same-speaker criterion (0.85) — conservative, so we prefer an occasional over-split (easy to
    /// merge in the review wizard) over a wrong merge (hard to undo).
    let matchThreshold: Float
    let strategy: SpeakerIdentityMatcher
    let ambiguityMargin: Float

    init(
        matchThreshold: Float = 0.85,
        strategy: SpeakerIdentityMatcher = .greedy,
        ambiguityMargin: Float = 0
    ) {
        self.matchThreshold = matchThreshold
        self.strategy = strategy
        self.ambiguityMargin = ambiguityMargin
    }

    func assign(
        newClusters: [[Float]],
        existing: [(uuid: String, embedding: [Float])]
    ) -> [Match] {
        switch strategy {
        case .greedy:
            return assignGreedily(newClusters: newClusters, existing: existing)
        case .optimalWithMargin:
            return assignOptimally(newClusters: newClusters, existing: existing)
        case .prototypeConsensus:
            return assignPrototypeConsensus(
                newClusters: newClusters.enumerated().map {
                    SpeakerIdentityCluster(label: "\($0.offset)", embedding: $0.element)
                },
                existing: existing.map {
                    SpeakerIdentityProfileEvidence(
                        uuid: $0.uuid,
                        meanEmbedding: $0.embedding,
                        prototypes: [$0.embedding]
                    )
                }
            )
        case .evidenceGraph:
            // Graph mode deliberately enrolls recording-local clusters before resolving them in a
            // batch. Its edge threshold is calibrated for corroborated graph evidence and is much
            // lower than a safe one-shot enrollment threshold.
            return [Match](repeating: .new, count: newClusters.count)
        }
    }

    /// Multi-prototype global matching. The first pass is still a maximum-weight one-to-one
    /// assignment. A conservative second pass may reuse an already-selected global identity for an
    /// over-split local cluster when:
    /// - the identity wins by the configured ambiguity margin;
    /// - multiple historical recording prototypes support it (or a new identity is exceptionally
    ///   close); and
    /// - the local clusters do not contain simultaneous speech.
    func assign(
        newClusters: [SpeakerIdentityCluster],
        existing: [SpeakerIdentityProfileEvidence]
    ) -> [Match] {
        if strategy == .evidenceGraph {
            return [Match](repeating: .new, count: newClusters.count)
        }
        guard strategy == .prototypeConsensus else {
            let reliableIndices = newClusters.indices.filter {
                newClusters[$0].isReliableForGlobalIdentity
            }
            let reliableMatches = assign(
                newClusters: reliableIndices.map { newClusters[$0].embedding },
                existing: existing.map { ($0.uuid, $0.meanEmbedding) }
            )
            var result = [Match](repeating: .new, count: newClusters.count)
            for (offset, index) in reliableIndices.enumerated() {
                result[index] = reliableMatches[offset]
            }
            return result
        }
        return assignPrototypeConsensus(newClusters: newClusters, existing: existing)
    }

    struct RankedProfileScore: Equatable {
        let uuid: String
        let value: Float
        let bestPrototype: Float
        let supportingPrototypeCount: Int
    }

    private struct ProfileScore {
        let value: Float
        let bestPrototype: Float
        let supportingPrototypeCount: Int
    }

    /// Exposes the evidence behind a benchmark decision without changing the assignment path.
    /// Production callers still consume only `Match`; evaluation reports can show why a link won.
    func rankedProfileScores(
        for cluster: SpeakerIdentityCluster,
        existing: [SpeakerIdentityProfileEvidence]
    ) -> [RankedProfileScore] {
        existing.map { profile in
            let score = profileScore(cluster.embedding, profile: profile)
            return RankedProfileScore(
                uuid: profile.uuid,
                value: score.value,
                bestPrototype: score.bestPrototype,
                supportingPrototypeCount: score.supportingPrototypeCount
            )
        }
        .sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.uuid < $1.uuid
        }
    }

    private func assignPrototypeConsensus(
        newClusters: [SpeakerIdentityCluster],
        existing: [SpeakerIdentityProfileEvidence]
    ) -> [Match] {
        guard !newClusters.isEmpty, !existing.isEmpty else {
            return [Match](repeating: .new, count: newClusters.count)
        }

        let scores = newClusters.map { cluster in
            existing.map { profileScore(cluster.embedding, profile: $0) }
        }
        let eligible = newClusters.indices.map { row in
            existing.indices.map { column in
                newClusters[row].isReliableForGlobalIdentity && isEligible(
                    scores[row][column],
                    profile: existing[column],
                    alternatives: existing.indices
                        .filter { $0 != column }
                        .map { scores[row][$0].value }
                )
            }
        }

        let realColumnCount = existing.count
        let columnCount = realColumnCount + newClusters.count
        let forbidden = -1_000_000.0
        var weights = Array(
            repeating: Array(repeating: 0.0, count: columnCount),
            count: newClusters.count
        )
        for row in newClusters.indices {
            for column in existing.indices {
                weights[row][column] = eligible[row][column]
                    ? Double(scores[row][column].value - matchThreshold) + 0.000_001
                    : forbidden
            }
        }

        let assignment = Self.maximumWeightAssignment(weights)
        var result = [Match](repeating: .new, count: newClusters.count)
        var clustersByUUID: [String: [Int]] = [:]
        for row in newClusters.indices {
            let column = assignment[row]
            if column >= 0, column < realColumnCount, eligible[row][column] {
                let uuid = existing[column].uuid
                result[row] = .existing(uuid: uuid)
                clustersByUUID[uuid, default: []].append(row)
            }
        }

        // A second local cluster may reuse the winning global UUID. This is intentionally stricter
        // than the first pass because a false merge is much harder to repair than a false split.
        for row in newClusters.indices
        where result[row] == .new && newClusters[row].isReliableForGlobalIdentity {
            let ranked = existing.indices
                .map { ($0, scores[row][$0]) }
                .sorted {
                    if $0.1.value != $1.1.value { return $0.1.value > $1.1.value }
                    return existing[$0.0].uuid < existing[$1.0].uuid
                }
            guard let winner = ranked.first else { continue }
            let profile = existing[winner.0]
            let secondBest = ranked.dropFirst().first?.1.value ?? -1
            let requiredMargin = max(ambiguityMargin, 0.06)
            let stricterThreshold = min(0.98, matchThreshold + 0.04)
            let hasRepeatedEvidence = profile.prototypes.count >= 2
                && winner.1.supportingPrototypeCount >= 2
            let hasExceptionalSingleEvidence = winner.1.bestPrototype >= min(0.98, matchThreshold + 0.12)
            guard winner.1.value >= stricterThreshold,
                  winner.1.value - secondBest >= requiredMargin,
                  hasRepeatedEvidence || hasExceptionalSingleEvidence,
                  let claimed = clustersByUUID[profile.uuid],
                  claimed.allSatisfy({
                      !Self.materiallyOverlap(newClusters[row].spans, newClusters[$0].spans)
                  })
            else { continue }

            result[row] = .existing(uuid: profile.uuid)
            clustersByUUID[profile.uuid, default: []].append(row)
        }
        return result
    }

    private func profileScore(
        _ embedding: [Float],
        profile: SpeakerIdentityProfileEvidence
    ) -> ProfileScore {
        let prototypeSimilarities = profile.prototypes
            .map { Self.cosine(embedding, $0) }
            .sorted(by: >)
        let meanSimilarity = Self.cosine(embedding, profile.meanEmbedding)
        guard !prototypeSimilarities.isEmpty else {
            return ProfileScore(
                value: meanSimilarity,
                bestPrototype: meanSimilarity,
                supportingPrototypeCount: meanSimilarity >= matchThreshold - 0.08 ? 1 : 0
            )
        }

        // Keep the best recording/channel prototype influential, but require the surrounding
        // prototypes to agree. A plain top-three average hid real speakers after a microphone or
        // codec change; a pure nearest-neighbour score was too vulnerable to one lucky hit.
        let robustCount = min(3, prototypeSimilarities.count)
        let robustPrototypeScore = prototypeSimilarities.prefix(robustCount).reduce(0, +)
            / Float(robustCount)
        let consensusScore = (0.70 * prototypeSimilarities[0]) + (0.30 * robustPrototypeScore)
        let supportFloor = max(
            0.30,
            min(matchThreshold - 0.08, prototypeSimilarities[0] - 0.20)
        )
        return ProfileScore(
            value: max(meanSimilarity, consensusScore),
            bestPrototype: prototypeSimilarities[0],
            supportingPrototypeCount: prototypeSimilarities.filter {
                $0 >= supportFloor
            }.count
        )
    }

    private func isEligible(
        _ score: ProfileScore,
        profile: SpeakerIdentityProfileEvidence,
        alternatives: [Float]
    ) -> Bool {
        let bestAlternative = alternatives.max() ?? -1
        guard score.value >= matchThreshold,
              ambiguityMargin <= 0 || score.value - bestAlternative >= ambiguityMargin
        else { return false }

        if profile.prototypes.count >= 2 {
            return score.supportingPrototypeCount >= 2
                || score.value >= min(0.98, matchThreshold + 0.10)
        }
        // The first cross-recording link has only one historical prototype, so demand a little
        // more evidence until the identity has been observed in multiple recordings.
        return score.value >= min(0.98, matchThreshold + 0.03)
    }

    /// More than 200 ms of simultaneous activity is treated as a hard cannot-link constraint.
    /// Tiny edge overlaps are common in diarizer windows and do not represent true crosstalk.
    static func materiallyOverlap(
        _ lhs: [SpeakerIdentityTimeSpan],
        _ rhs: [SpeakerIdentityTimeSpan],
        tolerance: TimeInterval = 0.20
    ) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        for left in lhs {
            for right in rhs {
                if min(left.end, right.end) - max(left.start, right.start) > tolerance {
                    return true
                }
            }
        }
        return false
    }

    private func assignGreedily(
        newClusters: [[Float]],
        existing: [(uuid: String, embedding: [Float])]
    ) -> [Match] {
        var result = [Match](repeating: .new, count: newClusters.count)
        guard !newClusters.isEmpty, !existing.isEmpty else { return result }

        // Every candidate (similarity, clusterIndex, existingIndex) at or above threshold.
        struct Candidate { let sim: Float; let i: Int; let j: Int }
        var candidates: [Candidate] = []
        for i in newClusters.indices {
            for j in existing.indices {
                let sim = Self.cosine(newClusters[i], existing[j].embedding)
                if sim >= matchThreshold {
                    candidates.append(Candidate(sim: sim, i: i, j: j))
                }
            }
        }

        // Greedy: highest similarity first; deterministic tie-break by cluster then existing index.
        candidates.sort {
            if $0.sim != $1.sim { return $0.sim > $1.sim }
            if $0.i != $1.i { return $0.i < $1.i }
            return $0.j < $1.j
        }

        var clusterAssigned = [Bool](repeating: false, count: newClusters.count)
        var existingClaimed = [Bool](repeating: false, count: existing.count)
        for c in candidates {
            guard !clusterAssigned[c.i], !existingClaimed[c.j] else { continue }
            result[c.i] = .existing(uuid: existing[c.j].uuid)
            clusterAssigned[c.i] = true
            existingClaimed[c.j] = true
        }
        return result
    }

    /// Maximum-total-similarity one-to-one assignment. Greedy matching can consume the only good
    /// profile for a later cluster; Hungarian assignment evaluates the whole recording jointly.
    /// An ambiguity margin rejects a cluster when its best and second-best identities are too close.
    private func assignOptimally(
        newClusters: [[Float]],
        existing: [(uuid: String, embedding: [Float])]
    ) -> [Match] {
        guard !newClusters.isEmpty, !existing.isEmpty else {
            return [Match](repeating: .new, count: newClusters.count)
        }

        var similarities = Array(
            repeating: Array(repeating: Float.zero, count: existing.count),
            count: newClusters.count
        )
        var eligible = Array(
            repeating: Array(repeating: false, count: existing.count),
            count: newClusters.count
        )

        for row in newClusters.indices {
            for column in existing.indices {
                similarities[row][column] = Self.cosine(
                    newClusters[row],
                    existing[column].embedding
                )
            }
            for column in existing.indices {
                let bestAlternative = existing.indices
                    .filter { $0 != column }
                    .map { similarities[row][$0] }
                    .max() ?? -1
                eligible[row][column] = similarities[row][column] >= matchThreshold
                    && (ambiguityMargin <= 0
                        || similarities[row][column] - bestAlternative >= ambiguityMargin)
            }
        }

        // Add one zero-valued dummy column per new cluster, allowing any row to remain new.
        let realColumnCount = existing.count
        let columnCount = realColumnCount + newClusters.count
        let forbidden = -1_000_000.0
        var weights = Array(
            repeating: Array(repeating: 0.0, count: columnCount),
            count: newClusters.count
        )
        for row in newClusters.indices {
            for column in existing.indices {
                weights[row][column] = eligible[row][column]
                    ? Double(similarities[row][column] - matchThreshold) + 0.000_001
                    : forbidden
            }
        }

        let assignment = Self.maximumWeightAssignment(weights)
        var result = [Match](repeating: .new, count: newClusters.count)
        for row in newClusters.indices {
            let column = assignment[row]
            if column >= 0, column < realColumnCount, eligible[row][column] {
                result[row] = .existing(uuid: existing[column].uuid)
            }
        }
        return result
    }

    /// Hungarian algorithm for a rectangular matrix with columns >= rows.
    /// Returns the selected column for every row, or -1 only for an empty matrix.
    private static func maximumWeightAssignment(_ weights: [[Double]]) -> [Int] {
        let rowCount = weights.count
        guard rowCount > 0 else { return [] }
        let columnCount = weights[0].count
        precondition(columnCount >= rowCount)

        let maximum = weights.flatMap { $0 }.max() ?? 0
        let costs = weights.map { row in row.map { maximum - $0 } }
        var rowPotential = [Double](repeating: 0, count: rowCount + 1)
        var columnPotential = [Double](repeating: 0, count: columnCount + 1)
        var matchedRow = [Int](repeating: 0, count: columnCount + 1)
        var predecessor = [Int](repeating: 0, count: columnCount + 1)

        for row in 1...rowCount {
            matchedRow[0] = row
            var column0 = 0
            var minimum = [Double](repeating: .infinity, count: columnCount + 1)
            var used = [Bool](repeating: false, count: columnCount + 1)

            repeat {
                used[column0] = true
                let row0 = matchedRow[column0]
                var delta = Double.infinity
                var column1 = 0
                for column in 1...columnCount where !used[column] {
                    let reduced = costs[row0 - 1][column - 1]
                        - rowPotential[row0]
                        - columnPotential[column]
                    if reduced < minimum[column] {
                        minimum[column] = reduced
                        predecessor[column] = column0
                    }
                    if minimum[column] < delta {
                        delta = minimum[column]
                        column1 = column
                    }
                }
                for column in 0...columnCount {
                    if used[column] {
                        rowPotential[matchedRow[column]] += delta
                        columnPotential[column] -= delta
                    } else {
                        minimum[column] -= delta
                    }
                }
                column0 = column1
            } while matchedRow[column0] != 0

            repeat {
                let previous = predecessor[column0]
                matchedRow[column0] = matchedRow[previous]
                column0 = previous
            } while column0 != 0
        }

        var assignment = [Int](repeating: -1, count: rowCount)
        for column in 1...columnCount where matchedRow[column] > 0 {
            assignment[matchedRow[column] - 1] = column - 1
        }
        return assignment
    }

    /// Cosine similarity; returns 0 for a zero-length vector or a dimension mismatch.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for k in a.indices {
            dot += a[k] * b[k]
            na += a[k] * a[k]
            nb += b[k] * b[k]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (sqrt(na) * sqrt(nb))
    }
}
