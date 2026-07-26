import Foundation

struct SpeakerEvaluationSegment: Codable, Equatable {
    let recordingKey: String
    let speakerKey: String?
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String?
    var timingIsGold: Bool = false

    var duration: TimeInterval { max(0, endTime - startTime) }
    var wordCount: Int {
        text?.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count ?? 0
    }
}

struct SpeakerPipelineMetrics: Codable, Equatable {
    let recordingCount: Int
    let referenceSpeakerCount: Int
    let predictedSpeakerCount: Int
    let speakerCountMeanAbsoluteError: Double
    let evaluatedReferenceSeconds: TimeInterval
    let evaluatedWords: Int

    /// Strict temporal DER is nil unless every evaluated reference segment has hand-verified timing.
    let diarizationErrorRate: Double?
    let missedSpeechRate: Double?
    let falseAlarmRate: Double?
    let speakerConfusionRate: Double?

    /// Word-weighted speaker attribution error over the reference utterance spans.
    let wordDiarizationErrorRate: Double?

    /// Cross-recording, label-invariant same-person pair metrics.
    let identityPairPrecision: Double?
    let identityPairRecall: Double?
    let identityPairF1: Double?
    let falseMergePairs: Int
    let falseSplitPairs: Int

    /// Transcript-row diagnostics. These are separate from DER/WDER because a correctly identified
    /// person may be represented by several short rows without becoming several global identities.
    var transcriptSegmentCount: Int? = nil
    var transcriptFragmentationRatio: Double? = nil
    var meanTranscriptSegmentDuration: TimeInterval? = nil
    var p95TranscriptSegmentDuration: TimeInterval? = nil
    /// Fraction of predicted transcript rows that overlap reference speech from more than one
    /// speaker. Lower is safer. It becomes more meaningful as gold timing coverage improves.
    var mixedSpeakerTranscriptSegmentRate: Double? = nil
}

struct SpeakerPipelineBenchmarkReport: Codable, Equatable {
    let runName: String
    let profile: SpeakerPipelineProfile
    let configuration: SpeakerPipelineConfiguration
    let metrics: SpeakerPipelineMetrics
    let requestedRecordingCount: Int
    let processedRecordingCount: Int
    let skippedRecordingCount: Int
    let wallClockSeconds: TimeInterval
    let audioSeconds: TimeInterval
    let realTimeFactor: Double?
    let diarizationStageSeconds: SpeakerDiarizationStageTimings?
    let generatedAt: Date
    var identityDecisions: [SpeakerIdentityBenchmarkDecision]? = nil
    /// Gold-only cross-recording clustering scores at the recording-local-cluster level. Unlike the
    /// legacy utterance-pair metric, these do not let a long call dominate quadratically.
    var globalIdentityCandidates: [GlobalSpeakerIdentityCandidateReport]? = nil
    /// Cheap post-alignment ablations over the exact same diarization run. This lets users compare
    /// transcript row policies without rerunning the acoustic models or changing People data.
    var transcriptSegmentationCandidates: [SpeakerTranscriptSegmentationCandidateReport]? = nil
}

struct SpeakerTranscriptSegmentationCandidateReport: Codable, Equatable, Identifiable {
    let mode: SpeakerUtteranceSegmentation
    let metrics: SpeakerPipelineMetrics

    var id: String { mode.rawValue }
}

/// Audit trail for every local-to-global decision in a benchmark run. This is deliberately saved
/// only in the local JSON report: it makes threshold failures diagnosable without cluttering the
/// headline metrics table.
struct SpeakerIdentityBenchmarkDecision: Codable, Equatable {
    let recordingKey: String
    let recordingTitle: String
    let localLabel: String
    let referenceSpeakerKey: String?
    let referenceOverlapSeconds: TimeInterval
    let assignedPredictedUUID: String
    let reusedExistingIdentity: Bool
    let winnerUUID: String?
    let winnerScore: Float?
    let runnerUpScore: Float?
    let bestPrototypeScore: Float?
    let supportingPrototypeCount: Int?
    let priorReferenceSpeakers: [String]
    let clusterCohesion: Float
    let clusterConfidence: Float
    let clusterEmbeddingTurnCount: Int
    let clusterDurationSeconds: TimeInterval
    let eligibleForGlobalIdentity: Bool
    let mixtureSplitGain: Float?
    let mixtureCentroidSimilarity: Float?
}

/// Label-invariant metrics shared by unit tests, live benchmarks, and exported test sets.
enum SpeakerPipelineEvaluator {
    static func evaluate(
        reference: [SpeakerEvaluationSegment],
        predicted: [SpeakerEvaluationSegment],
        speakerAttributedPredicted: [SpeakerEvaluationSegment]? = nil,
        identityPredicted: [SpeakerEvaluationSegment]? = nil
    ) -> SpeakerPipelineMetrics {
        // Keep temporal diarization and transcript attribution separate. DER and speaker count use
        // the raw diarizer timeline; WDER and cross-record identity use the post-alignment output.
        // Callers that only have one representation retain the original behavior.
        let attributedPrediction = speakerAttributedPredicted ?? predicted
        let identityPrediction = identityPredicted ?? attributedPrediction
        let recordingKeys = Set(reference.map(\.recordingKey))
        var speakerCountError: Double = 0
        var referenceSpeakerCount = 0
        var predictedSpeakerCount = 0
        var totalSeconds: TimeInterval = 0
        var totalWords = 0
        var wordErrors = 0

        var missSeconds: TimeInterval = 0
        var falseAlarmSeconds: TimeInterval = 0
        var confusionSeconds: TimeInterval = 0
        let canScoreDER = !reference.isEmpty && reference.allSatisfy(\.timingIsGold)

        for recordingKey in recordingKeys.sorted() {
            let ref = reference.filter { $0.recordingKey == recordingKey && $0.speakerKey != nil }
            let pred = predicted.filter { $0.recordingKey == recordingKey && $0.speakerKey != nil }
            let attributedPred = attributedPrediction.filter {
                $0.recordingKey == recordingKey && $0.speakerKey != nil
            }
            let refSpeakers = Set(ref.compactMap(\.speakerKey))
            let predSpeakers = Set(pred.compactMap(\.speakerKey))
            referenceSpeakerCount += refSpeakers.count
            predictedSpeakerCount += predSpeakers.count
            speakerCountError += Double(abs(refSpeakers.count - predSpeakers.count))
            totalSeconds += ref.reduce(0) { $0 + $1.duration }
            totalWords += ref.reduce(0) { $0 + $1.wordCount }

            let wordMapping = optimalSpeakerMapping(
                reference: ref,
                predicted: attributedPred,
                weight: { referenceSegment, predictedSegment, overlap in
                    guard referenceSegment.duration > 0 else { return 0 }
                    return Double(referenceSegment.wordCount) * overlap / referenceSegment.duration
                }
            )
            for referenceSegment in ref {
                guard referenceSegment.wordCount > 0 else { continue }
                let winner = predictedWinner(for: referenceSegment, predicted: attributedPred)
                if winner.flatMap({ wordMapping[$0] }) != referenceSegment.speakerKey {
                    wordErrors += referenceSegment.wordCount
                }
            }

            if canScoreDER {
                let timeMapping = optimalSpeakerMapping(
                    reference: ref,
                    predicted: pred,
                    weight: { _, _, overlap in overlap }
                )
                let components = temporalErrorComponents(
                    reference: ref,
                    predicted: pred,
                    mapping: timeMapping
                )
                missSeconds += components.miss
                falseAlarmSeconds += components.falseAlarm
                confusionSeconds += components.confusion
            }
        }

        let identity = identityPairMetrics(reference: reference, predicted: identityPrediction)
        let denominator = max(totalSeconds, 0.000_001)
        let der = canScoreDER
            ? (missSeconds + falseAlarmSeconds + confusionSeconds) / denominator
            : nil
        let wder = totalWords > 0 ? Double(wordErrors) / Double(totalWords) : nil
        let precision = identity.truePositive + identity.falseMerge > 0
            ? Double(identity.truePositive) / Double(identity.truePositive + identity.falseMerge)
            : nil
        let recall = identity.truePositive + identity.falseSplit > 0
            ? Double(identity.truePositive) / Double(identity.truePositive + identity.falseSplit)
            : nil
        let f1: Double?
        if let precision, let recall, precision + recall > 0 {
            f1 = 2 * precision * recall / (precision + recall)
        } else {
            f1 = nil
        }

        let transcriptSegments = attributedPrediction.filter {
            $0.speakerKey != nil && $0.duration > 0
        }
        let transcriptDurations = transcriptSegments.map(\.duration).sorted()
        let p95Index = transcriptDurations.isEmpty
            ? nil
            : max(0, Int(ceil(Double(transcriptDurations.count) * 0.95)) - 1)
        var mixedTranscriptSegments = 0
        var scorableTranscriptSegments = 0
        for predictedSegment in transcriptSegments {
            let overlappingReferenceSpeakers = Set(reference.compactMap { referenceSegment -> String? in
                guard referenceSegment.recordingKey == predictedSegment.recordingKey,
                      max(
                          0,
                          min(referenceSegment.endTime, predictedSegment.endTime)
                              - max(referenceSegment.startTime, predictedSegment.startTime)
                      ) > 0.05 else {
                    return nil
                }
                return referenceSegment.speakerKey
            })
            guard !overlappingReferenceSpeakers.isEmpty else { continue }
            scorableTranscriptSegments += 1
            if overlappingReferenceSpeakers.count > 1 {
                mixedTranscriptSegments += 1
            }
        }

        var metrics = SpeakerPipelineMetrics(
            recordingCount: recordingKeys.count,
            referenceSpeakerCount: referenceSpeakerCount,
            predictedSpeakerCount: predictedSpeakerCount,
            speakerCountMeanAbsoluteError: recordingKeys.isEmpty
                ? 0
                : speakerCountError / Double(recordingKeys.count),
            evaluatedReferenceSeconds: totalSeconds,
            evaluatedWords: totalWords,
            diarizationErrorRate: der,
            missedSpeechRate: canScoreDER ? missSeconds / denominator : nil,
            falseAlarmRate: canScoreDER ? falseAlarmSeconds / denominator : nil,
            speakerConfusionRate: canScoreDER ? confusionSeconds / denominator : nil,
            wordDiarizationErrorRate: wder,
            identityPairPrecision: precision,
            identityPairRecall: recall,
            identityPairF1: f1,
            falseMergePairs: identity.falseMerge,
            falseSplitPairs: identity.falseSplit
        )
        metrics.transcriptSegmentCount = transcriptSegments.count
        metrics.transcriptFragmentationRatio = reference.isEmpty
            ? nil
            : Double(transcriptSegments.count) / Double(reference.count)
        metrics.meanTranscriptSegmentDuration = transcriptDurations.isEmpty
            ? nil
            : transcriptDurations.reduce(0, +) / Double(transcriptDurations.count)
        metrics.p95TranscriptSegmentDuration = p95Index.map {
            transcriptDurations[$0]
        }
        metrics.mixedSpeakerTranscriptSegmentRate = scorableTranscriptSegments > 0
            ? Double(mixedTranscriptSegments) / Double(scorableTranscriptSegments)
            : nil
        return metrics
    }

    private static func predictedWinner(
        for reference: SpeakerEvaluationSegment,
        predicted: [SpeakerEvaluationSegment]
    ) -> String? {
        var overlapBySpeaker: [String: TimeInterval] = [:]
        for segment in predicted where segment.recordingKey == reference.recordingKey {
            guard let speaker = segment.speakerKey else { continue }
            let overlap = max(0, min(reference.endTime, segment.endTime)
                - max(reference.startTime, segment.startTime))
            overlapBySpeaker[speaker, default: 0] += overlap
        }
        return overlapBySpeaker
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .first?.key
    }

    private static func optimalSpeakerMapping(
        reference: [SpeakerEvaluationSegment],
        predicted: [SpeakerEvaluationSegment],
        weight: (SpeakerEvaluationSegment, SpeakerEvaluationSegment, TimeInterval) -> Double
    ) -> [String: String] {
        let referenceKeys = Array(Set(reference.compactMap(\.speakerKey))).sorted()
        let predictedKeys = Array(Set(predicted.compactMap(\.speakerKey))).sorted()
        guard !referenceKeys.isEmpty, !predictedKeys.isEmpty else { return [:] }

        var matrix = Array(
            repeating: Array(repeating: 0.0, count: referenceKeys.count + predictedKeys.count),
            count: predictedKeys.count
        )
        for (predictedIndex, predictedKey) in predictedKeys.enumerated() {
            for (referenceIndex, referenceKey) in referenceKeys.enumerated() {
                var score: Double = 0
                for ref in reference where ref.speakerKey == referenceKey {
                    for pred in predicted where pred.speakerKey == predictedKey {
                        let overlap = max(0, min(ref.endTime, pred.endTime) - max(ref.startTime, pred.startTime))
                        if overlap > 0 { score += weight(ref, pred, overlap) }
                    }
                }
                matrix[predictedIndex][referenceIndex] = score
            }
        }
        let assignment = maximumWeightAssignment(matrix)
        var mapping: [String: String] = [:]
        for row in predictedKeys.indices {
            let column = assignment[row]
            if column >= 0, column < referenceKeys.count, matrix[row][column] > 0 {
                mapping[predictedKeys[row]] = referenceKeys[column]
            }
        }
        return mapping
    }

    private static func temporalErrorComponents(
        reference: [SpeakerEvaluationSegment],
        predicted: [SpeakerEvaluationSegment],
        mapping: [String: String]
    ) -> (miss: TimeInterval, falseAlarm: TimeInterval, confusion: TimeInterval) {
        let boundaries = Set(
            reference.flatMap { [$0.startTime, $0.endTime] }
                + predicted.flatMap { [$0.startTime, $0.endTime] }
        ).sorted()
        guard boundaries.count >= 2 else { return (0, 0, 0) }

        var result: (miss: TimeInterval, falseAlarm: TimeInterval, confusion: TimeInterval) = (0, 0, 0)
        for index in 0..<(boundaries.count - 1) {
            let start = boundaries[index]
            let end = boundaries[index + 1]
            guard end > start else { continue }
            let midpoint = (start + end) / 2
            let refActive = Set(reference.compactMap {
                $0.startTime <= midpoint && midpoint < $0.endTime ? $0.speakerKey : nil
            })
            let predActive = Set(predicted.compactMap { segment -> String? in
                guard segment.startTime <= midpoint,
                      midpoint < segment.endTime,
                      let speaker = segment.speakerKey else { return nil }
                return mapping[speaker] ?? "unmapped:\(speaker)"
            })
            let duration = end - start
            let correct = refActive.intersection(predActive).count
            result.miss += Double(max(0, refActive.count - predActive.count)) * duration
            result.falseAlarm += Double(max(0, predActive.count - refActive.count)) * duration
            result.confusion += Double(max(0, min(refActive.count, predActive.count) - correct)) * duration
        }
        return result
    }

    private static func identityPairMetrics(
        reference: [SpeakerEvaluationSegment],
        predicted: [SpeakerEvaluationSegment]
    ) -> (truePositive: Int, falseMerge: Int, falseSplit: Int) {
        let usableReference = reference.filter { $0.speakerKey != nil }
        var predictedByReferenceIndex: [Int: String] = [:]
        for index in usableReference.indices {
            predictedByReferenceIndex[index] = predictedWinner(
                for: usableReference[index],
                predicted: predicted
            )
        }

        var truePositive = 0
        var falseMerge = 0
        var falseSplit = 0
        for left in usableReference.indices {
            guard left + 1 < usableReference.count else { continue }
            for right in (left + 1)..<usableReference.count
            where usableReference[left].recordingKey != usableReference[right].recordingKey {
                let referenceSame = usableReference[left].speakerKey == usableReference[right].speakerKey
                let predictedSame = predictedByReferenceIndex[left] != nil
                    && predictedByReferenceIndex[left] == predictedByReferenceIndex[right]
                if referenceSame && predictedSame { truePositive += 1 }
                if !referenceSame && predictedSame { falseMerge += 1 }
                if referenceSame && !predictedSame { falseSplit += 1 }
            }
        }
        return (truePositive, falseMerge, falseSplit)
    }

    private static func maximumWeightAssignment(_ weights: [[Double]]) -> [Int] {
        let rows = weights.count
        guard rows > 0 else { return [] }
        let columns = weights[0].count
        precondition(columns >= rows)
        let maximum = weights.flatMap { $0 }.max() ?? 0
        let costs = weights.map { row in row.map { maximum - $0 } }
        var u = [Double](repeating: 0, count: rows + 1)
        var v = [Double](repeating: 0, count: columns + 1)
        var p = [Int](repeating: 0, count: columns + 1)
        var way = [Int](repeating: 0, count: columns + 1)

        for row in 1...rows {
            p[0] = row
            var column0 = 0
            var minimum = [Double](repeating: .infinity, count: columns + 1)
            var used = [Bool](repeating: false, count: columns + 1)
            repeat {
                used[column0] = true
                let row0 = p[column0]
                var delta = Double.infinity
                var column1 = 0
                for column in 1...columns where !used[column] {
                    let current = costs[row0 - 1][column - 1] - u[row0] - v[column]
                    if current < minimum[column] {
                        minimum[column] = current
                        way[column] = column0
                    }
                    if minimum[column] < delta {
                        delta = minimum[column]
                        column1 = column
                    }
                }
                for column in 0...columns {
                    if used[column] {
                        u[p[column]] += delta
                        v[column] -= delta
                    } else {
                        minimum[column] -= delta
                    }
                }
                column0 = column1
            } while p[column0] != 0

            repeat {
                let previous = way[column0]
                p[column0] = p[previous]
                column0 = previous
            } while column0 != 0
        }

        var assignment = [Int](repeating: -1, count: rows)
        for column in 1...columns where p[column] > 0 {
            assignment[p[column] - 1] = column - 1
        }
        return assignment
    }
}
