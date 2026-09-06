import Foundation
import NaturalLanguage

struct GemmaFinalizationResult {
    let decisions: [NightlyQualityDecision]
    let blindCandidate: NightlyQualityCandidate?
    let fusedCandidate: NightlyQualityCandidate
    let cumulativeInputTokens: Int
    let peakRAMBytes: UInt64?
    let textTraces: [NightlyQualityLLMTrace]
}

#if false
// DEFERRED: historical nightly Gemma audio/blind/fusion pipeline.
//
// The production final step is VibeVoiceAnchoredConsensusFinalizer, which sends text only and
// locks VibeVoice timestamps and speaker turns. This source remains only as design history.

/// Audio-grounded candidate generation and fusion. Maximum mode uses two independent chat turns
/// per audio window: audio-only first, then audio plus every untrusted candidate. `/clear` resets
/// the KV cache between turns while the worker keeps Gemma and its audio projector resident.
struct NightlyGemmaFinalizer {
    typealias ProgressHandler = @Sendable (NightlyQualityTelemetry) async -> Void
    typealias CheckpointHandler = @Sendable (
        NightlyQualityCandidate?,
        NightlyQualityCandidate?,
        NightlyQualityTelemetry
    ) async -> Void

    struct Span: Equatable {
        /// Whisper/VAD owns these boundaries. Gemma never generates or adjusts them.
        let speechStart: TimeInterval
        let speechEnd: TimeInterval
        /// Short acoustic context around the VAD region prevents clipped edge words.
        let audioStart: TimeInterval
        let audioEnd: TimeInterval
        let supportingUtteranceIDs: [Int64]
        let usedFallbackHardSplit: Bool
    }

    let maximumInputTokens: Int
    let modelKey: String
    let mode: NightlyQualityMode

    func finalize(
        artifact: NightlyQualityArtifact,
        audioPath: String,
        language: String?,
        onProgress: ProgressHandler? = nil,
        onCheckpoint: CheckpointHandler? = nil
    ) async throws -> GemmaFinalizationResult {
        let promptLanguage = resolvedPromptLanguage(
            recordingLanguage: language,
            baseline: artifact.whisper.segments
        )
        let spans = makeSpans(
            baseline: artifact.whisper.segments,
            vibeVoice: artifact.vibeVoice?.segments ?? []
        )
        guard !spans.isEmpty else {
            return GemmaFinalizationResult(
                decisions: [],
                blindCandidate: nil,
                fusedCandidate: makeCandidate(
                    engine: .fused,
                    role: "audio_grounded_fusion",
                    segments: []
                ),
                cumulativeInputTokens: 0,
                peakRAMBytes: nil
            )
        }

        let worker = PersistentGemmaFinalizerWorker()
        let turnsPerSpan = mode.runsBlindGemma ? 2 : 1
        let selection = TranscriptionEngineSelection(
            backend: .llm,
            whisperVariantIdentifier: nil,
            llmEngine: .gemma,
            llmModelKey: modelKey,
            vibeVoiceQuantization: nil,
            vibeVoiceSpeakerMode: nil,
            vibeVoiceModelRevision: nil,
            vibeVoiceRuntimeRevision: nil,
            vibeVoiceContext: nil
        )
        let telemetryState = NightlyQualityTelemetryState(NightlyQualityTelemetry(
            maximumInputTokens: maximumInputTokens,
            totalWindows: spans.count * turnsPerSpan,
            estimatedModelPeakBytes: TranscriptionResourceProfile.forSelection(
                selection
            ).estimatedPeakBytes
        ))
        await telemetryState.updatePhase(
            currentClip: nil,
            totalClips: spans.count,
            phase: "Loading Gemma model and audio projector"
        )
        await onProgress?(await telemetryState.snapshot())

        try await worker.start(
            modelKey: modelKey,
            maximumInputTokens: maximumInputTokens
        ) { current, peak, available in
            await telemetryState.updateMemory(
                current: current,
                peak: peak,
                available: available
            )
            await onProgress?(await telemetryState.snapshot())
        }
        defer { Task { await worker.stop() } }

        var blindSegments: [NightlyQualityCandidateSegment] = []
        var fusedSegments: [NightlyQualityCandidateSegment] = []
        var cumulativeInputTokens = 0
        var completedTurns = 0

        for (spanOffset, span) in spans.enumerated() {
            try Task.checkCancellation()
            let clipNumber = spanOffset + 1
            await telemetryState.updatePhase(
                currentClip: clipNumber,
                totalClips: spans.count,
                phase: "Preparing audio clip"
            )
            await onProgress?(await telemetryState.snapshot())
            let duration = span.audioEnd - span.audioStart
            let clip = try await AudioSegmentExtractor.shared.extractSegment(
                from: audioPath,
                startTime: span.audioStart,
                endTime: span.audioEnd,
                padding: 0
            )
            let clipURL = try await GemmaAudioClipPreparer.prepare(clip)

            do {
                var blindForSpan: [NightlyQualityCandidateSegment] = []
                if mode.runsBlindGemma {
                    await telemetryState.updatePhase(
                        currentClip: clipNumber,
                        totalClips: spans.count,
                        phase: "Gemma blind transcription"
                    )
                    let prompt = buildBlindPrompt(language: promptLanguage)
                    let estimate = try checkedTokenEstimate(
                        prompt: prompt,
                        audioDuration: duration
                    )
                    cumulativeInputTokens += estimate
                    await telemetryState.updateWork(
                        currentTokens: estimate,
                        cumulativeTokens: cumulativeInputTokens,
                        completedWindows: completedTurns
                    )
                    await onProgress?(await telemetryState.snapshot())

                    let raw = try await worker.adjudicate(
                        audioURL: clipURL,
                        prompt: prompt,
                        estimatedInputTokens: estimate,
                        maximumInputTokens: maximumInputTokens
                    )
                    guard !PersistentGemmaFinalizerWorker.isMissingAudioRefusal(raw) else {
                        throw PersistentGemmaWorkerError.mediaAttachmentFailed(raw)
                    }
                    let observed = await worker.latestInputTokenCount()
                    let recorded = observed ?? estimate
                    if observed != nil {
                        cumulativeInputTokens += recorded - estimate
                    }
                    guard let normalized = transcriptSegment(
                        raw,
                        span: span,
                        source: "audio"
                    ) else {
                        Self.logInvalidResponse(raw, pass: "blind", span: span)
                        throw PersistentGemmaWorkerError.invalidResponse
                    }
                    blindForSpan = [normalized]
                    blindSegments.append(normalized)
                    completedTurns += 1
                    await telemetryState.updateWork(
                        currentTokens: recorded,
                        cumulativeTokens: cumulativeInputTokens,
                        completedWindows: completedTurns
                    )
                    let checkpointTelemetry = await telemetryState.snapshot()
                    await onProgress?(checkpointTelemetry)
                    await onCheckpoint?(
                        makeCandidate(
                            engine: .gemma,
                            role: "blind_audio_only",
                            segments: deduplicated(blindSegments)
                        ),
                        fusedSegments.isEmpty
                            ? nil
                            : makeCandidate(
                                engine: .fused,
                                role: "audio_grounded_fusion",
                                segments: deduplicated(fusedSegments)
                            ),
                        checkpointTelemetry
                    )
                }

                await telemetryState.updatePhase(
                    currentClip: clipNumber,
                    totalClips: spans.count,
                    phase: "Gemma audio-grounded fusion"
                )
                let fusionPrompt = buildFusionPrompt(
                    span: span,
                    allBaseline: artifact.whisper.segments,
                    vibeVoice: artifact.vibeVoice?.segments ?? [],
                    blindGemma: blindForSpan,
                    language: promptLanguage
                )
                let fusionEstimate = try checkedTokenEstimate(
                    prompt: fusionPrompt,
                    audioDuration: duration
                )
                cumulativeInputTokens += fusionEstimate
                await telemetryState.updateWork(
                    currentTokens: fusionEstimate,
                    cumulativeTokens: cumulativeInputTokens,
                    completedWindows: completedTurns
                )
                await onProgress?(await telemetryState.snapshot())

                let rawFusion = try await worker.adjudicate(
                    audioURL: clipURL,
                    prompt: fusionPrompt,
                    estimatedInputTokens: fusionEstimate,
                    maximumInputTokens: maximumInputTokens
                )
                guard !PersistentGemmaFinalizerWorker.isMissingAudioRefusal(rawFusion) else {
                    throw PersistentGemmaWorkerError.mediaAttachmentFailed(rawFusion)
                }
                let observedFusion = await worker.latestInputTokenCount()
                let recordedFusion = observedFusion ?? fusionEstimate
                if observedFusion != nil {
                    cumulativeInputTokens += recordedFusion - fusionEstimate
                }
                guard let normalized = transcriptSegment(
                    rawFusion,
                    span: span,
                    source: "combined"
                ) else {
                    Self.logInvalidResponse(rawFusion, pass: "fusion", span: span)
                    throw PersistentGemmaWorkerError.invalidResponse
                }
                fusedSegments.append(normalized)
                completedTurns += 1
                await telemetryState.updateWork(
                    currentTokens: recordedFusion,
                    cumulativeTokens: cumulativeInputTokens,
                    completedWindows: completedTurns
                )
                let checkpointTelemetry = await telemetryState.snapshot()
                await onProgress?(checkpointTelemetry)
                await onCheckpoint?(
                    blindSegments.isEmpty
                        ? nil
                        : makeCandidate(
                            engine: .gemma,
                            role: "blind_audio_only",
                            segments: deduplicated(blindSegments)
                        ),
                    makeCandidate(
                        engine: .fused,
                        role: "audio_grounded_fusion",
                        segments: deduplicated(fusedSegments)
                    ),
                    checkpointTelemetry
                )
            } catch {
                try? FileManager.default.removeItem(at: clipURL)
                throw error
            }
            try? FileManager.default.removeItem(at: clipURL)
        }

        blindSegments = deduplicated(blindSegments)
        // These are window anchors copied from Whisper/VAD, not timestamps authored by Gemma.
        // The fused text must still receive word-level acoustic alignment before database commit.
        fusedSegments = deduplicated(fusedSegments)
        await telemetryState.updatePhase(
            currentClip: spans.count,
            totalClips: spans.count,
            phase: "Building private benchmark"
        )
        await onProgress?(await telemetryState.snapshot())
        let decisions = oneToOneDecisions(
            baseline: artifact.whisper.segments,
            fused: fusedSegments
        )
        let peak = await worker.peakMemoryBytes
        await worker.stop()
        return GemmaFinalizationResult(
            decisions: decisions,
            blindCandidate: mode.runsBlindGemma
                ? makeCandidate(
                    engine: .gemma,
                    role: "blind_audio_only",
                    segments: blindSegments
                )
                : nil,
            fusedCandidate: makeCandidate(
                engine: .fused,
                role: "audio_grounded_fusion",
                segments: fusedSegments
            ),
            cumulativeInputTokens: cumulativeInputTokens,
            peakRAMBytes: peak
        )
    }

    /// Gemma 4 accepts at most 30 seconds of audio. Whisper/VAD boundaries therefore define each
    /// blind window: complete adjacent utterances are packed together, while short audio-only
    /// context is added outside the region Gemma is asked to transcribe. VibeVoice boundaries are
    /// used only if Whisper produced no usable speech at all. A hard split is a last-resort fallback
    /// for a single malformed/very long Whisper utterance.
    func makeSpans(
        baseline: [NightlyQualityCandidateSegment],
        vibeVoice: [NightlyQualityCandidateSegment]
    ) -> [Span] {
        let maximumAudioDuration: TimeInterval = 29.5
        let contextPadding: TimeInterval = 1
        let maximumSpeechDuration = maximumAudioDuration - 2 * contextPadding
        let maximumJoinGap: TimeInterval = 2
        let whisperEvidence = baseline
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let evidence = (whisperEvidence.isEmpty ? vibeVoice : whisperEvidence)
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                $0.startTime != $1.startTime
                    ? $0.startTime < $1.startTime
                    : $0.endTime < $1.endTime
            }
        guard !evidence.isEmpty else { return [] }

        typealias Core = (
            start: TimeInterval,
            end: TimeInterval,
            ids: [Int64],
            hardSplit: Bool
        )
        var cores: [Core] = []
        var current: Core?

        func appendCurrent() {
            if let current {
                cores.append(current)
            }
            current = nil
        }

        for segment in evidence {
            let start = max(0, segment.startTime)
            let end = max(start + 0.05, segment.endTime)
            let ids = segment.utteranceID.map { [$0] } ?? []

            if end - start > maximumSpeechDuration {
                appendCurrent()
                var cursor = start
                while cursor < end {
                    let pieceEnd = min(end, cursor + maximumSpeechDuration)
                    cores.append((
                        start: cursor,
                        end: pieceEnd,
                        ids: ids,
                        hardSplit: true
                    ))
                    cursor = pieceEnd
                }
                continue
            }

            if var existing = current {
                let proposedEnd = max(existing.end, end)
                if start - existing.end <= maximumJoinGap,
                   proposedEnd - existing.start <= maximumSpeechDuration {
                    existing.end = proposedEnd
                    existing.ids.append(contentsOf: ids)
                    current = existing
                } else {
                    appendCurrent()
                    current = (start, end, ids, false)
                }
            } else {
                current = (start, end, ids, false)
            }
        }
        appendCurrent()

        return cores.map { core in
            var audioStart = max(0, core.start - contextPadding)
            var audioEnd = core.end + contextPadding
            if audioEnd - audioStart > maximumAudioDuration {
                let overflow = audioEnd - audioStart - maximumAudioDuration
                let removableBefore = max(0, core.start - audioStart)
                let removeBefore = min(removableBefore, overflow / 2)
                audioStart += removeBefore
                audioEnd -= overflow - removeBefore
            }
            return Span(
                speechStart: core.start,
                speechEnd: core.end,
                audioStart: audioStart,
                audioEnd: audioEnd,
                supportingUtteranceIDs: Array(Set(core.ids)).sorted(),
                usedFallbackHardSplit: core.hardSplit
            )
        }
    }

    /// Google's canonical Gemma 4 ASR prompt. Keep this wording intentionally uncustomized so the
    /// blind benchmark measures the model's documented transcription path.
    func buildBlindPrompt(language: String?) -> String {
        GemmaConfiguration.canonicalASRPrompt(language: language)
    }

    private func buildFusionPrompt(
        span: Span,
        allBaseline: [NightlyQualityCandidateSegment],
        vibeVoice: [NightlyQualityCandidateSegment],
        blindGemma: [NightlyQualityCandidateSegment],
        language: String?
    ) -> String {
        let spokenLanguage = normalizedLanguageInstruction(language)
        let baselineInSpan = allBaseline.filter {
            $0.endTime > span.speechStart && $0.startTime < span.speechEnd
        }
        let spanIDs = Set(baselineInSpan.compactMap(\.utteranceID))
        let baselinePayload = baselineInSpan.map { line -> [String: Any] in
            [
                "id": line.utteranceID ?? -1,
                "start": line.startTime - span.audioStart,
                "end": line.endTime - span.audioStart,
                "text": line.text,
                "speaker_hint": line.speakerLabel ?? ""
            ]
        }
        let previous = allBaseline
            .filter { !spanIDs.contains($0.utteranceID ?? -1) && $0.endTime <= span.speechStart }
            .suffix(3)
            .map(\.text)
            .joined(separator: " ")
        let following = allBaseline
            .filter { !spanIDs.contains($0.utteranceID ?? -1) && $0.startTime >= span.speechEnd }
            .prefix(3)
            .map(\.text)
            .joined(separator: " ")
        let payload: [String: Any] = [
            "language": spokenLanguage,
            "previous_context": previous,
            "following_context": following,
            "foreground_untrusted": baselinePayload,
            "vibevoice_untrusted": relativePayload(vibeVoice, in: span),
            "blind_gemma_untrusted": relativePayload(blindGemma, in: span)
        ]
        let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let focusStart = span.speechStart - span.audioStart
        let focusEnd = span.speechEnd - span.audioStart
        return """
        Listen to the audio again and produce the most accurate transcription in \(spokenLanguage). \
        The audio is authoritative; every supplied hypothesis is untrusted spelling and context \
        evidence. The attached clip includes brief context to avoid clipped words. Transcribe only \
        the focus region from \(String(format: "%.2f", focusStart)) to \
        \(String(format: "%.2f", focusEnd)) seconds; use audio outside it only as context. Preserve \
        disfluencies, names, numbers, and audible silence or noise markers. Write numbers as digits. \
        Do not summarize, translate, identify speakers, invent timestamps, or invent speech. Only \
        output the corrected transcription as one line. Hypotheses: \(json)
        """
    }

    private func normalizedLanguageInstruction(_ language: String?) -> String {
        let value = language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if value.isEmpty || value == "auto" || value == "auto-detected" || value == "unknown" {
            return "the language spoken in the audio"
        }
        return language ?? "the language spoken in the audio"
    }

    func resolvedPromptLanguage(
        recordingLanguage: String?,
        baseline: [NightlyQualityCandidateSegment]
    ) -> String? {
        let recorded = recordingLanguage?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalized = recorded.lowercased()
        if !recorded.isEmpty,
           normalized != "auto",
           normalized != "auto-detected",
           normalized != "unknown" {
            return recorded
        }

        // Blind means no candidate WORDS reach Gemma. A language label is still required by
        // Google's recommended ASR prompt, so infer only that label from the foreground text.
        let sample = baseline
            .prefix(40)
            .map(\.text)
            .joined(separator: " ")
        guard !sample.isEmpty,
              let code = NLLanguageRecognizer.dominantLanguage(for: sample)?.rawValue else {
            return nil
        }
        let name = Locale(identifier: "en_US")
            .localizedString(forLanguageCode: code) ?? code
        return "\(name) (\(code))"
    }

    private func relativePayload(
        _ candidates: [NightlyQualityCandidateSegment],
        in span: Span
    ) -> [[String: Any]] {
        candidates.filter {
            $0.endTime > span.speechStart && $0.startTime < span.speechEnd
        }.map {
            [
                "start": max(0, $0.startTime - span.audioStart),
                "end": min(span.audioEnd, $0.endTime) - span.audioStart,
                "text": $0.text,
                "speaker_hint": $0.speakerLabel ?? ""
            ]
        }
    }

    private func checkedTokenEstimate(
        prompt: String,
        audioDuration: TimeInterval
    ) throws -> Int {
        let estimate = GemmaInputBudget.estimatedInputTokens(
            prompt: prompt,
            audioDuration: audioDuration
        )
        guard estimate <= maximumInputTokens else {
            throw PersistentGemmaWorkerError.inputTooLarge(
                estimated: estimate,
                maximum: maximumInputTokens
            )
        }
        return estimate
    }

    /// Gemma supplies words only. The enclosing Whisper/VAD region is copied as a coarse window
    /// anchor so the result can be displayed and later sent to forced acoustic alignment.
    func transcriptSegment(
        _ raw: String,
        span: Span,
        source: String
    ) -> NightlyQualityCandidateSegment? {
        let text = raw
            .replacingOccurrences(of: "\0", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              span.speechEnd > span.speechStart,
              !text.hasPrefix("{\"segments\""),
              !text.localizedCaseInsensitiveContains("return only this json") else {
            return nil
        }
        return NightlyQualityCandidateSegment(
            utteranceID: nil,
            startTime: span.speechStart,
            endTime: span.speechEnd,
            text: text,
            speakerUUID: nil,
            speakerLabel: nil,
            userProtected: false,
            confidence: nil,
            source: source,
            supportingUtteranceIDs: span.supportingUtteranceIDs,
            alignmentMethod: span.usedFallbackHardSplit
                ? "whisper_vad_window_hard_split"
                : "whisper_vad_window"
        )
    }

    private func deduplicated(
        _ segments: [NightlyQualityCandidateSegment]
    ) -> [NightlyQualityCandidateSegment] {
        var result: [NightlyQualityCandidateSegment] = []
        for segment in segments.sorted(by: {
            $0.startTime != $1.startTime
                ? $0.startTime < $1.startTime
                : $0.endTime < $1.endTime
        }) {
            if let last = result.last,
               abs(last.startTime - segment.startTime) < 0.15,
               abs(last.endTime - segment.endTime) < 0.15,
               last.text.caseInsensitiveCompare(segment.text) == .orderedSame {
                continue
            }
            result.append(segment)
        }
        return result
    }

    /// Structural edits remain shadow/review data. Automatic mode only applies an unambiguous
    /// one-output-to-one-input correction; splits, merges, additions, and deletions never bypass
    /// alignment and speaker reprocessing.
    private func oneToOneDecisions(
        baseline: [NightlyQualityCandidateSegment],
        fused: [NightlyQualityCandidateSegment]
    ) -> [NightlyQualityDecision] {
        baseline.compactMap { original in
            guard let id = original.utteranceID, !original.userProtected else { return nil }
            let matches = fused.filter { $0.supportingUtteranceIDs == [id] }
            guard matches.count == 1, let match = matches.first else { return nil }
            return NightlyQualityDecision(
                utteranceID: id,
                originalText: original.text,
                finalText: match.text,
                confidence: match.confidence ?? "low",
                source: match.source ?? "combined",
                estimatedInputTokens: 0
            )
        }
    }

    private func makeCandidate(
        engine: NightlyQualityCandidate.Engine,
        role: String,
        segments: [NightlyQualityCandidateSegment]
    ) -> NightlyQualityCandidate {
        let settings = try? JSONSerialization.data(
            withJSONObject: [
                "mode": mode.rawValue,
                "maximum_input_tokens": maximumInputTokens,
                "blind_window_source": "whisper_vad",
                "blind_language_source": "foreground_language_label_only",
                "gemma_outputs_timestamps": false
            ],
            options: [.sortedKeys]
        )
        return NightlyQualityCandidate(
            engine: engine,
            model: "Gemma · \(modelKey)",
            createdAt: Date(),
            segments: segments,
            provenance: NightlyQualityCandidateProvenance(
                role: role,
                engineIdentifier: "gemma",
                modelIdentifier: modelKey,
                modelRevision: nil,
                runtimeRevision: nil,
                settingsJSON: settings.flatMap { String(data: $0, encoding: .utf8) },
                sourceRevisionDate: Date(),
                certainty: .exact
            )
        )
    }

    private static func logInvalidResponse(_ raw: String, pass: String, span: Span) {
        let diagnostic = raw
            .replacingOccurrences(of: "\0", with: "")
            .prefix(8_000)
        VoxtralLogger.shared.warning(
            "[NightlyGemma] Invalid \(pass) response for "
                + "\(String(format: "%.2f", span.audioStart))-"
                + "\(String(format: "%.2f", span.audioEnd))s: \(diagnostic)"
        )
    }
}
#endif
