import Foundation

/// Per-invocation aggregate of whisper token probabilities — the only confidence signal
/// whisper-cli exports (`-ojf`; segment-level no_speech_prob/avg_logprob never reach the JSON).
/// One whisper invocation == one TranscriptionChunk == one utterance in the unified pipeline,
/// so these stats attach directly to the resulting utterance.
struct WhisperTokenStats: Codable, Equatable {
    let meanP: Float
    let minP: Float
    /// Fraction of tokens with p below `WhisperJSONParser.lowProbabilityThreshold`.
    let lowFrac: Float
    let tokenCount: Int
}

/// A transcription plus the token-probability aggregate from the `-ojf` sidecar.
/// `tokenStats` is nil whenever the sidecar was missing or unparseable — confidence capture
/// must never fail a transcription that already succeeded.
struct WhisperDetailedTranscription {
    let text: String
    let tokenStats: WhisperTokenStats?
    let timedSegments: [WhisperTimedSegment]
}

struct WhisperTimedSegment: Codable, Equatable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let tokenStats: WhisperTokenStats?
}

/// Parses the sidecar JSON file written by `whisper-cli -ojf`.
/// Shape (verified against External/whisper.cpp/examples/cli/cli.cpp `output_json`):
/// `{"transcription": [{"text", "timestamps", "offsets", "tokens": [{"text", "id", "p", ...}]}]}`.
/// Pure and total: malformed input returns nil, never throws — a broken sidecar must never
/// fail a transcription that already succeeded.
enum WhisperJSONParser {

    static let lowProbabilityThreshold: Float = 0.4

    struct Token: Equatable {
        let text: String
        let id: Int
        let p: Float
    }

    /// All tokens across all segments, special tokens included.
    /// nil = unparseable; [] = parseable but token-free (the non-full `-oj` shape).
    static func parseTokens(_ data: Data) -> [Token]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segments = root["transcription"] as? [[String: Any]] else {
            return nil
        }
        var tokens: [Token] = []
        for segment in segments {
            guard let rawTokens = segment["tokens"] as? [[String: Any]] else { continue }
            for raw in rawTokens {
                guard let text = raw["text"] as? String,
                      let p = (raw["p"] as? NSNumber)?.floatValue else { continue }
                let id = (raw["id"] as? NSNumber)?.intValue ?? -1
                tokens.append(Token(text: text, id: id, p: p))
            }
        }
        return tokens
    }

    /// Aggregate over REAL tokens only — `[_BEG_]`, `[_TT_250]`, `[_EOT_]` etc. carry
    /// meaningless probabilities and would poison the stats. nil when no real tokens remain.
    static func stats(from tokens: [Token]) -> WhisperTokenStats? {
        let real = tokens.filter { !isSpecialToken($0.text) }
        guard !real.isEmpty else { return nil }
        let probabilities = real.map(\.p)
        let mean = probabilities.reduce(0, +) / Float(real.count)
        let low = probabilities.filter { $0 < lowProbabilityThreshold }.count
        return WhisperTokenStats(
            meanP: mean,
            minP: probabilities.min() ?? 0,
            lowFrac: Float(low) / Float(real.count),
            tokenCount: real.count
        )
    }

    static func parseStats(_ data: Data) -> WhisperTokenStats? {
        parseTokens(data).flatMap(stats(from:))
    }

    /// Parses whisper's millisecond `offsets` into timestamped text segments. With `-ml 1`
    /// these are word-sized; without it they are phrase-sized. Invalid individual rows are
    /// skipped so one malformed segment cannot discard the rest of a successful transcript.
    static func parseTimedSegments(_ data: Data) -> [WhisperTimedSegment]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segments = root["transcription"] as? [[String: Any]] else {
            return nil
        }

        return segments.compactMap { segment in
            guard let text = segment["text"] as? String,
                  let offsets = segment["offsets"] as? [String: Any],
                  let fromMilliseconds = (offsets["from"] as? NSNumber)?.doubleValue,
                  let toMilliseconds = (offsets["to"] as? NSNumber)?.doubleValue,
                  toMilliseconds >= fromMilliseconds else {
                return nil
            }

            var segmentTokens: [Token] = []
            if let rawTokens = segment["tokens"] as? [[String: Any]] {
                segmentTokens = rawTokens.compactMap { raw in
                    guard let tokenText = raw["text"] as? String,
                          let probability = (raw["p"] as? NSNumber)?.floatValue else { return nil }
                    return Token(
                        text: tokenText,
                        id: (raw["id"] as? NSNumber)?.intValue ?? -1,
                        p: probability
                    )
                }
            }

            return WhisperTimedSegment(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                startTime: fromMilliseconds / 1_000,
                endTime: toMilliseconds / 1_000,
                tokenStats: stats(from: segmentTokens)
            )
        }
    }

    /// Special tokens render as `[_BEG_]`, `[_EOT_]`, or `[_TT_549]` — note the timestamp form
    /// has NO trailing underscore, so match on the `[_` prefix and `]` suffix only.
    private static func isSpecialToken(_ text: String) -> Bool {
        text.hasPrefix("[_") && text.hasSuffix("]")
    }
}
