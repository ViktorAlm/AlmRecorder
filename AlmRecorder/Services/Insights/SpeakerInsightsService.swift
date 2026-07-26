import Foundation

/// Generates and persists an AI "About this person" profile (summary + topics) for a speaker,
/// built from the things they said across all recordings. Mirrors `RecordingInsightsService`:
/// uses the Gemma text LLM via `LLMTextService`, is idempotent via a version marker, and degrades
/// gracefully (no-op) when no text model is available.
final class SpeakerInsightsService {
    static let shared = SpeakerInsightsService()

    static let currentVersion = "1"

    private let speakerRepo = GRDBSpeakerRepository()
    private let insightsRepo = GRDBSpeakerInsightsRepository()
    private let logger = VoxtralLogger.shared

    /// Hard cap on quote characters fed to the model so a prolific speaker can't overflow context.
    private let maxChars = 12_000
    /// Don't bother profiling a speaker with almost nothing on record.
    private let minUtterances = 3

    private init() {}

    /// Currently-stored insights for a speaker, or nil. Synchronous read for the UI.
    func existing(uuid: String) -> GRDBSpeakerInsightsRepository.SpeakerInsights? {
        insightsRepo.get(uuid: uuid)
    }

    /// True when the speaker already has insights for the current version.
    func hasInsights(uuid: String) -> Bool {
        guard let existing = insightsRepo.get(uuid: uuid) else { return false }
        return existing.version == Self.currentVersion && !existing.summary.isEmpty
    }

    /// Generate insights for a speaker and persist them. No-ops when no text model is available,
    /// the speaker has too few utterances, or insights already exist (unless `force`).
    func generateAndPersist(speakerUuid: String, force: Bool = false) async throws {
        guard LLMTextService.shared.isAvailable else {
            logger.info("[SpeakerInsights] No Gemma text model available; skipping speaker \(speakerUuid)")
            return
        }
        if !force && hasInsights(uuid: speakerUuid) { return }

        let utterances = try speakerRepo.getUtterancesForSpeaker(uuid: speakerUuid)
        guard utterances.count >= minUtterances else {
            logger.info("[SpeakerInsights] Speaker \(speakerUuid) has too few utterances; skipping")
            return
        }

        let speaker = try? speakerRepo.getByUUID(speakerUuid)
        let name = (speaker ?? nil)?.name
        let transcript = String(utterances.map { $0.utterance.text }.joined(separator: "\n").prefix(maxChars))
        let prompt = Self.prompt(name: name, transcript: transcript)

        let raw = try await LLMTextService.shared.generateText(prompt: prompt)
        guard let parsed = Self.parse(from: raw) else {
            logger.warning("[SpeakerInsights] Could not parse insights for speaker \(speakerUuid)")
            return
        }
        insightsRepo.save(uuid: speakerUuid, summary: parsed.summary, topics: parsed.topics, version: Self.currentVersion)
        logger.info("[SpeakerInsights] Speaker \(speakerUuid) done | topics=\(parsed.topics.count)")
    }

    // MARK: - Prompt + parsing (pure)

    static func prompt(name: String?, transcript: String) -> String {
        let who = (name?.isEmpty == false) ? "a person named \"\(name!)\"" : "a person"
        return """
        You are building a profile of \(who) from things they said across several recorded conversations. Read their quotes below and reply with a SINGLE JSON object and nothing else, in exactly this shape:
        {"summary": "<2-4 sentence description of who this person seems to be and what they talk about>", "topics": ["<topic>", ...]}
        Base it only on the quotes. Use at most 6 short topics. Do not output any text outside the JSON.

        Their quotes:
        \"\"\"
        \(transcript)
        \"\"\"
        """
    }

    /// Extract the first balanced `{...}` block and decode `{summary, topics}`. Tolerant of
    /// leading/trailing prose. Returns nil for missing/empty summary or unparseable output.
    static func parse(from output: String) -> (summary: String, topics: [String])? {
        guard let start = output.firstIndex(of: "{") else { return nil }
        var depth = 0
        var end: String.Index?
        var idx = start
        while idx < output.endIndex {
            let c = output[idx]
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { end = idx; break }
            }
            idx = output.index(after: idx)
        }
        guard let endIdx = end else { return nil }
        let jsonString = String(output[start...endIdx])
        guard let data = jsonString.data(using: .utf8) else { return nil }

        struct Raw: Decodable {
            let summary: String?
            let topics: [String]?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        let summary = (raw.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return nil }
        let topics = (raw.topics ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (summary, topics)
    }
}
