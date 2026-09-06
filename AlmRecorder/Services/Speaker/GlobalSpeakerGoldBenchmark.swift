import Foundation

/// One recording-local voice cluster used to evaluate cross-recording identity independently from
/// transcript segmentation. `goldSpeakerKey` is supplied only by the benchmark and is never read by
/// the clustering algorithms.
struct GlobalSpeakerBenchmarkNode: Equatable, Sendable {
    let id: String
    let recordingKey: String
    let recordingId: Int64
    let embedding: [Float]
    let spans: [SpeakerIdentityTimeSpan]
    let reliableForIdentity: Bool
    let goldSpeakerKey: String?
    let goldPurity: Double
    /// Production batch consolidation starts with each existing global profile as a must-link
    /// component. Benchmarks leave this nil so every local cluster is resolved from scratch.
    var initialIdentityKey: String? = nil
}

struct GlobalSpeakerClusteringMetrics: Codable, Equatable, Sendable {
    let evaluatedNodeCount: Int
    let excludedNodeCount: Int
    let recordingCount: Int
    let referenceIdentityCount: Int
    let predictedIdentityCount: Int
    let identityCountAbsoluteError: Int
    let pairPrecision: Double?
    let pairRecall: Double?
    let pairF1: Double?
    let falseMergePairs: Int
    let falseSplitPairs: Int
    let bCubedPrecision: Double?
    let bCubedRecall: Double?
    let bCubedF1: Double?
}

struct GlobalSpeakerIdentityCandidateReport: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let method: String
    let threshold: Float?
    let metrics: GlobalSpeakerClusteringMetrics
    let endToEndPairPrecision: Double?
    let endToEndPairRecall: Double?
    let endToEndPairF1: Double?
    let endToEndFalseMergePairs: Int
    let endToEndFalseSplitPairs: Int
    /// Exact recording-local-cluster assignments for this candidate. They are stored only in the
    /// developer's private benchmark artifact so the comparison UI can explain every method.
    /// Older artifacts decode with no assignments and simply ask for a fresh benchmark run.
    var assignments: [String: String]? = nil
}

/// The development-gold gate is intentionally asymmetric: global recall may improve only without
/// adding a single false-merge pair. Passing it makes a method eligible for held-out validation; it
/// does not by itself promote a method or turn development gold into a test set.
enum GlobalSpeakerGoldRegressionGate {
    static func passes(
        candidate: GlobalSpeakerClusteringMetrics,
        baseline: GlobalSpeakerClusteringMetrics
    ) -> Bool {
        guard candidate.evaluatedNodeCount == baseline.evaluatedNodeCount,
              candidate.referenceIdentityCount == baseline.referenceIdentityCount,
              candidate.recordingCount == baseline.recordingCount,
              candidate.falseMergePairs <= baseline.falseMergePairs,
              (candidate.pairF1 ?? 0) > (baseline.pairF1 ?? 0),
              (candidate.bCubedF1 ?? 0) >= (baseline.bCubedF1 ?? 0),
              candidate.identityCountAbsoluteError <= baseline.identityCountAbsoluteError
        else { return false }
        return true
    }
}

enum GlobalSpeakerGoldScorer {
    /// A mixed or unreliable local cluster is a diarization error, not useful evidence about the
    /// global linker. Keep it in end-to-end WDER, but exclude it from this isolated global score.
    static let minimumGoldPurity = 0.70

    static func evaluate(
        nodes: [GlobalSpeakerBenchmarkNode],
        assignments: [String: String]
    ) -> GlobalSpeakerClusteringMetrics {
        let usable = nodes.filter {
            $0.reliableForIdentity
                && $0.goldPurity >= minimumGoldPurity
                && $0.goldSpeakerKey != nil
                && assignments[$0.id] != nil
        }
        let excluded = nodes.count - usable.count
        let referenceIdentities = Set(usable.compactMap(\.goldSpeakerKey))
        let predictedIdentities = Set(usable.compactMap { assignments[$0.id] })

        var truePositive = 0
        var falseMerge = 0
        var falseSplit = 0
        for left in usable.indices {
            guard left + 1 < usable.count else { continue }
            for right in (left + 1)..<usable.count
            where usable[left].recordingKey != usable[right].recordingKey {
                let referenceSame = usable[left].goldSpeakerKey == usable[right].goldSpeakerKey
                let predictedSame = assignments[usable[left].id] == assignments[usable[right].id]
                if referenceSame && predictedSame { truePositive += 1 }
                if !referenceSame && predictedSame { falseMerge += 1 }
                if referenceSame && !predictedSame { falseSplit += 1 }
            }
        }

        let pairPrecision = truePositive + falseMerge > 0
            ? Double(truePositive) / Double(truePositive + falseMerge)
            : nil
        let pairRecall = truePositive + falseSplit > 0
            ? Double(truePositive) / Double(truePositive + falseSplit)
            : nil
        let pairF1 = harmonicMean(pairPrecision, pairRecall)

        var bPrecisionTotal = 0.0
        var bRecallTotal = 0.0
        for node in usable {
            guard let reference = node.goldSpeakerKey,
                  let predicted = assignments[node.id] else { continue }
            let referenceCluster = usable.filter { $0.goldSpeakerKey == reference }
            let predictedCluster = usable.filter { assignments[$0.id] == predicted }
            let intersection = referenceCluster.filter { assignments[$0.id] == predicted }.count
            bPrecisionTotal += Double(intersection) / Double(max(1, predictedCluster.count))
            bRecallTotal += Double(intersection) / Double(max(1, referenceCluster.count))
        }
        let bPrecision = usable.isEmpty ? nil : bPrecisionTotal / Double(usable.count)
        let bRecall = usable.isEmpty ? nil : bRecallTotal / Double(usable.count)

        return GlobalSpeakerClusteringMetrics(
            evaluatedNodeCount: usable.count,
            excludedNodeCount: excluded,
            recordingCount: Set(usable.map(\.recordingKey)).count,
            referenceIdentityCount: referenceIdentities.count,
            predictedIdentityCount: predictedIdentities.count,
            identityCountAbsoluteError: abs(referenceIdentities.count - predictedIdentities.count),
            pairPrecision: pairPrecision,
            pairRecall: pairRecall,
            pairF1: pairF1,
            falseMergePairs: falseMerge,
            falseSplitPairs: falseSplit,
            bCubedPrecision: bPrecision,
            bCubedRecall: bRecall,
            bCubedF1: harmonicMean(bPrecision, bRecall)
        )
    }

    private static func harmonicMean(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let lhs, let rhs, lhs + rhs > 0 else { return nil }
        return 2 * lhs * rhs / (lhs + rhs)
    }
}

/// Deterministic constrained evidence-graph clustering over recording-local voice prototypes.
///
/// The graph deliberately does not connect two nodes merely because they occurred in one recording:
/// their common channel makes that evidence non-independent. A merge instead needs either an
/// exceptional cross-recording edge or multiple supporting cross-recording edges. Repeated
/// co-occurrence in two recordings is treated as strong negative evidence unless the acoustic
/// evidence is exceptional. This preserves within-call over-segmentation while blocking the common
/// "two people alternate in every call, therefore a transitive chain merges them" failure.
enum GlobalSpeakerEvidenceGraph {
    enum Linkage: String, Codable, Equatable, Sendable {
        case single
        case complete
        case constrainedEvidence
    }

    struct Configuration: Codable, Equatable, Sendable {
        let linkage: Linkage
        let threshold: Float
        let supportSlack: Float
        let exceptionalMargin: Float
        let repeatedCooccurrenceMargin: Float

        init(
            linkage: Linkage,
            threshold: Float,
            supportSlack: Float = 0.15,
            exceptionalMargin: Float = 0.12,
            repeatedCooccurrenceMargin: Float = 0.20
        ) {
            self.linkage = linkage
            self.threshold = threshold
            self.supportSlack = supportSlack
            self.exceptionalMargin = exceptionalMargin
            self.repeatedCooccurrenceMargin = repeatedCooccurrenceMargin
        }
    }

    struct Merge: Equatable, Sendable {
        let leftNodeIDs: [String]
        let rightNodeIDs: [String]
        let score: Float
        let bestScore: Float
        let secondBestScore: Float?
        let supportingEdgeCount: Int
    }

    struct Result: Equatable, Sendable {
        let assignments: [String: String]
        let merges: [Merge]
    }

    private struct Component {
        var nodes: [GlobalSpeakerBenchmarkNode]

        var stableID: String {
            nodes.map(\.id).sorted().first ?? ""
        }
    }

    private struct Candidate {
        let left: Int
        let right: Int
        let score: Float
        let best: Float
        let second: Float?
        let support: Int
    }

    static func cluster(
        _ nodes: [GlobalSpeakerBenchmarkNode],
        configuration: Configuration
    ) -> Result {
        var grouped: [String: [GlobalSpeakerBenchmarkNode]] = [:]
        for node in nodes {
            grouped[node.initialIdentityKey ?? node.id, default: []].append(node)
        }
        var components = grouped.values
            .map { Component(nodes: $0.sorted { $0.id < $1.id }) }
            .sorted { $0.stableID < $1.stableID }
        var merges: [Merge] = []

        while components.count > 1 {
            var candidates: [Candidate] = []
            for left in components.indices {
                guard left + 1 < components.count else { continue }
                for right in (left + 1)..<components.count {
                    if let evidence = mergeEvidence(
                        components[left],
                        components[right],
                        configuration: configuration
                    ) {
                        candidates.append(
                            Candidate(
                                left: left,
                                right: right,
                                score: evidence.score,
                                best: evidence.best,
                                second: evidence.second,
                                support: evidence.support
                            )
                        )
                    }
                }
            }
            guard let winner = candidates.sorted(by: candidateOrder).first else { break }
            let left = components[winner.left]
            let right = components[winner.right]
            merges.append(
                Merge(
                    leftNodeIDs: left.nodes.map(\.id).sorted(),
                    rightNodeIDs: right.nodes.map(\.id).sorted(),
                    score: winner.score,
                    bestScore: winner.best,
                    secondBestScore: winner.second,
                    supportingEdgeCount: winner.support
                )
            )
            var combined = Component(nodes: left.nodes + right.nodes)
            combined.nodes.sort { $0.id < $1.id }
            components.remove(at: winner.right)
            components.remove(at: winner.left)
            components.append(combined)
            components.sort { $0.stableID < $1.stableID }
        }

        var assignments: [String: String] = [:]
        for component in components {
            let identity = "graph:\(component.stableID)"
            for node in component.nodes {
                assignments[node.id] = identity
            }
        }
        return Result(assignments: assignments, merges: merges)
    }

    private static func mergeEvidence(
        _ lhs: Component,
        _ rhs: Component,
        configuration: Configuration
    ) -> (score: Float, best: Float, second: Float?, support: Int)? {
        guard lhs.nodes.allSatisfy(\.reliableForIdentity),
              rhs.nodes.allSatisfy(\.reliableForIdentity),
              !hasTemporalConflict(lhs, rhs) else { return nil }

        let scores = lhs.nodes.flatMap { left in
            rhs.nodes.compactMap { right -> Float? in
                guard left.recordingId != right.recordingId,
                      left.embedding.count == right.embedding.count,
                      !left.embedding.isEmpty else { return nil }
                return SpeakerUnifier.cosine(left.embedding, right.embedding)
            }
        }
        .sorted(by: >)
        guard let best = scores.first else { return nil }

        switch configuration.linkage {
        case .single:
            guard best >= configuration.threshold else { return nil }
            return (best, best, scores.dropFirst().first, 1)
        case .complete:
            guard scores.allSatisfy({ $0 >= configuration.threshold }) else { return nil }
            return (
                scores.reduce(0, +) / Float(scores.count),
                best,
                scores.dropFirst().first,
                scores.count
            )
        case .constrainedEvidence:
            break
        }

        let supportFloor = configuration.threshold - configuration.supportSlack
        let support = scores.filter { $0 >= supportFloor }.count
        let second = scores.dropFirst().first
        let topCount = min(3, scores.count)
        let robustTop = scores.prefix(topCount).reduce(0, +) / Float(topCount)
        let score = (0.70 * best) + (0.30 * robustTop)

        guard best >= configuration.threshold else { return nil }
        if scores.count == 1 {
            guard best >= configuration.threshold + configuration.exceptionalMargin else {
                return nil
            }
        } else {
            guard support >= 2 else { return nil }
            let smaller = lhs.nodes.count <= rhs.nodes.count ? lhs : rhs
            let larger = lhs.nodes.count <= rhs.nodes.count ? rhs : lhs
            guard smaller.nodes.allSatisfy({ node in
                larger.nodes.contains { other in
                    node.recordingId != other.recordingId
                        && SpeakerUnifier.cosine(node.embedding, other.embedding) >= supportFloor
                }
            }) else { return nil }
        }

        let sharedRecordings = Set(lhs.nodes.map(\.recordingId))
            .intersection(Set(rhs.nodes.map(\.recordingId)))
        if sharedRecordings.count >= 2 {
            guard best >= configuration.threshold + configuration.repeatedCooccurrenceMargin,
                  let second,
                  second >= configuration.threshold
                    + max(0.08, configuration.repeatedCooccurrenceMargin / 2)
            else { return nil }
        }
        return (score, best, second, support)
    }

    private static func hasTemporalConflict(_ lhs: Component, _ rhs: Component) -> Bool {
        for left in lhs.nodes {
            for right in rhs.nodes
            where left.recordingId == right.recordingId
                && SpeakerUnifier.materiallyOverlap(left.spans, right.spans) {
                return true
            }
        }
        return false
    }

    private static func candidateOrder(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.best != rhs.best { return lhs.best > rhs.best }
        if lhs.support != rhs.support { return lhs.support > rhs.support }
        if lhs.left != rhs.left { return lhs.left < rhs.left }
        return lhs.right < rhs.right
    }
}
