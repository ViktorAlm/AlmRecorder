import Foundation

/// Detects Whisper hallucinations on silence/non-speech so they can be dropped before becoming utterances.
/// Pure and deterministic. Two failure modes, both classic for subtitle-trained ASR fed silence:
///   1. subtitle-credit boilerplate ("Undertexter av Amara.org", "btistudios.com", "Subtitles by …")
///   2. runaway repetition loops ("ready to work ready to work …")
enum TranscriptHallucinationFilter {
    /// Subtitle-credit phrases Whisper emits on silence. Specific enough to not hit real meeting speech.
    private static let boilerplateMarkers = [
        "amara.org", "btistudios", "undertexter av", "teksting av",
        "subtitles by", "subtitling by", "subtitled by", "subs by",
    ]

    static func isHallucination(_ text: String) -> Bool {
        let lower = text.lowercased()
        if hasBoilerplateMarker(lower) { return true }
        return isRunawayRepetition(lower)
    }

    /// Expects already-lowercased text.
    static func hasBoilerplateMarker(_ lower: String) -> Bool {
        boilerplateMarkers.contains(where: lower.contains)
    }

    /// A loop is long text built from very few distinct words ("ready to work" ×14). Real speech keeps a
    /// high distinct/total ratio; a repetition loop collapses it. Short utterances are never flagged.
    /// Expects already-lowercased text.
    static func isRunawayRepetition(_ lower: String) -> Bool {
        let words = lower
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard words.count >= 12 else { return false }
        let distinctRatio = Double(Set(words).count) / Double(words.count)
        return distinctRatio <= 0.35
    }
}
