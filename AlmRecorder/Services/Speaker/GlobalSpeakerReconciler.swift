import Foundation
import GRDB
import Accelerate

/// A direct human constraint over two immutable recording-local speaker clusters.
///
/// These constraints belong to the reconciliation layer, not the People projection. A must-link
/// says that two clean local clusters are one human. A cannot-link says that they must never share
/// a global identity, regardless of acoustic similarity or transitive graph evidence.
struct GlobalSpeakerReconciliationConstraint: Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case mustLink
        case cannotLink
    }

    let leftNodeID: String
    let rightNodeID: String
    let kind: Kind

    init(_ lhs: String, _ rhs: String, kind: Kind) {
        if lhs <= rhs {
            leftNodeID = lhs
            rightNodeID = rhs
        } else {
            leftNodeID = rhs
            rightNodeID = lhs
        }
        self.kind = kind
    }
}

struct GlobalSpeakerCalibrationExample: Equatable, Sendable {
    let leftNodeID: String
    let rightNodeID: String
    let samePerson: Bool
}

/// Small regularized logistic backend fitted to the user's direct Same/Different labels.
///
/// The embedding extractor remains WeSpeaker. Calibration learns how its cosine distribution moves
/// on this user's microphones and rooms. The second feature is a symmetric cohort-normalized score:
/// each endpoint is normalized against the other voices in the current corpus, which is the local,
/// deterministic equivalent of score normalization used by speaker-verification backends.
struct GlobalSpeakerCalibrationModel: Codable, Equatable, Sendable {
    let bias: Double
    let cosineWeight: Double
    let cohortWeight: Double
    let cosineMean: Double
    let cosineScale: Double
    let cohortMean: Double
    let cohortScale: Double
    let trainingPairCount: Int
    let samePersonPairCount: Int
    let differentPeoplePairCount: Int
    let isLearned: Bool

    func probability(cosine: Float, cohortNormalized: Double) -> Double {
        let xCosine = (Double(cosine) - cosineMean) / max(0.0001, cosineScale)
        let xCohort = (cohortNormalized - cohortMean) / max(0.0001, cohortScale)
        let logit = max(
            -30,
            min(30, bias + cosineWeight * xCosine + cohortWeight * xCohort)
        )
        return 1 / (1 + exp(-logit))
    }

    static let conservativeFallback = GlobalSpeakerCalibrationModel(
        bias: -0.4,
        cosineWeight: 1.35,
        cohortWeight: 0.15,
        cosineMean: 0.55,
        cosineScale: 0.10,
        cohortMean: 0,
        cohortScale: 1,
        trainingPairCount: 0,
        samePersonPairCount: 0,
        differentPeoplePairCount: 0,
        isLearned: false
    )
}

/// A calibrated scorer plus the fixed nuisance cohort used to make score normalization comparable
/// between the production library and a small held-out benchmark.
struct GlobalSpeakerCalibrationBackend: Sendable {
    let model: GlobalSpeakerCalibrationModel
    let cohortEmbeddings: [[Float]]
}

struct GlobalSpeakerReconciliationMerge: Equatable, Sendable {
    let leftNodeIDs: [String]
    let rightNodeIDs: [String]
    let probability: Double
    let supportingEdgeCount: Int
}

struct GlobalSpeakerReconciliationResult: Equatable, Sendable {
    let assignments: [String: String]
    let merges: [GlobalSpeakerReconciliationMerge]
    let constraintConflictCount: Int
    let excludedNodeCount: Int
}

struct GlobalSpeakerReconciliationShadowReport: Equatable, Sendable {
    let evaluatedNodeCount: Int
    let excludedNodeCount: Int
    let existingIdentityCount: Int
    let proposedIdentityCount: Int
    let proposedSplitIdentityCount: Int
    let proposedMergeComponentCount: Int
    let automaticAcousticMergeCount: Int
    let constraintConflictCount: Int
    let trainingPairCount: Int
    let samePersonPairCount: Int
    let differentPeoplePairCount: Int
    let learnedCalibration: Bool
}

/// Precision-first, from-scratch global reconciliation.
///
/// Existing *automatic* People assignments are deliberately not initial components. Only explicit
/// manual/gold anchors and human pair constraints are hard truth, so a contaminated automatic
/// identity can split in the shadow result. The algorithm never mutates People.
enum GlobalSpeakerReconciler {
    struct Configuration: Equatable, Sendable {
        var mergeProbability: Double = 0.88
        var supportSlack: Double = 0.16
        var exceptionalSingleEdgeProbability: Double = 0.985
        var mutualNearestMargin: Double = 0.035
        var repeatedCooccurrenceProbability: Double = 0.96
    }

    private struct FeatureSpace {
        let nodesByID: [String: GlobalSpeakerBenchmarkNode]
        let nodeIndexByID: [String: Int]
        let similarities: [Float]
        let nodeCount: Int
        let cohortStats: [String: (mean: Double, deviation: Double)]

        init(
            nodes: [GlobalSpeakerBenchmarkNode],
            cohortEmbeddings: [[Float]]? = nil
        ) {
            nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
            nodeIndexByID = Dictionary(
                uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) }
            )
            nodeCount = nodes.count

            let dimension = nodes.first(where: { !$0.embedding.isEmpty })?.embedding.count ?? 0
            var normalized = [Float](repeating: 0, count: nodes.count * dimension)
            if dimension > 0 {
                for (row, node) in nodes.enumerated()
                where node.embedding.count == dimension {
                    var squaredNorm: Float = 0
                    vDSP_svesq(node.embedding, 1, &squaredNorm, vDSP_Length(dimension))
                    guard squaredNorm > 0 else { continue }
                    var scale = 1 / sqrt(squaredNorm)
                    node.embedding.withUnsafeBufferPointer { source in
                        normalized.withUnsafeMutableBufferPointer { destination in
                            vDSP_vsmul(
                                source.baseAddress!,
                                1,
                                &scale,
                                destination.baseAddress! + row * dimension,
                                1,
                                vDSP_Length(dimension)
                            )
                        }
                    }
                }
            }

            // One BLAS matrix multiplication replaces millions of independent Swift cosine loops.
            // At the current library size this is a small (~19 MB) dense matrix and keeps the
            // read-only shadow evaluation interactive. It also gives fit and reconcile identical
            // floating-point features.
            var similarityMatrix = [Float](repeating: 0, count: nodes.count * nodes.count)
            if !nodes.isEmpty, dimension > 0 {
                var transposed = [Float](repeating: 0, count: normalized.count)
                for row in nodes.indices {
                    for column in 0..<dimension {
                        transposed[column * nodes.count + row] =
                            normalized[row * dimension + column]
                    }
                }
                vDSP_mmul(
                    normalized,
                    1,
                    transposed,
                    1,
                    &similarityMatrix,
                    1,
                    vDSP_Length(nodes.count),
                    vDSP_Length(nodes.count),
                    vDSP_Length(dimension)
                )
            }
            similarities = similarityMatrix

            let externalCohort = cohortEmbeddings?.filter {
                $0.count == dimension && !$0.isEmpty
            } ?? []
            var externalScores: [Float]?
            if !externalCohort.isEmpty, !nodes.isEmpty, dimension > 0 {
                var normalizedCohort = [Float](
                    repeating: 0,
                    count: externalCohort.count * dimension
                )
                for (row, embedding) in externalCohort.enumerated() {
                    var squaredNorm: Float = 0
                    vDSP_svesq(embedding, 1, &squaredNorm, vDSP_Length(dimension))
                    guard squaredNorm > 0 else { continue }
                    var scale = 1 / sqrt(squaredNorm)
                    embedding.withUnsafeBufferPointer { source in
                        normalizedCohort.withUnsafeMutableBufferPointer { destination in
                            vDSP_vsmul(
                                source.baseAddress!,
                                1,
                                &scale,
                                destination.baseAddress! + row * dimension,
                                1,
                                vDSP_Length(dimension)
                            )
                        }
                    }
                }
                var transposedCohort = [Float](
                    repeating: 0,
                    count: normalizedCohort.count
                )
                for row in externalCohort.indices {
                    for column in 0..<dimension {
                        transposedCohort[column * externalCohort.count + row] =
                            normalizedCohort[row * dimension + column]
                    }
                }
                var crossScores = [Float](
                    repeating: 0,
                    count: nodes.count * externalCohort.count
                )
                vDSP_mmul(
                    normalized,
                    1,
                    transposedCohort,
                    1,
                    &crossScores,
                    1,
                    vDSP_Length(nodes.count),
                    vDSP_Length(externalCohort.count),
                    vDSP_Length(dimension)
                )
                externalScores = crossScores
            }

            var stats: [String: (mean: Double, deviation: Double)] = [:]
            for (nodeIndex, node) in nodes.enumerated() where node.reliableForIdentity {
                func moments(
                    lowerBound: Double? = nil,
                    upperBound: Double? = nil
                ) -> (count: Int, mean: Double, deviation: Double) {
                    var count = 0
                    var mean = 0.0
                    var sumOfSquares = 0.0
                    if let externalScores {
                        for cohortIndex in externalCohort.indices {
                            let score = Double(
                                externalScores[
                                    nodeIndex * externalCohort.count + cohortIndex
                                ]
                            )
                            // An exact match is normally the node itself when a held-out call was
                            // already indexed. It is not an impostor-cohort observation.
                            if score > 0.9995 { continue }
                            if let lowerBound, score < lowerBound { continue }
                            if let upperBound, score > upperBound { continue }
                            count += 1
                            let delta = score - mean
                            mean += delta / Double(count)
                            sumOfSquares += delta * (score - mean)
                        }
                    } else {
                        for (otherIndex, other) in nodes.enumerated() {
                            guard otherIndex != nodeIndex,
                                  other.reliableForIdentity,
                                  other.recordingId != node.recordingId,
                                  node.embedding.count == other.embedding.count,
                                  !node.embedding.isEmpty
                            else { continue }
                            let score = Double(
                                similarityMatrix[nodeIndex * nodes.count + otherIndex]
                            )
                            if let lowerBound, score < lowerBound { continue }
                            if let upperBound, score > upperBound { continue }
                            count += 1
                            let delta = score - mean
                            mean += delta / Double(count)
                            sumOfSquares += delta * (score - mean)
                        }
                    }
                    guard count > 1 else { return (count, mean, 1) }
                    return (
                        count,
                        mean,
                        max(0.025, sqrt(sumOfSquares / Double(count - 1)))
                    )
                }
                let initial = moments()
                guard initial.count > 0 else {
                    stats[node.id] = (0, 1)
                    continue
                }
                // A second sigma-clipped pass removes same-speaker neighbors and extreme channel
                // outliers from the nuisance cohort without sorting every corpus row.
                let clipped = moments(
                    lowerBound: initial.mean - 2 * initial.deviation,
                    upperBound: initial.mean + 2 * initial.deviation
                )
                stats[node.id] = clipped.count >= 3
                    ? (clipped.mean, clipped.deviation)
                    : (initial.mean, initial.deviation)
            }
            cohortStats = stats
        }

        func features(_ lhs: String, _ rhs: String) -> (cosine: Float, cohort: Double)? {
            guard let left = nodesByID[lhs],
                  let right = nodesByID[rhs],
                  let leftIndex = nodeIndexByID[lhs],
                  let rightIndex = nodeIndexByID[rhs],
                  left.embedding.count == right.embedding.count,
                  !left.embedding.isEmpty
            else { return nil }
            let cosine = similarities[leftIndex * nodeCount + rightIndex]
            let leftStats = cohortStats[lhs] ?? (0, 1)
            let rightStats = cohortStats[rhs] ?? (0, 1)
            let leftZ = (Double(cosine) - leftStats.mean) / leftStats.deviation
            let rightZ = (Double(cosine) - rightStats.mean) / rightStats.deviation
            return (cosine, max(-6, min(6, (leftZ + rightZ) / 2)))
        }
    }

    private struct PairKey: Hashable {
        let left: String
        let right: String

        init(_ lhs: String, _ rhs: String) {
            if lhs <= rhs {
                left = lhs
                right = rhs
            } else {
                left = rhs
                right = lhs
            }
        }
    }

    private struct ScoredEdge {
        let left: String
        let right: String
        let probability: Double
    }

    private struct NeighborRanking {
        var bestID: String?
        var bestProbability = -Double.infinity
        var runnerUpProbability = -Double.infinity

        mutating func consider(_ id: String, probability: Double) {
            if probability > bestProbability
                || (probability == bestProbability && id < (bestID ?? id)) {
                if bestID != id {
                    runnerUpProbability = max(runnerUpProbability, bestProbability)
                }
                bestID = id
                bestProbability = probability
            } else if bestID != id, probability > runnerUpProbability {
                runnerUpProbability = probability
            }
        }

        func hasMargin(_ required: Double) -> Bool {
            runnerUpProbability == -.infinity
                || bestProbability - runnerUpProbability >= required
        }
    }

    private struct UnionFind {
        var parent: [String: String]
        var components: [String: [String]]

        init(_ ids: [String]) {
            parent = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) })
            components = Dictionary(uniqueKeysWithValues: ids.map { ($0, [$0]) })
        }

        mutating func find(_ id: String) -> String {
            guard let value = parent[id] else {
                parent[id] = id
                return id
            }
            if value == id { return id }
            let root = find(value)
            parent[id] = root
            return root
        }

        mutating func union(_ lhs: String, _ rhs: String) {
            let left = find(lhs)
            let right = find(rhs)
            guard left != right else { return }
            let winner = min(left, right)
            let loser = max(left, right)
            parent[loser] = winner
            components[winner, default: []].append(contentsOf: components[loser] ?? [])
            components.removeValue(forKey: loser)
        }

        mutating func component(containing id: String) -> [String] {
            components[find(id)] ?? [id]
        }

        mutating func members() -> [String: [String]] {
            components
        }
    }

    static func fit(
        nodes: [GlobalSpeakerBenchmarkNode],
        examples: [GlobalSpeakerCalibrationExample]
    ) -> GlobalSpeakerCalibrationModel {
        let featureSpace = FeatureSpace(nodes: nodes)
        return fit(featureSpace: featureSpace, examples: examples)
    }

    private static func fit(
        featureSpace: FeatureSpace,
        examples: [GlobalSpeakerCalibrationExample]
    ) -> GlobalSpeakerCalibrationModel {
        let rows = examples.compactMap { example
            -> (cosine: Double, cohort: Double, target: Double)? in
            guard let feature = featureSpace.features(
                example.leftNodeID,
                example.rightNodeID
            ) else { return nil }
            return (
                Double(feature.cosine),
                feature.cohort,
                example.samePerson ? 1 : 0
            )
        }
        let positiveCount = rows.filter { $0.target == 1 }.count
        let negativeCount = rows.count - positiveCount
        guard rows.count >= 8, positiveCount >= 3, negativeCount >= 3 else {
            var fallback = GlobalSpeakerCalibrationModel.conservativeFallback
            fallback = GlobalSpeakerCalibrationModel(
                bias: fallback.bias,
                cosineWeight: fallback.cosineWeight,
                cohortWeight: fallback.cohortWeight,
                cosineMean: fallback.cosineMean,
                cosineScale: fallback.cosineScale,
                cohortMean: fallback.cohortMean,
                cohortScale: fallback.cohortScale,
                trainingPairCount: rows.count,
                samePersonPairCount: positiveCount,
                differentPeoplePairCount: negativeCount,
                isLearned: false
            )
            return fallback
        }

        let cosineMean = rows.map(\.cosine).reduce(0, +) / Double(rows.count)
        let cohortMean = rows.map(\.cohort).reduce(0, +) / Double(rows.count)
        let cosineScale = standardDeviation(rows.map(\.cosine), mean: cosineMean)
        let cohortScale = standardDeviation(rows.map(\.cohort), mean: cohortMean)
        let positiveWeight = Double(rows.count) / Double(2 * positiveCount)
        let negativeWeight = Double(rows.count) / Double(2 * negativeCount)

        var bias = log(Double(positiveCount) / Double(negativeCount))
        var cosineWeight = 0.0
        var cohortWeight = 0.0
        let regularization = 0.35
        for iteration in 0..<700 {
            var biasGradient = 0.0
            var cosineGradient = 0.0
            var cohortGradient = 0.0
            for row in rows {
                let xCosine = (row.cosine - cosineMean) / cosineScale
                let xCohort = (row.cohort - cohortMean) / cohortScale
                let logit = max(
                    -30,
                    min(30, bias + cosineWeight * xCosine + cohortWeight * xCohort)
                )
                let probability = 1 / (1 + exp(-logit))
                let classWeight = row.target == 1 ? positiveWeight : negativeWeight
                let residual = (probability - row.target) * classWeight
                biasGradient += residual
                cosineGradient += residual * xCosine
                cohortGradient += residual * xCohort
            }
            let count = Double(rows.count)
            cosineGradient = cosineGradient / count + regularization * cosineWeight
            cohortGradient = cohortGradient / count + regularization * cohortWeight
            biasGradient /= count
            let learningRate = 0.10 / sqrt(1 + Double(iteration) / 80)
            bias -= learningRate * biasGradient
            cosineWeight -= learningRate * cosineGradient
            cohortWeight -= learningRate * cohortGradient
        }

        return GlobalSpeakerCalibrationModel(
            bias: bias,
            cosineWeight: cosineWeight,
            cohortWeight: cohortWeight,
            cosineMean: cosineMean,
            cosineScale: cosineScale,
            cohortMean: cohortMean,
            cohortScale: cohortScale,
            trainingPairCount: rows.count,
            samePersonPairCount: positiveCount,
            differentPeoplePairCount: negativeCount,
            isLearned: true
        )
    }

    static func reconcile(
        nodes: [GlobalSpeakerBenchmarkNode],
        model: GlobalSpeakerCalibrationModel,
        cohortEmbeddings: [[Float]]? = nil,
        constraints: [GlobalSpeakerReconciliationConstraint] = [],
        trustedAnchors: [String: String] = [:],
        configuration: Configuration = Configuration()
    ) -> GlobalSpeakerReconciliationResult {
        reconcile(
            nodes: nodes,
            featureSpace: FeatureSpace(
                nodes: nodes,
                cohortEmbeddings: cohortEmbeddings
            ),
            model: model,
            constraints: constraints,
            trustedAnchors: trustedAnchors,
            configuration: configuration
        )
    }

    static func fitAndReconcile(
        nodes: [GlobalSpeakerBenchmarkNode],
        examples: [GlobalSpeakerCalibrationExample],
        constraints: [GlobalSpeakerReconciliationConstraint] = [],
        trustedAnchors: [String: String] = [:],
        configuration: Configuration = Configuration()
    ) -> (
        model: GlobalSpeakerCalibrationModel,
        result: GlobalSpeakerReconciliationResult
    ) {
        let featureSpace = FeatureSpace(nodes: nodes)
        let model = fit(featureSpace: featureSpace, examples: examples)
        let result = reconcile(
            nodes: nodes,
            featureSpace: featureSpace,
            model: model,
            constraints: constraints,
            trustedAnchors: trustedAnchors,
            configuration: configuration
        )
        return (model, result)
    }

    private static func reconcile(
        nodes: [GlobalSpeakerBenchmarkNode],
        featureSpace: FeatureSpace,
        model: GlobalSpeakerCalibrationModel,
        constraints: [GlobalSpeakerReconciliationConstraint],
        trustedAnchors: [String: String],
        configuration: Configuration
    ) -> GlobalSpeakerReconciliationResult {
        let nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let reliableIDs = Set(nodes.filter(\.reliableForIdentity).map(\.id))
        let excludedCount = nodes.count - reliableIDs.count
        var unionFind = UnionFind(nodes.map(\.id))
        let cannotPairs = Set(
            constraints
                .filter { $0.kind == .cannotLink }
                .map { PairKey($0.leftNodeID, $0.rightNodeID) }
        )
        var conflictCount = 0

        func componentsConflict(_ lhs: [String], _ rhs: [String]) -> Bool {
            let leftAnchors = Set(lhs.compactMap { trustedAnchors[$0] })
            let rightAnchors = Set(rhs.compactMap { trustedAnchors[$0] })
            if !leftAnchors.isEmpty, !rightAnchors.isEmpty, leftAnchors != rightAnchors {
                return true
            }
            for left in lhs {
                for right in rhs {
                    if cannotPairs.contains(PairKey(left, right)) { return true }
                    guard let leftNode = nodesByID[left],
                          let rightNode = nodesByID[right] else { continue }
                    if leftNode.recordingId == rightNode.recordingId,
                       SpeakerUnifier.materiallyOverlap(leftNode.spans, rightNode.spans) {
                        return true
                    }
                }
            }
            return false
        }

        // Manual and whole-conversation-gold assignments are the only persisted identities that
        // remain initial must-link components. Automatic/legacy assignments are intentionally not
        // consulted here, allowing shadow reconciliation to split a contaminated People record.
        for ids in Dictionary(
            grouping: trustedAnchors.keys.filter { reliableIDs.contains($0) },
            by: { trustedAnchors[$0] ?? "" }
        ).values {
            guard let first = ids.sorted().first else { continue }
            for other in ids.sorted().dropFirst() {
                unionFind.union(first, other)
            }
        }

        for constraint in constraints
        where constraint.kind == .mustLink
            && reliableIDs.contains(constraint.leftNodeID)
            && reliableIDs.contains(constraint.rightNodeID) {
            let leftRoot = unionFind.find(constraint.leftNodeID)
            let rightRoot = unionFind.find(constraint.rightNodeID)
            guard leftRoot != rightRoot else { continue }
            let left = unionFind.component(containing: leftRoot)
            let right = unionFind.component(containing: rightRoot)
            guard !componentsConflict(left, right) else {
                conflictCount += 1
                continue
            }
            unionFind.union(leftRoot, rightRoot)
        }

        var pairProbabilities: [PairKey: Double] = [:]
        var neighborRankings: [String: NeighborRanking] = [:]
        var edges: [ScoredEdge] = []
        let reliableNodes = nodes.filter(\.reliableForIdentity)
        for leftIndex in reliableNodes.indices {
            guard leftIndex + 1 < reliableNodes.count else { continue }
            for rightIndex in (leftIndex + 1)..<reliableNodes.count {
                let left = reliableNodes[leftIndex]
                let right = reliableNodes[rightIndex]
                guard left.recordingId != right.recordingId,
                      let feature = featureSpace.features(left.id, right.id) else { continue }
                let probability = model.probability(
                    cosine: feature.cosine,
                    cohortNormalized: feature.cohort
                )
                neighborRankings[left.id, default: NeighborRanking()].consider(
                    right.id,
                    probability: probability
                )
                neighborRankings[right.id, default: NeighborRanking()].consider(
                    left.id,
                    probability: probability
                )
                if probability >= configuration.mergeProbability - configuration.supportSlack {
                    pairProbabilities[PairKey(left.id, right.id)] = probability
                    edges.append(
                        ScoredEdge(
                            left: left.id,
                            right: right.id,
                            probability: probability
                        )
                    )
                }
            }
        }
        edges.sort {
            if $0.probability != $1.probability { return $0.probability > $1.probability }
            if $0.left != $1.left { return $0.left < $1.left }
            return $0.right < $1.right
        }

        var merges: [GlobalSpeakerReconciliationMerge] = []
        for edge in edges {
            let leftRoot = unionFind.find(edge.left)
            let rightRoot = unionFind.find(edge.right)
            guard leftRoot != rightRoot else { continue }
            let left = unionFind.component(containing: leftRoot)
            let right = unionFind.component(containing: rightRoot)
            guard !componentsConflict(left, right) else { continue }

            let scores = left.flatMap { leftID in
                right.compactMap { rightID in
                    pairProbabilities[PairKey(leftID, rightID)]
                }
            }
            .sorted(by: >)
            guard let best = scores.first,
                  best >= configuration.mergeProbability else { continue }
            let supportFloor = configuration.mergeProbability - configuration.supportSlack
            let support = scores.filter { $0 >= supportFloor }.count
            if scores.count == 1 {
                let leftID = left[0]
                let rightID = right[0]
                let requiredMargin = best >= configuration.exceptionalSingleEdgeProbability
                    ? min(0.01, configuration.mutualNearestMargin)
                    : configuration.mutualNearestMargin
                guard best >= configuration.mergeProbability,
                      neighborRankings[leftID]?.bestID == rightID,
                      neighborRankings[rightID]?.bestID == leftID,
                      neighborRankings[leftID]?.hasMargin(requiredMargin) == true,
                      neighborRankings[rightID]?.hasMargin(requiredMargin) == true
                else { continue }
            } else {
                guard support >= 2 else { continue }
                let smaller = left.count <= right.count ? left : right
                let larger = left.count <= right.count ? right : left
                guard smaller.allSatisfy({ member in
                    larger.contains {
                        (pairProbabilities[PairKey(member, $0)] ?? 0) >= supportFloor
                    }
                }) else { continue }
            }

            let sharedRecordingCount = Set(left.compactMap { nodesByID[$0]?.recordingId })
                .intersection(Set(right.compactMap { nodesByID[$0]?.recordingId }))
                .count
            if sharedRecordingCount >= 2,
               best < configuration.repeatedCooccurrenceProbability {
                continue
            }

            merges.append(
                GlobalSpeakerReconciliationMerge(
                    leftNodeIDs: left.sorted(),
                    rightNodeIDs: right.sorted(),
                    probability: best,
                    supportingEdgeCount: support
                )
            )
            unionFind.union(leftRoot, rightRoot)
        }

        let finalGroups = unionFind.members()
        var assignments: [String: String] = [:]
        for members in finalGroups.values {
            let anchors = Set(members.compactMap { trustedAnchors[$0] })
            let identity: String
            if anchors.count == 1, let anchor = anchors.first {
                identity = "anchor:\(anchor)"
            } else {
                identity = "reconciled:\(members.sorted().first ?? UUID().uuidString)"
            }
            for member in members {
                assignments[member] = identity
            }
        }
        return GlobalSpeakerReconciliationResult(
            assignments: assignments,
            merges: merges,
            constraintConflictCount: conflictCount,
            excludedNodeCount: excludedCount
        )
    }

    private static func standardDeviation(_ values: [Double], mean: Double) -> Double {
        guard values.count > 1 else { return 1 }
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) }
            / Double(values.count - 1)
        return max(0.0001, sqrt(variance))
    }
}

/// Loads the complete local-cluster graph and produces a no-write reconciliation preview.
enum GlobalSpeakerLibraryReconciliation {
    private struct CodableSpan: Codable {
        let start: TimeInterval
        let end: TimeInterval
    }

    static func shadowReport(_ db: Database) throws -> GlobalSpeakerReconciliationShadowReport? {
        guard try db.tableExists("speaker_local_clusters"),
              try db.tableExists("speaker_global_assignments") else { return nil }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT c.id,
                       c.recording_id,
                       c.embedding,
                       c.embedding_turn_count,
                       c.cohesion,
                       c.mixture_split_gain,
                       c.spans_json,
                       a.speaker_uuid,
                       a.state,
                       mixed.verdict AS mixed_verdict
                FROM speaker_local_clusters c
                LEFT JOIN speaker_global_assignments a ON a.local_cluster_id = c.id
                LEFT JOIN speaker_local_cluster_gold_labels mixed
                  ON mixed.local_cluster_id = c.id
                 AND mixed.verdict = 'multiple_speakers'
                WHERE c.embedding IS NOT NULL
                ORDER BY c.id
            """
        )
        var nodes: [GlobalSpeakerBenchmarkNode] = []
        var currentIdentityByNode: [String: String] = [:]
        var trustedAnchors: [String: String] = [:]
        for row in rows {
            guard let clusterID: Int64 = row["id"],
                  let recordingID: Int64 = row["recording_id"],
                  let data: Data = row["embedding"] else { continue }
            let embedding = VoiceEmbeddingStore.dataToFloats(data)
            guard embedding.count == SpeakerEmbeddingPolicy.dimension else { continue }
            let id = "cluster:\(clusterID)"
            let turnCount: Int = row["embedding_turn_count"] ?? 0
            let cohesion: Double? = row["cohesion"]
            let splitGain: Double? = row["mixture_split_gain"]
            let mixedVerdict: String? = row["mixed_verdict"]
            let reliable = mixedVerdict == nil
                && splitGain == nil
                && !(turnCount > 1 && (cohesion ?? 1) < 0.35)
            nodes.append(
                GlobalSpeakerBenchmarkNode(
                    id: id,
                    recordingKey: "recording:\(recordingID)",
                    recordingId: recordingID,
                    embedding: embedding,
                    spans: decodeSpans(row["spans_json"]),
                    reliableForIdentity: reliable,
                    goldSpeakerKey: nil,
                    goldPurity: 0
                )
            )
            if let uuid: String = row["speaker_uuid"] {
                currentIdentityByNode[id] = uuid
                let stateRaw: String = row["state"] ?? GlobalSpeakerAssignmentState.legacy.rawValue
                let state = GlobalSpeakerAssignmentState(rawValue: stateRaw) ?? .legacy
                if state.isTrustedEnrollment {
                    trustedAnchors[id] = uuid
                }
            }
        }
        guard !nodes.isEmpty else { return nil }

        let labels = try loadPairLabels(db)
        let constraints = labels.compactMap { label
            -> GlobalSpeakerReconciliationConstraint? in
            let left = "cluster:\(label.leftClusterId)"
            let right = "cluster:\(label.rightClusterId)"
            switch label.verdict {
            case .samePerson:
                return .init(left, right, kind: .mustLink)
            case .differentPeople:
                return .init(left, right, kind: .cannotLink)
            case .mixedOrUnclear, .unsure:
                return nil
            }
        }
        let examples = labels.compactMap { label -> GlobalSpeakerCalibrationExample? in
            switch label.verdict {
            case .samePerson:
                return .init(
                    leftNodeID: "cluster:\(label.leftClusterId)",
                    rightNodeID: "cluster:\(label.rightClusterId)",
                    samePerson: true
                )
            case .differentPeople:
                return .init(
                    leftNodeID: "cluster:\(label.leftClusterId)",
                    rightNodeID: "cluster:\(label.rightClusterId)",
                    samePerson: false
                )
            case .mixedOrUnclear, .unsure:
                return nil
            }
        }
        let shadow = GlobalSpeakerReconciler.fitAndReconcile(
            nodes: nodes,
            examples: examples,
            constraints: constraints,
            trustedAnchors: trustedAnchors
        )
        let model = shadow.model
        let result = shadow.result

        let reliableNodeIDs = Set(nodes.filter(\.reliableForIdentity).map(\.id))
        let currentIdentities = Set(
            currentIdentityByNode.compactMap {
                reliableNodeIDs.contains($0.key) ? $0.value : nil
            }
        )
        let proposedIdentities = Set(
            result.assignments.compactMap {
                reliableNodeIDs.contains($0.key) ? $0.value : nil
            }
        )
        let proposedByCurrent = Dictionary(grouping: currentIdentityByNode.keys) {
            currentIdentityByNode[$0] ?? "isolated:\($0)"
        }
        let splitCount = proposedByCurrent.values.filter { nodeIDs in
            Set(nodeIDs.compactMap { result.assignments[$0] }).count > 1
        }.count
        let proposedComponents = Dictionary(grouping: reliableNodeIDs) {
            result.assignments[$0] ?? "isolated:\($0)"
        }
        let mergeCount = proposedComponents.values.filter { nodeIDs in
            Set(nodeIDs.compactMap { currentIdentityByNode[$0] }).count > 1
        }.count

        return GlobalSpeakerReconciliationShadowReport(
            evaluatedNodeCount: reliableNodeIDs.count,
            excludedNodeCount: result.excludedNodeCount,
            existingIdentityCount: currentIdentities.count,
            proposedIdentityCount: proposedIdentities.count,
            proposedSplitIdentityCount: splitCount,
            proposedMergeComponentCount: mergeCount,
            automaticAcousticMergeCount: result.merges.count,
            constraintConflictCount: result.constraintConflictCount,
            trainingPairCount: model.trainingPairCount,
            samePersonPairCount: model.samePersonPairCount,
            differentPeoplePairCount: model.differentPeoplePairCount,
            learnedCalibration: model.isLearned
        )
    }

    static func calibrationBackend(_ db: Database) throws -> GlobalSpeakerCalibrationBackend? {
        guard try db.tableExists("speaker_local_clusters") else { return nil }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT c.id,
                       c.recording_id,
                       c.embedding,
                       c.embedding_turn_count,
                       c.cohesion,
                       c.mixture_split_gain,
                       c.spans_json,
                       mixed.verdict AS mixed_verdict
                FROM speaker_local_clusters c
                LEFT JOIN speaker_local_cluster_gold_labels mixed
                  ON mixed.local_cluster_id = c.id
                 AND mixed.verdict = 'multiple_speakers'
                WHERE c.embedding IS NOT NULL
                ORDER BY c.id
            """
        )
        let nodes = rows.compactMap { row -> GlobalSpeakerBenchmarkNode? in
            guard let clusterID: Int64 = row["id"],
                  let recordingID: Int64 = row["recording_id"],
                  let data: Data = row["embedding"] else { return nil }
            let embedding = VoiceEmbeddingStore.dataToFloats(data)
            guard embedding.count == SpeakerEmbeddingPolicy.dimension else { return nil }
            let turnCount: Int = row["embedding_turn_count"] ?? 0
            let cohesion: Double? = row["cohesion"]
            let splitGain: Double? = row["mixture_split_gain"]
            let mixedVerdict: String? = row["mixed_verdict"]
            return GlobalSpeakerBenchmarkNode(
                id: "cluster:\(clusterID)",
                recordingKey: "recording:\(recordingID)",
                recordingId: recordingID,
                embedding: embedding,
                spans: decodeSpans(row["spans_json"]),
                reliableForIdentity: mixedVerdict == nil
                    && splitGain == nil
                    && !(turnCount > 1 && (cohesion ?? 1) < 0.35),
                goldSpeakerKey: nil,
                goldPurity: 0
            )
        }
        let examples = try loadPairLabels(db).compactMap {
            switch $0.verdict {
            case .samePerson:
                return GlobalSpeakerCalibrationExample(
                    leftNodeID: "cluster:\($0.leftClusterId)",
                    rightNodeID: "cluster:\($0.rightClusterId)",
                    samePerson: true
                )
            case .differentPeople:
                return GlobalSpeakerCalibrationExample(
                    leftNodeID: "cluster:\($0.leftClusterId)",
                    rightNodeID: "cluster:\($0.rightClusterId)",
                    samePerson: false
                )
            case .mixedOrUnclear, .unsure:
                return nil
            }
        }
        guard !examples.isEmpty else { return nil }
        return GlobalSpeakerCalibrationBackend(
            model: GlobalSpeakerReconciler.fit(nodes: nodes, examples: examples),
            cohortEmbeddings: nodes.filter(\.reliableForIdentity).map(\.embedding)
        )
    }

    static func calibrationModel(_ db: Database) throws -> GlobalSpeakerCalibrationModel? {
        try calibrationBackend(db)?.model
    }

    private static func loadPairLabels(_ db: Database) throws -> [SpeakerPairGoldLabel] {
        guard try db.tableExists("speaker_pair_gold_labels") else { return [] }
        return try Row.fetchAll(
            db,
            sql: """
                SELECT left_local_cluster_id, right_local_cluster_id, verdict, updated_at
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
                updatedAt: row["updated_at"] ?? .distantPast
            )
        }
    }

    private static func decodeSpans(_ value: String?) -> [SpeakerIdentityTimeSpan] {
        guard let value,
              let data = value.data(using: .utf8),
              let spans = try? JSONDecoder().decode([CodableSpan].self, from: data)
        else { return [] }
        return spans.map { SpeakerIdentityTimeSpan(start: $0.start, end: $0.end) }
    }
}
