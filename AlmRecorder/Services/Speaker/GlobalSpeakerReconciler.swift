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

struct GlobalSpeakerCalibrationPairScore: Equatable, Sendable {
    let leftNodeID: String
    let rightNodeID: String
    let samePerson: Bool
    let cosine: Float
    let cohortNormalized: Double
    let probability: Double
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
    let mergeProbability: Double
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
    let localClusterCount: Int
    let acousticEvidenceNodeCount: Int
    let missingAcousticEvidenceCount: Int
    let acousticEvidenceCoverage: Double
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
    let calibratedMergeProbability: Double
    let heldOutPairCount: Int
    let heldOutSamePersonPairCount: Int
    let heldOutDifferentPeoplePairCount: Int
    let heldOutFalseMergePairs: Int
    let heldOutFalseSplitPairs: Int
    let heldOutAccuracy: Double?
    let heldOutPairScores: [GlobalSpeakerCalibrationPairScore]
    let applyBlockers: [String]

    var canApply: Bool { applyBlockers.isEmpty }
}

struct GlobalSpeakerReconciliationApplyResult: Equatable, Sendable {
    let runID: String
    let changedClusterCount: Int
    let createdIdentityCount: Int
    let retiredIdentityCount: Int
}

struct GlobalSpeakerReconciliationUndoResult: Equatable, Sendable {
    let runID: String
    let restoredClusterCount: Int
    let skippedClusterCount: Int
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
        // The product gate promises that three positive and three negative examples are enough
        // to fit a user-specific calibration. Requiring a larger hidden total here made a fully
        // balanced 3 + 3 gold set impossible to apply even though the UI reported it as ready.
        guard rows.count >= 6, positiveCount >= 3, negativeCount >= 3 else {
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

    /// Select a precision-first operating point from development labels only. The held-out set is
    /// never consulted here; it is reserved for the apply gate. A small margin above the hardest
    /// development impostor adapts the decision boundary to this user's microphones without
    /// baking the arbitrary logistic probability scale into production.
    static func recommendedMergeProbability(
        nodes: [GlobalSpeakerBenchmarkNode],
        examples: [GlobalSpeakerCalibrationExample],
        model: GlobalSpeakerCalibrationModel,
        cohortEmbeddings: [[Float]]? = nil
    ) -> Double {
        guard model.isLearned else { return Configuration().mergeProbability }
        let featureSpace = FeatureSpace(
            nodes: nodes,
            cohortEmbeddings: cohortEmbeddings
        )
        let negativeProbabilities = examples.compactMap { example -> Double? in
            guard !example.samePerson,
                  let feature = featureSpace.features(
                    example.leftNodeID,
                    example.rightNodeID
                  )
            else { return nil }
            return model.probability(
                cosine: feature.cosine,
                cohortNormalized: feature.cohort
            )
        }
        guard let hardestImpostor = negativeProbabilities.max() else {
            return Configuration().mergeProbability
        }
        return min(0.985, max(0.60, hardestImpostor + 0.03))
    }

    static func scorePairs(
        nodes: [GlobalSpeakerBenchmarkNode],
        examples: [GlobalSpeakerCalibrationExample],
        model: GlobalSpeakerCalibrationModel,
        cohortEmbeddings: [[Float]]? = nil
    ) -> [GlobalSpeakerCalibrationPairScore] {
        let featureSpace = FeatureSpace(
            nodes: nodes,
            cohortEmbeddings: cohortEmbeddings
        )
        return examples.compactMap { example in
            guard let feature = featureSpace.features(
                example.leftNodeID,
                example.rightNodeID
            ) else { return nil }
            return GlobalSpeakerCalibrationPairScore(
                leftNodeID: example.leftNodeID,
                rightNodeID: example.rightNodeID,
                samePerson: example.samePerson,
                cosine: feature.cosine,
                cohortNormalized: feature.cohort,
                probability: model.probability(
                    cosine: feature.cosine,
                    cohortNormalized: feature.cohort
                )
            )
        }
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
    /// A from-scratch result is only representative when most immutable local voices actually have
    /// acoustic evidence. The remaining tail stays visible for review/backfill instead of being
    /// silently treated as proof that the library has been reconciled.
    static func acousticEvidenceBlocker(
        totalClusterCount: Int,
        acousticEvidenceNodeCount: Int,
        minimumCoverage: Double = 0.90
    ) -> String? {
        guard totalClusterCount > 0 else { return nil }
        let covered = min(totalClusterCount, max(0, acousticEvidenceNodeCount))
        let coverage = Double(covered) / Double(totalClusterCount)
        guard coverage + 0.000_001 < minimumCoverage else { return nil }
        return "Acoustic evidence covers \(covered) of \(totalClusterCount) local voices "
            + "(\(coverage.formatted(.percent.precision(.fractionLength(0))))); "
            + "run the non-destructive voice-evidence backfill before applying."
    }

    private struct CodableSpan: Codable {
        let start: TimeInterval
        let end: TimeInterval
    }

    private struct PlannedChange {
        let clusterID: Int64
        let nodeID: String
        let previousUUID: String
        let targetUUID: String
    }

    private struct WorkingPlan {
        let report: GlobalSpeakerReconciliationShadowReport
        let model: GlobalSpeakerCalibrationModel
        let changes: [PlannedChange]
        let newIdentityEmbeddings: [String: [Float]]
        let affectedExistingUUIDs: Set<String>
    }

    enum ApplyError: LocalizedError {
        case previewChanged
        case safetyGate([String])
        case trustedAssignmentWouldMove(Int64)
        case noPreview

        var errorDescription: String? {
            switch self {
            case .previewChanged:
                return "Speaker evidence changed. Refresh the preview before applying it."
            case .safetyGate(let blockers):
                return blockers.joined(separator: " ")
            case .trustedAssignmentWouldMove(let clusterID):
                return "The plan attempted to move protected cluster \(clusterID). Nothing changed."
            case .noPreview:
                return "There is not enough clean speaker evidence to build a reconciliation plan."
            }
        }
    }

    static func apply(
        expectedReport: GlobalSpeakerReconciliationShadowReport
    ) throws -> GlobalSpeakerReconciliationApplyResult {
        try GRDBDatabaseManager.shared.write { db in
            try apply(db, expectedReport: expectedReport)
        }
    }

    static func apply(
        _ db: Database,
        expectedReport: GlobalSpeakerReconciliationShadowReport
    ) throws -> GlobalSpeakerReconciliationApplyResult {
        try GlobalSpeakerIdentityStore.migrate(db)
        guard let plan = try makeWorkingPlan(db) else { throw ApplyError.noPreview }
        guard plan.report == expectedReport else { throw ApplyError.previewChanged }
        guard plan.report.canApply else {
            throw ApplyError.safetyGate(plan.report.applyBlockers)
        }
        return try apply(plan, db: db)
    }

    /// Reconcile after ingest only when the private development labels have produced a calibrated
    /// model and the independent held-out labels still show zero false merges. This intentionally
    /// returns `nil` for an unsafe or no-op preview instead of falling back to the old merge-only
    /// graph. The whole preview + apply happens in one database write transaction.
    static func applyLatestIfSafe() throws -> GlobalSpeakerReconciliationApplyResult? {
        try GRDBDatabaseManager.shared.write { db in
            try applyLatestIfSafe(db)
        }
    }

    static func applyLatestIfSafe(
        _ db: Database
    ) throws -> GlobalSpeakerReconciliationApplyResult? {
        try GlobalSpeakerIdentityStore.migrate(db)
        guard let plan = try makeWorkingPlan(db),
              plan.report.canApply,
              !plan.changes.isEmpty
        else { return nil }
        return try apply(plan, db: db)
    }

    static func undoLatest() throws -> GlobalSpeakerReconciliationUndoResult? {
        try GRDBDatabaseManager.shared.write { db in
            try undoLatest(db)
        }
    }

    static func undoLatest(
        _ db: Database
    ) throws -> GlobalSpeakerReconciliationUndoResult? {
        guard let run = try Row.fetchOne(
                db,
                sql: """
                    SELECT id
                    FROM speaker_reconciliation_runs
                    WHERE status = 'active'
                    ORDER BY created_at DESC
                    LIMIT 1
                """
            ), let runID: String = run["id"] else { return nil }
            let members = try Row.fetchAll(
                db,
                sql: """
                    SELECT *
                    FROM speaker_reconciliation_members
                    WHERE run_id = ?
                    ORDER BY local_cluster_id
                """,
                arguments: [runID]
            )
            var restored = 0
            var skipped = 0
            var affectedUUIDs: Set<String> = []
            for row in members {
                guard let clusterID: Int64 = row["local_cluster_id"],
                      let previousUUID: String = row["previous_speaker_uuid"],
                      let previousState: String = row["previous_state"],
                      let previousSource: String = row["previous_source"],
                      let previousConfidence: Double = row["previous_confidence"],
                      let targetUUID: String = row["target_speaker_uuid"]
                else { continue }
                let activeRun = try String.fetchOne(
                    db,
                    sql: """
                        SELECT reconciliation_run_id
                        FROM speaker_global_assignments
                        WHERE local_cluster_id = ?
                    """,
                    arguments: [clusterID]
                )
                guard activeRun == runID else {
                    skipped += 1
                    continue
                }
                try db.execute(
                    sql: """
                        UPDATE speaker_global_assignments SET
                            speaker_uuid = ?,
                            state = ?,
                            source = ?,
                            confidence = ?,
                            score = ?,
                            margin = ?,
                            supporting_prototype_count = ?,
                            matcher = ?,
                            evidence_json = ?,
                            operation_id = ?,
                            reconciliation_run_id = NULL,
                            updated_at = ?
                        WHERE local_cluster_id = ?
                    """,
                    arguments: [
                        previousUUID,
                        previousState,
                        previousSource,
                        previousConfidence,
                        row["previous_score"] as Double?,
                        row["previous_margin"] as Double?,
                        row["previous_supporting_prototype_count"] as Int?,
                        row["previous_matcher"] as String?,
                        row["previous_evidence_json"] as String?,
                        row["previous_operation_id"] as Int64?,
                        Date(),
                        clusterID,
                    ]
                )
                try db.execute(
                    sql: """
                        UPDATE utterances SET
                            speaker_uuid = ?,
                            speaker_assignment_source = ?
                        WHERE local_speaker_cluster_id = ?
                    """,
                    arguments: [previousUUID, previousSource, clusterID]
                )
                affectedUUIDs.insert(previousUUID)
                affectedUUIDs.insert(targetUUID)
                restored += 1
            }

            let speakerSnapshots = try Row.fetchAll(
                db,
                sql: """
                    SELECT *
                    FROM speaker_reconciliation_speakers
                    WHERE run_id = ?
                """,
                arguments: [runID]
            )
            for row in speakerSnapshots {
                guard let uuid: String = row["speaker_uuid"] else { continue }
                let wasCreated: Bool = row["was_created"] ?? false
                if wasCreated {
                    // Keep the row for audit/recovery, but remove it from active People.
                    try db.execute(
                        sql: """
                            UPDATE speakers SET
                                identity_state = 'retired',
                                canonical_uuid = NULL,
                                updated_at = ?
                            WHERE uuid = ?
                        """,
                        arguments: [Date(), uuid]
                    )
                } else {
                    try db.execute(
                        sql: """
                            UPDATE speakers SET
                                identity_state = ?,
                                canonical_uuid = ?,
                                updated_at = ?
                            WHERE uuid = ?
                        """,
                        arguments: [
                            row["previous_identity_state"] as String? ?? "active",
                            row["previous_canonical_uuid"] as String?,
                            Date(),
                            uuid,
                        ]
                    )
                }
                affectedUUIDs.insert(uuid)
            }
            for uuid in affectedUUIDs {
                try GlobalSpeakerIdentityStore.refreshProfile(db, uuid: uuid)
                try SpeakerVoicePrototypeStore.rebuild(
                    db,
                    speakerUUID: uuid,
                    policy: .qualityDurationWeighted
                )
            }
            try db.execute(
                sql: """
                    UPDATE speaker_reconciliation_runs
                    SET status = ?, undone_at = ?
                    WHERE id = ?
                """,
                arguments: [
                    skipped == 0 ? "undone" : "undone_partial",
                    Date(),
                    runID,
                ]
            )
        return GlobalSpeakerReconciliationUndoResult(
            runID: runID,
            restoredClusterCount: restored,
            skippedClusterCount: skipped
        )
    }

    static func shadowReport(_ db: Database) throws -> GlobalSpeakerReconciliationShadowReport? {
        guard try db.tableExists("speaker_local_clusters"),
              try db.tableExists("speaker_global_assignments") else { return nil }
        let totalClusterCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM speaker_local_clusters"
        ) ?? 0
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

        let labels = try loadReliablePairLabels(db, nodes: nodes)
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
        let developmentLabels = labels.filter { $0.role == .development }
        let examples = developmentLabels.compactMap {
            label -> GlobalSpeakerCalibrationExample? in
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
        let model = GlobalSpeakerReconciler.fit(nodes: nodes, examples: examples)
        let mergeProbability = GlobalSpeakerReconciler.recommendedMergeProbability(
            nodes: nodes,
            examples: examples,
            model: model
        )
        let result = GlobalSpeakerReconciler.reconcile(
            nodes: nodes,
            model: model,
            constraints: constraints,
            trustedAnchors: trustedAnchors,
            configuration: .init(mergeProbability: mergeProbability)
        )
        let developmentConstraints = constraintsFor(developmentLabels)
        let heldOutLabels = labels.filter {
            $0.role == .heldOut && $0.verdict.isScored
        }
        let heldOutExamples = heldOutLabels.map {
            GlobalSpeakerCalibrationExample(
                leftNodeID: "cluster:\($0.leftClusterId)",
                rightNodeID: "cluster:\($0.rightClusterId)",
                samePerson: $0.verdict == .samePerson
            )
        }
        let heldOutPairScores = GlobalSpeakerReconciler.scorePairs(
            nodes: nodes,
            examples: heldOutExamples,
            model: model
        )
        let safetyResult = GlobalSpeakerReconciler.reconcile(
            nodes: nodes,
            model: model,
            constraints: developmentConstraints,
            trustedAnchors: trustedAnchors,
            configuration: .init(mergeProbability: mergeProbability)
        )
        let heldOutMetrics = pairMetrics(
            labels: heldOutLabels,
            assignments: safetyResult.assignments
        )

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
        var blockers: [String] = []
        if let evidenceBlocker = acousticEvidenceBlocker(
            totalClusterCount: totalClusterCount,
            acousticEvidenceNodeCount: nodes.count
        ) {
            blockers.append(evidenceBlocker)
        }
        if !model.isLearned {
            blockers.append("Need at least 3 Same and 3 Different calibration pairs.")
        }
        if heldOutMetrics.samePersonPairCount < 3 {
            blockers.append("Need 3 held-out Same pairs from separate recordings.")
        }
        if heldOutMetrics.differentPeoplePairCount < 3 {
            blockers.append("Need 3 held-out Different pairs from separate recordings.")
        }
        if heldOutMetrics.falseMergePairs > 0 {
            blockers.append(
                "\(heldOutMetrics.falseMergePairs) held-out false merge"
                    + (heldOutMetrics.falseMergePairs == 1 ? "" : "s")
                    + " must be resolved."
            )
        }
        if heldOutMetrics.samePersonPairCount >= 3 {
            let correctlyLinkedSamePairs = heldOutMetrics.samePersonPairCount
                - heldOutMetrics.falseSplitPairs
            // Global reconciliation must actually reunite locally over-split voices. Zero false
            // merges is not sufficient when the model simply refuses every merge.
            if correctlyLinkedSamePairs * 3 < heldOutMetrics.samePersonPairCount * 2 {
                let recall = Double(correctlyLinkedSamePairs)
                    / Double(heldOutMetrics.samePersonPairCount)
                blockers.append(
                    "Held-out Same recall is "
                        + recall.formatted(.percent.precision(.fractionLength(0)))
                        + "; label more cross-recording Same outliers until it reaches 67%."
                )
            }
        }
        if result.constraintConflictCount > 0 {
            blockers.append("Resolve conflicting manual/gold speaker constraints.")
        }

        return GlobalSpeakerReconciliationShadowReport(
            localClusterCount: totalClusterCount,
            acousticEvidenceNodeCount: nodes.count,
            missingAcousticEvidenceCount: max(0, totalClusterCount - nodes.count),
            acousticEvidenceCoverage: totalClusterCount > 0
                ? Double(nodes.count) / Double(totalClusterCount)
                : 1,
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
            learnedCalibration: model.isLearned,
            calibratedMergeProbability: mergeProbability,
            heldOutPairCount: heldOutMetrics.evaluatedPairCount,
            heldOutSamePersonPairCount: heldOutMetrics.samePersonPairCount,
            heldOutDifferentPeoplePairCount: heldOutMetrics.differentPeoplePairCount,
            heldOutFalseMergePairs: heldOutMetrics.falseMergePairs,
            heldOutFalseSplitPairs: heldOutMetrics.falseSplitPairs,
            heldOutAccuracy: heldOutMetrics.accuracy,
            heldOutPairScores: heldOutPairScores,
            applyBlockers: blockers
        )
    }

    private static func makeWorkingPlan(_ db: Database) throws -> WorkingPlan? {
        guard let report = try shadowReport(db) else { return nil }
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
        var currentStateByNode: [String: GlobalSpeakerAssignmentState] = [:]
        var trustedAnchors: [String: String] = [:]
        for row in rows {
            guard let clusterID: Int64 = row["id"],
                  let recordingID: Int64 = row["recording_id"],
                  let data: Data = row["embedding"] else { continue }
            let embedding = VoiceEmbeddingStore.dataToFloats(data)
            guard embedding.count == SpeakerEmbeddingPolicy.dimension else { continue }
            let nodeID = "cluster:\(clusterID)"
            let turnCount: Int = row["embedding_turn_count"] ?? 0
            let cohesion: Double? = row["cohesion"]
            let splitGain: Double? = row["mixture_split_gain"]
            let reliable = (row["mixed_verdict"] as String?) == nil
                && splitGain == nil
                && !(turnCount > 1 && (cohesion ?? 1) < 0.35)
            nodes.append(
                GlobalSpeakerBenchmarkNode(
                    id: nodeID,
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
                currentIdentityByNode[nodeID] = uuid
                let state = GlobalSpeakerAssignmentState(
                    rawValue: row["state"] ?? ""
                ) ?? .legacy
                currentStateByNode[nodeID] = state
                if state.isTrustedEnrollment {
                    trustedAnchors[nodeID] = uuid
                }
            }
        }
        guard !nodes.isEmpty else { return nil }

        let labels = try loadReliablePairLabels(db, nodes: nodes)
        let developmentLabels = labels.filter { $0.role == .development }
        let examples = developmentLabels.compactMap { label
            -> GlobalSpeakerCalibrationExample? in
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
        let model = GlobalSpeakerReconciler.fit(nodes: nodes, examples: examples)
        let mergeProbability = GlobalSpeakerReconciler.recommendedMergeProbability(
            nodes: nodes,
            examples: examples,
            model: model
        )
        let result = GlobalSpeakerReconciler.reconcile(
            nodes: nodes,
            model: model,
            constraints: constraintsFor(labels),
            trustedAnchors: trustedAnchors,
            configuration: .init(mergeProbability: mergeProbability)
        )
        let reliableNodes = nodes.filter(\.reliableForIdentity)
        let components = Dictionary(grouping: reliableNodes) {
            result.assignments[$0.id] ?? "isolated:\($0.id)"
        }

        struct ExistingIdentity {
            let uuid: String
            let hasName: Bool
            let assignmentCount: Int
        }
        let existingIdentities = Dictionary(
            uniqueKeysWithValues: try Row.fetchAll(
                db,
                sql: """
                    SELECT s.uuid,
                           TRIM(COALESCE(s.name, '')) != '' AS has_name,
                           COUNT(a.local_cluster_id) AS assignment_count
                    FROM speakers s
                    LEFT JOIN speaker_global_assignments a
                      ON a.speaker_uuid = s.uuid
                    GROUP BY s.uuid
                """
            ).compactMap { row -> (String, ExistingIdentity)? in
                guard let uuid: String = row["uuid"] else { return nil }
                return (
                    uuid,
                    ExistingIdentity(
                        uuid: uuid,
                        hasName: (row["has_name"] as Bool?) ?? false,
                        assignmentCount: row["assignment_count"] ?? 0
                    )
                )
            }
        )

        var targetByComponent: [String: String] = [:]
        var usedTargets: Set<String> = []
        for (componentID, members) in components {
            let anchors = Set(members.compactMap { trustedAnchors[$0.id] })
            if anchors.count == 1, let anchor = anchors.first {
                targetByComponent[componentID] = anchor
                usedTargets.insert(anchor)
            }
        }
        let unanchored = components
            .filter { targetByComponent[$0.key] == nil }
            .sorted {
                if $0.value.count != $1.value.count {
                    return $0.value.count > $1.value.count
                }
                return $0.key < $1.key
            }
        var newIdentityEmbeddings: [String: [Float]] = [:]
        for (componentID, members) in unanchored {
            let currentCounts = Dictionary(
                grouping: members.compactMap { currentIdentityByNode[$0.id] },
                by: { $0 }
            ).mapValues(\.count)
            let candidates = currentCounts.keys
                .filter { !usedTargets.contains($0) && existingIdentities[$0] != nil }
                .sorted { lhs, rhs in
                    let left = existingIdentities[lhs]!
                    let right = existingIdentities[rhs]!
                    if left.hasName != right.hasName { return left.hasName }
                    if currentCounts[lhs] != currentCounts[rhs] {
                        return (currentCounts[lhs] ?? 0) > (currentCounts[rhs] ?? 0)
                    }
                    if left.assignmentCount != right.assignmentCount {
                        return left.assignmentCount > right.assignmentCount
                    }
                    return lhs < rhs
                }
            let target: String
            if let existing = candidates.first {
                target = existing
            } else {
                target = UUID().uuidString
                if let embedding = VoiceMath.meanNormalized(members.map(\.embedding)) {
                    newIdentityEmbeddings[target] = embedding
                }
            }
            targetByComponent[componentID] = target
            usedTargets.insert(target)
        }

        var changes: [PlannedChange] = []
        var affectedExistingUUIDs: Set<String> = []
        for (componentID, members) in components {
            guard let target = targetByComponent[componentID] else { continue }
            if existingIdentities[target] != nil {
                affectedExistingUUIDs.insert(target)
            }
            for member in members {
                guard let previous = currentIdentityByNode[member.id],
                      previous != target,
                      let clusterID = Int64(member.id.dropFirst("cluster:".count))
                else { continue }
                if currentStateByNode[member.id]?.isTrustedEnrollment == true {
                    throw ApplyError.trustedAssignmentWouldMove(clusterID)
                }
                affectedExistingUUIDs.insert(previous)
                changes.append(
                    PlannedChange(
                        clusterID: clusterID,
                        nodeID: member.id,
                        previousUUID: previous,
                        targetUUID: target
                    )
                )
            }
        }
        return WorkingPlan(
            report: report,
            model: model,
            changes: changes.sorted { $0.clusterID < $1.clusterID },
            newIdentityEmbeddings: newIdentityEmbeddings,
            affectedExistingUUIDs: affectedExistingUUIDs
        )
    }

    private static func apply(
        _ plan: WorkingPlan,
        db: Database
    ) throws -> GlobalSpeakerReconciliationApplyResult {
        let runID = UUID().uuidString
        let now = Date()
        try db.execute(
            sql: """
                INSERT INTO speaker_reconciliation_runs (
                    id, status, matcher, calibration_pair_count,
                    held_out_pair_count, changed_cluster_count,
                    created_identity_count, created_at
                ) VALUES (?, 'active', ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                runID,
                "calibrated-constrained-v1",
                plan.model.trainingPairCount,
                plan.report.heldOutPairCount,
                plan.changes.count,
                plan.newIdentityEmbeddings.count,
                now,
            ]
        )

        for uuid in plan.affectedExistingUUIDs.sorted() {
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT identity_state, canonical_uuid
                    FROM speakers
                    WHERE uuid = ?
                """,
                arguments: [uuid]
            ) else { continue }
            try db.execute(
                sql: """
                    INSERT INTO speaker_reconciliation_speakers (
                        run_id, speaker_uuid, previous_identity_state,
                        previous_canonical_uuid, was_created
                    ) VALUES (?, ?, ?, ?, 0)
                """,
                arguments: [
                    runID,
                    uuid,
                    row["identity_state"] as String? ?? "active",
                    row["canonical_uuid"] as String?,
                ]
            )
        }
        for (uuid, embedding) in plan.newIdentityEmbeddings.sorted(by: {
            $0.key < $1.key
        }) {
            try db.execute(
                sql: """
                    INSERT INTO speaker_reconciliation_speakers (
                        run_id, speaker_uuid, previous_identity_state,
                        previous_canonical_uuid, was_created
                    ) VALUES (?, ?, NULL, NULL, 1)
                """,
                arguments: [runID, uuid]
            )
            try db.execute(
                sql: """
                    INSERT INTO speakers (
                        uuid, name, embedding, embedding_count,
                        total_duration, utterance_count, confidence, notes,
                        created_at, updated_at, last_seen_at,
                        identity_state, canonical_uuid
                    ) VALUES (?, NULL, ?, 1, 0, 0, 0.70, ?, ?, ?, ?, 'active', NULL)
                """,
                arguments: [
                    uuid,
                    VoiceEmbeddingStore.floatsToData(embedding),
                    "Created by reversible global speaker reconciliation.",
                    now,
                    now,
                    now,
                ]
            )
        }

        let evidence = """
            {"matcher":"calibrated-constrained-v1","calibration_pairs":\(plan.model.trainingPairCount),"held_out_pairs":\(plan.report.heldOutPairCount)}
            """
        for change in plan.changes {
            guard let previous = try Row.fetchOne(
                db,
                sql: """
                    SELECT *
                    FROM speaker_global_assignments
                    WHERE local_cluster_id = ?
                """,
                arguments: [change.clusterID]
            ) else { continue }
            let state = GlobalSpeakerAssignmentState(
                rawValue: (previous["state"] as String?) ?? ""
            ) ?? .legacy
            guard !state.isTrustedEnrollment else {
                throw ApplyError.trustedAssignmentWouldMove(change.clusterID)
            }
            try db.execute(
                sql: """
                    INSERT INTO speaker_reconciliation_members (
                        run_id, local_cluster_id, previous_speaker_uuid,
                        previous_state, previous_source, previous_confidence,
                        previous_score, previous_margin,
                        previous_supporting_prototype_count, previous_matcher,
                        previous_evidence_json, previous_operation_id,
                        target_speaker_uuid
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    runID,
                    change.clusterID,
                    previous["speaker_uuid"] as String? ?? change.previousUUID,
                    previous["state"] as String? ?? GlobalSpeakerAssignmentState.legacy.rawValue,
                    previous["source"] as String? ?? SpeakerAssignmentSource.model.rawValue,
                    previous["confidence"] as Double? ?? 0,
                    previous["score"] as Double?,
                    previous["margin"] as Double?,
                    previous["supporting_prototype_count"] as Int?,
                    previous["matcher"] as String?,
                    previous["evidence_json"] as String?,
                    previous["operation_id"] as Int64?,
                    change.targetUUID,
                ]
            )
            try db.execute(
                sql: """
                    UPDATE speaker_global_assignments SET
                        speaker_uuid = ?,
                        state = ?,
                        source = ?,
                        confidence = 0.90,
                        score = NULL,
                        margin = NULL,
                        supporting_prototype_count = NULL,
                        matcher = ?,
                        evidence_json = ?,
                        operation_id = NULL,
                        reconciliation_run_id = ?,
                        updated_at = ?
                    WHERE local_cluster_id = ?
                """,
                arguments: [
                    change.targetUUID,
                    GlobalSpeakerAssignmentState.automatic.rawValue,
                    SpeakerAssignmentSource.globalAutomatic.rawValue,
                    "calibrated-constrained-v1",
                    evidence,
                    runID,
                    now,
                    change.clusterID,
                ]
            )
            try db.execute(
                sql: """
                    UPDATE utterances SET
                        speaker_uuid = ?,
                        speaker_assignment_source = ?
                    WHERE local_speaker_cluster_id = ?
                """,
                arguments: [
                    change.targetUUID,
                    SpeakerAssignmentSource.globalAutomatic.rawValue,
                    change.clusterID,
                ]
            )
        }

        let allTargets = Set(plan.changes.map(\.targetUUID))
            .union(plan.newIdentityEmbeddings.keys)
        for target in allTargets {
            try db.execute(
                sql: """
                    UPDATE speakers SET
                        identity_state = 'active',
                        canonical_uuid = NULL,
                        updated_at = ?
                    WHERE uuid = ?
                """,
                arguments: [now, target]
            )
        }
        var retiredCount = 0
        for oldUUID in plan.affectedExistingUUIDs.subtracting(allTargets) {
            let remaining = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM speaker_global_assignments
                    WHERE speaker_uuid = ?
                """,
                arguments: [oldUUID]
            ) ?? 0
            guard remaining == 0 else { continue }
            let destinations = Set(
                plan.changes
                    .filter { $0.previousUUID == oldUUID }
                    .map(\.targetUUID)
            )
            try db.execute(
                sql: """
                    UPDATE speakers SET
                        identity_state = ?,
                        canonical_uuid = ?,
                        updated_at = ?
                    WHERE uuid = ?
                """,
                arguments: [
                    destinations.count == 1 ? "alias" : "retired",
                    destinations.count == 1 ? destinations.first : nil,
                    now,
                    oldUUID,
                ]
            )
            retiredCount += 1
        }

        let refreshUUIDs = plan.affectedExistingUUIDs.union(allTargets)
        for uuid in refreshUUIDs {
            try GlobalSpeakerIdentityStore.refreshProfile(db, uuid: uuid)
            try SpeakerVoicePrototypeStore.rebuild(
                db,
                speakerUUID: uuid,
                policy: .qualityDurationWeighted
            )
        }
        return GlobalSpeakerReconciliationApplyResult(
            runID: runID,
            changedClusterCount: plan.changes.count,
            createdIdentityCount: plan.newIdentityEmbeddings.count,
            retiredIdentityCount: retiredCount
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
        let examples = try loadReliablePairLabels(db, nodes: nodes)
            .filter { $0.role == .development }
            .compactMap {
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
        let model = GlobalSpeakerReconciler.fit(nodes: nodes, examples: examples)
        let cohortEmbeddings = nodes.filter(\.reliableForIdentity).map(\.embedding)
        return GlobalSpeakerCalibrationBackend(
            model: model,
            cohortEmbeddings: cohortEmbeddings,
            mergeProbability: GlobalSpeakerReconciler.recommendedMergeProbability(
                nodes: nodes,
                examples: examples,
                model: model
            )
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

    private static func loadReliablePairLabels(
        _ db: Database,
        nodes: [GlobalSpeakerBenchmarkNode]
    ) throws -> [SpeakerPairGoldLabel] {
        let reliableClusterIDs = Set(
            nodes.compactMap { node -> Int64? in
                guard node.reliableForIdentity,
                      node.id.hasPrefix("cluster:") else { return nil }
                return Int64(node.id.dropFirst("cluster:".count))
            }
        )
        return try loadPairLabels(db).filter {
            reliableClusterIDs.contains($0.leftClusterId)
                && reliableClusterIDs.contains($0.rightClusterId)
        }
    }

    private static func constraintsFor(
        _ labels: [SpeakerPairGoldLabel]
    ) -> [GlobalSpeakerReconciliationConstraint] {
        labels.compactMap { label in
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
    }

    private static func pairMetrics(
        labels: [SpeakerPairGoldLabel],
        assignments: [String: String]
    ) -> SpeakerPairGoldMetrics {
        var same = 0
        var different = 0
        var correct = 0
        var falseMerges = 0
        var falseSplits = 0
        for label in labels {
            guard let left = assignments["cluster:\(label.leftClusterId)"],
                  let right = assignments["cluster:\(label.rightClusterId)"]
            else { continue }
            let predictedSame = left == right
            switch label.verdict {
            case .samePerson:
                same += 1
                if predictedSame { correct += 1 } else { falseSplits += 1 }
            case .differentPeople:
                different += 1
                if predictedSame { falseMerges += 1 } else { correct += 1 }
            case .mixedOrUnclear, .unsure:
                break
            }
        }
        let total = same + different
        return SpeakerPairGoldMetrics(
            evaluatedPairCount: total,
            samePersonPairCount: same,
            differentPeoplePairCount: different,
            correctPairCount: correct,
            accuracy: total > 0 ? Double(correct) / Double(total) : nil,
            falseMergePairs: falseMerges,
            falseSplitPairs: falseSplits
        )
    }

    private static func decodeSpans(_ value: String?) -> [SpeakerIdentityTimeSpan] {
        guard let value,
              let data = value.data(using: .utf8),
              let spans = try? JSONDecoder().decode([CodableSpan].self, from: data)
        else { return [] }
        return spans.map { SpeakerIdentityTimeSpan(start: $0.start, end: $0.end) }
    }
}
