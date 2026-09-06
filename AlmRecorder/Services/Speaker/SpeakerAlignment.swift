import Foundation

struct SpeakerIdentityEmbeddingSample {
    let embedding: [Float]
    let start: TimeInterval
    let end: TimeInterval
    let qualityScore: Float
}

struct SpeakerEmbeddingMixtureEvidence: Equatable {
    let gain: Float
    let centroidSimilarity: Float
    let smallerGroupCount: Int
}

enum SpeakerEmbeddingMixtureDetector {
    /// Conservative two-mode test shared by live enrollment and active-learning review. A cluster
    /// is treated as mixed only when two groups materially improve fit and their centroids are
    /// clearly separated.
    static func detect(
        vectors: [[Float]],
        centroid: [Float]
    ) -> SpeakerEmbeddingMixtureEvidence? {
        guard vectors.count >= 6,
              let firstSeed = vectors.min(by: {
                  SpeakerUnifier.cosine($0, centroid) < SpeakerUnifier.cosine($1, centroid)
              }),
              let secondSeed = vectors.min(by: {
                  SpeakerUnifier.cosine($0, firstSeed) < SpeakerUnifier.cosine($1, firstSeed)
              })
        else { return nil }

        var first: [[Float]] = []
        var second: [[Float]] = []
        for vector in vectors {
            if SpeakerUnifier.cosine(vector, firstSeed)
                >= SpeakerUnifier.cosine(vector, secondSeed) {
                first.append(vector)
            } else {
                second.append(vector)
            }
        }
        guard first.count >= 2, second.count >= 2,
              let firstCentroid = VoiceMath.meanNormalized(first),
              let secondCentroid = VoiceMath.meanNormalized(second) else {
            return nil
        }

        let oneGroupCohesion = vectors.reduce(Float.zero) {
            $0 + SpeakerUnifier.cosine($1, centroid)
        } / Float(vectors.count)
        let twoGroupCohesion = vectors.reduce(Float.zero) {
            $0 + max(
                SpeakerUnifier.cosine($1, firstCentroid),
                SpeakerUnifier.cosine($1, secondCentroid)
            )
        } / Float(vectors.count)
        let gain = twoGroupCohesion - oneGroupCohesion
        let separation = SpeakerUnifier.cosine(firstCentroid, secondCentroid)
        guard gain >= 0.08, separation <= 0.70 else { return nil }
        return SpeakerEmbeddingMixtureEvidence(
            gain: gain,
            centroidSimilarity: separation,
            smallerGroupCount: min(first.count, second.count)
        )
    }
}

/// A speaker turn from a diarizer: `speaker` is active over [start, end] seconds.
struct DiarizationTurn {
    let speaker: String
    let start: TimeInterval
    let end: TimeInterval
    /// Optional voice embedding for this turn (256-dim WeSpeaker from FluidAudio). Empty when
    /// not provided; the alignment logic ignores it.
    var embedding: [Float] = []
    /// FluidAudio's 0...1 estimate of how representative the segment embedding is.
    var qualityScore: Float = 1
    /// Raw overlapping-window embeddings retained by the offline diarizer. These preserve
    /// within-cluster variation; reconstructed segment embeddings are already collapsed to the
    /// speaker centroid and cannot reveal a mixed local label.
    var identityEmbeddingSamples: [SpeakerIdentityEmbeddingSample] = []
    /// Optional acoustic slot distinct from the identity label. Targeted diarization can use this
    /// to retain evidence that two voices overlap while conservatively anchoring an unconfirmed
    /// short voice to the same recording-local identity until it repeats in another window.
    var acousticSpeaker: String? = nil
}

struct SpeakerDiarizationRun {
    let turns: [DiarizationTurn]
    let wallClockSeconds: TimeInterval
    let stageTimings: SpeakerDiarizationStageTimings?
}

struct SpeakerDiarizationStageTimings: Codable, Equatable {
    let audioLoadingSeconds: TimeInterval
    let segmentationSeconds: TimeInterval
    let embeddingSeconds: TimeInterval
    let clusteringSeconds: TimeInterval
    let postProcessingSeconds: TimeInterval
}

struct SpeakerAlignedTextSegment: Equatable {
    var text: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var speaker: String?
    var embedding: [Float]?
    var confidence: Float?
    var tokenStats: WhisperTokenStats?
    var speakerOverlapRatio: Float = 0
    var activeSpeakerCount: Int = 1
    var overlappingSpeakers: [String] = []
}

private struct SpeakerTextSegmentationPolicy {
    let maximumMergeGap: TimeInterval
    let maximumDuration: TimeInterval?
    let maximumWords: Int?
    let sentenceBreakAfter: TimeInterval?
    let splitOnAcousticContextChange: Bool
    /// A diarizer can leave a short coverage hole inside one continuous turn. When the same
    /// speaker is assigned immediately before and after an otherwise non-overlapping hole, carry
    /// that label across the hole so a few unassigned ASR words do not fragment the transcript.
    let maximumUnassignedBridgeDuration: TimeInterval

    static func policy(for mode: SpeakerUtteranceSegmentation) -> Self {
        switch mode {
        case .legacyCoalesced:
            return SpeakerTextSegmentationPolicy(
                maximumMergeGap: 1.0,
                maximumDuration: nil,
                maximumWords: nil,
                sentenceBreakAfter: nil,
                splitOnAcousticContextChange: false,
                maximumUnassignedBridgeDuration: 5
            )
        case .readable:
            return SpeakerTextSegmentationPolicy(
                maximumMergeGap: 2.0,
                maximumDuration: 60,
                maximumWords: 160,
                sentenceBreakAfter: 25,
                splitOnAcousticContextChange: true,
                maximumUnassignedBridgeDuration: 8
            )
        case .speakerSafe:
            return SpeakerTextSegmentationPolicy(
                maximumMergeGap: 0.45,
                maximumDuration: 10,
                maximumWords: 28,
                sentenceBreakAfter: 4,
                splitOnAcousticContextChange: true,
                maximumUnassignedBridgeDuration: 1.5
            )
        }
    }
}

/// Assigns ASR utterances to diarizer speakers by maximum temporal overlap (the WhisperX
/// pattern): the ASR backend gives us text with timestamps; the diarizer gives us speaker
/// turns; we label each utterance with whichever speaker covers most of it.
enum SpeakerAlignment {
    struct OverlapEvidence: Equatable {
        let ratio: Float
        let maximumActiveSpeakerCount: Int
        let speakerLabels: [String]

        static let none = OverlapEvidence(
            ratio: 0,
            maximumActiveSpeakerCount: 1,
            speakerLabels: []
        )
    }

    /// Measure simultaneous diarizer activity without forcing it into the transcript's single
    /// display-speaker field. Boundaries partition the interval into regions with a constant set
    /// of active speakers, making the ratio exact for the supplied turn timeline.
    static func overlapEvidence(
        start: TimeInterval,
        end: TimeInterval,
        turns: [DiarizationTurn]
    ) -> OverlapEvidence {
        guard end > start else { return .none }
        let relevant = turns.filter { min(end, $0.end) > max(start, $0.start) }
        guard relevant.count >= 2 else { return .none }

        let boundaries = Set(
            [start, end] + relevant.flatMap {
                [max(start, $0.start), min(end, $0.end)]
            }
        ).sorted()
        guard boundaries.count >= 2 else { return .none }

        var overlappingDuration: TimeInterval = 0
        var maximumCount = 1
        var overlapLabels: Set<String> = []
        for index in 0..<(boundaries.count - 1) {
            let left = boundaries[index]
            let right = boundaries[index + 1]
            guard right > left else { continue }
            let midpoint = left + (right - left) / 2
            let activeTurns = relevant
                .filter { $0.start <= midpoint && midpoint < $0.end }
            let activeAcousticSpeakers = Set(
                activeTurns.map { $0.acousticSpeaker ?? $0.speaker }
            )
            maximumCount = max(maximumCount, activeAcousticSpeakers.count)
            if activeAcousticSpeakers.count >= 2 {
                overlappingDuration += right - left
                overlapLabels.formUnion(
                    activeTurns.map { $0.acousticSpeaker ?? $0.speaker }
                )
            }
        }
        return OverlapEvidence(
            ratio: Float(min(1, max(0, overlappingDuration / (end - start)))),
            maximumActiveSpeakerCount: maximumCount,
            speakerLabels: overlapLabels.sorted()
        )
    }

    /// The speaker whose turns overlap [start, end] the most (summed over all that speaker's
    /// turns), or `nil` if no turn overlaps. Ties break deterministically by speaker label so
    /// the result is stable.
    static func speaker(
        forUtteranceStart start: TimeInterval,
        end: TimeInterval,
        turns: [DiarizationTurn]
    ) -> String? {
        var overlapBySpeaker: [String: TimeInterval] = [:]
        for turn in turns {
            let overlap = max(0, min(end, turn.end) - max(start, turn.start))
            if overlap > 0 { overlapBySpeaker[turn.speaker, default: 0] += overlap }
        }
        return overlapBySpeaker
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .first?.key
    }

    /// Like `speaker(...)`, but also returns the 256-dim voice embedding of the winning speaker's
    /// most-overlapping turn — so we can persist a per-utterance voice fingerprint. `embedding` is
    /// nil when no turn overlaps or the overlapping turns carry no embedding.
    static func speakerAndEmbedding(
        forUtteranceStart start: TimeInterval,
        end: TimeInterval,
        turns: [DiarizationTurn]
    ) -> (speaker: String?, embedding: [Float]?) {
        var overlapBySpeaker: [String: TimeInterval] = [:]
        var bestTurn: [String: (overlap: TimeInterval, embedding: [Float])] = [:]
        for turn in turns {
            let overlap = max(0, min(end, turn.end) - max(start, turn.start))
            guard overlap > 0 else { continue }
            overlapBySpeaker[turn.speaker, default: 0] += overlap
            if !turn.embedding.isEmpty {
                if let existing = bestTurn[turn.speaker] {
                    if overlap > existing.overlap { bestTurn[turn.speaker] = (overlap, turn.embedding) }
                } else {
                    bestTurn[turn.speaker] = (overlap, turn.embedding)
                }
            }
        }
        guard let winner = overlapBySpeaker
            .sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key })
            .first?.key
        else {
            return (nil, nil)
        }
        return (winner, bestTurn[winner]?.embedding)
    }

    /// Last-resort timing for a successful transcript whose JSON sidecar has no usable word
    /// offsets. Uniform timing is less precise than Whisper's `-ml 1` output, but it preserves the
    /// ability to cut text at acoustic speaker boundaries instead of assigning an entire VAD block
    /// to one person.
    static func approximateWordSegments(
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        tokenStats: WhisperTokenStats? = nil
    ) -> [WhisperTimedSegment] {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        guard !words.isEmpty else { return [] }
        let duration = max(0, end - start)
        let step = duration / Double(words.count)
        return words.enumerated().map { index, word in
            let distributedStats: WhisperTokenStats?
            if let tokenStats {
                let baseCount = tokenStats.tokenCount / words.count
                let remainder = tokenStats.tokenCount % words.count
                let count = baseCount + (index < remainder ? 1 : 0)
                distributedStats = count > 0
                    ? WhisperTokenStats(
                        meanP: tokenStats.meanP,
                        minP: tokenStats.minP,
                        lowFrac: tokenStats.lowFrac,
                        tokenCount: count
                    )
                    : nil
            } else {
                distributedStats = nil
            }
            return WhisperTimedSegment(
                text: String(word),
                startTime: start + Double(index) * step,
                endTime: index == words.count - 1
                    ? end
                    : start + Double(index + 1) * step,
                tokenStats: distributedStats
            )
        }
    }

    /// Align word/phrase timestamps to the diarizer timeline, then coalesce adjacent words from
    /// the same voice. Boundary-aware mode uses the speaker active at the ASR segment midpoint;
    /// this avoids a long neighboring turn stealing a short word that crosses a boundary.
    static func align(
        _ segments: [WhisperTimedSegment],
        to turns: [DiarizationTurn],
        strategy: SpeakerAlignmentStrategy,
        globalOffset: TimeInterval = 0,
        maximumMergeGap: TimeInterval? = nil,
        utteranceSegmentation: SpeakerUtteranceSegmentation = .legacyCoalesced
    ) -> [SpeakerAlignedTextSegment] {
        var segmentationPolicy = SpeakerTextSegmentationPolicy.policy(
            for: utteranceSegmentation
        )
        if let maximumMergeGap {
            segmentationPolicy = SpeakerTextSegmentationPolicy(
                maximumMergeGap: maximumMergeGap,
                maximumDuration: segmentationPolicy.maximumDuration,
                maximumWords: segmentationPolicy.maximumWords,
                sentenceBreakAfter: segmentationPolicy.sentenceBreakAfter,
                splitOnAcousticContextChange: segmentationPolicy.splitOnAcousticContextChange,
                maximumUnassignedBridgeDuration:
                    segmentationPolicy.maximumUnassignedBridgeDuration
            )
        }
        let alignmentInputs = utteranceSegmentation == .legacyCoalesced
            ? segments
            : segments.flatMap { segment -> [WhisperTimedSegment] in
                guard wordCount(segment.text) > 1 else { return [segment] }
                return approximateWordSegments(
                    text: segment.text,
                    start: segment.startTime,
                    end: segment.endTime,
                    tokenStats: segment.tokenStats
                )
            }
        let ordered = alignmentInputs
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.startTime != $1.startTime ? $0.startTime < $1.startTime : $0.endTime < $1.endTime }

        var assigned: [SpeakerAlignedTextSegment] = []
        for segment in ordered {
            let start = globalOffset + segment.startTime
            let end = globalOffset + max(segment.startTime, segment.endTime)

            let assignment: (speaker: String?, embedding: [Float]?)
            let overlap = overlapEvidence(start: start, end: end, turns: turns)
            switch strategy {
            case .maximumOverlap:
                assignment = speakerAndEmbedding(
                    forUtteranceStart: start,
                    end: end,
                    turns: turns
                )
            case .splitAtSpeakerBoundaries:
                let midpoint = start + max(0, end - start) / 2
                if let active = turns
                    .filter({ $0.start <= midpoint && midpoint < $0.end })
                    .sorted(by: {
                        if $0.qualityScore != $1.qualityScore { return $0.qualityScore > $1.qualityScore }
                        return $0.speaker < $1.speaker
                    })
                    .first {
                    assignment = (active.speaker, active.embedding.isEmpty ? nil : active.embedding)
                } else {
                    assignment = speakerAndEmbedding(
                        forUtteranceStart: start,
                        end: end,
                        turns: turns
                    )
                }
            }

            let next = SpeakerAlignedTextSegment(
                text: segment.text,
                startTime: start,
                endTime: end,
                speaker: assignment.speaker,
                embedding: assignment.embedding,
                confidence: segment.tokenStats?.meanP,
                tokenStats: segment.tokenStats,
                speakerOverlapRatio: overlap.ratio,
                activeSpeakerCount: overlap.maximumActiveSpeakerCount,
                overlappingSpeakers: overlap.speakerLabels
            )
            assigned.append(next)
        }

        let bridged = bridgeUnassignedSpeakerGaps(
            assigned,
            policy: segmentationPolicy
        )
        var aligned: [SpeakerAlignedTextSegment] = []
        for next in bridged {
            if let lastIndex = aligned.indices.last,
               shouldMerge(
                   aligned[lastIndex],
                   with: next,
                   policy: segmentationPolicy
               ) {
                let oldDuration = max(0.001, aligned[lastIndex].endTime - aligned[lastIndex].startTime)
                let nextDuration = max(0.001, next.endTime - next.startTime)
                aligned[lastIndex].text = joined(aligned[lastIndex].text, next.text)
                aligned[lastIndex].endTime = max(aligned[lastIndex].endTime, next.endTime)
                aligned[lastIndex].speakerOverlapRatio = (
                    aligned[lastIndex].speakerOverlapRatio * Float(oldDuration)
                        + next.speakerOverlapRatio * Float(nextDuration)
                ) / Float(oldDuration + nextDuration)
                aligned[lastIndex].activeSpeakerCount = max(
                    aligned[lastIndex].activeSpeakerCount,
                    next.activeSpeakerCount
                )
                aligned[lastIndex].overlappingSpeakers = Array(
                    Set(
                        aligned[lastIndex].overlappingSpeakers
                            + next.overlappingSpeakers
                    )
                ).sorted()
                aligned[lastIndex].confidence = combinedConfidence(
                    aligned[lastIndex].confidence,
                    next.confidence
                )
                aligned[lastIndex].tokenStats = combinedTokenStats(
                    aligned[lastIndex].tokenStats,
                    next.tokenStats
                )
                if aligned[lastIndex].embedding == nil { aligned[lastIndex].embedding = next.embedding }
            } else {
                aligned.append(next)
            }
        }
        return aligned
    }

    /// Interpolate only high-confidence diarization coverage holes. This is deliberately narrower
    /// than nearest-speaker filling: both sides must exist, must agree on the same speaker, the
    /// unassigned run must be short, and none of its ASR spans may contain overlapping-speaker
    /// evidence. A genuine speaker transition therefore remains a hard boundary.
    private static func bridgeUnassignedSpeakerGaps(
        _ segments: [SpeakerAlignedTextSegment],
        policy: SpeakerTextSegmentationPolicy
    ) -> [SpeakerAlignedTextSegment] {
        guard segments.count >= 3 else { return segments }
        var result = segments
        var index = 0

        while index < result.count {
            guard result[index].speaker == nil else {
                index += 1
                continue
            }

            let runStart = index
            while index < result.count, result[index].speaker == nil {
                index += 1
            }
            let runEnd = index
            guard runStart > 0, runEnd < result.count,
                  let leftSpeaker = result[runStart - 1].speaker,
                  leftSpeaker == result[runEnd].speaker else {
                continue
            }

            let runDuration = max(
                0,
                result[runEnd - 1].endTime - result[runStart].startTime
            )
            let leftGap = max(
                0,
                result[runStart].startTime - result[runStart - 1].endTime
            )
            let rightGap = max(
                0,
                result[runEnd].startTime - result[runEnd - 1].endTime
            )
            guard runDuration <= policy.maximumUnassignedBridgeDuration,
                  leftGap <= policy.maximumMergeGap,
                  rightGap <= policy.maximumMergeGap,
                  result[runStart..<runEnd].allSatisfy({
                      $0.activeSpeakerCount <= 1 && $0.overlappingSpeakers.isEmpty
                  }) else {
                continue
            }

            let embedding = result[runStart - 1].embedding
                ?? result[runEnd].embedding
            for holeIndex in runStart..<runEnd {
                result[holeIndex].speaker = leftSpeaker
                if result[holeIndex].embedding == nil {
                    result[holeIndex].embedding = embedding
                }
            }
        }
        return result
    }

    /// Produces one normalized embedding per local diarization cluster with a selectable
    /// weighting policy. Quality weighting suppresses tiny/noisy turns from poisoning identity.
    static func clusterEmbeddings(
        from turns: [DiarizationTurn],
        policy: SpeakerCentroidPolicy
    ) -> [(speaker: String, embedding: [Float], confidence: Float, start: TimeInterval, end: TimeInterval)] {
        Dictionary(grouping: turns, by: \DiarizationTurn.speaker)
            .compactMap { speaker, speakerTurns in
                let rawSamples = speakerTurns.flatMap(\.identityEmbeddingSamples)
                let samples: [SpeakerIdentityEmbeddingSample] = rawSamples.isEmpty
                    ? speakerTurns.map {
                        SpeakerIdentityEmbeddingSample(
                            embedding: $0.embedding,
                            start: $0.start,
                            end: $0.end,
                            qualityScore: $0.qualityScore
                        )
                    }
                    : rawSamples
                let valid = samples.filter { !$0.embedding.isEmpty }
                guard let dimension = valid.first?.embedding.count,
                      dimension > 0,
                      valid.allSatisfy({ $0.embedding.count == dimension }) else { return nil }

                var sum = [Float](repeating: 0, count: dimension)
                var totalWeight: Float = 0
                for sample in valid {
                    let duration = Float(max(0.05, sample.end - sample.start))
                    let weight: Float
                    switch policy {
                    case .equalTurns: weight = 1
                    case .durationWeighted: weight = duration
                    case .qualityDurationWeighted:
                        weight = duration * max(0.05, sample.qualityScore)
                    }
                    let normalized = VoiceMath.normalized(sample.embedding)
                    guard normalized.count == dimension else { continue }
                    for index in sum.indices { sum[index] += normalized[index] * weight }
                    totalWeight += weight
                }
                guard totalWeight > 0 else { return nil }
                for index in sum.indices { sum[index] /= totalWeight }
                let norm = sqrt(sum.reduce(Float.zero) { $0 + ($1 * $1) })
                guard norm > 0 else { return nil }
                for index in sum.indices { sum[index] /= norm }

                let weightedQuality = valid.reduce(Float.zero) { partial, sample in
                    partial + max(0.05, sample.qualityScore)
                        * Float(max(0.05, sample.end - sample.start))
                }
                let duration = valid.reduce(Float.zero) {
                    $0 + Float(max(0.05, $1.end - $1.start))
                }
                return (
                    speaker,
                    sum,
                    min(1, weightedQuality / max(0.05, duration)),
                    speakerTurns.map(\.start).min() ?? 0,
                    speakerTurns.map(\.end).max() ?? 0
                )
            }
            .sorted { $0.speaker < $1.speaker }
    }

    static func identityClusters(
        from turns: [DiarizationTurn],
        policy: SpeakerCentroidPolicy,
        labelPrefix: String = ""
    ) -> [SpeakerIdentityCluster] {
        clusterEmbeddings(from: turns, policy: policy).map { centroid in
            let speakerTurns = turns.filter { $0.speaker == centroid.speaker }
            let rawSamples = speakerTurns.flatMap(\.identityEmbeddingSamples)
            let embeddings = rawSamples.isEmpty
                ? speakerTurns.map(\.embedding)
                : rawSamples.map(\.embedding)
            let similarities = embeddings
                .filter { $0.count == centroid.embedding.count }
                .map { SpeakerUnifier.cosine($0, centroid.embedding) }
                .sorted()
            let lowerQuartileCount = max(1, Int(ceil(Double(similarities.count) * 0.25)))
            let cohesion = similarities.isEmpty
                ? 0
                : similarities.prefix(lowerQuartileCount).reduce(0, +)
                    / Float(lowerQuartileCount)
            let mixture = SpeakerEmbeddingMixtureDetector.detect(
                vectors: embeddings,
                centroid: centroid.embedding
            )
            return SpeakerIdentityCluster(
                label: labelPrefix + centroid.speaker,
                embedding: centroid.embedding,
                spans: speakerTurns
                    .map { SpeakerIdentityTimeSpan(start: $0.start, end: $0.end) },
                confidence: centroid.confidence,
                cohesion: cohesion,
                embeddingTurnCount: similarities.count,
                mixtureSplitGain: mixture?.gain,
                mixtureCentroidSimilarity: mixture?.centroidSimilarity
            )
        }
    }

    static func quality(
        for speaker: String,
        start: TimeInterval,
        end: TimeInterval,
        turns: [DiarizationTurn]
    ) -> Float? {
        var weightedQuality: Float = 0
        var totalOverlap: Float = 0
        for turn in turns where turn.speaker == speaker {
            let overlap = Float(max(0, min(end, turn.end) - max(start, turn.start)))
            guard overlap > 0 else { continue }
            weightedQuality += turn.qualityScore * overlap
            totalOverlap += overlap
        }
        return totalOverlap > 0 ? weightedQuality / totalOverlap : nil
    }

    private static func joined(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        if right.first.map({ ".,!?;:%)]}".contains($0) }) == true { return left + right }
        if left.last.map({ "([{/–—-".contains($0) }) == true { return left + right }
        return left + " " + right
    }

    private static func shouldMerge(
        _ current: SpeakerAlignedTextSegment,
        with next: SpeakerAlignedTextSegment,
        policy: SpeakerTextSegmentationPolicy
    ) -> Bool {
        guard current.speaker == next.speaker,
              next.startTime - current.endTime <= policy.maximumMergeGap else {
            return false
        }

        if policy.splitOnAcousticContextChange,
           acousticContext(of: current) != acousticContext(of: next) {
            return false
        }

        let combinedDuration = max(current.endTime, next.endTime) - current.startTime
        if let maximumDuration = policy.maximumDuration,
           combinedDuration > maximumDuration {
            return false
        }

        if let maximumWords = policy.maximumWords,
           wordCount(current.text) + wordCount(next.text) > maximumWords {
            return false
        }

        if let sentenceBreakAfter = policy.sentenceBreakAfter,
           current.endTime - current.startTime >= sentenceBreakAfter,
           endsStrongSentence(current.text) {
            return false
        }

        return true
    }

    private static func acousticContext(
        of segment: SpeakerAlignedTextSegment
    ) -> String {
        "\(segment.activeSpeakerCount):\(segment.overlappingSpeakers.joined(separator: ","))"
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    private static func endsStrongSentence(_ text: String) -> Bool {
        guard let last = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .last else { return false }
        return ".!?…。！？".contains(last)
    }

    private static func combinedConfidence(_ lhs: Float?, _ rhs: Float?) -> Float? {
        switch (lhs, rhs) {
        case let (left?, right?): return (left + right) / 2
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }

    private static func combinedTokenStats(
        _ lhs: WhisperTokenStats?,
        _ rhs: WhisperTokenStats?
    ) -> WhisperTokenStats? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        let count = lhs.tokenCount + rhs.tokenCount
        guard count > 0 else { return nil }
        let leftCount = Float(lhs.tokenCount)
        let rightCount = Float(rhs.tokenCount)
        return WhisperTokenStats(
            meanP: ((lhs.meanP * leftCount) + (rhs.meanP * rightCount)) / Float(count),
            minP: min(lhs.minP, rhs.minP),
            lowFrac: ((lhs.lowFrac * leftCount) + (rhs.lowFrac * rightCount)) / Float(count),
            tokenCount: count
        )
    }
}
