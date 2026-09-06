import Foundation

/// Deferred scaffolding for comparing suspicious transcript lines with recording audio.
///
/// The pure parts (span building, prompt, verdict parsing) are static and unit-tested; parsing is
/// strict — a malformed or partial reply yields nil so the caller routes those lines to human
/// review instead of applying a guess.
///
/// IMPORTANT: Gemma audio input is intentionally disabled. Keep this type text/pure only until an
/// audio verifier is reintroduced behind a separately reviewed feature flag and benchmark.
final class TranscriptVerificationService {

    static let shared = TranscriptVerificationService()

    private init() {}

    // MARK: - Availability

    /// Gemma audio verification is deferred. Suspicious probabilistic findings remain in the human
    /// review inbox instead of being sent to a multimodal model.
    var isAvailable: Bool {
        false
    }

    /// Kept for source compatibility while the old projector UI is removed.
    var projectorFailureReason: String? {
        nil
    }

    func cancel() {}

    // MARK: - Types

    struct SpanLine: Equatable {
        let utteranceId: Int64
        let text: String
        /// Times relative to the span's audio clip.
        let relStart: TimeInterval
        let relEnd: TimeInterval
    }

    struct VerificationSpan: Equatable {
        let lines: [SpanLine]
        /// Absolute times into the recording.
        let audioStart: TimeInterval
        let audioEnd: TimeInterval
        /// True when a single utterance was longer than the window and got cut — verdicts on a
        /// partially-heard line are confidence-capped to medium by the caller.
        let clamped: Bool
    }

    enum VerdictKind: String, Codable {
        case correct
        case wrong
        case notSpoken = "not_spoken"
    }

    enum VerdictConfidence: String, Codable {
        case high, medium, low
    }

    struct LineVerdict: Equatable {
        let line: Int
        let verdict: VerdictKind
        let heard: String
        let confidence: VerdictConfidence
    }

    enum VerificationError: Error, LocalizedError {
        case unparseableReply
        case modelUnavailable
        case audioVerificationDeferred

        var errorDescription: String? {
            switch self {
            case .unparseableReply: return "Gemma reply did not contain valid line verdicts"
            case .modelUnavailable: return "Gemma model or audio projector not available"
            case .audioVerificationDeferred:
                return "Audio verification is deferred; this line needs human review"
            }
        }
    }

    // MARK: - Span building (pure)

    enum SpanDefaults {
        static let maxSpanDuration: TimeInterval = 26   // Gemma hears ~28s; leave headroom for padding
        static let mergeGap: TimeInterval = 2.0
        static let pad: TimeInterval = 1.0
        static let maxLines = 6                          // keep the JSON reply short and parseable
    }

    /// Greedily merge time-adjacent flagged utterances into verification spans.
    static func buildSpans(
        _ flagged: [Utterance],
        maxSpanDuration: TimeInterval = SpanDefaults.maxSpanDuration,
        mergeGap: TimeInterval = SpanDefaults.mergeGap,
        pad: TimeInterval = SpanDefaults.pad,
        maxLines: Int = SpanDefaults.maxLines
    ) -> [VerificationSpan] {
        let sorted = flagged.filter { $0.id != nil }.sorted { $0.startTime < $1.startTime }
        guard !sorted.isEmpty else { return [] }

        var spans: [VerificationSpan] = []
        var group: [Utterance] = []

        func flush() {
            guard let first = group.first, let last = group.last else { return }
            let audioStart = max(0, first.startTime - pad)
            var audioEnd = last.endTime + pad
            var clamped = false
            if audioEnd - audioStart > maxSpanDuration {
                // Only possible for a single oversized utterance (grouping respects the window).
                audioEnd = audioStart + maxSpanDuration
                clamped = true
            }
            let lines = group.map { u in
                SpanLine(utteranceId: u.id ?? -1,
                         text: u.text,
                         relStart: max(0, u.startTime - audioStart),
                         relEnd: min(u.endTime, audioEnd) - audioStart)
            }
            spans.append(VerificationSpan(lines: lines, audioStart: audioStart, audioEnd: audioEnd, clamped: clamped))
            group = []
        }

        for utterance in sorted {
            if let last = group.last {
                let spanStart = max(0, (group.first?.startTime ?? 0) - pad)
                let fits = utterance.startTime - last.endTime <= mergeGap
                    && (utterance.endTime + pad) - spanStart <= maxSpanDuration
                    && group.count < maxLines
                if !fits { flush() }
            }
            group.append(utterance)
        }
        flush()
        return spans
    }

    // MARK: - Prompt (pure)

    static func buildPrompt(span: VerificationSpan, language: String?) -> String {
        let lang = (language?.isEmpty == false && language != "auto") ? language! : "unknown"
        let lineBlock = span.lines.enumerated().map { index, line in
            let safeText = line.text
                .replacingOccurrences(of: "\"", with: "'")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return String(format: "Line %d [%.1fs-%.1fs]: \"%@\"", index + 1, line.relStart, line.relEnd, safeText)
        }.joined(separator: "\n")

        return """
        You are checking an automatic speech transcription against the actual audio clip.
        Listen to the clip. The transcription system claims these lines are spoken (times are relative to the start of the clip; claimed language: \(lang)):

        \(lineBlock)

        For EACH line decide:
        - "correct": the line matches what is actually said (minor punctuation/casing/spelling differences are fine)
        - "wrong": there is speech there but it says something different — write what you actually hear in "heard", in the spoken language
        - "not_spoken": nothing like this line is spoken there (silence, music, or noise)

        Reply with a SINGLE JSON object and nothing else, in exactly this shape:
        {"results":[{"line":1,"verdict":"correct","heard":"","confidence":"high"},{"line":2,"verdict":"not_spoken","heard":"","confidence":"medium"}]}
        One entry per line, in order. "confidence" is high, medium, or low. Do not output any text outside the JSON.
        """
    }

    // MARK: - Verdict parsing (pure)

    /// Extract the first balanced `{...}` block (tolerant of surrounding prose) and decode the
    /// verdicts. Strict on structure: the entries must cover lines 1…expectedLines exactly once
    /// with known verdict kinds, or the whole reply is rejected (nil) — partial replies are never
    /// applied. Lenient on confidence: missing/unknown becomes `.low`, which is never auto-applied.
    static func parseVerdicts(from raw: String, expectedLines: Int) -> [LineVerdict]? {
        guard let jsonString = firstBalancedJSONObject(in: raw),
              let root = try? JSONSerialization.jsonObject(with: Data(jsonString.utf8)) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else {
            return nil
        }

        var verdicts: [LineVerdict] = []
        for entry in results {
            guard let line = (entry["line"] as? NSNumber)?.intValue,
                  let verdictRaw = entry["verdict"] as? String,
                  let verdict = VerdictKind(rawValue: verdictRaw) else {
                return nil
            }
            let heard = (entry["heard"] as? String) ?? ""
            let confidence = (entry["confidence"] as? String).flatMap(VerdictConfidence.init(rawValue:)) ?? .low
            verdicts.append(LineVerdict(line: line, verdict: verdict,
                                        heard: heard.trimmingCharacters(in: .whitespacesAndNewlines),
                                        confidence: confidence))
        }

        verdicts.sort { $0.line < $1.line }
        guard verdicts.count == expectedLines,
              verdicts.map(\.line) == Array(1...max(expectedLines, 1)) || expectedLines == 0 else {
            return nil
        }
        return verdicts
    }

    private static func firstBalancedJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var idx = start
        while idx < text.endIndex {
            let char = text[idx]
            if char == "{" { depth += 1 }
            else if char == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...idx]) }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    // MARK: - Deferred I/O boundary

    /// Deliberately fails closed. No audio is read, cut, converted, or attached to Gemma.
    func verify(span: VerificationSpan, audioFilePath: String, language: String?) async throws -> [LineVerdict] {
        _ = span
        _ = audioFilePath
        _ = language
        throw VerificationError.audioVerificationDeferred
    }
}
