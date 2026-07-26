import Foundation

struct SpeakerEvaluationVoiceObservation {
    let recordingId: Int64
    let assignmentKey: String
    let globalSpeakerUUID: String?
    let embedding: [Float]
}

struct SpeakerEvaluationActiveLearningSignals: Equatable, Sendable {
    var vectorCount = 0
    var assignedVoiceCount = 0
    var estimatedVoiceGroupCount: Int?
    var possibleMixedIdentityCount = 0
    var strongestSplitGain: Float?
    var nearestDifferentIdentitySimilarity: Float?
    var farthestDifferentIdentitySimilarity: Float?
    var nearestOtherGlobalIdentitySimilarity: Float?
    var crossRecordingOutlierSimilarity: Float?
    var crossRecordingAppearanceCount = 0
    var score = 0.0
    var reasons: [String] = []
}

/// Active-learning analysis over persisted per-utterance voiceprints.
///
/// The goal is not to auto-correct labels. These deliberately conservative signals only decide
/// which conversations a human should inspect first:
/// - two assigned identities whose centroids are nearly identical (possible false split),
/// - one assigned identity whose vectors separate into two coherent groups (possible false merge),
/// - one global identity whose recording-local centroid disagrees with its other calls,
/// - clear, highly separated negative examples that help calibrate decision boundaries.
enum SpeakerEvaluationActiveLearning {
    private struct GroupKey: Hashable {
        let recordingId: Int64
        let assignmentKey: String
    }

    private struct VoiceGroup {
        let recordingId: Int64
        let assignmentKey: String
        let globalSpeakerUUID: String?
        let vectors: [[Float]]
        let centroid: [Float]
        let splitEvidence: SpeakerEmbeddingMixtureEvidence?
    }

    static func analyze(
        observations: [SpeakerEvaluationVoiceObservation],
        likelySameThreshold: Float = 0.82
    ) -> [Int64: SpeakerEvaluationActiveLearningSignals] {
        var grouped: [GroupKey: [SpeakerEvaluationVoiceObservation]] = [:]
        for observation in observations
        where observation.embedding.count == VoiceEmbeddingStore.dimensions {
            grouped[
                GroupKey(
                    recordingId: observation.recordingId,
                    assignmentKey: observation.assignmentKey
                ),
                default: []
            ].append(observation)
        }

        let groups: [VoiceGroup] = grouped.compactMap { key, items in
            let vectors = items.map(\.embedding)
            guard let centroid = VoiceMath.meanNormalized(vectors) else { return nil }
            return VoiceGroup(
                recordingId: key.recordingId,
                assignmentKey: key.assignmentKey,
                globalSpeakerUUID: items.compactMap(\.globalSpeakerUUID).first,
                vectors: vectors,
                centroid: centroid,
                splitEvidence: SpeakerEmbeddingMixtureDetector.detect(
                    vectors: vectors,
                    centroid: centroid
                )
            )
        }

        let groupsByRecording = Dictionary(grouping: groups, by: \.recordingId)
        var result: [Int64: SpeakerEvaluationActiveLearningSignals] = [:]

        for (recordingId, recordingGroups) in groupsByRecording {
            var signals = SpeakerEvaluationActiveLearningSignals()
            signals.vectorCount = recordingGroups.reduce(0) { $0 + $1.vectors.count }
            signals.assignedVoiceCount = recordingGroups.count

            let splitEvidence = recordingGroups.compactMap(\.splitEvidence)
            signals.possibleMixedIdentityCount = splitEvidence.count
            signals.strongestSplitGain = splitEvidence.map(\.gain).max()

            let pairSimilarities = pairwiseSimilarities(recordingGroups.map(\.centroid))
            signals.nearestDifferentIdentitySimilarity = pairSimilarities.max()
            signals.farthestDifferentIdentitySimilarity = pairSimilarities.min()
            signals.estimatedVoiceGroupCount = recordingGroups.isEmpty
                ? nil
                : connectedComponentCount(
                    centroids: recordingGroups.map(\.centroid),
                    threshold: likelySameThreshold
                )
            result[recordingId] = signals
        }

        addCrossRecordingSignals(groups: groups, to: &result)

        for recordingId in result.keys {
            guard var signals = result[recordingId] else { continue }
            finalize(&signals)
            result[recordingId] = signals
        }
        return result
    }

    private static func addCrossRecordingSignals(
        groups: [VoiceGroup],
        to result: inout [Int64: SpeakerEvaluationActiveLearningSignals]
    ) {
        let globalGroups = Dictionary(grouping: groups.compactMap { group in
            group.globalSpeakerUUID.map { ($0, group) }
        }, by: { $0.0 })
        let globalCentroids: [(uuid: String, centroid: [Float])] = globalGroups.compactMap {
            uuid, items in
            VoiceMath.meanNormalized(items.map { $0.1.centroid }).map { (uuid, $0) }
        }

        // Different UUIDs that are almost the same voice are especially valuable possible
        // false-split examples, even when the identities never appear in the same call.
        var nearestOther: [String: (uuid: String, similarity: Float)] = [:]
        for index in globalCentroids.indices {
            for otherIndex in globalCentroids.indices where otherIndex > index {
                let similarity = SpeakerUnifier.cosine(
                    globalCentroids[index].centroid,
                    globalCentroids[otherIndex].centroid
                )
                if similarity > (nearestOther[globalCentroids[index].uuid]?.similarity ?? -1) {
                    nearestOther[globalCentroids[index].uuid] = (
                        globalCentroids[otherIndex].uuid,
                        similarity
                    )
                }
                if similarity > (nearestOther[globalCentroids[otherIndex].uuid]?.similarity ?? -1) {
                    nearestOther[globalCentroids[otherIndex].uuid] = (
                        globalCentroids[index].uuid,
                        similarity
                    )
                }
            }
        }

        for (uuid, items) in globalGroups {
            let recordingGroups = items.map(\.1)
            // One duplicated global identity can occur in dozens of calls. Surface only its two
            // strongest-evidence calls, otherwise the labeling queue becomes twenty copies of the
            // same question instead of a diverse active-learning batch.
            if let similarity = nearestOther[uuid]?.similarity {
                for group in recordingGroups
                    .sorted(by: { $0.vectors.count > $1.vectors.count })
                    .prefix(2) {
                    var signals = result[group.recordingId] ?? SpeakerEvaluationActiveLearningSignals()
                    signals.nearestOtherGlobalIdentitySimilarity = max(
                        signals.nearestOtherGlobalIdentitySimilarity ?? -1,
                        similarity
                    )
                    result[group.recordingId] = signals
                }
            }

            // Compare each recording against a leave-one-recording-out identity centroid. This
            // avoids letting an outlier pull the reference toward itself.
            guard recordingGroups.count >= 3 else { continue }
            for group in recordingGroups {
                let others = recordingGroups
                    .filter { $0.recordingId != group.recordingId }
                    .map(\.centroid)
                guard let otherCentroid = VoiceMath.meanNormalized(others) else { continue }
                let similarity = SpeakerUnifier.cosine(group.centroid, otherCentroid)
                var signals = result[group.recordingId] ?? SpeakerEvaluationActiveLearningSignals()
                if signals.crossRecordingOutlierSimilarity == nil
                    || similarity < signals.crossRecordingOutlierSimilarity! {
                    signals.crossRecordingOutlierSimilarity = similarity
                    signals.crossRecordingAppearanceCount = recordingGroups.count
                }
                result[group.recordingId] = signals
            }
        }
    }

    private static func finalize(_ signals: inout SpeakerEvaluationActiveLearningSignals) {
        var scoredReasons: [(score: Double, reason: String)] = []

        if signals.possibleMixedIdentityCount > 0 {
            let gain = Double(signals.strongestSplitGain ?? 0)
            let score = min(70, 45 + gain * 140)
            signals.score += score
            scoredReasons.append((
                score,
                signals.possibleMixedIdentityCount == 1
                    ? "One speaker label contains two distant voice groups"
                    : "\(signals.possibleMixedIdentityCount) speaker labels contain mixed voice groups"
            ))
        }

        if let estimated = signals.estimatedVoiceGroupCount,
           signals.assignedVoiceCount > estimated {
            let excess = signals.assignedVoiceCount - estimated
            let score = min(55, 24 + Double(excess) * 12)
            signals.score += score
            scoredReasons.append((
                score,
                "\(signals.assignedVoiceCount) labels look like about \(estimated) distinct voice\(estimated == 1 ? "" : "s")"
            ))
        } else if let similarity = signals.nearestDifferentIdentitySimilarity,
                  similarity >= 0.74 {
            let score = 15 + Double(similarity - 0.74) * 100
            signals.score += score
            scoredReasons.append((
                score,
                "Different labels are \(percent(similarity)) voice-similar"
            ))
        }

        if let similarity = signals.nearestOtherGlobalIdentitySimilarity,
           similarity >= 0.78 {
            let score = min(45, 18 + Double(similarity - 0.78) * 120)
            signals.score += score
            scoredReasons.append((
                score,
                "Another global speaker is \(percent(similarity)) voice-similar"
            ))
        }

        if let similarity = signals.crossRecordingOutlierSimilarity,
           signals.crossRecordingAppearanceCount >= 3,
           similarity < 0.68 {
            let score = min(
                55,
                24 + Double(0.68 - similarity) * 100
                    + min(10, Double(signals.crossRecordingAppearanceCount - 3))
            )
            signals.score += score
            scoredReasons.append((
                score,
                "Same identity differs from its other \(signals.crossRecordingAppearanceCount - 1) calls (\(percent(similarity)) match)"
            ))
        }

        // Clear negative examples are useful for calibrating thresholds, but exploitation of
        // probable errors should remain ahead of this exploration bonus.
        if signals.assignedVoiceCount >= 2,
           let farthest = signals.farthestDifferentIdentitySimilarity,
           farthest < 0.20 {
            let score = min(12, 5 + Double(0.20 - farthest) * 20)
            signals.score += score
            scoredReasons.append((
                score,
                "Useful contrast: very different voices (\(percent(farthest)) match)"
            ))
        }

        signals.score = min(180, signals.score)
        signals.reasons = scoredReasons
            .sorted { $0.score > $1.score }
            .prefix(3)
            .map(\.reason)
    }

    private static func pairwiseSimilarities(_ centroids: [[Float]]) -> [Float] {
        guard centroids.count >= 2 else { return [] }
        var similarities: [Float] = []
        for index in centroids.indices {
            for otherIndex in centroids.indices where otherIndex > index {
                similarities.append(
                    SpeakerUnifier.cosine(centroids[index], centroids[otherIndex])
                )
            }
        }
        return similarities
    }

    private static func connectedComponentCount(
        centroids: [[Float]],
        threshold: Float
    ) -> Int {
        guard !centroids.isEmpty else { return 0 }
        var parent = Array(centroids.indices)

        func root(_ value: Int) -> Int {
            var current = value
            while parent[current] != current { current = parent[current] }
            return current
        }
        func merge(_ lhs: Int, _ rhs: Int) {
            let lhsRoot = root(lhs)
            let rhsRoot = root(rhs)
            if lhsRoot != rhsRoot { parent[rhsRoot] = lhsRoot }
        }

        for index in centroids.indices {
            for otherIndex in centroids.indices where otherIndex > index {
                if SpeakerUnifier.cosine(centroids[index], centroids[otherIndex]) >= threshold {
                    merge(index, otherIndex)
                }
            }
        }
        return Set(centroids.indices.map(root)).count
    }

    private static func percent(_ value: Float) -> String {
        "\(Int((max(0, min(1, value)) * 100).rounded()))%"
    }
}
