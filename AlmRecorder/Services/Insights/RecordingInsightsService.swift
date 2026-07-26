import Foundation

/// Generates and persists LLM insights (title, summary, topics, tags) for a single recording.
///
/// - Title → `Recording.title`, but only when it's still untouched (equals the filename) — unless
///   `force`. Editing/saving a title in the UI "claims" it and is preserved.
/// - Summary + topics → `Recording.metadata`.
/// - Tags → real `Tag` entities (find-or-create) so they're filterable in the Dashboard, plus a
///   comma-joined string in `metadata.customData["tags"]` for the detail-sheet fallback.
/// - An `insightsVersion` marker in `metadata.customData` makes regeneration idempotent — no DB migration.
final class RecordingInsightsService {
    static let shared = RecordingInsightsService()

    static let currentVersion = "1"

    private let recordingRepo = GRDBRecordingRepository()
    private let tagRepo = GRDBTagRepository()
    private let logger = VoxtralLogger.shared

    private let minTranscriptChars = 40
    private let autoTagColor = "#8E8E93" // neutral gray for generated tags

    private init() {}

    /// True if the recording already has insights for the current version.
    static func hasInsights(_ recording: Recording) -> Bool {
        recording.metadata?.customData?["insightsVersion"] == currentVersion
    }

    /// Generate insights for a recording and persist them. No-ops when no text model is available,
    /// the transcript is too short, or insights already exist (unless `force`).
    func generateAndPersist(recordingId: Int64, force: Bool = false) async throws {
        guard LLMTextService.shared.isAvailable else {
            logger.info("[Insights] No Gemma text model available; skipping recording \(recordingId)")
            return
        }
        guard let recording = try recordingRepo.getById(recordingId) else {
            logger.warning("[Insights] Recording \(recordingId) not found")
            return
        }
        if !force && Self.hasInsights(recording) { return }

        let transcript = resolvedTranscript(forRecording: recordingId, fallback: recording.fullTranscript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard transcript.count >= minTranscriptChars else {
            logger.info("[Insights] Recording \(recordingId) transcript too short; skipping")
            return
        }

        // Inject the full existing tag vocabulary (name + description) so the model reuses tags instead
        // of growing near-duplicates.
        let knownTags = ((try? tagRepo.getAllTags()) ?? []).map { tag -> String in
            if let d = tag.description, !d.isEmpty { return "\(tag.name) — \(d)" }
            return tag.name
        }
        let insights = try await LLMTextService.shared.generateRecordingInsights(transcript: transcript, knownTags: knownTags)
        try persist(insights, to: recording)
        logger.info("[Insights] Recording \(recordingId) done | title=\(insights.title.isEmpty ? "-" : insights.title) topics=\(insights.topics.count) tags=\(insights.tags.count)")
    }

    /// The transcript to summarize: re-derived from the recording's utterances so renamed /
    /// re-clustered speakers show their CURRENT global identity (uuid → name), falling back to the
    /// stored "[Speaker] text" blob only for legacy recordings that have no utterances. Hidden
    /// (cleaned-up) lines are excluded by `getByRecording`.
    private func resolvedTranscript(forRecording recordingId: Int64, fallback: String?) -> String {
        let utterances = (try? GRDBUtteranceRepository().getByRecording(id: recordingId)) ?? []
        guard !utterances.isEmpty else { return fallback ?? "" }
        let resolver = SpeakerNameResolver(speakers: (try? GRDBSpeakerRepository().getAll()) ?? [])
        let segments = utterances.map {
            LabeledTranscript.Segment(speakerUuid: $0.speakerUuid, localLabel: $0.speaker, text: $0.text)
        }
        return LabeledTranscript.render(segments, resolver: resolver)
    }

    // MARK: - Persistence

    private func persist(_ insights: RecordingInsights, to recording: Recording) throws {
        guard let recordingId = recording.id else { return }

        // Title: only overwrite when still untouched (equals the filename).
        let newTitle = (!insights.title.isEmpty && recording.title == recording.fileName) ? insights.title : recording.title

        var metadata = recording.metadata ?? Recording.RecordingMetadata(speakers: nil, topics: nil, summary: nil, customData: nil)
        metadata.summary = insights.summary
        if !insights.topics.isEmpty { metadata.topics = insights.topics }
        var custom = metadata.customData ?? [:]
        if !insights.tags.isEmpty { custom["tags"] = insights.tags.map { $0.name }.joined(separator: ", ") }
        custom["insightsVersion"] = Self.currentVersion
        metadata.customData = custom

        let updated = Recording(
            id: recording.id,
            title: newTitle,
            fileName: recording.fileName,
            filePath: recording.filePath,
            duration: recording.duration,
            language: recording.language,
            createdAt: recording.createdAt,
            transcribedAt: recording.transcribedAt,
            source: recording.source,
            fullTranscript: recording.fullTranscript,
            metadata: metadata
        )
        try recordingRepo.update(updated)

        if !insights.tags.isEmpty {
            try applyTags(insights.tags, to: recordingId)
        }
    }

    /// Find-or-create each tag and associate it with the recording (idempotent via INSERT OR IGNORE).
    private func applyTags(_ suggestions: [TagSuggestion], to recordingId: Int64) throws {
        var existing = try tagRepo.getAllTags()
        var appliedLower = Set<String>()
        for sug in suggestions {
            let name = sug.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = name.lowercased()
            guard !name.isEmpty, !appliedLower.contains(lower) else { continue }
            appliedLower.insert(lower)
            let desc = sug.description?.trimmingCharacters(in: .whitespacesAndNewlines)

            let tagId: Int64
            if let match = existing.first(where: { $0.name.lowercased() == lower }), let id = match.id {
                tagId = id
                // Backfill a description onto an existing tag that doesn't have one yet.
                if (match.description?.isEmpty ?? true), let desc, !desc.isEmpty {
                    try? tagRepo.updateTagDescription(id: id, description: desc)
                }
            } else {
                tagId = try tagRepo.createTag(name: name, color: autoTagColor, description: (desc?.isEmpty == false) ? desc : nil)
                existing.append(Tag(id: tagId, name: name, color: autoTagColor, description: desc))
            }
            try tagRepo.addTagToRecording(recordingId: recordingId, tagId: tagId)
        }
    }
}
