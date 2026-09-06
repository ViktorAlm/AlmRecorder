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
    /// Language selected by Whisper from the audio. This comes from the `result.language`
    /// field in the `-ojf` sidecar, never from inspecting the generated transcript.
    let detectedLanguage: String?
    /// Probability printed by whisper.cpp when `language=auto`. Explicitly selected languages
    /// legitimately have no detection confidence.
    let detectedLanguageConfidence: Float?
}

struct WhisperTimedSegment: Codable, Equatable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let tokenStats: WhisperTokenStats?
}

struct WhisperLanguageObservation: Equatable {
    let code: String
    let confidence: Float?
    let duration: TimeInterval
}

struct WhisperLanguageResolution: Equatable {
    let code: String
    let confidence: Float?
    let source: String
}

/// Resolves the recording-level language without reading generated words. Whisper performs
/// language ID once per VAD invocation, so an auto-language recording can have several
/// observations. Duration voting makes a tiny uncertain utterance unable to override the
/// dominant language of the meeting.
enum WhisperLanguageResolver {
    static func resolve(
        requestedLanguage: String?,
        observations: [WhisperLanguageObservation]
    ) -> WhisperLanguageResolution? {
        let requested = requestedLanguage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let requested,
           !requested.isEmpty,
           requested != "auto",
           requested != "auto-detected",
           requested != "unknown" {
            return WhisperLanguageResolution(
                code: requested,
                confidence: nil,
                source: "user_selected"
            )
        }

        let valid = observations.compactMap { observation -> WhisperLanguageObservation? in
            let code = observation.code
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !code.isEmpty, code != "auto", observation.duration > 0 else { return nil }
            return WhisperLanguageObservation(
                code: code,
                confidence: observation.confidence,
                duration: observation.duration
            )
        }
        guard !valid.isEmpty else { return nil }

        let durationByLanguage = Dictionary(grouping: valid, by: \.code).mapValues {
            $0.reduce(0) { $0 + $1.duration }
        }
        guard let winner = durationByLanguage.max(by: { $0.value < $1.value })?.key else {
            return nil
        }
        let winningObservations = valid.filter { $0.code == winner }
        let confidencePairs = winningObservations.compactMap { observation -> (Float, Double)? in
            observation.confidence.map { ($0, observation.duration) }
        }
        let confidenceWeight = confidencePairs.reduce(0.0) { $0 + $1.1 }
        let confidence: Float? = confidenceWeight > 0
            ? Float(
                confidencePairs.reduce(0.0) {
                    $0 + Double($1.0) * $1.1
                } / confidenceWeight
            )
            : nil

        return WhisperLanguageResolution(
            code: winner,
            confidence: confidence,
            source: "whisper_audio"
        )
    }
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

    /// Reads the language Whisper actually selected from the audio. `params.language` is only the
    /// request (`auto`, `sv`, ...); `result.language` is the resolved language and is the value
    /// AlmRecorder must persist.
    static func parseDetectedLanguage(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let rawLanguage = result["language"] as? String else {
            return nil
        }
        let language = rawLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return language.isEmpty || language == "auto" ? nil : language
    }

    /// whisper.cpp prints the probability only to stderr:
    /// `auto-detected language: sv (p = 0.998123)`.
    static func parseDetectedLanguageLog(_ output: String) -> (code: String, confidence: Float)? {
        let pattern = #"auto-detected language:\s*([A-Za-z-]+)\s*\(p\s*=\s*([0-9]*\.?[0-9]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: output,
                range: NSRange(output.startIndex..., in: output)
              ),
              let codeRange = Range(match.range(at: 1), in: output),
              let confidenceRange = Range(match.range(at: 2), in: output),
              let confidence = Float(output[confidenceRange]) else {
            return nil
        }
        return (String(output[codeRange]).lowercased(), confidence)
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
