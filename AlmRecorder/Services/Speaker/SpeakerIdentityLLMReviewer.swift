import Foundation
import GRDB

/// The LLM leg of speaker identification: attendance overlap can never separate people who
/// always meet together, but the TRANSCRIPT can — people address each other by name, introduce
/// themselves, and reveal roles. This reviewer builds evidence packs (attendee lists + excerpts
/// around the target voice's lines), asks the local Gemma text model who the voice is, and
/// stores the verdicts. `IdentityVerdictPolicy` then promotes confirmed suggestions, demotes
/// contradicted ones, and proposes the person the LLM actually heard.
final class SpeakerIdentityLLMReviewer {

    static let shared = SpeakerIdentityLLMReviewer()
    private let logger = VoxtralLogger.shared
    private init() {}

    /// Single-flight gate so only one review pass runs at a time (three uncoordinated triggers fire
    /// this). MainActor-isolated for atomic test-and-set across the detached callers.
    /// `internal` (not `private`) only so the gate contract can be unit-tested.
    @MainActor private(set) static var isReviewing = false
    @MainActor static func tryBeginReview() -> Bool {
        if isReviewing { return false }
        isReviewing = true
        return true
    }
    @MainActor static func endReview() { isReviewing = false }

    // MARK: - Pure: excerpt building

    struct Line: Equatable {
        let speaker: String
        let text: String
        let isTarget: Bool
    }

    struct Evidence: Equatable {
        let meetingTitle: String
        let attendees: [String]
        let excerpt: String
    }

    /// Windows of ±`radius` lines around the target voice's lines, merged when overlapping, rendered
    /// with speaker labels and the voice under question marked TARGET. Stays within the budget.
    /// Radius 5: a vocative ("Casey, can you start?") often lands several turns before the target's
    /// answer, and introductions span a few short lines — ±2 cut exactly that context off.
    static func excerpt(from lines: [Line], maxCharacters: Int, radius: Int = 5) -> String {
        let targetIndices = lines.indices.filter { lines[$0].isTarget }
        guard !targetIndices.isEmpty else { return "" }

        var included = IndexSet()
        for index in targetIndices {
            included.insert(integersIn: max(0, index - radius)...min(lines.count - 1, index + radius))
        }

        var rendered: [String] = []
        var used = 0
        for index in included.sorted() {
            let text = renderLine(lines[index])
            guard used + text.count + 1 <= maxCharacters else { break }
            rendered.append(text)
            used += text.count + 1
        }
        return rendered.joined(separator: "\n")
    }

    static func renderLine(_ line: Line) -> String {
        "\(line.isTarget ? "TARGET (\(line.speaker))" : line.speaker): \(line.text)"
    }

    /// Build a transcript `Line` rendering the GLOBAL speaker identity. NON-target speakers get their
    /// resolved name (or the stable `"Speaker <uuid8>"` when unnamed) so the model can see who
    /// addresses whom across recordings — the per-recording local label ("Speaker 1") is meaningless
    /// to Gemma and collides across the evidence pack. The TARGET is kept NEUTRAL: its own (possibly
    /// auto-applied, possibly WRONG) candidate name must never be fed back into its own verification,
    /// so it is labelled by its stable uuid-prefix, never the resolved name. Only an un-clustered row
    /// (no uuid) falls back to the raw local label.
    static func makeLine(speakerUuid: String?, localLabel: String?, text: String,
                         voiceUuid: String, candidateName: String? = nil,
                         resolver: SpeakerNameResolver) -> Line {
        let isTarget = (speakerUuid != nil && speakerUuid == voiceUuid)
        // Stable, name-free label — used for the target, and to neutralize any non-target line that
        // would otherwise wear the candidate's name.
        let neutralLabel = (speakerUuid.flatMap { $0.isEmpty ? nil : "Speaker \($0.prefix(8))" })
            ?? localLabel ?? "Speaker ?"
        let label: String
        if isTarget {
            label = neutralLabel
        } else {
            let resolved = resolver.displayName(speakerUuid: speakerUuid, localLabel: localLabel) ?? "Speaker ?"
            // A non-target line must NEVER bear the candidate's name: a same-person over-split shard
            // (auto-named the candidate) or a bystander coincidentally named like the candidate would
            // otherwise feed the guess back into the target's own verification. Neutralize those.
            if let candidateName, !candidateName.isEmpty,
               IdentityVerdictPolicy.personsMatch(resolved, candidateName) {
                label = neutralLabel
            } else {
                label = resolved
            }
        }
        return Line(speaker: label, text: text, isTarget: isTarget)
    }

    // MARK: - Pure: name-token + self-introduction evidence

    /// Searchable tokens for a candidate identity: the display name plus the email LOCAL PART split on
    /// separators, diacritic-folded and lowercased
    /// ("Taylor Example" + taylor.example@… → [taylor, example]).
    /// These are what we grep the transcripts for to see WHO actually says the name.
    static func nameSearchTokens(name: String?, email: String?) -> [String] {
        var raw = (name ?? "") + " "
        if let email {
            raw += email.firstIndex(of: "@").map { String(email[..<$0]) } ?? email
        }
        var seen = Set<String>()
        return fold(raw)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 && seen.insert($0).inserted }
    }

    /// Word-boundary mention check, case- and diacritic-insensitive: the email token "example" must
    /// match the spoken "Example", but "bo" must not match "about".
    static func containsWord(_ token: String, in text: String) -> Bool {
        let foldedToken = fold(token)
        guard !foldedToken.isEmpty else { return false }
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: foldedToken))\\b"
        return fold(text).range(of: pattern, options: .regularExpression) != nil
    }

    /// Lines (from the voice's recordings) where anyone says one of the candidate's name tokens.
    /// Both directions are evidence: OTHERS saying the name right before TARGET answers suggests the
    /// name is TARGET's; TARGET saying it usually means they're addressing someone else. The cap
    /// reserves room for the (rarer) target-spoken side so it can't be flooded out.
    static func mentionLines(in lines: [Line], tokens: [String], cap: Int = 8) -> [Line] {
        guard !tokens.isEmpty else { return [] }
        var seen = Set<String>()
        let hits = lines.filter { line in
            tokens.contains(where: { containsWord($0, in: line.text) })
                && seen.insert("\(line.isTarget)|\(line.speaker)|\(line.text)").inserted
        }
        let targetHits = hits.filter(\.isTarget).count
        let otherHits = hits.count - targetHits
        var targetQuota = min(targetHits, max(cap / 2, cap - otherHits))
        var otherQuota = cap - targetQuota
        return hits.filter { line in
            if line.isTarget { defer { targetQuota -= 1 }; return targetQuota > 0 }
            defer { otherQuota -= 1 }
            return otherQuota > 0
        }
    }

    /// Literal multilingual probes for self-introductions; also the query strings for the semantic
    /// (ANN) leg, which catches paraphrases and other languages the literal scan misses.
    static let introductionProbes = ["my name is", "mitt namn är", "jag heter"]

    /// Lines that literally contain a self-introduction phrase (folded matching, so "Mitt namn är"
    /// hits regardless of case/diacritics).
    static func introductionMatches(in lines: [Line], cap: Int = 5) -> [Line] {
        let probes = introductionProbes.map(fold)
        var seen = Set<String>()
        var result: [Line] = []
        for line in lines {
            guard result.count < cap else { break }
            let folded = fold(line.text)
            guard probes.contains(where: { folded.contains($0) }),
                  seen.insert("\(line.speaker)|\(line.text)").inserted else { continue }
            result.append(line)
        }
        return result
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// What to review this pass: unchecked suggestions first (the uncertain ones), then unchecked
    /// auto-applied names — a confidently WRONG auto-name is the worst failure, so it gets the LLM
    /// treatment too once the pending queue is drained. One check per voice, capped.
    static func reviewQueue(pending: [IdentityInference], autoApplied: [IdentityInference],
                            checkedKeys: Set<String>, maxChecks: Int) -> [IdentityInference] {
        var seenVoices: Set<String> = []
        var queue: [IdentityInference] = []
        for suggestion in pending + autoApplied where queue.count < maxChecks {
            guard !checkedKeys.contains("\(suggestion.speakerUuid)|\(suggestion.attendeeName)"),
                  seenVoices.insert(suggestion.speakerUuid).inserted else { continue }
            queue.append(suggestion)
        }
        return queue
    }

    // MARK: - Pure: prompt + parsing

    static func buildPrompt(candidate: String?, evidence: [Evidence],
                            introductions: [Line] = [], nameMentions: [Line] = [],
                            nameTokens: [String] = []) -> String {
        let blocks = evidence.map { pack in
            """
            Meeting: \(pack.meetingTitle)
            Invited attendees: \(pack.attendees.joined(separator: ", "))
            Excerpt:
            \(pack.excerpt)
            """
        }.joined(separator: "\n\n")

        var extraSections = ""
        if !introductions.isEmpty {
            extraSections += """


            Self-introduction moments found across this voice's recordings (search for "my name is"-style phrases):
            \(introductions.map(renderLine).joined(separator: "\n"))
            """
        }
        if !nameMentions.isEmpty {
            extraSections += """


            Lines mentioning the candidate's name (searched tokens: \(nameTokens.joined(separator: ", "))):
            \(nameMentions.map(renderLine).joined(separator: "\n"))
            Deduce the direction: when TARGET says this name they are usually addressing or referring to SOMEONE ELSE (unless they are introducing themself); when others say it and TARGET answers, the name is likely TARGET's.
            """
        }

        return """
        You are identifying who a speaker is in meeting recordings, using transcript excerpts.
        The same voice — marked TARGET — appears in these meetings:

        \(blocks)\(extraSections)

        The attendance-based guess is that TARGET is: \(candidate ?? "unknown").
        Look for people addressing TARGET by name, TARGET introducing themself, and role/context clues.
        Note: if someone says a name TO the target, the target is likely that person only when they respond to it; a speaker saying "Casey, can you start?" means SOMEONE ELSE is Casey unless TARGET is the one being asked.

        Reply with a SINGLE JSON object and nothing else, exactly this shape:
        {"person": "<a name or email from the attendee lists, or null if unclear>", "confidence": "high|medium|low", "evidence": "<short quote or reasoning>"}
        Only name a person when the transcript actually supports it; otherwise use null with confidence low.
        """
    }

    struct Verdict: Equatable {
        let person: String?
        let confidence: String
        let evidence: String
    }

    /// Balanced-brace JSON extraction (prose-tolerant); nil when no valid object is present.
    static func parseVerdict(from raw: String) -> Verdict? {
        guard let start = raw.firstIndex(of: "{") else { return nil }
        var depth = 0
        var end: String.Index?
        var index = start
        while index < raw.endIndex {
            let char = raw[index]
            if char == "{" { depth += 1 }
            else if char == "}" {
                depth -= 1
                if depth == 0 { end = index; break }
            }
            index = raw.index(after: index)
        }
        guard let end,
              let payload = try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8)) as? [String: Any] else {
            return nil
        }
        let person = payload["person"] as? String
        return Verdict(person: (person?.isEmpty == true) ? nil : person,
                       confidence: (payload["confidence"] as? String) ?? "low",
                       evidence: (payload["evidence"] as? String) ?? "")
    }

    // MARK: - I/O: evidence collection + review run

    /// Review up to `maxChecks` pending suggestions that have no stored verdict yet. Each check
    /// is one Gemma text call over excerpts from the voice's two most-spoken recordings, plus
    /// self-introduction hits (semantic + literal) and name-mention lines from ALL its recordings.
    @discardableResult
    func reviewPendingSuggestions(maxChecks: Int = 5) async -> Int {
        // Single-flight: this is fired from three uncoordinated triggers (post-transcription
        // recompute, a 300s periodic loop, and the "Verify with AI" button). Without this guard two
        // passes overlap, both acquire the SINGLE-caller-per-consumer `.identityReview`, the arbiter
        // grants both (its `current == c` branch), and TWO Gemma models go resident → the dual-
        // resident Metal OOM the GPU mutex exists to prevent. Test-and-set on the MainActor so the
        // detached callers can't race past it.
        guard await Self.tryBeginReview() else {
            logger.info("[IdentityLLM] Another review pass is already running — skipping")
            return 0
        }
        defer { Task { @MainActor in Self.endReview() } }

        guard LLMTextService.shared.isAvailable else {
            logger.info("[IdentityLLM] Skipped: Gemma text model not available")
            return 0
        }

        // Build the work list BEFORE touching the GPU: this runs on a periodic timer now, and an
        // idle tick must not preempt lower-priority queues (acquiring .insights pauses cleanup).
        // Unmapped suggestions first; then auto-applied (.strong) names, because a confidently
        // wrong auto-name is the original "you = candidate" failure. `.forced` deductions are exempt
        // (logically certain). Manual mappings never appear — the engine treats them as truth.
        let all = IdentityInferenceCoordinator.shared.computeAll()
        let mappedVoices = Set(((try? GRDBSpeakerAttendeeRepository().getAllMappings()) ?? []).map(\.speakerUuid))
        let pending = all.filter { $0.confidence < .strong && !mappedVoices.contains($0.speakerUuid) }
        let autoApplied = all.filter { $0.confidence == .strong }
        let checked: Set<String> = (try? GRDBDatabaseManager.shared.read { db in
            Set(try IdentityLLMVerdictStore.all(db).map { "\($0.speakerUuid)|\($0.suggestedName)" })
        }) ?? []
        let queue = Self.reviewQueue(pending: pending, autoApplied: autoApplied,
                                     checkedKeys: checked, maxChecks: maxChecks)
        guard !queue.isEmpty else { return 0 }   // all checked — the normal idle state, no log spam

        // Same GPU class as other background LLM text work: never compete with an active
        // transcription (two 12B-class models on Metal at once is how we hit OOM before).
        // Suspends until exclusively granted; false = this task was cancelled (preempted) while
        // waiting — skip this pass, the suggestions wait for the next one.
        // Embed the self-introduction probes once per run (brief GPU work), bracketed by the lock.
        guard await GPUResourceManager.shared.acquire(.identityReview) else {
            logger.info("[IdentityLLM] GPU preempted — \(queue.count) unchecked suggestions wait for the next pass")
            return 0
        }
        let probeEmbeddings = await Self.embedIntroProbes()
        await MainActor.run { GPUResourceManager.shared.release(.identityReview) }
        logger.info("[IdentityLLM] Reviewing \(queue.count) (of \(pending.count) pending + \(autoApplied.count) auto-applied)")

        // Resolve speaker uuids → global display names ONCE per pass, so every prompt shows the
        // stable cross-recording identity (real names where known) instead of the local "Speaker N".
        let resolver = nameResolver()

        var reviewed = 0
        for suggestion in queue {
            let candidate = suggestion.attendeeName
            guard let evidence = evidencePack(forVoice: suggestion.speakerUuid, candidateName: candidate, resolver: resolver), !evidence.isEmpty else { continue }
            let recordingIds = voiceRecordingIds(suggestion.speakerUuid)
            let transcriptLines = allLines(recordingIds: recordingIds, voiceUuid: suggestion.speakerUuid, candidateName: candidate, resolver: resolver)
            let tokens = Self.nameSearchTokens(name: suggestion.attendeeName, email: suggestion.attendeeEmail)
            let mentions = Self.mentionLines(in: transcriptLines, tokens: tokens)
            let intros = introductionLines(recordingIds: recordingIds, voiceUuid: suggestion.speakerUuid,
                                           probeEmbeddings: probeEmbeddings, transcriptLines: transcriptLines,
                                           candidateName: candidate, resolver: resolver)
            let prompt = Self.buildPrompt(candidate: suggestion.attendeeName, evidence: evidence,
                                          introductions: intros, nameMentions: mentions, nameTokens: tokens)
            // Bracket each Gemma call individually so a higher-priority consumer can preempt
            // between voices (and so the reviewer never shares the GPU with the insights queue).
            guard await GPUResourceManager.shared.acquire(.identityReview) else { break }
            let raw = try? await LLMTextService.shared.generateText(prompt: prompt, maxTokens: 400)
            await MainActor.run { GPUResourceManager.shared.release(.identityReview) }
            guard let raw, let verdict = Self.parseVerdict(from: raw) else {
                logger.warning("[IdentityLLM] Unparseable identity verdict for voice \(suggestion.speakerUuid.prefix(8))")
                continue
            }
            try? GRDBDatabaseManager.shared.write { db in
                try IdentityLLMVerdictStore.upsert(
                    db, speakerUuid: suggestion.speakerUuid, suggestedName: suggestion.attendeeName,
                    llmPerson: verdict.person, confidence: verdict.confidence, evidence: verdict.evidence)
            }
            reviewed += 1
            logger.info("[IdentityLLM] Voice \(suggestion.speakerUuid.prefix(8)): guess '\(suggestion.attendeeName)' → AI says '\(verdict.person ?? "unclear")' (\(verdict.confidence)) [intros=\(intros.count) mentions=\(mentions.count)]")
        }
        return reviewed
    }

    /// uuid → global display-name resolver, loaded from the speakers table. Built once per review
    /// pass and threaded into every Line builder so the prompt never shows the local "Speaker N".
    private func nameResolver() -> SpeakerNameResolver {
        let speakers = (try? GRDBSpeakerRepository().getAll()) ?? []
        return SpeakerNameResolver(speakers: speakers)
    }

    /// Excerpts + attendee lists from the voice's two most-spoken recordings.
    private func evidencePack(forVoice voiceUuid: String, candidateName: String?, resolver: SpeakerNameResolver) -> [Evidence]? {
        try? GRDBDatabaseManager.shared.read { db in
            let recordingIds = try Int64.fetchAll(db, sql: """
                SELECT recording_id FROM utterances
                WHERE speaker_uuid = ? AND is_hidden = 0
                GROUP BY recording_id ORDER BY COUNT(*) DESC LIMIT 2
            """, arguments: [voiceUuid])

            return try recordingIds.compactMap { recordingId -> Evidence? in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT speaker, speaker_uuid, text FROM utterances
                    WHERE recording_id = ? AND is_hidden = 0
                    ORDER BY utterance_index
                """, arguments: [recordingId])
                let lines = rows.map { row in
                    Self.makeLine(speakerUuid: row["speaker_uuid"], localLabel: row["speaker"],
                                  text: row["text"], voiceUuid: voiceUuid,
                                  candidateName: candidateName, resolver: resolver)
                }
                // 2400 chars/recording: the ±5 window needs headroom or later target windows
                // get truncated by the budget. ~1.3k tokens for two recordings — fine for Gemma.
                let excerpt = Self.excerpt(from: lines, maxCharacters: 2400)
                guard !excerpt.isEmpty else { return nil }

                let meetingRow = try Row.fetchOne(db, sql: """
                    SELECT m.title AS title, m.attendees AS attendees
                    FROM recording_meetings rm JOIN meetings m ON m.id = rm.meeting_id
                    WHERE rm.recording_id = ? LIMIT 1
                """, arguments: [recordingId])
                let recordingTitle = try String.fetchOne(
                    db, sql: "SELECT title FROM recordings WHERE id = ?", arguments: [recordingId])
                let title = (meetingRow?["title"] as String?) ?? recordingTitle ?? "Recording \(recordingId)"
                let attendees = Self.decodeAttendeeNames(meetingRow?["attendees"] as String?)
                return Evidence(meetingTitle: title, attendees: attendees, excerpt: excerpt)
            }
        }
    }

    /// All recordings where this voice speaks, most-spoken first (capped — the searches below
    /// iterate through them, and 30 recordings is plenty of evidence).
    private func voiceRecordingIds(_ voiceUuid: String, limit: Int = 30) -> [Int64] {
        (try? GRDBDatabaseManager.shared.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT recording_id FROM utterances
                WHERE speaker_uuid = ? AND is_hidden = 0
                GROUP BY recording_id ORDER BY COUNT(*) DESC LIMIT ?
            """, arguments: [voiceUuid, limit])
        }) ?? []
    }

    /// Every visible line across the given recordings, in transcript order, TARGET-marked.
    /// Feeds the pure mention/introduction scanners.
    private func allLines(recordingIds: [Int64], voiceUuid: String, candidateName: String?, resolver: SpeakerNameResolver) -> [Line] {
        guard !recordingIds.isEmpty else { return [] }
        let ids = recordingIds.map(String.init).joined(separator: ",")
        return (try? GRDBDatabaseManager.shared.read { db in
            try Row.fetchAll(db, sql: """
                SELECT speaker, speaker_uuid, text FROM utterances
                WHERE recording_id IN (\(ids)) AND is_hidden = 0
                ORDER BY recording_id, utterance_index
            """).map { row in
                Self.makeLine(speakerUuid: row["speaker_uuid"], localLabel: row["speaker"],
                              text: row["text"], voiceUuid: voiceUuid,
                              candidateName: candidateName, resolver: resolver)
            }
        }) ?? []
    }

    /// Self-introduction evidence: literal probe matches merged with the top ANN hits for each
    /// probe embedding, restricted to the voice's recordings. The semantic leg catches paraphrases
    /// and languages the literal list doesn't cover; capped at 5 lines total.
    private func introductionLines(recordingIds: [Int64], voiceUuid: String,
                                   probeEmbeddings: [Data], transcriptLines: [Line],
                                   candidateName: String?, resolver: SpeakerNameResolver) -> [Line] {
        var result = Self.introductionMatches(in: transcriptLines)
        guard !recordingIds.isEmpty, !probeEmbeddings.isEmpty else { return result }
        let repo = GRDBUtteranceRepository()
        for embedding in probeEmbeddings {
            let hits = (try? repo.searchSimilarInRecordings(embedding: embedding,
                                                            recordingIds: recordingIds, limit: 3)) ?? []
            for hit in hits where result.count < 5 {
                let line = Self.makeLine(speakerUuid: hit.utterance.speakerUuid, localLabel: hit.utterance.speaker,
                                         text: hit.utterance.text, voiceUuid: voiceUuid,
                                         candidateName: candidateName, resolver: resolver)
                if !result.contains(line) { result.append(line) }
            }
        }
        return Array(result.prefix(5))
    }

    /// One embedding per introduction probe (tiny model, ~seconds). Empty when the embedding
    /// model isn't loaded — the literal scan still works.
    private static func embedIntroProbes() async -> [Data] {
        guard EmbeddingModelManager.shared.isModelLoaded else { return [] }
        var embeddings: [Data] = []
        for probe in introductionProbes {
            if let data = try? await EmbeddingService.shared.generateEmbedding(for: probe) {
                embeddings.append(data)
            }
        }
        return embeddings
    }

    static func decodeAttendeeNames(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let email = (entry["email"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            if !name.isEmpty && name != email { return email.isEmpty ? name : "\(name) (\(email))" }
            return email.isEmpty ? nil : email
        }
    }
}

// MARK: - Verdict policy (pure)

/// How stored LLM verdicts adjust the attendance-based inferences: only HIGH-confidence verdicts
/// act; agreement promotes one tier (so a confirmed suggestion can auto-apply), disagreement
/// demotes to weak and proposes the person the LLM actually heard.
enum IdentityVerdictPolicy {

    struct Verdict: Equatable {
        let speakerUuid: String
        let suggestedName: String
        let llmPerson: String?
        let confidence: String
        let evidence: String
    }

    static func apply(inferences: [IdentityInference], verdicts: [Verdict]) -> [IdentityInference] {
        let byKey = Dictionary(uniqueKeysWithValues: verdicts.map { ("\($0.speakerUuid)|\($0.suggestedName)", $0) })
        var adjusted: [IdentityInference] = []

        for inference in inferences {
            guard let verdict = byKey["\(inference.speakerUuid)|\(inference.attendeeName)"],
                  verdict.confidence == "high", let person = verdict.llmPerson else {
                adjusted.append(inference)
                continue
            }

            if personsMatch(person, inference.attendeeName) {
                let promoted = min(IdentityInference.Tier(rawValue: inference.confidence.rawValue + 1) ?? inference.confidence,
                                   .strong)
                adjusted.append(IdentityInference(
                    speakerUuid: inference.speakerUuid, attendeeName: inference.attendeeName,
                    attendeeEmail: inference.attendeeEmail, confidence: promoted,
                    reason: inference.reason + " · AI confirmed: “\(verdict.evidence.prefix(80))”",
                    score: max(inference.score, 0.9)))
            } else {
                adjusted.append(IdentityInference(
                    speakerUuid: inference.speakerUuid, attendeeName: inference.attendeeName,
                    attendeeEmail: inference.attendeeEmail, confidence: .weak,
                    reason: inference.reason + " — AI heard otherwise", score: inference.score))
                adjusted.append(IdentityInference(
                    speakerUuid: inference.speakerUuid, attendeeName: person, attendeeEmail: nil,
                    confidence: .likely,
                    reason: "AI heard it in the call: “\(verdict.evidence.prefix(80))”",
                    score: 0.7))
            }
        }
        return adjusted
    }

    /// Compare display names and email local-parts after folding case/diacritics and tokenizing.
    /// One normalized token set must contain the other.
    static func personsMatch(_ a: String, _ b: String) -> Bool {
        let tokensA = nameTokens(a)
        let tokensB = nameTokens(b)
        guard !tokensA.isEmpty, !tokensB.isEmpty else { return false }
        return tokensA.isSubset(of: tokensB) || tokensB.isSubset(of: tokensA)
    }

    private static func nameTokens(_ raw: String) -> Set<String> {
        var text = raw.lowercased()
        if let atIndex = text.firstIndex(of: "@") {
            text = String(text[..<atIndex])   // email → local part
        }
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return Set(folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            .filter { $0.count > 1 }
    }
}

// MARK: - Verdict persistence (v27)

enum IdentityLLMVerdictStore {

    static let tableName = "identity_llm_verdicts"

    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS \(tableName) (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                speaker_uuid TEXT NOT NULL,
                suggested_name TEXT NOT NULL,
                llm_person TEXT,
                confidence TEXT NOT NULL,
                evidence TEXT NOT NULL DEFAULT '',
                checked_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                UNIQUE(speaker_uuid, suggested_name)
            )
        """)
    }

    static func upsert(_ db: Database, speakerUuid: String, suggestedName: String,
                       llmPerson: String?, confidence: String, evidence: String) throws {
        guard try db.tableExists(tableName) else { return }
        try db.execute(sql: """
            INSERT INTO \(tableName) (speaker_uuid, suggested_name, llm_person, confidence, evidence, checked_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(speaker_uuid, suggested_name) DO UPDATE SET
                llm_person = excluded.llm_person, confidence = excluded.confidence,
                evidence = excluded.evidence, checked_at = excluded.checked_at
        """, arguments: [speakerUuid, suggestedName, llmPerson, confidence, evidence, Date()])
    }

    static func all(_ db: Database) throws -> [IdentityVerdictPolicy.Verdict] {
        guard try db.tableExists(tableName) else { return [] }
        return try Row.fetchAll(db, sql: "SELECT * FROM \(tableName)").map { row in
            IdentityVerdictPolicy.Verdict(speakerUuid: row["speaker_uuid"],
                                          suggestedName: row["suggested_name"],
                                          llmPerson: row["llm_person"],
                                          confidence: row["confidence"],
                                          evidence: row["evidence"])
        }
    }
}
