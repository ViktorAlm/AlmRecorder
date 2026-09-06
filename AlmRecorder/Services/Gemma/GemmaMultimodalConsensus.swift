import Foundation

enum GemmaMultimodalError: LocalizedError {
    case unavailable(String)
    case serverExited(String)
    case startupTimedOut
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            return detail
        case .serverExited(let detail):
            return detail.isEmpty
                ? "The Gemma audio server exited unexpectedly"
                : "The Gemma audio server exited: \(detail)"
        case .startupTimedOut:
            return "Gemma did not finish loading its model and audio projector"
        case .invalidResponse(let detail):
            return detail.isEmpty
                ? "Gemma returned an invalid audio-consensus response"
                : "Gemma returned an invalid audio-consensus response: \(detail)"
        }
    }
}

/// Current llama.cpp server client for Gemma audio. Unlike the retired interactive `/audio`
/// worker, every request contains typed `input_audio` parts and can carry several chronological
/// clips. Text is deliberately placed before audio, matching Gemma 4's documented prompt order.
actor GemmaMultimodalServer {
    typealias TelemetryHandler = @Sendable (UInt64?, UInt64?, UInt64?) async -> Void
    private final class LogBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""

        func append(_ data: Data) {
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            lock.lock()
            value.append(text)
            if value.utf8.count > 32_768 {
                value = String(value.suffix(16_384))
            }
            lock.unlock()
        }

        func suffix(_ count: Int = 2_000) -> String {
            lock.lock()
            defer { lock.unlock() }
            return String(value.suffix(count))
        }
    }

    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private let logs = LogBuffer()
    private var baseURL: URL?
    private var memoryMonitor: Task<Void, Never>?
    private var peakRAMBytes: UInt64?

    func start(
        modelKey: String,
        onTelemetry: TelemetryHandler? = nil
    ) async throws {
        if process?.isRunning == true { return }
        let manager = GemmaModelManager()
        guard let binary = LlamaRuntime.findBinary(named: "llama-server") else {
            throw GemmaMultimodalError.unavailable(
                "llama-server is missing; rebuild AlmRecorder's bundled llama.cpp tools"
            )
        }
        guard manager.isAudioModelDownloaded(modelKey),
              let model = manager.getModelPath(for: modelKey),
              let projector = manager.getMmprojPath(for: modelKey) else {
            throw GemmaMultimodalError.unavailable(
                "Gemma \(modelKey) and its audio projector are not installed"
            )
        }
        let profile = TranscriptionResourceProfile.gemmaAudio(modelKey)
        if let deferral = SystemMemoryGate.shared.transcriptionDeferral(profile: profile) {
            throw TranscriptionError.resourcesUnavailable(deferral.reason)
        }

        let port = Int.random(in: 38_000...49_000)
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "-m", model.path,
            "--mmproj", projector.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--no-webui",
            "-ngl", "99",
            "--ctx-size", "32768",
            "--parallel", "1",
            "--cache-ram", "0"
        ]
        process.standardOutput = stdout
        process.standardError = stderr
        LlamaRuntime.applyLibraryPath(to: process, binaryPath: binary)
        stdout.fileHandleForReading.readabilityHandler = { [logs] handle in
            let data = handle.availableData
            if !data.isEmpty { logs.append(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [logs] handle in
            let data = handle.availableData
            if !data.isEmpty { logs.append(data) }
        }
        try process.run()
        self.process = process
        outputPipe = stdout
        errorPipe = stderr
        baseURL = URL(string: "http://127.0.0.1:\(port)")
        startMemoryMonitor(
            pid: process.processIdentifier,
            profile: profile,
            handler: onTelemetry
        )

        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            try Task.checkCancellation()
            guard process.isRunning else {
                throw GemmaMultimodalError.serverExited(logs.suffix())
            }
            if await isHealthy() { return }
            try await Task.sleep(for: .milliseconds(300))
        }
        await stop()
        throw GemmaMultimodalError.startupTimedOut
    }

    func complete(
        prompt: String,
        audio: [Data],
        maximumOutputTokens: Int
    ) async throws -> String {
        guard let baseURL, process?.isRunning == true else {
            throw GemmaMultimodalError.unavailable("Gemma audio server is not running")
        }
        guard !audio.isEmpty else {
            throw GemmaMultimodalError.invalidResponse("no audio clips were attached")
        }
        var content: [[String: Any]] = [
            ["type": "text", "text": prompt]
        ]
        content.append(contentsOf: audio.map {
            [
                "type": "input_audio",
                "input_audio": [
                    "data": $0.base64EncodedString(),
                    "format": "wav"
                ]
            ]
        })
        let body: [String: Any] = [
            "model": "gemma-audio-consensus",
            "messages": [
                [
                    "role": "user",
                    "content": content
                ]
            ],
            "temperature": 0.2,
            "top_p": 0.95,
            "top_k": 64,
            "max_tokens": max(64, min(1_536, maximumOutputTokens)),
            "seed": 42,
            "stream": false,
            "reasoning_effort": "none",
            "chat_template_kwargs": ["enable_thinking": false]
        ]
        var request = URLRequest(
            url: baseURL.appendingPathComponent("v1/chat/completions")
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP request failed"
            throw GemmaMultimodalError.invalidResponse(String(detail.prefix(2_000)))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let raw = message["content"] as? String else {
            throw GemmaMultimodalError.invalidResponse(
                String((String(data: data, encoding: .utf8) ?? "").prefix(2_000))
            )
        }
        return raw
    }

    func stop() async {
        memoryMonitor?.cancel()
        memoryMonitor = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process = nil
        outputPipe = nil
        errorPipe = nil
        baseURL = nil
    }

    func peakMemoryBytes() -> UInt64? {
        peakRAMBytes
    }

    private func isHealthy() async -> Bool {
        guard let baseURL else { return false }
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return false
        }
        return (200..<300).contains(http.statusCode)
    }

    private func startMemoryMonitor(
        pid: pid_t,
        profile: TranscriptionResourceProfile,
        handler: TelemetryHandler?
    ) {
        memoryMonitor?.cancel()
        memoryMonitor = Task { [weak self] in
            await self?.monitorMemory(pid: pid, profile: profile, handler: handler)
        }
    }

    private func monitorMemory(
        pid: pid_t,
        profile: TranscriptionResourceProfile,
        handler: TelemetryHandler?
    ) async {
        while !Task.isCancelled {
            guard kill(pid, 0) == 0 else { return }
            let current = SystemMemoryDiagnostics.physicalFootprint(pid: pid)
            let available = SystemMemoryGate.memorySnapshot()?.availableBytes
            if let current {
                peakRAMBytes = max(peakRAMBytes ?? 0, current)
            }
            await handler?(current, peakRAMBytes, available)
            if let reason = SystemMemoryGate.shared.transcriptionEmergencyReason(
                profile: profile
            ) {
                VoxtralLogger.shared.warning(
                    "[GemmaAudioConsensus] Emergency memory stop: \(reason)"
                )
                kill(pid, SIGTERM)
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

/// Audio-grounded, one-turn-at-a-time repair over immutable VibeVoice native turns.
///
/// A long VibeVoice turn remains one output turn. Its audio is partitioned near Whisper/VAD
/// boundaries into <30 second clips. Up to three clips are attached to one Gemma request; unusually
/// long turns use consecutive requests whose plain-text answers are joined inside the same locked
/// VibeVoice time range.
struct GemmaMultimodalConsensusFinalizer {
    typealias ProgressHandler = @Sendable (NightlyQualityTelemetry) async -> Void
    typealias CheckpointHandler = @Sendable (
        NightlyQualityCandidate?,
        NightlyQualityCandidate?,
        NightlyQualityTelemetry,
        [NightlyQualityLLMTrace]
    ) async -> Void

    struct AudioRange: Equatable {
        let start: TimeInterval
        let end: TimeInterval
        let source: String
    }

    let maximumInputTokens: Int
    let modelKey: String
    let strategy: ConsensusRepairStrategy

    init(
        maximumInputTokens: Int,
        modelKey: String = GemmaConfiguration.defaultAudioModel,
        strategy: ConsensusRepairStrategy = .readableReconstruction
    ) {
        self.maximumInputTokens = maximumInputTokens
        self.modelKey = modelKey
        self.strategy = strategy
    }

    func finalize(
        artifact: NightlyQualityArtifact,
        audioPath: String,
        language: String?,
        onProgress: ProgressHandler? = nil,
        onCheckpoint: CheckpointHandler? = nil
    ) async throws -> GemmaFinalizationResult {
        guard let vibeVoice = artifact.vibeVoice,
              let whisper = artifact.whisperCandidate else {
            throw TranscriptionError.transcriptionFailed(
                "Whisper and VibeVoice candidates are required for audio consensus"
            )
        }
        let projector = VibeVoiceAnchoredConsensusFinalizer(
            maximumInputTokens: maximumInputTokens,
            modelKey: modelKey,
            strategy: strategy
        )
        let turns = projector.makeTurns(
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

        let duration = try AudioSegmentExtractor.shared.getDuration(of: audioPath)
        let plans = turns.map {
            audioRanges(
                for: $0,
                whisper: whisper.segments,
                recordingDuration: duration
            ).chunked(maxCount: GemmaConfiguration.maximumAudioClipsPerRequest)
        }
        let totalWindows = max(1, plans.reduce(0) { $0 + $1.count })
        let telemetryState = NightlyQualityTelemetryState(
            NightlyQualityTelemetry(
                maximumInputTokens: maximumInputTokens,
                totalWindows: totalWindows,
                estimatedModelPeakBytes: TranscriptionResourceProfile
                    .gemmaAudio(modelKey)
                    .estimatedPeakBytes
            )
        )
        await telemetryState.updatePhase(
            currentClip: nil,
            totalClips: totalWindows,
            phase: "Loading Gemma \(modelKey) and the audio projector"
        )
        await onProgress?(await telemetryState.snapshot())

        let server = GemmaMultimodalServer()
        do {
            try await server.start(
                modelKey: modelKey,
                onTelemetry: { current, peak, available in
                    await telemetryState.updateMemory(
                        current: current,
                        peak: peak,
                        available: available
                    )
                    await onProgress?(await telemetryState.snapshot())
                }
            )
        } catch {
            await server.stop()
            throw error
        }
        var completed: [NightlyQualityCandidateSegment] = []
        var completedByTurnID: [Int: NightlyQualityCandidateSegment] = [:]
        var traces: [NightlyQualityLLMTrace] = []
        var cumulativeInputTokens = 0
        var completedWindows = 0

        var peakRAMBytes: UInt64?
        do {
            for turnIndex in turns.indices {
                try Task.checkCancellation()
                let turn = turns[turnIndex]
                let groups = plans[turnIndex]
                var repairedParts: [String] = []
                var turnTraceIndices: [Int] = []

                for (partIndex, ranges) in groups.enumerated() {
                    try Task.checkCancellation()
                    let prompt = buildPrompt(
                        turn: turn,
                        turnIndex: turnIndex,
                        turns: turns,
                        ranges: ranges,
                        partIndex: partIndex,
                        partCount: groups.count,
                        whisper: whisper.segments,
                        previousConsensus: completedByTurnID,
                        previousPart: repairedParts.last,
                        language: language
                    )
                    let inputTokens = GemmaInputBudget.estimatedInputTokens(prompt: prompt)
                    cumulativeInputTokens += inputTokens
                    await telemetryState.updatePhase(
                        currentClip: completedWindows + 1,
                        totalClips: totalWindows,
                        phase: "Preparing \(ranges.count) audio clip"
                            + (ranges.count == 1 ? "" : "s")
                            + " for VibeVoice turn \(turnIndex + 1)/\(turns.count)"
                    )
                    await telemetryState.updateWork(
                        currentTokens: inputTokens,
                        cumulativeTokens: cumulativeInputTokens,
                        completedWindows: completedWindows
                    )
                    await onProgress?(await telemetryState.snapshot())

                    var audio: [Data] = []
                    for (clipIndex, range) in ranges.enumerated() {
                        await telemetryState.updatePhase(
                            currentClip: completedWindows + 1,
                            totalClips: totalWindows,
                            phase: "Encoding audio \(clipIndex + 1)/\(ranges.count) · "
                                + timeLabel(range.start, range.end)
                        )
                        await onProgress?(await telemetryState.snapshot())
                        audio.append(
                            try await normalizedAudio(
                                audioPath: audioPath,
                                range: range
                            )
                        )
                    }
                    await telemetryState.updatePhase(
                        currentClip: completedWindows + 1,
                        totalClips: totalWindows,
                        phase: "Gemma is listening and repairing turn "
                            + "\(turnIndex + 1)/\(turns.count)"
                    )
                    await onProgress?(await telemetryState.snapshot())
                    let raw = try await server.complete(
                        prompt: prompt,
                        audio: audio,
                        maximumOutputTokens: outputTokenLimit(
                            for: turn,
                            ranges: ranges
                        )
                    )
                    let repair = VibeVoiceAnchoredConsensusFinalizer.parseRepair(raw)
                    if let repair { repairedParts.append(repair.text) }
                    let before = Array(turns[max(0, turnIndex - 3)..<turnIndex])
                    let afterEnd = min(turns.count, turnIndex + 4)
                    let after = Array(turns[(turnIndex + 1)..<afterEnd])
                    traces.append(
                        NightlyQualityLLMTrace(
                            batchIndex: completedWindows + 1,
                            attempt: 1,
                            targetIDs: [turn.id],
                            prompt: prompt,
                            response: raw,
                            parsedSuccessfully: repair != nil,
                            strategy: strategy,
                            instructionSummary:
                                "Audio-grounded repair; VibeVoice time and speaker locked",
                            target: traceTurn(turn, position: "target"),
                            contextBefore: before.map {
                                traceTurn(
                                    $0,
                                    position: "before",
                                    previousConsensus: completedByTurnID[$0.id]?.text
                                )
                            },
                            contextAfter: after.map {
                                traceTurn($0, position: "after")
                            },
                            audioClipRanges: ranges.map {
                                NightlyQualityAudioClipTrace(
                                    startTime: $0.start,
                                    endTime: $0.end,
                                    source: $0.source
                                )
                            },
                            audioGrounded: true
                        )
                    )
                    turnTraceIndices.append(traces.count - 1)
                    completedWindows += 1
                    await telemetryState.updateWork(
                        currentTokens: inputTokens,
                        cumulativeTokens: cumulativeInputTokens,
                        completedWindows: completedWindows
                    )
                }

                let proposed = repairedParts
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let segment = resolvedSegment(turn: turn, proposed: proposed)
                for index in turnTraceIndices {
                    let scores = evidenceScores(proposed, turn: turn)
                    traces[index].evidenceAccepted =
                        segment.source == "gemma_audio_consensus"
                    traces[index].evidenceTrigramCoverage = scores.trigram
                    traces[index].evidenceBigramCoverage = scores.bigram
                    traces[index].resolutionSource = segment.source
                }
                completed.append(segment)
                completedByTurnID[turn.id] = segment
                await onProgress?(await telemetryState.snapshot())
                await onCheckpoint?(
                    nil,
                    makeCandidate(segments: completed),
                    await telemetryState.snapshot(),
                    traces
                )
            }
            peakRAMBytes = await server.peakMemoryBytes()
            await server.stop()
        } catch {
            await server.stop()
            throw error
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
            peakRAMBytes: peakRAMBytes,
            textTraces: traces
        )
    }

    func audioRanges(
        for turn: VibeVoiceAnchoredConsensusFinalizer.Turn,
        whisper: [NightlyQualityCandidateSegment],
        recordingDuration: TimeInterval
    ) -> [AudioRange] {
        let start = max(0, turn.vibeVoice.startTime)
        let end = min(recordingDuration, max(start, turn.vibeVoice.endTime))
        guard end > start else { return [] }
        let maximum = GemmaConfiguration.maximumAudioClipDuration
        if end - start <= maximum - 1.5 {
            return [
                paddedRange(
                    start: start,
                    end: end,
                    recordingDuration: recordingDuration,
                    source: "vibevoice_turn"
                )
            ]
        }

        let boundaries = whisper
            .flatMap { [$0.startTime, $0.endTime] }
            .filter { $0 > start + 8 && $0 < end - 3 }
            .sorted()
        var ranges: [AudioRange] = []
        var cursor = start
        while cursor < end - 0.05 {
            let ideal = cursor + GemmaConfiguration.targetAudioClipDuration
            let latest = min(end, cursor + maximum - 1.5)
            let eligible = boundaries.filter {
                $0 >= cursor + 10 && $0 <= latest
            }
            let cut = eligible.min { abs($0 - ideal) < abs($1 - ideal) } ?? latest
            let centralEnd = max(cursor + 0.1, min(end, cut))
            ranges.append(
                paddedRange(
                    start: cursor,
                    end: centralEnd,
                    recordingDuration: recordingDuration,
                    source: eligible.isEmpty ? "duration_fallback" : "whisper_vad_boundary"
                )
            )
            cursor = centralEnd
        }
        return ranges
    }

    private func paddedRange(
        start: TimeInterval,
        end: TimeInterval,
        recordingDuration: TimeInterval,
        source: String
    ) -> AudioRange {
        var audioStart = max(0, start - 0.6)
        var audioEnd = min(recordingDuration, end + 0.6)
        let maximum = GemmaConfiguration.maximumAudioClipDuration
        if audioEnd - audioStart > maximum {
            audioEnd = audioStart + maximum
        }
        if audioEnd > recordingDuration {
            audioEnd = recordingDuration
            audioStart = max(0, audioEnd - maximum)
        }
        return AudioRange(start: audioStart, end: audioEnd, source: source)
    }

    private func normalizedAudio(
        audioPath: String,
        range: AudioRange
    ) async throws -> Data {
        let extracted = try await AudioSegmentExtractor.shared.extractSegment(
            from: audioPath,
            startTime: range.start,
            endTime: range.end,
            padding: 0
        )
        let temporary = FileManager.default.temporaryDirectory
        let id = UUID().uuidString
        let source = temporary.appendingPathComponent("gemma-\(id)-source.wav")
        let normalized = temporary.appendingPathComponent("gemma-\(id)-16k.wav")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: normalized)
        }
        try extracted.write(to: source, options: .atomic)
        _ = try await AudioPreprocessor().convertToWAV(
            sourceURL: source,
            sampleRate: GemmaConfiguration.audioSampleRate,
            outputURL: normalized
        )
        return try Data(contentsOf: normalized)
    }

    private func buildPrompt(
        turn: VibeVoiceAnchoredConsensusFinalizer.Turn,
        turnIndex: Int,
        turns: [VibeVoiceAnchoredConsensusFinalizer.Turn],
        ranges: [AudioRange],
        partIndex: Int,
        partCount: Int,
        whisper: [NightlyQualityCandidateSegment],
        previousConsensus: [Int: NightlyQualityCandidateSegment],
        previousPart: String?,
        language: String?
    ) -> String {
        let trimmedLanguage = language?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let languageName = trimmedLanguage.isEmpty
            ? "the language spoken in the audio"
            : trimmedLanguage
        let before = Array(turns[max(0, turnIndex - 3)..<turnIndex])
        let afterEnd = min(turns.count, turnIndex + 4)
        let after = Array(turns[(turnIndex + 1)..<afterEnd])
        let rangeStart = ranges.first?.start ?? turn.vibeVoice.startTime
        let rangeEnd = ranges.last?.end ?? turn.vibeVoice.endTime
        let projectedWhisper = whisper
            .filter { $0.endTime > rangeStart && $0.startTime < rangeEnd }
            .map(\.text)
            .joined(separator: " ")
        let whisperForPart = projectedWhisper.isEmpty
            ? "(no Whisper text)"
            : projectedWhisper
        let partDescription = partCount == 1
            ? "the complete target turn"
            : "part \(partIndex + 1) of \(partCount) of the same target turn"
        return """
        Listen to every attached audio clip. They are chronological and together contain \
        \(partDescription). Produce a faithful, readable verbatim transcript for only that target \
        audio. The expected language is \(languageName), but preserve the language actually spoken.

        EDITING MODE — \(strategy.displayName):
        \(strategy.promptInstruction)

        VibeVoice owns the speaker turn and timestamps. Do not invent timestamps, speaker labels, \
        commentary, JSON, Markdown, or alternatives. Correct misheard words, names, compounds, \
        grammar, and punctuation when the audio and surrounding conversation support the repair. \
        Preserve meaningful fillers and [Environmental Sounds] when they are actually audible. \
        Never summarize and never add facts.

        TARGET SPEAKER: \(turn.vibeVoice.speakerLabel ?? "unknown")
        TARGET LOCKED RANGE: \(timeLabel(turn.vibeVoice.startTime, turn.vibeVoice.endTime))
        VIBEVOICE CANDIDATE: \(turn.vibeVoice.text)
        WHISPER CANDIDATE FOR THESE CLIPS: \(whisperForPart)
        \(previousPart.map { "PREVIOUS REPAIRED PART OF THIS TURN: \($0)" } ?? "")

        THREE TURNS BEFORE:
        \(contextText(before, previousConsensus: previousConsensus))

        THREE TURNS AFTER:
        \(contextText(after, previousConsensus: [:]))

        Output only the cleaned transcript text for the attached target audio clips, on one line.
        """
    }

    private func contextText(
        _ turns: [VibeVoiceAnchoredConsensusFinalizer.Turn],
        previousConsensus: [Int: NightlyQualityCandidateSegment]
    ) -> String {
        guard !turns.isEmpty else { return "(none)" }
        return turns.map { turn in
            let clean = turn.projectedForegroundCleanContext
                .map { " | previous clean: \($0)" } ?? ""
            let consensus: String
            if let repaired = previousConsensus[turn.id]?.text {
                consensus = " | repaired: \(repaired)"
            } else {
                consensus = ""
            }
            return "\(timeLabel(turn.vibeVoice.startTime, turn.vibeVoice.endTime)) "
                + "\(turn.vibeVoice.speakerLabel ?? "unknown"): "
                + "VibeVoice \(turn.vibeVoice.text) | Whisper "
                + "\(turn.projectedWhisper ?? "(none)")\(clean)\(consensus)"
        }.joined(separator: "\n")
    }

    func resolvedSegment(
        turn: VibeVoiceAnchoredConsensusFinalizer.Turn,
        proposed: String
    ) -> NightlyQualityCandidateSegment {
        let text: String
        let source: String
        let confidence: String
        if !turn.whisperSelectable {
            text = turn.vibeVoice.text
            source = "overlap_guard_vibevoice"
            confidence = "high"
        } else if isSafeAudioRepair(proposed, turn: turn) {
            text = proposed
            source = "gemma_audio_consensus"
            // This has passed the audio-grounded refusal, length, n-gram, overlap, and one-to-one
            // guards. Mark it high so automatic mode can actually commit the accepted repair.
            confidence = "high"
        } else {
            text = turn.vibeVoice.text
            source = proposed.isEmpty
                ? "gemma_audio_invalid_fallback_vibevoice"
                : "gemma_audio_evidence_fallback_vibevoice"
            confidence = "high"
        }
        return NightlyQualityCandidateSegment(
            utteranceID: nil,
            startTime: turn.vibeVoice.startTime,
            endTime: turn.vibeVoice.endTime,
            text: text,
            speakerUUID: turn.vibeVoice.speakerUUID,
            speakerLabel: turn.vibeVoice.speakerLabel,
            userProtected: false,
            confidence: confidence,
            source: source,
            supportingUtteranceIDs: turn.supportingUtteranceIDs,
            alignmentMethod: "vibevoice_native_turn_audio_grounded"
        )
    }

    private func isSafeAudioRepair(
        _ proposed: String,
        turn: VibeVoiceAnchoredConsensusFinalizer.Turn
    ) -> Bool {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.localizedCaseInsensitiveContains("audio file"),
              !trimmed.localizedCaseInsensitiveContains("cannot transcribe"),
              !trimmed.localizedCaseInsensitiveContains("as an ai"),
              !trimmed.contains("```"),
              !trimmed.contains("{\"") else {
            return false
        }
        let candidateWords = max(
            1,
            max(
                turn.vibeVoice.text.split(whereSeparator: \.isWhitespace).count,
                turn.projectedWhisper?.split(whereSeparator: \.isWhitespace).count ?? 0
            )
        )
        let outputWords = trimmed.split(whereSeparator: \.isWhitespace).count
        guard outputWords <= max(24, candidateWords * 3),
              outputWords >= max(1, candidateWords / 4) else {
            return false
        }
        let scores = evidenceScores(trimmed, turn: turn)
        return outputWords <= 4
            ? scores.unigram >= 0.2
            : scores.bigram >= 0.10 || scores.trigram >= 0.05
    }

    private func evidenceScores(
        _ proposed: String,
        turn: VibeVoiceAnchoredConsensusFinalizer.Turn
    ) -> (unigram: Double, bigram: Double, trigram: Double) {
        let evidence = [
            turn.vibeVoice.text,
            turn.projectedWhisper ?? "",
            turn.projectedForegroundRawContext ?? ""
        ].joined(separator: " ")
        return (
            ngramCoverage(proposed, evidence: evidence, size: 1),
            ngramCoverage(proposed, evidence: evidence, size: 2),
            ngramCoverage(proposed, evidence: evidence, size: 3)
        )
    }

    private func ngramCoverage(
        _ proposed: String,
        evidence: String,
        size: Int
    ) -> Double {
        let lhs = normalizedWords(proposed)
        let rhs = Set(ngrams(normalizedWords(evidence), size: size))
        let grams = ngrams(lhs, size: size)
        guard !grams.isEmpty else { return 0 }
        return Double(grams.filter(rhs.contains).count) / Double(grams.count)
    }

    private func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private func ngrams(_ words: [String], size: Int) -> [String] {
        guard size > 0, words.count >= size else { return words }
        return (0...(words.count - size)).map {
            words[$0..<($0 + size)].joined(separator: " ")
        }
    }

    private func outputTokenLimit(
        for turn: VibeVoiceAnchoredConsensusFinalizer.Turn,
        ranges: [AudioRange]
    ) -> Int {
        let words = max(
            turn.vibeVoice.text.split(whereSeparator: \.isWhitespace).count,
            turn.projectedWhisper?.split(whereSeparator: \.isWhitespace).count ?? 0
        )
        let duration = ranges.reduce(0) { $0 + max(0, $1.end - $1.start) }
        return max(128, min(1_536, max(words * 3, Int(duration * 5))))
    }

    private func traceTurn(
        _ turn: VibeVoiceAnchoredConsensusFinalizer.Turn,
        position: String,
        previousConsensus: String? = nil
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
            previousConsensus: previousConsensus,
            whisperSelectable: position == "target" ? turn.whisperSelectable : nil
        )
    }

    private func makeCandidate(
        segments: [NightlyQualityCandidateSegment]
    ) -> NightlyQualityCandidate {
        let settings = try? JSONSerialization.data(
            withJSONObject: [
                "audio_input": true,
                "audio_api": "llama-server input_audio",
                "audio_model": modelKey,
                "maximum_audio_item_seconds":
                    GemmaConfiguration.maximumAudioClipDuration,
                "maximum_audio_items_per_request":
                    GemmaConfiguration.maximumAudioClipsPerRequest,
                "long_turn_split_owner": "whisper_vad_boundaries",
                "structure_owner": "vibevoice_native",
                "context_turns_before": 3,
                "context_turns_after": 3,
                "timestamps_mutable": false,
                "speakers_mutable": false,
                "output_format": "plain_text",
                "strategy": strategy.rawValue
            ],
            options: [.sortedKeys]
        )
        return NightlyQualityCandidate(
            engine: .fused,
            model: "Gemma \(modelKey) audio consensus · VibeVoice native structure",
            createdAt: Date(),
            segments: segments,
            provenance: NightlyQualityCandidateProvenance(
                role: "vibevoice_anchored_audio_consensus",
                engineIdentifier: "gemma_audio_consensus",
                modelIdentifier: modelKey,
                modelRevision: nil,
                runtimeRevision: "llama-server input_audio",
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
                  !original.userProtected,
                  consensus.filter({ $0.supportingUtteranceIDs == [id] }).count == 1 else {
                return nil
            }
            return NightlyQualityDecision(
                utteranceID: id,
                originalText: original.text,
                finalText: segment.text,
                confidence: segment.confidence ?? "medium",
                source: segment.source ?? "gemma_audio_consensus",
                estimatedInputTokens: 0
            )
        }
    }

    private func timeLabel(_ start: TimeInterval, _ end: TimeInterval) -> String {
        "\(String(format: "%.2f", start))–\(String(format: "%.2f", end))"
    }
}

private extension Array {
    func chunked(maxCount: Int) -> [[Element]] {
        guard maxCount > 0 else { return [self] }
        return stride(from: 0, to: count, by: maxCount).map {
            Array(self[$0..<Swift.min($0 + maxCount, count)])
        }
    }
}
