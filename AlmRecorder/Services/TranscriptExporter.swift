import Foundation
import UniformTypeIdentifiers

/// Renders a recording's utterances into shareable transcript formats. Pure + testable — the views
/// build `[Line]` from the DB utterances and hand the string to a save panel. Replaces the older
/// ad-hoc SRT/VTT exporters that split the flat transcript and faked "3 seconds per line".
enum TranscriptExporter {
    /// One utterance, decoupled from the DB model for easy testing.
    struct Line: Equatable {
        let speaker: String?
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    enum Format: String, CaseIterable, Identifiable {
        case text, markdown, srt, vtt
        var id: String { rawValue }
        var label: String {
            switch self {
            case .text: return "Plain Text (.txt)"
            case .markdown: return "Markdown (.md)"
            case .srt: return "Subtitles (.srt)"
            case .vtt: return "WebVTT (.vtt)"
            }
        }
        var ext: String {
            switch self {
            case .text: return "txt"
            case .markdown: return "md"
            case .srt: return "srt"
            case .vtt: return "vtt"
            }
        }
        var utType: UTType { self == .markdown ? (UTType("net.daringfireball.markdown") ?? .plainText) : .plainText }
    }

    /// Build export lines from DB utterances, resolving each speaker to its GLOBAL display identity
    /// (uuid → name / stable "Speaker <uuid8>"), falling back to the raw local label only for
    /// un-clustered rows. Sorted by start time. Keeps the formatters pure — they only see resolved
    /// labels, so every format inherits the fix.
    static func lines(from utterances: [Utterance], resolver: SpeakerNameResolver) -> [Line] {
        utterances
            .sorted { $0.startTime < $1.startTime }
            .map { Line(speaker: resolver.displayName(for: $0), start: $0.startTime, end: $0.endTime, text: $0.text) }
    }

    static func export(_ lines: [Line], format: Format, title: String) -> String {
        switch format {
        case .text: return plainText(lines)
        case .markdown: return markdown(lines, title: title)
        case .srt: return srt(lines)
        case .vtt: return vtt(lines)
        }
    }

    // MARK: - Formats

    static func plainText(_ lines: [Line]) -> String {
        lines.map { prefixedSpeaker($0) + $0.text }.joined(separator: "\n")
    }

    static func markdown(_ lines: [Line], title: String) -> String {
        var out = "# \(title)\n"
        var lastSpeaker: String?? = .some(nil) // distinct from "no speaker" so the first row prints
        for l in lines {
            if l.speaker != (lastSpeaker ?? nil) {
                lastSpeaker = .some(l.speaker)
                if let s = l.speaker, !s.isEmpty {
                    out += "\n**\(s)** _(\(clock(l.start)))_\n\n"
                } else {
                    out += "\n"
                }
            }
            out += "\(l.text)\n"
        }
        return out
    }

    static func srt(_ lines: [Line]) -> String {
        var out = ""
        for (i, l) in lines.enumerated() {
            out += "\(i + 1)\n\(srtTime(l.start)) --> \(srtTime(l.end))\n\(prefixedSpeaker(l))\(l.text)\n\n"
        }
        return out
    }

    static func vtt(_ lines: [Line]) -> String {
        var out = "WEBVTT\n\n"
        for l in lines {
            let cue: String
            if let s = l.speaker, !s.isEmpty { cue = "<v \(s)>\(l.text)" } else { cue = l.text }
            out += "\(vttTime(l.start)) --> \(vttTime(l.end))\n\(cue)\n\n"
        }
        return out
    }

    // MARK: - Timestamps

    /// SRT uses a comma before milliseconds; WebVTT uses a dot. Both are HH:MM:SS.
    static func srtTime(_ t: TimeInterval) -> String { hms(t, msSeparator: ",") }
    static func vttTime(_ t: TimeInterval) -> String { hms(t, msSeparator: ".") }

    private static func hms(_ t: TimeInterval, msSeparator: String) -> String {
        let total = max(0, t)
        let whole = Int(total)
        let h = whole / 3600, m = (whole % 3600) / 60, s = whole % 60
        let ms = Int((total - Double(whole)) * 1000.0)
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, msSeparator, ms)
    }

    private static func clock(_ t: TimeInterval) -> String {
        let whole = Int(max(0, t)); return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    private static func prefixedSpeaker(_ l: Line) -> String {
        (l.speaker?.isEmpty == false) ? "\(l.speaker!): " : ""
    }
}
