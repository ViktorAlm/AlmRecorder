import Foundation

/// Runs the pure `SpeakerIdentityInferenceEngine` over the whole library and applies the **tiered policy**:
///   - `.forced` / `.strong`  → auto-applied (an `inferred` mapping + a non-destructive `inferred` name).
///   - `.likely` / `.weak`     → surfaced as suggestions for the user to confirm.
///
/// Fetching, applying, and confirming live here; the engine stays pure. Viewing the inbox is read-only
/// (`pendingSuggestions()` / `appliedInferences()`); side effects happen only on an explicit `recompute()`
/// (post-transcription trigger or the inbox's "Re-run").
final class IdentityInferenceCoordinator: @unchecked Sendable {
    static let shared = IdentityInferenceCoordinator()

    private let db = GRDBDatabaseManager.shared
    private let attendeeRepo = GRDBSpeakerAttendeeRepository()
    private let speakerRepo = GRDBSpeakerRepository()
    private let owner = OwnerIdentityService.shared
    private let logger = VoxtralLogger.shared

    private init() {}

    struct Result {
        let applied: [IdentityInference]      // auto-named (forced/strong)
        let suggestions: [IdentityInference]  // pending confirmation (likely/weak)
    }

    // MARK: - Compute

    /// All inferences across the library, recomputed from current data. Read-only (no writes).
    func computeAll() -> [IdentityInference] {
        owner.detectOwnerVoiceIfNeeded()
        let ownerId = owner.currentOwner()
        let contexts = (try? db.read { try GRDBIdentityInferenceQueries.meetingContexts($0) }) ?? []
        // Manual mappings are locked truth and seed deduction; inferred mappings are our own prior guesses
        // and are recomputed fresh each run.
        let manual = ((try? attendeeRepo.getAllMappings()) ?? []).filter { $0.source == .manual }
        let rejected = speakerRepo.rejectedVoiceUuids()

        // Don't assume one person == one voice cluster. Diarization over-splits a single person into several
        // clusters (drift, environment changes mid-call — they hop in the car and their voiceprint shifts).
        // Group acoustically-identical clusters into personas and infer over THOSE: pooling a person's
        // meetings across their shards fixes diluted coverage AND stops the greedy from shoving duplicate
        // shards onto the wrong attendees. Grouping is acoustic only — same-person shards may co-occur.
        let speakers = (try? speakerRepo.getAll()) ?? []
        let speakerConfiguration = SpeakerPipelineSettings.shared.activeConfiguration
        let personas = VoicePersonaGrouper.group(
            speakers.map { ($0.uuid, $0.embeddingArray) },
            threshold: speakerConfiguration.personaSimilarityThreshold,
            linkage: speakerConfiguration.personaLinkage
        )
        let toPersona = VoicePersonaGrouper.representativeMap(personas)
        let membersOf = Dictionary(uniqueKeysWithValues: personas.map { ($0.id, $0.members) })
        func persona(_ uuid: String) -> String { toPersona[uuid] ?? uuid }

        // Remap every voice reference to its persona id; same-persona shards within one meeting collapse.
        let pooledContexts = contexts.map { ctx in
            MeetingContext(meetingId: ctx.meetingId, confidence: ctx.confidence,
                           attendees: ctx.attendees, voiceUuids: Array(Set(ctx.voiceUuids.map(persona))))
        }
        let pooledOwner = OwnerIdentity(speakerUuid: ownerId.speakerUuid.map(persona),
                                        name: ownerId.name, email: ownerId.email)
        let pooledManual = manual.map {
            SpeakerAttendeeMapping(speakerUuid: persona($0.speakerUuid), attendeeName: $0.attendeeName,
                                   attendeeEmail: $0.attendeeEmail, source: $0.source)
        }

        let pooled = SpeakerIdentityInferenceEngine
            // Surface best-guesses too (incl. .weak) for the inbox + profile "most likely" banner.
            // Auto-apply stays strict: recompute() only writes names for >= .strong.
            .infer(meetings: pooledContexts, existingMappings: pooledManual, owner: pooledOwner, minConfidence: .weak)

        // Expand each persona-level inference back onto every member cluster, so all shards of a person get
        // the same identity (and a lookup for any one shard resolves). Then honor per-voice user dismissals.
        var result = pooled
            .flatMap { inf -> [IdentityInference] in
                (membersOf[inf.speakerUuid] ?? [inf.speakerUuid]).map {
                    IdentityInference(speakerUuid: $0, attendeeName: inf.attendeeName, attendeeEmail: inf.attendeeEmail,
                                      confidence: inf.confidence, reason: inf.reason, score: inf.score)
                }
            }
            .filter { !rejected.contains($0.speakerUuid) }

        // Owner-likeness guard: a candidate voice that SOUNDS like the owner is one of the
        // owner's own diarization shards the persona grouper missed — propose it as YOU instead
        // of letting attendance overlap pin it on the most frequent colleague.
        if let ownerUuid = ownerId.speakerUuid,
           let ownerEmbedding = speakers.first(where: { $0.uuid == ownerUuid })?.embeddingArray,
           !ownerEmbedding.isEmpty {
            let candidateVoices = Set(result.map(\.speakerUuid))
            let embeddings = speakers
                .filter { candidateVoices.contains($0.uuid) && $0.uuid != ownerUuid }
                .map { (uuid: $0.uuid, embedding: $0.embeddingArray) }
            let ownerLike = OwnerVoiceLikeness.ownerLikeVoices(voices: embeddings, ownerEmbedding: ownerEmbedding)
            if !ownerLike.isEmpty {
                let ownerDisplay = (ownerId.name?.isEmpty == false ? ownerId.name : nil) ?? ownerId.email ?? "You"
                result.removeAll { ownerLike.keys.contains($0.speakerUuid) }
                for (uuid, similarity) in ownerLike {
                    result.append(IdentityInference(
                        speakerUuid: uuid, attendeeName: ownerDisplay, attendeeEmail: ownerId.email,
                        confidence: .likely,
                        reason: "Sounds like your voice (\(Int(similarity * 100))% match)",
                        score: similarity))
                }
            }
        }

        // LLM transcript verdicts: confirmations promote (and can auto-apply), contradictions
        // demote and propose the person the AI actually heard in the call.
        let verdicts = (try? db.read { try IdentityLLMVerdictStore.all($0) }) ?? []
        return IdentityVerdictPolicy.apply(inferences: result, verdicts: verdicts)
    }

    /// The current cross-meeting inference for a single voice, if any — used to enrich the per-recording
    /// review wizard with identities deduced from the voice's *other* meetings.
    func inference(forVoice uuid: String) -> IdentityInference? {
        computeAll().first { $0.speakerUuid == uuid }
    }

    /// Lower-confidence inferences (likely/weak) not yet mapped — what the inbox shows as "suggested".
    func pendingSuggestions() -> [IdentityInference] {
        let mappedVoices = Set(((try? attendeeRepo.getAllMappings()) ?? []).map(\.speakerUuid))
        return computeAll().filter { $0.confidence < .strong && !mappedVoices.contains($0.speakerUuid) }
    }

    /// Auto-applied inferences currently in the DB (inferred mappings) — what the inbox shows as
    /// "auto-named", each confirmable or undoable.
    func appliedInferences() -> [SpeakerAttendeeMapping] {
        ((try? attendeeRepo.getAllMappings()) ?? []).filter { $0.source == .inferred }
    }

    // MARK: - Apply (side effects)

    /// Recompute and auto-apply the near-certain tier. Idempotent; never overwrites a user-assigned name.
    /// Also RETRACTS previously auto-applied names the engine no longer endorses (the data changed, or an
    /// AI verdict demoted them) — inferred mappings are our own guesses, recomputed fresh each run, and a
    /// stale one must not keep naming the voice. Manual mappings are never touched.
    @discardableResult
    func recompute() -> Result {
        var applied: [IdentityInference] = []
        var suggestions: [IdentityInference] = []
        let inferences = computeAll()
        for inf in inferences {
            if inf.confidence >= .strong {
                apply(inf)
                applied.append(inf)
            } else {
                suggestions.append(inf)
            }
        }
        let existing = (try? attendeeRepo.getAllMappings()) ?? []
        for stale in Self.staleInferredMappings(existing: existing, endorsed: inferences) {
            try? attendeeRepo.removeMapping(speakerUuid: stale.speakerUuid, attendeeName: stale.attendeeName)
            try? speakerRepo.clearInferredName(uuid: stale.speakerUuid)
            logger.info("[IdentityInference] retracted stale inferred name '\(stale.attendeeName)' for voice \(stale.speakerUuid.prefix(8))")
        }
        logger.info("[IdentityInference] recompute applied=\(applied.count) suggestions=\(suggestions.count)")
        return Result(applied: applied, suggestions: suggestions)
    }

    /// Pure: inferred mappings whose (voice, person) the current run no longer endorses at auto-apply
    /// strength. Manual mappings are user truth and never stale.
    static func staleInferredMappings(existing: [SpeakerAttendeeMapping],
                                      endorsed: [IdentityInference]) -> [SpeakerAttendeeMapping] {
        let endorsedKeys = Set(endorsed.filter { $0.confidence >= .strong }
            .map { "\($0.speakerUuid)|\($0.attendeeName)" })
        return existing.filter {
            $0.source == .inferred && !endorsedKeys.contains("\($0.speakerUuid)|\($0.attendeeName)")
        }
    }

    /// Write an inferred mapping and name the voice — non-destructively (skips voices with a user name).
    private func apply(_ inf: IdentityInference) {
        try? attendeeRepo.setMapping(speakerUuid: inf.speakerUuid, attendeeName: inf.attendeeName,
                                     attendeeEmail: inf.attendeeEmail, source: .inferred)
        if !speakerRepo.hasUserAssignedName(uuid: inf.speakerUuid) {
            try? speakerRepo.setName(uuid: inf.speakerUuid, name: inf.attendeeName, source: "inferred")
        }
    }

    /// User confirms an inference (auto-applied or suggested): promote mapping + name to manual.
    func confirm(speakerUuid: String, attendeeName: String, attendeeEmail: String?) {
        try? attendeeRepo.setMapping(speakerUuid: speakerUuid, attendeeName: attendeeName,
                                     attendeeEmail: attendeeEmail, source: .manual)
        try? speakerRepo.setName(uuid: speakerUuid, name: attendeeName, source: "manual")
    }

    func confirm(_ inf: IdentityInference) {
        confirm(speakerUuid: inf.speakerUuid, attendeeName: inf.attendeeName, attendeeEmail: inf.attendeeEmail)
    }

    /// User rejects/dismisses an inference: drop any inferred mapping and tombstone the voice so the engine
    /// stops re-proposing it. A later manual rename re-enables inference for that voice.
    func reject(speakerUuid: String, attendeeName: String) {
        try? attendeeRepo.removeMapping(speakerUuid: speakerUuid, attendeeName: attendeeName)
        try? speakerRepo.markInferenceRejected(uuid: speakerUuid)
    }

    /// Fire-and-forget recompute off the main thread — the post-transcription trigger.
    /// After recomputing, the LLM reviews unchecked suggestions against actual call transcripts,
    /// and a second recompute applies anything the AI promoted to certainty.
    func scheduleRecompute() {
        Task.detached(priority: .utility) { [weak self] in
            _ = self?.recompute()
            let reviewed = await SpeakerIdentityLLMReviewer.shared.reviewPendingSuggestions()
            if reviewed > 0 { _ = self?.recompute() }
        }
    }

    // MARK: - Automatic LLM review (no button needed)

    private var periodicReviewTask: Task<Void, Never>?

    /// Background catch-up loop for the LLM identity review. The event triggers (post-transcription,
    /// post-calendar-sync) miss two cases: suggestions that already existed before the feature shipped,
    /// and runs skipped because the GPU was busy. So poll: every tick reviews a few unchecked
    /// suggestions and re-applies. Idle ticks are cheap — the reviewer builds its work list (and exits)
    /// BEFORE acquiring the GPU, so nothing is preempted when there's nothing to do.
    func startPeriodicReview(interval: TimeInterval = 300, initialDelay: TimeInterval = 90) {
        guard periodicReviewTask == nil else { return }
        periodicReviewTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(initialDelay * 1_000_000_000))
            while !Task.isCancelled {
                let reviewed = await SpeakerIdentityLLMReviewer.shared.reviewPendingSuggestions()
                if reviewed > 0 { _ = self?.recompute() }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }
}
