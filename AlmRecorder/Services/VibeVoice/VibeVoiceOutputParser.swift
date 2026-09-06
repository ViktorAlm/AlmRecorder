import Foundation

struct VibeVoiceOutput {
    let chunks: [TranscriptionChunk]
    let language: String?
    let peakMemoryGB: Double?
    let processingSeconds: Double?
    let generationTokens: Int?
    let outputRecovered: Bool
    let outputLikelyTruncated: Bool

    init(
        chunks: [TranscriptionChunk],
        language: String?,
        peakMemoryGB: Double?,
        processingSeconds: Double?,
        generationTokens: Int? = nil,
        outputRecovered: Bool = false,
        outputLikelyTruncated: Bool = false
    ) {
        self.chunks = chunks
        self.language = language
        self.peakMemoryGB = peakMemoryGB
        self.processingSeconds = processingSeconds
        self.generationTokens = generationTokens
        self.outputRecovered = outputRecovered
        self.outputLikelyTruncated = outputLikelyTruncated
    }
}

enum VibeVoiceOutputParser {
    private struct Envelope: Decodable {
        let schemaVersion: Int?
        let segments: [Segment]
        let language: String?
        let peakMemoryGB: Double?
        let processingSeconds: Double?
        let generationTokens: Int?
        let outputRecovered: Bool?
        let outputLikelyTruncated: Bool?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case segments
            case language
            case peakMemoryGB = "peak_memory_gb"
            case processingSeconds = "processing_seconds"
            case generationTokens = "generation_tokens"
            case outputRecovered = "output_recovered"
            case outputLikelyTruncated = "output_likely_truncated"
        }
    }

    private struct Segment: Decodable {
        let start: Double
        let end: Double
        let speaker: String
        let text: String

        private enum CodingKeys: String, CodingKey {
            case start, end, speaker, text
            case capitalStart = "Start"
            case capitalEnd = "End"
            case capitalSpeaker = "Speaker"
            case content = "Content"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            start = try Self.decodeDouble(container, keys: [.start, .capitalStart])
            end = try Self.decodeDouble(container, keys: [.end, .capitalEnd])
            speaker = try Self.decodeString(
                container,
                keys: [.speaker, .capitalSpeaker],
                defaultValue: "unknown"
            )
            text = try Self.decodeString(
                container,
                keys: [.text, .content],
                defaultValue: ""
            )
        }

        private static func decodeDouble(
            _ container: KeyedDecodingContainer<CodingKeys>,
            keys: [CodingKeys]
        ) throws -> Double {
            for key in keys {
                if let value = try? container.decode(Double.self, forKey: key) {
                    return value
                }
                if let value = try? container.decode(String.self, forKey: key),
                   let number = Double(value) {
                    return number
                }
            }
            throw DecodingError.dataCorrupted(
                .init(codingPath: container.codingPath, debugDescription: "Missing numeric timestamp")
            )
        }

        private static func decodeString(
            _ container: KeyedDecodingContainer<CodingKeys>,
            keys: [CodingKeys],
            defaultValue: String
        ) throws -> String {
            for key in keys {
                if let value = try? container.decode(String.self, forKey: key) {
                    return value
                }
                if let value = try? container.decode(Int.self, forKey: key) {
                    return String(value)
                }
            }
            return defaultValue
        }
    }

    static func parse(
        _ data: Data,
        duration: TimeInterval? = nil,
        offset: TimeInterval = 0
    ) throws -> VibeVoiceOutput {
        let cleaned = stripCodeFence(from: data)
        let decoder = JSONDecoder()

        let envelope: Envelope
        if let decoded = try? decoder.decode(Envelope.self, from: cleaned) {
            envelope = decoded
        } else if let segments = try? decoder.decode([Segment].self, from: cleaned) {
            envelope = Envelope(
                schemaVersion: nil,
                segments: segments,
                language: nil,
                peakMemoryGB: nil,
                processingSeconds: nil,
                generationTokens: nil,
                outputRecovered: nil,
                outputLikelyTruncated: nil
            )
        } else {
            throw TranscriptionError.invalidResponse
        }

        if let version = envelope.schemaVersion,
           version > VibeVoiceConfiguration.helperSchemaVersion {
            throw TranscriptionError.transcriptionFailed(
                "VibeVoice helper output schema \(version) is newer than this app supports."
            )
        }

        let maximum = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let chunks = envelope.segments.compactMap { segment -> TranscriptionChunk? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  segment.start.isFinite,
                  segment.end.isFinite else { return nil }
            let localStart = max(0, segment.start)
            let localEnd = min(maximum ?? segment.end, segment.end)
            guard localEnd > localStart else { return nil }
            let nativeLabel = "VibeVoice Speaker \(segment.speaker)"
            return TranscriptionChunk(
                text: text,
                startTime: offset + localStart,
                endTime: offset + localEnd,
                speaker: nativeLabel,
                speakerUUID: nil,
                nativeSpeakerLabel: nativeLabel,
                confidence: nil
            )
        }
        .sorted {
            $0.startTime != $1.startTime
                ? $0.startTime < $1.startTime
                : $0.endTime < $1.endTime
        }

        guard !chunks.isEmpty else {
            throw TranscriptionError.transcriptionFailed(
                "VibeVoice returned no valid timestamped speech segments."
            )
        }
        return VibeVoiceOutput(
            chunks: chunks,
            language: envelope.language,
            peakMemoryGB: envelope.peakMemoryGB,
            processingSeconds: envelope.processingSeconds,
            generationTokens: envelope.generationTokens,
            outputRecovered: envelope.outputRecovered ?? false,
            outputLikelyTruncated: envelope.outputLikelyTruncated ?? false
        )
    }

    private static func stripCodeFence(from data: Data) -> Data {
        guard var text = String(data: data, encoding: .utf8) else { return data }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if text.hasSuffix("```") {
                text.removeLast(3)
            }
        }
        return Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    }
}
