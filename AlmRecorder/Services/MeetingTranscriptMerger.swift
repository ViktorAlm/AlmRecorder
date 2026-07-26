import Foundation

/// Merge the two independently-transcribed meeting tracks (mic = "Me", system audio = "Them") into a
/// single timeline-ordered script. Both tracks share one clock (they start together), so this is a
/// stable interleave by start time — the value is the by-source labeling and deterministic ordering,
/// which beats diarizing a muddy mono mix.
enum MeetingTranscriptMerger {
    enum MeetingSource: String, Equatable {
        case mic
        case system
        /// Human label for the combined transcript.
        var label: String { self == .mic ? "Me" : "Them" }
    }

    /// One utterance from a single source track (decoupled from the DB `Utterance` for easy testing).
    /// `id` carries the originating utterance id so callers (the assembler) can map results back.
    struct SourceUtterance: Equatable {
        let speaker: String?
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        var id: Int64? = nil
    }

    struct MergedLine: Equatable {
        let source: MeetingSource
        let speaker: String?
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        var id: Int64? = nil
    }

    static func merge(mic: [SourceUtterance], system: [SourceUtterance]) -> [MergedLine] {
        let tagged = mic.map { line(from: $0, source: .mic) }
            + system.map { line(from: $0, source: .system) }
        // Stable sort by start time; on a tie, mic ("Me") precedes system ("Them") because mic is
        // appended first and `sorted(by:)` is stable for equal keys.
        return tagged.enumerated()
            .sorted { a, b in
                if a.element.start != b.element.start { return a.element.start < b.element.start }
                return a.offset < b.offset
            }
            .map { $0.element }
    }

    /// Merge + remove echo duplicates in one step (ordered by time). See `dedupe`.
    static func mergeDeduped(
        mic: [SourceUtterance],
        system: [SourceUtterance],
        timeTolerance: TimeInterval = 2.5,
        textThreshold: Double = 0.5
    ) -> [MergedLine] {
        dedupe(merge(mic: mic, system: system), timeTolerance: timeTolerance, textThreshold: textThreshold)
    }

    /// Remove echo duplicates: the mic also records the speaker output, so a mic line overlapping in
    /// time with a system line of similar text is the SAME speech captured twice — drop the mic copy
    /// (the system capture is cleaner). Lines unique to a source (real "Me" vs "Them" turns) are kept.
    static func dedupe(
        _ lines: [MergedLine],
        timeTolerance: TimeInterval = 2.5,
        textThreshold: Double = 0.5
    ) -> [MergedLine] {
        var drop = Set<Int>()
        for i in lines.indices where lines[i].source == .mic {
            for j in lines.indices where lines[j].source == .system {
                guard timeOverlaps(lines[i], lines[j], tol: timeTolerance) else { continue }
                if textSimilarity(lines[i].text, lines[j].text) >= textThreshold {
                    drop.insert(i)
                    break
                }
            }
        }
        return lines.enumerated().filter { !drop.contains($0.offset) }.map { $0.element }
    }

    // MARK: - Similarity helpers (pure)

    static func timeOverlaps(_ a: MergedLine, _ b: MergedLine, tol: TimeInterval) -> Bool {
        a.start <= b.end + tol && b.start <= a.end + tol
    }

    /// Jaccard overlap of normalized word sets (0…1).
    static func textSimilarity(_ a: String, _ b: String) -> Double {
        let sa = tokens(a), sb = tokens(b)
        guard !sa.isEmpty, !sb.isEmpty else { return 0 }
        let inter = sa.intersection(sb).count
        let union = sa.union(sb).count
        return union == 0 ? 0 : Double(inter) / Double(union)
    }

    static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 1 })
    }

    private static func line(from u: SourceUtterance, source: MeetingSource) -> MergedLine {
        MergedLine(source: source, speaker: u.speaker, start: u.start, end: u.end, text: u.text, id: u.id)
    }
}
