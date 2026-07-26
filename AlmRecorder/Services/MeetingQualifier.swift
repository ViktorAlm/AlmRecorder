import Foundation

/// Decides whether a calendar event is a real "meeting with people" worth offering to record, and
/// surfaces the video-call join URL when present. Pure + dependency-free so it's unit-testable.
enum MeetingQualifier {
    struct Result: Equatable {
        let qualifies: Bool
        let joinURL: URL?
    }

    static let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "webex.com"]

    static func evaluate(_ meeting: Meeting) -> Result {
        // Sanity guard against malformed rows (sync already excludes all-day events).
        let duration = meeting.duration
        guard duration > 0, duration < 24 * 3600 else { return Result(qualifies: false, joinURL: nil) }

        let join = detectJoinURL(in: meeting.location) ?? detectJoinURL(in: meeting.notes)
        let qualifies = !meeting.parsedAttendees.isEmpty || join != nil
        return Result(qualifies: qualifies, joinURL: join)
    }

    /// Returns a video-call URL if `text` references a known conferencing host. Prefers a real URL
    /// parsed by `NSDataDetector`; falls back to constructing one from the matching token so a bare
    /// `zoom.us/j/…` (no scheme) still counts.
    static func detectJoinURL(in text: String?) -> URL? {
        guard let text = text, !text.isEmpty else { return nil }
        let lower = text.lowercased()
        guard hosts.contains(where: { lower.contains($0) }) else { return nil }

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, options: [], range: range) {
                if let url = match.url, let host = url.host?.lowercased(),
                   hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                    return url
                }
            }
        }

        // Fallback: build a URL from the first whitespace-delimited token containing a host.
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            if hosts.contains(where: { token.lowercased().contains($0) }) {
                var s = String(token)
                if !s.lowercased().hasPrefix("http") { s = "https://" + s }
                if let url = URL(string: s) { return url }
            }
        }
        return URL(string: "https://" + (hosts.first { lower.contains($0) } ?? "zoom.us"))
    }
}
