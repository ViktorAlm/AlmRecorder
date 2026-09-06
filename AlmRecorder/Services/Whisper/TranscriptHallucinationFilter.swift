import Foundation

/// Detects Whisper hallucinations on silence/non-speech so they can be dropped before becoming utterances.
/// Pure and deterministic. Two failure modes, both classic for subtitle-trained ASR fed silence:
///   1. subtitle-credit boilerplate ("Undertexter av Amara.org", "btistudios.com", "Subtitles by …")
///   2. runaway repetition loops ("ready to work ready to work …")
enum TranscriptHallucinationFilter {
    /// A subtitle credit appended to substantial real speech must not discard the whole segment.
    /// Cleanup can still route that mixed segment through audio-backed repair.
    static let hardBoilerplateMaxWords = 24
    static let hardRepetitionMinWords = 10
    static let hardRepetitionMinCoverage = 0.6
    /// Subtitle-credit phrases Whisper emits on silence. Specific enough to not hit real meeting speech.
    private static let boilerplateMarkers = [
        "amara.org", "btistudios", "undertexter av", "teksting av",
        "subtitles by", "subtitling by", "subtitled by", "subs by",
    ]

    static func isHallucination(_ text: String) -> Bool {
        let lower = text.lowercased()
        if isStandaloneBoilerplate(lower) { return true }
        return isRunawayRepetition(lower)
    }

    /// Expects already-lowercased text.
    static func hasBoilerplateMarker(_ lower: String) -> Bool {
        boilerplateMarkers.contains(where: lower.contains)
    }

    static func hasRepeatedBoilerplateMarker(_ lower: String) -> Bool {
        boilerplateMarkers.contains { occurrenceCount(of: $0, in: lower) >= 2 }
    }

    /// Hard only when the credit is effectively the segment. Long mixed-content segments are
    /// retained so cleanup can repair the tail without deleting legitimate speech.
    static func isStandaloneBoilerplate(_ lower: String) -> Bool {
        hasBoilerplateMarker(lower)
            && (words(in: lower).count <= hardBoilerplateMaxWords
                || hasRepeatedBoilerplateMarker(lower))
    }

    /// A hard loop is a sustained consecutive 1–4-gram run that dominates the whole segment.
    /// Global vocabulary ratios and local disfluencies ("it is … it is …") both misclassify real
    /// speech, so a shorter repeated span inside a substantial utterance remains reviewable.
    /// Expects already-lowercased text.
    static func isRunawayRepetition(_ lower: String) -> Bool {
        let tokens = words(in: lower)
        guard tokens.count >= hardRepetitionMinWords else { return false }
        let loop = maxConsecutiveNGramLoop(tokens)
        return loop.run >= 5
            && Double(loop.coveredWords) / Double(tokens.count) >= hardRepetitionMinCoverage
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    private static func occurrenceCount(of needle: String, in text: String) -> Int {
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<text.endIndex
        }
        return count
    }

    /// Returns the longest single run plus the union of words covered by any repeated run of at
    /// least three units. Silence hallucinations often switch from one loop to another; coverage
    /// must therefore include all such runs, not only the longest phrase.
    private static func maxConsecutiveNGramLoop(_ words: [String]) -> (run: Int, coveredWords: Int) {
        guard words.count >= 2 else { return (1, words.count) }
        var maxRun = 1
        var coveredIndices: Set<Int> = []
        for n in 1...4 where words.count >= n * 2 {
            for offset in 0..<n {
                var run = 1
                var index = offset + n
                while index + n <= words.count {
                    if words[index..<(index + n)].elementsEqual(
                        words[(index - n)..<index]
                    ) {
                        run += 1
                        maxRun = max(maxRun, run)
                        if run >= 3 {
                            let start = index - ((run - 1) * n)
                            coveredIndices.formUnion(start..<(index + n))
                        }
                    } else {
                        run = 1
                    }
                    index += n
                }
            }
        }
        return (maxRun, coveredIndices.count)
    }
}
