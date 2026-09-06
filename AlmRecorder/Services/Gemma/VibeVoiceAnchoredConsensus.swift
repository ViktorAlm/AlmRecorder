import Foundation

/// Text-only repair over immutable VibeVoice native turns.
///
/// VibeVoice owns every output segment's timestamps and recording-local speaker label. Whisper is
/// projected into those turns using its own timestamped utterances. Gemma may correct or combine
/// the two text candidates inside each turn, but it never receives audio and can never change
/// timestamps, speaker labels, turn ordering, splits, or merges.
struct VibeVoiceAnchoredConsensusFinalizer {
    typealias ProgressHandler = @Sendable (NightlyQualityTelemetry) async -> Void
    typealias CheckpointHandler = @Sendable (
        NightlyQualityCandidate?,
        NightlyQualityCandidate?,
        NightlyQualityTelemetry,
        [NightlyQualityLLMTrace]
    ) async -> Void

    enum Choice: String, Codable, Equatable {
        case vibeVoice = "vibevoice"
        case whisper
        case combined
    }

    struct Repair: Equatable {
        let text: String
        let basis: Choice
    }

    struct Turn: Equatable {
        let id: Int
        let vibeVoice: NightlyQualityCandidateSegment
        let projectedWhisper: String?
        /// The committed foreground is context only and never an output choice. Protected edits
        /// deliberately fall back to raw ASR so private-gold answers cannot leak into the prompt.
        var projectedForegroundRawContext: String? = nil
        var projectedForegroundCleanContext: String? = nil
        let supportingUtteranceIDs: [Int64]
        let whisperSelectable: Bool

        /// Source-compatible alias for v5 tests and persisted design terminology.
        var projectedWhisperCleanContext: String? {
            projectedForegroundCleanContext
        }

        init(
            id: Int,
            vibeVoice: NightlyQualityCandidateSegment,
            projectedWhisper: String?,
            projectedWhisperCleanContext: String? = nil,
            projectedForegroundRawContext: String? = nil,
            projectedForegroundCleanContext: String? = nil,
            supportingUtteranceIDs: [Int64],
            whisperSelectable: Bool
        ) {
            self.id = id
            self.vibeVoice = vibeVoice
            self.projectedWhisper = projectedWhisper
            self.projectedForegroundRawContext = projectedForegroundRawContext
            self.projectedForegroundCleanContext =
                projectedForegroundCleanContext ?? projectedWhisperCleanContext
            self.supportingUtteranceIDs = supportingUtteranceIDs
            self.whisperSelectable = whisperSelectable
        }
    }

    struct Batch: Equatable {
        let targets: [Turn]
        let contextBefore: [Turn]
        let contextAfter: [Turn]
    }

    private struct RepairEnvelope: Decodable {
        let text: String
        let basis: String
    }

    let maximumInputTokens: Int
    let modelKey: String
    let strategy: ConsensusRepairStrategy

    init(
        maximumInputTokens: Int,
        modelKey: String,
        strategy: ConsensusRepairStrategy = .coherentVerbatim
    ) {
        self.maximumInputTokens = maximumInputTokens
        self.modelKey = modelKey
        self.strategy = strategy
    }

    func finalize(
        artifact: NightlyQualityArtifact,
        language: String?,
        onProgress: ProgressHandler? = nil,
        onCheckpoint: CheckpointHandler? = nil
    ) async throws -> GemmaFinalizationResult {
        guard let vibeVoice = artifact.vibeVoice else {
            throw TranscriptionError.transcriptionFailed(
                "The VibeVoice candidate is missing"
            )
        }
        guard let whisper = artifact.whisperCandidate else {
            throw TranscriptionError.transcriptionFailed(
                "The independent Whisper candidate is missing"
            )
        }
        let turns = makeTurns(
            vibeVoice: vibeVoice.segments,
            whisper: whisper.segments,
            foreground: artifact.whisper.segments
        )
        guard !turns.isEmpty else {
            return GemmaFinalizationResult(
                decisions: [],
                blindCandidate: nil,
                fusedCandidate: makeCandidate(segments: []),
                cumulativeInputTokens: 0,
                peakRAMBytes: nil,
                textTraces: []
            )
        }

        let batches = makeBatches(turns: turns, language: language)
        let telemetryState = NightlyQualityTelemetryState(
            NightlyQualityTelemetry(
                maximumInputTokens: min(maximumInputTokens, Self.maximumTextContextTokens),
                totalWindows: max(1, batches.count),
                estimatedModelPeakBytes: TranscriptionResourceProfile
                    .gemmaText(modelKey)
                    .estimatedPeakBytes
            )
        )
        var completed: [NightlyQualityCandidateSegment] = []
        var completedByTurnID: [Int: NightlyQualityCandidateSegment] = [:]
        var cumulativeInputTokens = 0
        var textTraces: [NightlyQualityLLMTrace] = []

        for (batchIndex, batch) in batches.enumerated() {
            try Task.checkCancellation()
            let prompt = buildPrompt(
                batch: batch,
                previousConsensus: completedByTurnID,
                language: language
            )
            let inputTokens = GemmaInputBudget.estimatedInputTokens(prompt: prompt)
            cumulativeInputTokens += inputTokens
            await telemetryState.updatePhase(
                currentClip: batchIndex + 1,
                totalClips: batches.count,
                phase: "Repairing text inside locked VibeVoice turns"
            )
            await telemetryState.updateWork(
                currentTokens: inputTokens,
                cumulativeTokens: cumulativeInputTokens,
                completedWindows: batchIndex
            )
            await onProgress?(await telemetryState.snapshot())

            let raw = try await LLMTextService.shared.generateText(
                prompt: prompt,
                modelKey: modelKey,
                maxTokens: maximumOutputTokens(for: batch)
            )
            let target = batch.targets[0]
            var repair = Self.parseRepair(raw)
            textTraces.append(
                NightlyQualityLLMTrace(
                    batchIndex: batchIndex + 1,
                    attempt: 1,
                    targetIDs: batch.targets.map(\.id),
                    prompt: prompt,
                    response: raw,
                    parsedSuccessfully: repair != nil,
                    strategy: strategy,
                    instructionSummary: strategy.shortDescription,
                    target: traceTurn(target, position: "target"),
                    contextBefore: batch.contextBefore.map {
                        traceTurn(
                            $0,
                            position: "before",
                            previousConsensus: completedByTurnID[$0.id]
                        )
                    },
                    contextAfter: batch.contextAfter.map {
                        traceTurn($0, position: "after")
                    }
                )
            )
            if repair == nil {
                VoxtralLogger.shared.warning(
                    "[NightlyConsensus] Invalid repair response "
                        + "(\(Self.responseDiagnostic(raw))); retrying target turn \(target.id)"
                )
                await telemetryState.updatePhase(
                    currentClip: batchIndex + 1,
                    totalClips: batches.count,
                    phase: "Retrying invalid text repair in smaller batches"
                )
                await onProgress?(await telemetryState.snapshot())
                let retry = try await retryRepairs(
                    batch: batch,
                    batchIndex: batchIndex + 1,
                    previousConsensus: completedByTurnID,
                    language: language
                )
                repair = retry.repair
                textTraces.append(contentsOf: retry.traces)
                cumulativeInputTokens += retry.inputTokens
                await telemetryState.updateWork(
                    currentTokens: inputTokens,
                    cumulativeTokens: cumulativeInputTokens,
                    completedWindows: batchIndex
                )
            }
            if repair == nil {
                VoxtralLogger.shared.warning(
                    "[NightlyConsensus] Preserving VibeVoice after invalid repair for turn "
                        + "\(target.id)"
                )
            }
            let resolvedBatch = [
                resolvedSegment(
                    turn: target,
                    repair: repair,
                    invalidResponse: repair == nil
                )
            ]
            if let traceIndex = textTraces.indices.last {
                let segment = resolvedBatch[0]
                let scores = repair.map {
                    Self.combinedEvidenceScores($0.text, for: target)
                }
                let rejectedByGuard =
                    segment.source?.contains("fallback") == true
                    || segment.source == "overlap_guard_vibevoice"
                textTraces[traceIndex].evidenceAccepted =
                    repair != nil && !rejectedByGuard
                textTraces[traceIndex].evidenceTrigramCoverage = scores?.trigram
                textTraces[traceIndex].evidenceBigramCoverage = scores?.bigram
                textTraces[traceIndex].resolutionSource = segment.source
            }
            completed.append(contentsOf: resolvedBatch)
            for (turn, segment) in zip(batch.targets, resolvedBatch) {
                completedByTurnID[turn.id] = segment
            }

            await telemetryState.updateWork(
                currentTokens: inputTokens,
                cumulativeTokens: cumulativeInputTokens,
                completedWindows: batchIndex + 1
            )
            let checkpointTelemetry = await telemetryState.snapshot()
            await onProgress?(checkpointTelemetry)
            await onCheckpoint?(
                nil,
                makeCandidate(segments: completed),
                checkpointTelemetry,
                textTraces
            )
        }

        let candidate = makeCandidate(segments: completed)
        return GemmaFinalizationResult(
            decisions: oneToOneDecisions(
                baseline: artifact.whisper.segments,
                consensus: candidate.segments
            ),
            blindCandidate: nil,
            fusedCandidate: candidate,
            cumulativeInputTokens: cumulativeInputTokens,
            peakRAMBytes: nil,
            textTraces: textTraces
        )
    }

    func makeTurns(
        vibeVoice: [NightlyQualityCandidateSegment],
        whisper: [NightlyQualityCandidateSegment],
        foreground: [NightlyQualityCandidateSegment]? = nil
    ) -> [Turn] {
        let timedRawWords = Self.timedWhisperWords(whisper, textKind: .raw)
        let contextSegments = foreground ?? whisper
        let timedForegroundRawWords = Self.timedWhisperWords(
            contextSegments,
            textKind: .raw
        )
        let timedForegroundCleanWords = Self.timedWhisperWords(
            contextSegments,
            textKind: .cleanContext
        )
        let sortedVibeVoice = vibeVoice
            .sorted {
                $0.startTime != $1.startTime
                    ? $0.startTime < $1.startTime
                    : $0.endTime < $1.endTime
            }
        return sortedVibeVoice
            .enumerated()
            .map { index, segment in
                let overlapping = contextSegments.filter {
                    $0.endTime > segment.startTime && $0.startTime < segment.endTime
                }
                let hasSimultaneousNativeTurn = sortedVibeVoice.enumerated().contains {
                    otherIndex, other in
                    guard otherIndex != index else { return false }
                    let overlap = min(segment.endTime, other.endTime)
                        - max(segment.startTime, other.startTime)
                    return overlap >= Self.minimumSimultaneousTurnOverlap
                }
                let projectedWords = timedRawWords.filter { word in
                    let midpoint = word.start + max(0, word.end - word.start) / 2
                    return segment.startTime <= midpoint && midpoint < segment.endTime
                }
                let projectedForegroundRawWords = timedForegroundRawWords.filter { word in
                    let midpoint = word.start + max(0, word.end - word.start) / 2
                    return segment.startTime <= midpoint && midpoint < segment.endTime
                }
                let projectedForegroundCleanWords = timedForegroundCleanWords.filter { word in
                    let midpoint = word.start + max(0, word.end - word.start) / 2
                    return segment.startTime <= midpoint && midpoint < segment.endTime
                }
                let projected = projectedWords
                    .map(\.text)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let projectedForegroundRaw = projectedForegroundRawWords
                    .map(\.text)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let projectedForegroundClean = projectedForegroundCleanWords
                    .map(\.text)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return Turn(
                    id: index,
                    vibeVoice: segment,
                    projectedWhisper: projected.isEmpty ? nil : projected,
                    projectedForegroundRawContext: projectedForegroundRaw.isEmpty
                        ? nil
                        : projectedForegroundRaw,
                    projectedForegroundCleanContext: projectedForegroundClean.isEmpty
                        ? nil
                        : projectedForegroundClean,
                    supportingUtteranceIDs: overlapping.compactMap(\.utteranceID),
                    // One timestamp-projected Whisper stream cannot safely identify which words
                    // belong to which simultaneous native speaker. Keep VibeVoice's own text for
                    // these turns instead of duplicating one sentence across multiple speakers.
                    whisperSelectable: !hasSimultaneousNativeTurn
                )
            }
    }

    func buildPrompt(turns: [Turn], language: String?) -> String {
        buildPrompt(
            batch: Batch(targets: turns, contextBefore: [], contextAfter: []),
            previousConsensus: [:],
            language: language
        )
    }

    func buildPrompt(
        batch: Batch,
        previousConsensus: [Int: NightlyQualityCandidateSegment],
        language: String?
    ) -> String {
        let targets: [[String: Any]] = batch.targets.map { turn in
            let foregroundRaw: Any
            if let raw = turn.projectedForegroundRawContext ?? turn.projectedWhisper {
                foregroundRaw = raw
            } else {
                foregroundRaw = NSNull()
            }
            return [
                "id": turn.id,
                "start": turn.vibeVoice.startTime,
                "end": turn.vibeVoice.endTime,
                "speaker": turn.vibeVoice.speakerLabel ?? "",
                "vibevoice": turn.vibeVoice.text,
                "whisper": turn.projectedWhisper ?? NSNull(),
                "foreground_raw_context": foregroundRaw,
                "foreground_clean_context":
                    turn.projectedForegroundCleanContext ?? NSNull(),
                "whisper_selectable": turn.whisperSelectable
            ]
        }
        let contextBefore = batch.contextBefore.map {
            contextPayload(
                turn: $0,
                position: "before",
                previousConsensus: previousConsensus[$0.id],
                includeCleanForeground: true
            )
        }
        let contextAfter = batch.contextAfter.map {
            contextPayload(
                turn: $0,
                position: "after",
                previousConsensus: nil,
                includeCleanForeground: false
            )
        }
        let data = try? JSONSerialization.data(
            withJSONObject: [
                "context_before": contextBefore,
                "targets": targets,
                "context_after": contextAfter
            ],
            options: [.sortedKeys]
        )
        let json = data.flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"context_before":[],"targets":[],"context_after":[]}"#
        let languageInstruction = language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
            ?? "the recording's original language"
        return """
        Produce the best transcript text for the single target VibeVoice speaker turn. \
        The language setting is \(languageInstruction); preserve the language actually spoken. \
        Timestamps, turn boundaries, ordering, and speaker labels are immutable. Repair only the \
        text inside each target turn. You may select VibeVoice, select Whisper, or combine evidence \
        from both candidates and conversational context.

        Repair strategy: \(strategy.displayName).
        \(strategy.promptInstruction)

        Never summarize, translate, censor, add facts, invent content, or move words between turns. \
        Every name, number, claim, and meaningful word in the result must be supported by VibeVoice, \
        Whisper, or the supplied conversational context.

        Use context_before and context_after only to understand language, names, objects, topic, \
        and conversational flow. The raw, cleaned, and previous-consensus context versions are \
        evidence only; never emit a repair for a context id. Whisper text is a timestamp projection \
        and can contain words from a neighbouring turn. Use only words that belong inside the \
        target's exact interval. When whisper_selectable is false, return the VibeVoice text exactly \
        because simultaneous speakers make the Whisper projection unsafe.

        targets contains exactly one turn. Return only the final repaired transcript text for that \
        target as one plain-text line. Do not return JSON, Markdown fences, a speaker label, an id, \
        a prefix, or an explanation.

        \(json)
        """
    }

    private func contextPayload(
        turn: Turn,
        position: String,
        previousConsensus: NightlyQualityCandidateSegment?,
        includeCleanForeground: Bool
    ) -> [String: Any] {
        let cleanForeground: Any
        if includeCleanForeground, let clean = turn.projectedForegroundCleanContext {
            cleanForeground = clean
        } else {
            cleanForeground = NSNull()
        }
        let rawForeground: Any
        if let raw = turn.projectedForegroundRawContext ?? turn.projectedWhisper {
            rawForeground = raw
        } else {
            rawForeground = NSNull()
        }
        return [
            "id": turn.id,
            "position": position,
            "start": turn.vibeVoice.startTime,
            "end": turn.vibeVoice.endTime,
            "speaker": turn.vibeVoice.speakerLabel ?? "",
            "vibevoice_raw": turn.vibeVoice.text,
            "whisper_raw": turn.projectedWhisper ?? NSNull(),
            "foreground_raw": rawForeground,
            "foreground_clean": cleanForeground,
            "previous_consensus": previousConsensus?.text ?? NSNull()
        ]
    }

    private func traceTurn(
        _ turn: Turn,
        position: String,
        previousConsensus: NightlyQualityCandidateSegment? = nil
    ) -> NightlyQualityTraceTurn {
        NightlyQualityTraceTurn(
            id: turn.id,
            position: position,
            startTime: turn.vibeVoice.startTime,
            endTime: turn.vibeVoice.endTime,
            speaker: turn.vibeVoice.speakerLabel,
            vibeVoice: turn.vibeVoice.text,
            whisper: turn.projectedWhisper,
            foregroundRaw: turn.projectedForegroundRawContext,
            foregroundClean: turn.projectedForegroundCleanContext,
            previousConsensus: previousConsensus?.text,
            whisperSelectable: position == "target" ? turn.whisperSelectable : nil
        )
    }

    static func parseRepair(_ output: String) -> Repair? {
        // Tolerate a legacy JSON-shaped answer during upgrades, but the production prompt asks
        // for plain transcript text because a single target needs no IDs or structured array.
        if let json = firstJSONObject(in: output),
           let data = json.data(using: .utf8),
           let envelope = try? JSONDecoder().decode(RepairEnvelope.self, from: data) {
            let text = envelope.text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  let basis = Choice(rawValue: envelope.basis.lowercased()) else {
                return nil
            }
            return Repair(text: text, basis: basis)
        }

        var text = output
            .replacingOccurrences(of: "[end of text]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(
            of: #"^\s*```(?:text|plaintext)?\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: #"\s*```\s*$"#,
            with: "",
            options: .regularExpression
        )
        text = text
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              !looksLikeRefusal(text) else {
            return nil
        }
        return Repair(text: text, basis: .combined)
    }

    func makeBatches(
        turns: [Turn],
        language: String?
    ) -> [Batch] {
        let limit = min(maximumInputTokens, Self.maximumTextContextTokens)
        var batches: [Batch] = []
        var start = 0
        while start < turns.count {
            var acceptedEnd = start + 1
            var proposedEnd = acceptedEnd
            while proposedEnd <= turns.count,
                  proposedEnd - start <= Self.maximumTargetsPerBatch {
                let proposed = makeBatch(
                    turns: turns,
                    targetRange: start..<proposedEnd
                )
                let estimate = GemmaInputBudget.estimatedInputTokens(
                    prompt: buildPrompt(
                        batch: proposed,
                        previousConsensus: [:],
                        language: language
                    )
                )
                if proposedEnd > start + 1,
                   estimate > limit - Self.outputTokenReserve {
                    break
                }
                acceptedEnd = proposedEnd
                proposedEnd += 1
            }
            batches.append(
                makeBatch(turns: turns, targetRange: start..<acceptedEnd)
            )
            start = acceptedEnd
        }
        return batches
    }

    private func makeBatch(
        turns: [Turn],
        targetRange: Range<Int>
    ) -> Batch {
        let beforeStart = max(0, targetRange.lowerBound - Self.contextTurnCount)
        let afterEnd = min(turns.count, targetRange.upperBound + Self.contextTurnCount)
        return Batch(
            targets: Array(turns[targetRange]),
            contextBefore: Array(turns[beforeStart..<targetRange.lowerBound]),
            contextAfter: Array(turns[targetRange.upperBound..<afterEnd])
        )
    }

    func resolvedSegment(
        turn: Turn,
        repair: Repair?,
        invalidResponse: Bool
    ) -> NightlyQualityCandidateSegment {
        let resolution: (text: String, source: String, confidence: String)
        if invalidResponse || repair == nil {
            resolution = (
                turn.vibeVoice.text,
                "llm_invalid_fallback_vibevoice",
                "high"
            )
        } else if !turn.whisperSelectable {
            resolution = (
                turn.vibeVoice.text,
                "overlap_guard_vibevoice",
                "high"
            )
        } else if let repair,
                  Self.isSafeRepair(repair.text, for: turn, strategy: strategy) {
            guard Self.hasMinimumNGramEvidence(
                repair.text,
                for: turn,
                strategy: strategy
            ) else {
                return NightlyQualityCandidateSegment(
                    utteranceID: nil,
                    startTime: turn.vibeVoice.startTime,
                    endTime: turn.vibeVoice.endTime,
                    text: turn.vibeVoice.text,
                    speakerUUID: turn.vibeVoice.speakerUUID,
                    speakerLabel: turn.vibeVoice.speakerLabel,
                    userProtected: false,
                    confidence: "high",
                    source: "llm_low_ngram_fallback_vibevoice",
                    supportingUtteranceIDs: turn.supportingUtteranceIDs,
                    alignmentMethod: "vibevoice_native_turn_locked"
                )
            }
            let source: String
            if Self.equivalent(repair.text, turn.vibeVoice.text) {
                source = "llm_repair_vibevoice"
            } else if let whisper = turn.projectedWhisper,
                      Self.equivalent(repair.text, whisper) {
                source = "llm_repair_whisper"
            } else {
                source = "llm_repair_combined"
            }
            resolution = (repair.text, source, "medium")
        } else {
            resolution = (
                turn.vibeVoice.text,
                "llm_unsafe_repair_fallback_vibevoice",
                "high"
            )
        }
        return NightlyQualityCandidateSegment(
            utteranceID: nil,
            startTime: turn.vibeVoice.startTime,
            endTime: turn.vibeVoice.endTime,
            text: resolution.text,
            speakerUUID: turn.vibeVoice.speakerUUID,
            speakerLabel: turn.vibeVoice.speakerLabel,
            userProtected: false,
            confidence: resolution.confidence,
            source: resolution.source,
            supportingUtteranceIDs: turn.supportingUtteranceIDs,
            alignmentMethod: "vibevoice_native_turn_locked"
        )
    }

    private func makeCandidate(
        segments: [NightlyQualityCandidateSegment]
    ) -> NightlyQualityCandidate {
        let settings = try? JSONSerialization.data(
            withJSONObject: [
                "audio_input": false,
                "structure_owner": "vibevoice_native",
                "text_operation": strategy.rawValue,
                "repair_strategy": strategy.rawValue,
                "prompt_version": strategy.promptVersion,
                "allowed_evidence": ["vibevoice", "whisper", "context"],
                "whisper_source": "fresh_independent_candidate",
                "foreground_source": "context_only",
                "context_turns_before": Self.contextTurnCount,
                "context_turns_after": Self.contextTurnCount,
                "context_includes_raw_and_clean_previous": true,
                "minimum_combined_evidence_trigram_coverage":
                    strategy.minimumCombinedTrigramCoverage,
                "minimum_combined_evidence_bigram_coverage":
                    strategy.minimumCombinedBigramCoverage,
                "timestamps_mutable": false,
                "speakers_mutable": false
            ],
            options: [.sortedKeys]
        )
        return NightlyQualityCandidate(
            engine: .fused,
            model: "Gemma \(strategy.displayName) · VibeVoice native structure",
            createdAt: Date(),
            segments: segments,
            provenance: NightlyQualityCandidateProvenance(
                role: "vibevoice_anchored_text_consensus",
                engineIdentifier: "gemma_text_repair",
                modelIdentifier: modelKey,
                modelRevision: nil,
                runtimeRevision: nil,
                settingsJSON: settings.flatMap { String(data: $0, encoding: .utf8) },
                sourceRevisionDate: Date(),
                certainty: .exact
            )
        )
    }

    private func oneToOneDecisions(
        baseline: [NightlyQualityCandidateSegment],
        consensus: [NightlyQualityCandidateSegment]
    ) -> [NightlyQualityDecision] {
        let baselineByID = Dictionary(
            uniqueKeysWithValues: baseline.compactMap { segment in
                segment.utteranceID.map { ($0, segment) }
            }
        )
        return consensus.compactMap { segment in
            guard segment.supportingUtteranceIDs?.count == 1,
                  let id = segment.supportingUtteranceIDs?.first,
                  let original = baselineByID[id],
                  !original.userProtected else {
                return nil
            }
            let matches = consensus.filter { $0.supportingUtteranceIDs == [id] }
            guard matches.count == 1 else { return nil }
            return NightlyQualityDecision(
                utteranceID: id,
                originalText: original.text,
                finalText: segment.text,
                // Text-only model selection is useful benchmark evidence, but without forced
                // acoustic alignment it must never cross the automatic-commit "high" gate.
                confidence: "medium",
                source: segment.source ?? "vibevoice_anchored_consensus",
                estimatedInputTokens: 0
            )
        }
    }

    private enum WhisperTextKind {
        case raw
        case cleanContext
    }

    private static func timedWhisperWords(
        _ segments: [NightlyQualityCandidateSegment],
        textKind: WhisperTextKind
    ) -> [(text: String, start: TimeInterval, end: TimeInterval)] {
        var allWords: [(text: String, start: TimeInterval, end: TimeInterval)] = []
        for segment in segments {
            let rawText = segment.originalASRText ?? segment.text
            let sourceText: String
            switch textKind {
            case .raw:
                sourceText = rawText
            case .cleanContext:
                sourceText = segment.userProtected ? rawText : segment.text
            }
            let words = sourceText.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty, segment.endTime > segment.startTime else { continue }
            let weights = words.map { max(1, $0.unicodeScalars.count) }
            let totalWeight = max(1, weights.reduce(0, +))
            let duration = segment.endTime - segment.startTime
            var cursor = segment.startTime
            for (index, word) in words.enumerated() {
                let start = cursor
                let weightFraction = Double(weights[index]) / Double(totalWeight)
                let end: TimeInterval
                if index == words.count - 1 {
                    end = segment.endTime
                } else {
                    end = start + duration * weightFraction
                }
                allWords.append((text: word, start: start, end: end))
                cursor = end
            }
        }
        return allWords.sorted {
            $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end
        }
    }

    private static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private func maximumOutputTokens(for batch: Batch) -> Int {
        let candidateCharacters = batch.targets.reduce(0) { partial, turn in
            partial + max(
                turn.vibeVoice.text.count,
                turn.projectedWhisper?.count ?? 0
            )
        }
        // Swedish and English ASR text are normally 3–4 characters/token. JSON escaping, keys,
        // and conservative repairs need additional room. A truncated JSON object is unusable.
        let estimate = candidateCharacters / 2 + 96
        return min(512, max(96, estimate))
    }

    private func retryRepairs(
        batch: Batch,
        batchIndex: Int,
        previousConsensus: [Int: NightlyQualityCandidateSegment],
        language: String?
    ) async throws -> (
        repair: Repair?,
        inputTokens: Int,
        traces: [NightlyQualityLLMTrace]
    ) {
        let prompt = buildPrompt(
            batch: batch,
            previousConsensus: previousConsensus,
            language: language
        )
        let retryInputTokens = GemmaInputBudget.estimatedInputTokens(prompt: prompt)
        let raw = try await LLMTextService.shared.generateText(
            prompt: prompt,
            modelKey: modelKey,
            maxTokens: maximumOutputTokens(for: batch)
        )
        let repair = Self.parseRepair(raw)
        let trace = NightlyQualityLLMTrace(
            batchIndex: batchIndex,
            attempt: 2,
            targetIDs: batch.targets.map(\.id),
            prompt: prompt,
            response: raw,
            parsedSuccessfully: repair != nil,
            strategy: strategy,
            instructionSummary: strategy.shortDescription,
            target: batch.targets.first.map { traceTurn($0, position: "target") },
            contextBefore: batch.contextBefore.map {
                traceTurn(
                    $0,
                    position: "before",
                    previousConsensus: previousConsensus[$0.id]
                )
            },
            contextAfter: batch.contextAfter.map {
                traceTurn($0, position: "after")
            }
        )
        return (repair, retryInputTokens, [trace])
    }

    private static func isSafeRepair(
        _ proposed: String,
        for turn: Turn,
        strategy: ConsensusRepairStrategy
    ) -> Bool {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("<|"),
              !looksLikeRefusal(trimmed) else {
            return false
        }

        let candidates = [turn.vibeVoice.text, turn.projectedWhisper]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let longestCharacters = candidates.map(\.count).max(),
              let longestWords = candidates.map({ normalizedWords($0).count }).max()
        else {
            return false
        }
        let proposedWords = normalizedWords(trimmed)
        guard !proposedWords.isEmpty,
              trimmed.count <= max(
                  80,
                  Int(Double(longestCharacters) * strategy.maximumCharacterMultiplier) + 32
              ),
              proposedWords.count <= max(
                  12,
                  Int(Double(longestWords) * strategy.maximumWordMultiplier) + 4
              )
        else {
            return false
        }
        return true
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func hasMinimumNGramEvidence(
        _ proposed: String,
        for turn: Turn,
        strategy: ConsensusRepairStrategy
    ) -> Bool {
        let scores = combinedEvidenceScores(proposed, for: turn)
        return scores.trigram >= strategy.minimumCombinedTrigramCoverage
            || scores.bigram >= strategy.minimumCombinedBigramCoverage
    }

    private static func combinedEvidenceScores(
        _ proposed: String,
        for turn: Turn
    ) -> (trigram: Double, bigram: Double) {
        let candidates = [turn.vibeVoice.text, turn.projectedWhisper]
            .compactMap { $0 }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return (
            combinedEvidenceCoverage(
                proposed,
                candidates: candidates,
                width: 3
            ),
            combinedEvidenceCoverage(
                proposed,
                candidates: candidates,
                width: 2
            )
        )
    }

    private static func combinedEvidenceCoverage(
        _ proposed: String,
        candidates: [String],
        width: Int
    ) -> Double {
        let proposedGrams = nGrams(normalizedCharacters(proposed), width: width)
        guard !proposedGrams.isEmpty else { return 0 }
        let combinedEvidence = candidates.reduce(into: Set<String>()) { partial, candidate in
            partial.formUnion(nGrams(normalizedCharacters(candidate), width: width))
        }
        return Double(proposedGrams.intersection(combinedEvidence).count)
            / Double(proposedGrams.count)
    }

    private static func normalizedCharacters(_ text: String) -> [Character] {
        Array(
            text.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: nil
            )
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        )
    }

    private static func nGrams(_ characters: [Character], width: Int) -> Set<String> {
        guard characters.count >= width else { return [] }
        return Set(
            (0...(characters.count - width)).map { start in
                String(characters[start..<(start + width)])
            }
        )
    }

    private static func equivalent(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(
                rhs.trimmingCharacters(in: .whitespacesAndNewlines)
            ) == .orderedSame
    }

    private static func looksLikeRefusal(_ text: String) -> Bool {
        let normalized = text.lowercased()
        let markers = [
            "no audio file",
            "audio is not attached",
            "provide the audio",
            "upload the audio",
            "i cannot transcribe",
            "i can't transcribe",
            "i’m unable to transcribe"
        ]
        return markers.contains { normalized.contains($0) }
    }

    private static func responseDiagnostic(_ output: String) -> String {
        return "chars=\(output.count), validPlainText=\(parseRepair(output) != nil)"
    }

    private static let maximumTextContextTokens = 12_000
    private static let outputTokenReserve = 4_096
    private static let contextTurnCount = 3
    private static let maximumTargetsPerBatch = 1
    private static let minimumSimultaneousTurnOverlap: TimeInterval = 0.35
}

extension ConsensusRepairStrategy {
    var promptInstruction: String {
        switch self {
        case .evidenceRepair:
            return "Make the smallest evidence-supported correction. Fix recognition errors, "
                + "spelling, punctuation, names, numbers, and terminology, but preserve wording, "
                + "hesitations, repetitions, silence markers, and incomplete speech."
        case .coherentVerbatim:
            return "Reconstruct what the speaker most likely actually said. Resolve phonetic ASR "
                + "mishearings and broken fragments using both candidates plus nearby context. "
                + "Produce a coherent grammatical spoken sentence with proper punctuation while "
                + "preserving meaning, details, tone, and meaningful hesitations."
        case .readableReconstruction:
            return """
            Act as a careful transcript editor, not a verbatim copier. First reconstruct the \
            speaker's intended meaning silently from both ASR candidates and the nearby \
            conversation. Then output fully grammatical, coherent, natural spoken language.

            Every returned sentence MUST make sense. Fix ALL broken word order, agreement, false \
            starts, sentence fragments, and nonsensical or phonetically misheard words. Do not \
            preserve an error merely because one or both ASR candidates contain it. Use context to \
            choose the most plausible intended word, including names and domain terms. You may \
            reorder and inflect words, join fragments, remove filler and abandoned starts, and \
            repair punctuation.

            Examples of the required editing freedom:
            BROKEN: "Sen är jag kanske tar bort den här kolumnen."
            CLEAN: "Sen kanske jag tar bort den här kolumnen."
            BROKEN: "Så det jag, vad, det jag liksom. Kört som capabilities."
            CLEAN: "Så det jag har kört som capabilities."
            BROKEN: "The plan, what we, the plan is maybe launch."
            CLEAN: "The plan is that we might launch."

            Before answering, silently review your draft. If its grammar, word order, or meaning is \
            still broken, rewrite it again. Preserve every supported fact, detail, intent, and \
            uncertainty. Do not summarize or introduce new information. Return only the proper \
            cleaned transcript, never an explanation of your edits.
            """
        }
    }

    var promptVersion: Int {
        switch self {
        case .evidenceRepair, .coherentVerbatim: return 1
        case .readableReconstruction: return 5
        }
    }

    var maximumCharacterMultiplier: Double {
        switch self {
        case .evidenceRepair: return 1.75
        case .coherentVerbatim: return 2.15
        case .readableReconstruction: return 2.7
        }
    }

    var maximumWordMultiplier: Double {
        switch self {
        case .evidenceRepair: return 1.45
        case .coherentVerbatim: return 1.7
        case .readableReconstruction: return 2.0
        }
    }

    var minimumCombinedTrigramCoverage: Double {
        switch self {
        case .evidenceRepair: return 0.68
        case .coherentVerbatim: return 0.50
        case .readableReconstruction: return 0.32
        }
    }

    var minimumCombinedBigramCoverage: Double {
        switch self {
        case .evidenceRepair: return 0.78
        case .coherentVerbatim: return 0.62
        case .readableReconstruction: return 0.45
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
