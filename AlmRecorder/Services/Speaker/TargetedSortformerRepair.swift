import Foundation

/// Pure planning and timeline surgery for the utterance-targeted Sortformer pass.
///
/// Sortformer has four speaker slots per inference window, not per recording. The planner keeps
/// each inference window at the model's native 30.72 seconds and assigns only a bounded group of
/// recording-local utterances to it. Predictions are cropped back to those targets, so a meeting
/// may contain any number of people as long as no repaired target itself needs more than four.
enum TargetedSortformerRepair {
    static let modelWindowDuration: TimeInterval = 30.72
    static let maximumTargetGroupDuration: TimeInterval = 12
    static let contextPadding: TimeInterval = 4
    static let minimumContextDuration: TimeInterval = 8
    static let minimumTargetDuration: TimeInterval = 0.16

    struct Target: Equatable {
        let start: TimeInterval
        let end: TimeInterval

        var duration: TimeInterval { max(0, end - start) }
        var range: Range<TimeInterval> { start..<end }
    }

    struct Window: Equatable {
        let start: TimeInterval
        let end: TimeInterval
        let targets: [Target]

        var duration: TimeInterval { max(0, end - start) }
    }

    struct LocalTurn: Equatable {
        let speakerIndex: Int
        let start: TimeInterval
        let end: TimeInterval
        let activity: Float
    }

    /// Coalesced Whisper/VBx utterances can occasionally be very long. Split those targets before
    /// grouping so the four-slot constraint remains local and the target still has surrounding
    /// acoustic context.
    static func windows(
        for segments: [WhisperTimedSegment],
        audioDuration: TimeInterval
    ) -> [Window] {
        guard audioDuration > 0 else { return [] }
        let normalized = mergeOverlappingTargets(segments
            .flatMap {
                splitTarget(
                    start: max(0, min(audioDuration, $0.startTime)),
                    end: max(0, min(audioDuration, $0.endTime))
                )
            }
            .sorted {
                $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end
            })
        guard !normalized.isEmpty else { return [] }

        var groups: [[Target]] = []
        var current: [Target] = []
        for target in normalized {
            if let first = current.first,
               target.end - first.start > maximumTargetGroupDuration {
                groups.append(current)
                current = [target]
            } else {
                current.append(target)
            }
        }
        if !current.isEmpty { groups.append(current) }

        return groups.map { targets in
            let targetStart = targets.first?.start ?? 0
            let targetEnd = targets.map(\.end).max() ?? targetStart
            var windowStart = max(0, targetStart - contextPadding)
            var windowEnd = min(audioDuration, targetEnd + contextPadding)
            let missingContext = max(
                0,
                min(minimumContextDuration, audioDuration) - (windowEnd - windowStart)
            )
            if missingContext > 0 {
                let growLeft = min(windowStart, missingContext / 2)
                windowStart -= growLeft
                windowEnd = min(audioDuration, windowEnd + missingContext - growLeft)
                if windowEnd - windowStart < min(minimumContextDuration, audioDuration) {
                    windowStart = max(
                        0,
                        windowEnd - min(minimumContextDuration, audioDuration)
                    )
                }
            }
            return Window(start: windowStart, end: windowEnd, targets: targets)
        }
    }

    static func localTurns(
        _ turns: [LocalTurn],
        in target: Target
    ) -> [LocalTurn] {
        turns.compactMap { turn in
            let start = max(target.start, turn.start)
            let end = min(target.end, turn.end)
            guard end > start else { return nil }
            return LocalTurn(
                speakerIndex: turn.speakerIndex,
                start: start,
                end: end,
                activity: turn.activity
            )
        }
    }

    /// A second slot must occupy a material amount of the target. This suppresses one-frame false
    /// alarms but still keeps short interjections and overlap. The threshold grows gently with the
    /// target and caps below NVIDIA's curation-oriented 0.8-second filter.
    static func meaningfulSpeakerIndices(
        in target: Target,
        turns: [LocalTurn]
    ) -> [Int] {
        let clipped = localTurns(turns, in: target)
        let durationThreshold = min(0.60, max(0.24, target.duration * 0.05))
        return Dictionary(grouping: clipped, by: \.speakerIndex)
            .compactMap { speaker, speakerTurns in
                unionDuration(speakerTurns.map { $0.start..<$0.end }) >= durationThreshold
                    ? speaker
                    : nil
            }
            .sorted()
    }

    static func shouldRepair(
        target: Target,
        turns: [LocalTurn]
    ) -> Bool {
        meaningfulSpeakerIndices(in: target, turns: turns).count >= 2
    }

    /// A target with one material Sortformer voice is still valuable: its exclusive embedding
    /// can separate two people that VBx previously placed in the same recording-local cluster,
    /// even when those people never overlap or share an utterance.
    static func hasMaterialSpeaker(
        target: Target,
        turns: [LocalTurn]
    ) -> Bool {
        !meaningfulSpeakerIndices(in: target, turns: turns).isEmpty
    }

    /// Returns intervals in which exactly one Sortformer speaker is active. Only these spans may
    /// train a global voice embedding; overlap is retained for attribution but never enrollment.
    static func exclusiveSpans(
        for speakerIndex: Int,
        turns: [LocalTurn],
        within bounds: Range<TimeInterval>
    ) -> [Range<TimeInterval>] {
        let clipped = turns.compactMap { turn -> LocalTurn? in
            let start = max(bounds.lowerBound, turn.start)
            let end = min(bounds.upperBound, turn.end)
            guard end > start else { return nil }
            return LocalTurn(
                speakerIndex: turn.speakerIndex,
                start: start,
                end: end,
                activity: turn.activity
            )
        }
        let boundaries = Set(
            [bounds.lowerBound, bounds.upperBound]
                + clipped.flatMap { [$0.start, $0.end] }
        ).sorted()
        guard boundaries.count >= 2 else { return [] }

        var spans: [Range<TimeInterval>] = []
        for index in 0..<(boundaries.count - 1) {
            let start = boundaries[index]
            let end = boundaries[index + 1]
            guard end > start else { continue }
            let midpoint = start + (end - start) / 2
            let active = Set(
                clipped
                    .filter { $0.start <= midpoint && midpoint < $0.end }
                    .map(\.speakerIndex)
            )
            guard active == [speakerIndex] else { continue }
            if let last = spans.last, abs(last.upperBound - start) < 0.0001 {
                spans[spans.count - 1] = last.lowerBound..<end
            } else {
                spans.append(start..<end)
            }
        }
        return spans
    }

    /// Replace only the repaired target. Sortformer turns win where it found speech; uncovered
    /// regions retain the baseline VBx turns so quiet/distant speakers missed by Sortformer do not
    /// disappear from the transcript.
    static func replacing(
        baseline: [DiarizationTurn],
        target: Target,
        with replacements: [DiarizationTurn]
    ) -> [DiarizationTurn] {
        let replacementCoverage = mergedRanges(
            replacements.map { max(target.start, $0.start)..<min(target.end, $0.end) }
                .filter { $0.upperBound > $0.lowerBound }
        )
        var result: [DiarizationTurn] = []

        for turn in baseline {
            guard turn.end > target.start, turn.start < target.end else {
                result.append(turn)
                continue
            }

            if turn.start < target.start {
                result.append(copy(turn, start: turn.start, end: target.start))
            }

            let inside = max(turn.start, target.start)..<min(turn.end, target.end)
            var surviving = [inside]
            for coverage in replacementCoverage {
                surviving = surviving.flatMap { subtract($0, coverage) }
            }
            for range in surviving where range.upperBound > range.lowerBound {
                result.append(copy(turn, start: range.lowerBound, end: range.upperBound))
            }

            if turn.end > target.end {
                result.append(copy(turn, start: target.end, end: turn.end))
            }
        }
        result.append(contentsOf: replacements)
        return mergeAdjacent(
            result
                .filter { $0.end > $0.start }
                .sorted {
                    if $0.start != $1.start { return $0.start < $1.start }
                    if $0.end != $1.end { return $0.end < $1.end }
                    return $0.speaker < $1.speaker
                }
        )
    }

    /// Preserve an acoustic slot for overlap/segmentation evidence while anchoring an
    /// insufficiently repeated short slot to a trusted VBx identity. Identity samples from the
    /// uncertain slot are removed so they cannot pollute global speaker enrollment.
    static func remappingSpeakers(
        in turns: [DiarizationTurn],
        aliases: [String: String],
        anchorEmbeddings: [String: [Float]]
    ) -> [DiarizationTurn] {
        turns.map { turn in
            guard let anchor = aliases[turn.speaker] else { return turn }
            return DiarizationTurn(
                speaker: anchor,
                start: turn.start,
                end: turn.end,
                embedding: anchorEmbeddings[anchor] ?? [],
                qualityScore: turn.qualityScore,
                identityEmbeddingSamples: [],
                acousticSpeaker: turn.acousticSpeaker ?? turn.speaker
            )
        }
    }

    /// Timeline replacement may remove the one VBx turn that carries all exposed chunk
    /// embeddings for a local speaker. Reattach the original full-call evidence after surgery so
    /// a boundary repair cannot silently replace a stable identity prototype with a handful of
    /// short-window centroids. Confirmed new Sortformer labels are untouched.
    static func restoringBaselineIdentityEvidence(
        in turns: [DiarizationTurn],
        from baseline: [DiarizationTurn]
    ) -> [DiarizationTurn] {
        let evidenceBySpeaker = Dictionary(grouping: baseline, by: \.speaker)
            .mapValues { $0.flatMap(\.identityEmbeddingSamples) }
            .filter { !$0.value.isEmpty }
        guard !evidenceBySpeaker.isEmpty else { return turns }

        var result = turns
        for (speaker, evidence) in evidenceBySpeaker {
            let indices = result.indices.filter { result[$0].speaker == speaker }
            guard let firstIndex = indices.first else { continue }
            for index in indices {
                result[index].identityEmbeddingSamples = []
            }
            result[firstIndex].identityEmbeddingSamples = evidence
        }
        return result
    }

    private static func splitTarget(
        start: TimeInterval,
        end: TimeInterval
    ) -> [Target] {
        guard end - start >= minimumTargetDuration else { return [] }
        guard end - start > maximumTargetGroupDuration else {
            return [Target(start: start, end: end)]
        }
        var result: [Target] = []
        var cursor = start
        while cursor < end {
            let next = min(end, cursor + maximumTargetGroupDuration)
            if next - cursor >= minimumTargetDuration {
                result.append(Target(start: cursor, end: next))
            }
            cursor = next
        }
        return result
    }

    private static func mergeOverlappingTargets(_ targets: [Target]) -> [Target] {
        var result: [Target] = []
        for target in targets {
            guard let last = result.last, target.start < last.end else {
                result.append(target)
                continue
            }
            result[result.count - 1] = Target(
                start: last.start,
                end: max(last.end, target.end)
            )
        }
        return result.flatMap {
            splitTarget(start: $0.start, end: $0.end)
        }
    }

    private static func unionDuration(
        _ ranges: [Range<TimeInterval>]
    ) -> TimeInterval {
        mergedRanges(ranges).reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    private static func mergedRanges(
        _ ranges: [Range<TimeInterval>]
    ) -> [Range<TimeInterval>] {
        let sorted = ranges
            .filter { $0.upperBound > $0.lowerBound }
            .sorted { $0.lowerBound < $1.lowerBound }
        var result: [Range<TimeInterval>] = []
        for range in sorted {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    private static func subtract(
        _ source: Range<TimeInterval>,
        _ removed: Range<TimeInterval>
    ) -> [Range<TimeInterval>] {
        let overlapStart = max(source.lowerBound, removed.lowerBound)
        let overlapEnd = min(source.upperBound, removed.upperBound)
        guard overlapEnd > overlapStart else { return [source] }
        var result: [Range<TimeInterval>] = []
        if source.lowerBound < overlapStart {
            result.append(source.lowerBound..<overlapStart)
        }
        if overlapEnd < source.upperBound {
            result.append(overlapEnd..<source.upperBound)
        }
        return result
    }

    private static func copy(
        _ turn: DiarizationTurn,
        start: TimeInterval,
        end: TimeInterval
    ) -> DiarizationTurn {
        let clippedIdentitySamples = turn.identityEmbeddingSamples.compactMap {
            sample -> SpeakerIdentityEmbeddingSample? in
            let clippedStart = max(start, sample.start)
            let clippedEnd = min(end, sample.end)
            guard clippedEnd > clippedStart else { return nil }
            return SpeakerIdentityEmbeddingSample(
                embedding: sample.embedding,
                start: clippedStart,
                end: clippedEnd,
                qualityScore: sample.qualityScore
            )
        }
        return DiarizationTurn(
            speaker: turn.speaker,
            start: start,
            end: end,
            embedding: turn.embedding,
            qualityScore: turn.qualityScore,
            identityEmbeddingSamples: clippedIdentitySamples,
            acousticSpeaker: turn.acousticSpeaker
        )
    }

    private static func mergeAdjacent(
        _ turns: [DiarizationTurn]
    ) -> [DiarizationTurn] {
        var result: [DiarizationTurn] = []
        for turn in turns {
            guard let lastIndex = result.indices.last,
                  result[lastIndex].speaker == turn.speaker,
                  result[lastIndex].embedding == turn.embedding,
                  result[lastIndex].acousticSpeaker == turn.acousticSpeaker,
                  abs(result[lastIndex].end - turn.start) < 0.0001 else {
                result.append(turn)
                continue
            }
            let previous = result[lastIndex]
            result[lastIndex] = DiarizationTurn(
                speaker: previous.speaker,
                start: previous.start,
                end: turn.end,
                embedding: previous.embedding,
                qualityScore: max(previous.qualityScore, turn.qualityScore),
                identityEmbeddingSamples: previous.identityEmbeddingSamples
                    + turn.identityEmbeddingSamples,
                acousticSpeaker: previous.acousticSpeaker
            )
        }
        return result
    }
}
