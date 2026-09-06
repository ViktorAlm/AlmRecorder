import Darwin
import Foundation

#if false
// DEFERRED: persistent multimodal Gemma worker and audio clip preparation.
//
// No production path may start this worker or issue `/audio`. Gemma is text-only until audio
// transcription is separately reintroduced and benchmarked.

/// `FileHandle.readabilityHandler` delivers bytes in stream order. Keep appending synchronously:
/// spawning an unstructured `Task` per callback can reorder adjacent chunks and corrupt UTF-8,
/// echoed prompts, and JSON responses before the actor ever sees them.
private final class GemmaProcessOutputBuffer: @unchecked Sendable {
    private var value = ""
    private let maximumCharacters = 2_000_000
    private let lock = NSLock()

    func append(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        value.append(text)
        if value.count > maximumCharacters {
            value.removeFirst(value.count - maximumCharacters)
        }
    }

    func takeThrough(_ marker: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let range = value.range(of: marker) else { return nil }
        let result = String(value[..<range.lowerBound])
        value.removeSubrange(..<range.upperBound)
        return result
    }

    func tail(_ count: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(value.suffix(max(0, count)))
    }
}
#endif

actor NightlyQualityTelemetryState {
    private var value: NightlyQualityTelemetry

    init(_ value: NightlyQualityTelemetry) {
        self.value = value
    }

    func updateMemory(current: UInt64?, peak: UInt64?, available: UInt64?) {
        value.currentRAMBytes = current
        value.peakRAMBytes = peak
        value.systemAvailableBytes = available
    }

    func updateWork(currentTokens: Int, cumulativeTokens: Int, completedWindows: Int) {
        value.currentInputTokens = currentTokens
        value.cumulativeInputTokens = cumulativeTokens
        value.completedWindows = completedWindows
    }

    func updatePhase(currentClip: Int?, totalClips: Int?, phase: String) {
        value.currentClip = currentClip
        value.totalClips = totalClips
        value.currentPhase = phase
    }

    func snapshot() -> NightlyQualityTelemetry {
        value
    }
}

#if false
// DEFERRED: all remaining declarations implement Gemma audio attachment/transcription.
enum PersistentGemmaWorkerError: Error, LocalizedError {
    case unavailable
    case startupTimedOut
    case responseTimedOut
    case processExited(String)
    case mediaAttachmentFailed(String)
    case invalidResponse
    case inputTooLarge(estimated: Int, maximum: Int)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Gemma or its audio projector is unavailable"
        case .startupTimedOut:
            return "Gemma did not finish loading within two minutes"
        case .responseTimedOut:
            return "Gemma finalization window timed out"
        case .processExited(let detail):
            return detail.isEmpty ? "The persistent Gemma worker exited" : detail
        case .mediaAttachmentFailed(let detail):
            return detail.isEmpty
                ? "Gemma could not load the audio clip"
                : "Gemma could not load the audio clip: \(detail)"
        case .invalidResponse:
            return "Gemma returned an invalid finalization response"
        case .inputTooLarge(let estimated, let maximum):
            return "Gemma input is \(estimated) estimated tokens; maximum is \(maximum)"
        }
    }
}

/// The segment extractor preserves the source recording's native PCM format. Voice Memos commonly
/// produces 48 kHz Float32 WAV data, which llama.cpp's mtmd WAV loader rejects. Normalize every
/// Gemma attachment to the decoder's known-good 16 kHz mono PCM16 format before `/audio`.
enum GemmaAudioClipPreparer {
    static func prepare(_ extractedAudio: Data) async throws -> URL {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let identifier = UUID().uuidString
        let sourceURL = temporaryDirectory
            .appendingPathComponent("nightly-gemma-\(identifier)-source.wav")
        let normalizedURL = temporaryDirectory
            .appendingPathComponent("nightly-gemma-\(identifier)-16k-pcm16.wav")

        do {
            try extractedAudio.write(to: sourceURL, options: .atomic)
            _ = try await AudioPreprocessor().convertToWAV(
                sourceURL: sourceURL,
                sampleRate: GemmaConfiguration.audioSampleRate,
                outputURL: normalizedURL
            )
            try? FileManager.default.removeItem(at: sourceURL)
            return normalizedURL
        } catch {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: normalizedURL)
            throw error
        }
    }
}

/// Persistent chat-mode wrapper around llama-mtmd-cli. `/clear` resets the KV cache between audio
/// windows while retaining model weights and the BF16 audio projector, avoiding 150–300 model
/// reloads for one or two hours of daily audio.
actor PersistentGemmaFinalizerWorker {
    typealias TelemetryHandler = @Sendable (UInt64?, UInt64?, UInt64?) async -> Void

    /// Google's Gemma 4 ASR guide uses `max_new_tokens = 64`. Keeping the documented bound also
    /// prevents a malformed turn from spending minutes hallucinating after the transcript.
    static let maximumOutputTokens = 64

    private let output = GemmaProcessOutputBuffer()
    private let errors = GemmaProcessOutputBuffer()
    private var process: Process?
    private var input: FileHandle?
    private var monitorTask: Task<Void, Never>?
    private var peakRAMBytes: UInt64?
    private var resourceProfile: TranscriptionResourceProfile?
    private var telemetryHandler: TelemetryHandler?

    private static let promptMarker = "\n> "

    func start(
        modelKey: String,
        maximumInputTokens: Int,
        onTelemetry: TelemetryHandler? = nil
    ) async throws {
        if process?.isRunning == true { return }

        let manager = GemmaModelManager()
        let runner = LlamaCppProcessRunner(engineParameters: GemmaConfiguration.processParameters)
        guard runner.isLlamaInstalled,
              manager.isModelDownloaded(modelKey),
              let model = manager.getModelPath(for: modelKey),
              let mmproj = manager.getMmprojPath(for: modelKey) else {
            throw PersistentGemmaWorkerError.unavailable
        }

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
        let profile = TranscriptionResourceProfile.forSelection(selection)
        if let deferral = SystemMemoryGate.shared.transcriptionDeferral(profile: profile) {
            throw TranscriptionError.resourcesUnavailable(deferral.reason)
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: runner.llamaMtmdPath)
        process.arguments = [
            "-m", model.path,
            "--mmproj", mmproj.path,
            "--jinja",
            "--reasoning", "off",
            "-ngl", "99",
            "--ctx-size", String(max(4_096, maximumInputTokens + 2_048)),
            "--temp", "1.0",
            "--top-k", "64",
            "--top-p", "0.95",
            "--seed", "42",
            "-n", String(Self.maximumOutputTokens),
            "--log-verbosity", "2"
        ]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        LlamaRuntime.applyLibraryPath(to: process, binaryPath: runner.llamaMtmdPath)
        try Self.preventSIGPIPE(on: inputPipe.fileHandleForWriting)

        outputPipe.fileHandleForReading.readabilityHandler = { [output] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            output.append(data)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [errors] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            errors.append(data)
        }

        try process.run()
        ChildProcessReaper.shared.track(process, label: "persistent-gemma-finalizer")
        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.resourceProfile = profile
        self.telemetryHandler = onTelemetry
        startMemoryMonitor(pid: process.processIdentifier, profile: profile)

        do {
            _ = try await readUntilPrompt(timeout: 120)
        } catch {
            await stop()
            if error is PersistentGemmaWorkerError {
                throw error
            }
            throw PersistentGemmaWorkerError.startupTimedOut
        }
    }

    func adjudicate(
        audioURL: URL,
        prompt: String,
        estimatedInputTokens: Int,
        maximumInputTokens: Int
    ) async throws -> String {
        guard estimatedInputTokens <= maximumInputTokens else {
            throw PersistentGemmaWorkerError.inputTooLarge(
                estimated: estimatedInputTokens,
                maximum: maximumInputTokens
            )
        }
        guard process?.isRunning == true, let input else {
            throw PersistentGemmaWorkerError.processExited(errors.tail(4_000))
        }

        try write("/clear\n", to: input)
        _ = try await readUntilPrompt(timeout: 30)

        try write("/audio \(audioURL.path)\n", to: input)
        _ = try await readUntilAudioAcknowledged(audioURL: audioURL, timeout: 60)

        // Chat mode reads one line as one user turn. Our bundled mtmd CLI holds the already-loaded
        // audio marker until this text arrives, yielding Google's required text-then-audio order.
        // Keep structured payloads on a single line.
        let singleLinePrompt = prompt
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        try write(singleLinePrompt + "\n", to: input)
        let raw = try await readUntilPrompt(timeout: 300)
        let answer = Self.generatedAnswer(from: raw, echoedPrompt: singleLinePrompt)
        if answer.isEmpty {
            let diagnostic = raw
                .replacingOccurrences(of: "\0", with: "")
                .replacingOccurrences(of: "\n", with: "\\n")
                .prefix(8_000)
            VoxtralLogger.shared.warning(
                "[PersistentGemma] Empty generated answer. Raw turn "
                    + "(\(raw.count) chars): \(diagnostic)"
            )
        }
        return answer
    }

    static func audioLoadWasAcknowledged(_ output: String, audioURL: URL) -> Bool {
        let normalized = output
            .replacingOccurrences(
                of: #"\u{001B}\[[0-9;?]*[ -/]*[@-~]"#,
                with: "",
                options: .regularExpression
            )
            .lowercased()
        return normalized.contains("audio loaded")
            && normalized.contains(audioURL.lastPathComponent.lowercased())
    }

    static func isMissingAudioRefusal(_ text: String) -> Bool {
        let normalized = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let mentionsAudio = normalized.contains("audio")
            || normalized.contains("clip")
            || normalized.contains("file")
        let reportsMissing = normalized.contains("no audio")
            || normalized.contains("not provided")
            || normalized.contains("not attached")
            || normalized.contains("haven't provided")
            || normalized.contains("cannot hear")
            || normalized.contains("can't hear")
            || normalized.contains("cannot see")
            || normalized.contains("can't see")
            || normalized.contains("unable to hear")
            || normalized.contains("unable to access")
        let requestsAttachment = normalized.contains("please upload")
            || normalized.contains("please provide")
            || normalized.contains("attach the")
        return mentionsAudio && (reportsMissing || requestsAttachment)
    }

    /// The experimental mtmd chat CLI uses a terminal-oriented reader that echoes piped input to
    /// stdout. Remove that echo and console/control sequences before treating the remainder as the
    /// model answer.
    static func generatedAnswer(from raw: String, echoedPrompt: String) -> String {
        var answer = raw.replacingOccurrences(
            of: #"\u{001B}\[[0-9;?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression
        )
        if answer.hasPrefix(echoedPrompt) {
            answer.removeFirst(echoedPrompt.count)
        } else if let echo = answer.range(of: echoedPrompt) {
            answer.removeSubrange(answer.startIndex..<echo.upperBound)
        }
        answer = GemmaConfiguration.stripThoughtChannel(answer)
        for token in GemmaConfiguration.systemTokensToRemove {
            answer = answer.replacingOccurrences(of: token, with: "")
        }
        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func stop() async {
        monitorTask?.cancel()
        monitorTask = nil

        if let input {
            try? write("/quit\n", to: input)
            try? input.close()
        }
        if let process, process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            try? await Task.sleep(for: .seconds(1))
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
        if let process {
            ChildProcessReaper.shared.untrack(process)
        }
        process = nil
        input = nil
        resourceProfile = nil
        telemetryHandler = nil
    }

    var peakMemoryBytes: UInt64? {
        peakRAMBytes
    }

    /// llama.cpp reports evaluated prompt tokens on stderr. Audio builds that omit the perf line
    /// simply return nil and the caller retains the conservative preflight estimate.
    func latestInputTokenCount() async -> Int? {
        let log = errors.tail(16_000)
        guard let regex = try? NSRegularExpression(
            pattern: #"prompt eval time\s*=.*?/\s*([0-9]+)\s+tokens"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(log.startIndex..<log.endIndex, in: log)
        guard let match = regex.matches(in: log, range: range).last,
              match.numberOfRanges > 1,
              let tokenRange = Range(match.range(at: 1), in: log) else {
            return nil
        }
        return Int(log[tokenRange])
    }

    /// Darwin normally terminates the entire app with SIGPIPE when a subprocess exits between the
    /// `isRunning` check and this write. Disable SIGPIPE on this descriptor so Foundation reports
    /// EPIPE as a throwable error and the nightly controller can requeue the stage safely.
    static func preventSIGPIPE(on handle: FileHandle) throws {
        guard Darwin.fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func write(_ string: String, to handle: FileHandle) throws {
        guard process?.isRunning == true else {
            throw PersistentGemmaWorkerError.processExited(errors.tail(4_000))
        }
        do {
            try handle.write(contentsOf: Data(string.utf8))
        } catch {
            let processErrors = errors.tail(4_000)
            let detail = processErrors.isEmpty ? error.localizedDescription : processErrors
            throw PersistentGemmaWorkerError.processExited(detail)
        }
    }

    private func readUntilPrompt(timeout: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = output.takeThrough(Self.promptMarker) {
                return result
            }
            if process?.isRunning != true {
                throw PersistentGemmaWorkerError.processExited(errors.tail(4_000))
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw timeout >= 100
            ? PersistentGemmaWorkerError.startupTimedOut
            : PersistentGemmaWorkerError.responseTimedOut
    }

    /// The terminal-oriented mtmd reader can emit an intermediate prompt while it is echoing a
    /// piped command. Do not interpret that first prompt as completion and delete the clip out
    /// from under the decoder; keep consuming prompt-delimited output until the CLI confirms the
    /// exact attachment or reports an explicit decoder failure.
    private func readUntilAudioAcknowledged(
        audioURL: URL,
        timeout: TimeInterval
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        let errorBaseline = errors.tail(16_000)
        var combinedOutput = ""

        while Date() < deadline {
            if let chunk = output.takeThrough(Self.promptMarker) {
                combinedOutput.append(chunk)
                if Self.audioLoadWasAcknowledged(combinedOutput, audioURL: audioURL) {
                    return combinedOutput
                }
            }

            let currentErrors = errors.tail(16_000)
            let newErrors: String
            if currentErrors.hasPrefix(errorBaseline) {
                newErrors = String(currentErrors.dropFirst(errorBaseline.count))
            } else {
                newErrors = currentErrors
            }
            let normalizedErrors = newErrors.lowercased()
            if normalizedErrors.contains("unable to read wav")
                || normalizedErrors.contains("failed to decode buffer")
                || normalizedErrors.contains("does not support audio input") {
                throw audioAttachmentFailure(
                    output: combinedOutput,
                    errors: newErrors
                )
            }
            if process?.isRunning != true {
                throw PersistentGemmaWorkerError.processExited(errors.tail(4_000))
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        throw audioAttachmentFailure(
            output: combinedOutput,
            errors: errors.tail(4_000)
        )
    }

    private func audioAttachmentFailure(
        output: String,
        errors: String
    ) -> PersistentGemmaWorkerError {
        let diagnostic = (output + "\n" + errors)
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        VoxtralLogger.shared.error(
            "[PersistentGemma] Refusing text-only turn because /audio was not acknowledged: "
                + String(diagnostic.prefix(4_000))
        )
        return .mediaAttachmentFailed(String(diagnostic.suffix(1_000)))
    }

    private func startMemoryMonitor(
        pid: pid_t,
        profile: TranscriptionResourceProfile
    ) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard kill(pid, 0) == 0 else { return }
                let current = SystemMemoryDiagnostics.physicalFootprint(pid: pid)
                let available = SystemMemoryGate.memorySnapshot()?.availableBytes
                await self?.recordMemory(current: current, available: available)
                if let reason = SystemMemoryGate.shared.transcriptionEmergencyReason(
                    profile: profile
                ) {
                    VoxtralLogger.shared.warning(
                        "[PersistentGemma] Stopping to protect system memory: \(reason)"
                    )
                    kill(pid, SIGTERM)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func recordMemory(current: UInt64?, available: UInt64?) async {
        if let current {
            peakRAMBytes = max(peakRAMBytes ?? 0, current)
        }
        await telemetryHandler?(current, peakRAMBytes, available)
    }
}

private struct LegacyGemmaFinalizationResult {
    let decisions: [NightlyQualityDecision]
    let cumulativeInputTokens: Int
    let peakRAMBytes: UInt64?
}

/// Builds bounded audio windows over the committed Whisper utterances, adds time-overlapping
/// VibeVoice candidates, and asks the persistent Gemma worker for a strict line-for-line result.
/// No database writes occur here; the controller applies a complete result atomically afterward.
private struct LegacyNightlyGemmaFinalizer {
    typealias ProgressHandler = @Sendable (NightlyQualityTelemetry) async -> Void

    private struct Response: Decodable {
        struct Line: Decodable {
            let id: Int64
            let text: String
            let confidence: String
            let source: String
        }
        let lines: [Line]
    }

    private struct Span {
        let lines: [NightlyQualityCandidateSegment]
        let audioStart: TimeInterval
        let audioEnd: TimeInterval
    }

    let maximumInputTokens: Int
    let modelKey: String

    func finalize(
        artifact: NightlyQualityArtifact,
        audioPath: String,
        language: String?,
        onProgress: ProgressHandler? = nil
    ) async throws -> LegacyGemmaFinalizationResult {
        let spans = makeSpans(artifact.whisper.segments)
        guard !spans.isEmpty else {
            return LegacyGemmaFinalizationResult(
                decisions: [],
                cumulativeInputTokens: 0,
                peakRAMBytes: nil
            )
        }

        let worker = PersistentGemmaFinalizerWorker()
        let telemetryState = NightlyQualityTelemetryState(NightlyQualityTelemetry(
            maximumInputTokens: maximumInputTokens,
            totalWindows: spans.count,
            estimatedModelPeakBytes: TranscriptionResourceProfile.forSelection(
                TranscriptionEngineSelection(
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
            ).estimatedPeakBytes
        ))

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

        var decisions: [NightlyQualityDecision] = []
        var cumulativeInputTokens = 0
        for (index, span) in spans.enumerated() {
            try Task.checkCancellation()
            let prompt = buildPrompt(
                span: span,
                allWhisper: artifact.whisper.segments,
                vibeVoice: artifact.vibeVoice?.segments ?? [],
                language: language
            )
            let duration = span.audioEnd - span.audioStart
            let tokenEstimate = GemmaInputBudget.estimatedInputTokens(
                prompt: prompt,
                audioDuration: duration
            )
            guard tokenEstimate <= maximumInputTokens else {
                throw PersistentGemmaWorkerError.inputTooLarge(
                    estimated: tokenEstimate,
                    maximum: maximumInputTokens
                )
            }

            cumulativeInputTokens += tokenEstimate
            await telemetryState.updateWork(
                currentTokens: tokenEstimate,
                cumulativeTokens: cumulativeInputTokens,
                completedWindows: index
            )
            await onProgress?(await telemetryState.snapshot())

            let clip = try await AudioSegmentExtractor.shared.extractSegment(
                from: audioPath,
                startTime: span.audioStart,
                endTime: span.audioEnd,
                padding: 0
            )
            let clipURL = try await GemmaAudioClipPreparer.prepare(clip)

            let raw: String
            do {
                defer { try? FileManager.default.removeItem(at: clipURL) }
                raw = try await worker.adjudicate(
                    audioURL: clipURL,
                    prompt: prompt,
                    estimatedInputTokens: tokenEstimate,
                    maximumInputTokens: maximumInputTokens
                )
            }
            guard !PersistentGemmaFinalizerWorker.isMissingAudioRefusal(raw) else {
                throw PersistentGemmaWorkerError.mediaAttachmentFailed(raw)
            }
            let observedTokens = await worker.latestInputTokenCount()
            let recordedTokens = observedTokens ?? tokenEstimate
            if observedTokens != nil {
                cumulativeInputTokens += recordedTokens - tokenEstimate
                await telemetryState.updateWork(
                    currentTokens: recordedTokens,
                    cumulativeTokens: cumulativeInputTokens,
                    completedWindows: index
                )
                await onProgress?(await telemetryState.snapshot())
            }
            guard let response = Self.parseResponse(raw),
                  response.lines.count == span.lines.count,
                  Set(response.lines.map(\.id))
                    == Set(span.lines.compactMap(\.utteranceID)),
                  response.lines.allSatisfy({
                      ["high", "medium", "low"].contains($0.confidence.lowercased())
                          && ["whisper", "vibevoice", "audio", "combined"].contains(
                              $0.source.lowercased()
                          )
                  }) else {
                throw PersistentGemmaWorkerError.invalidResponse
            }
            let originals = Dictionary(
                uniqueKeysWithValues: span.lines.compactMap { line in
                    line.utteranceID.map { ($0, line.text) }
                }
            )
            decisions.append(contentsOf: response.lines.compactMap { line in
                guard let original = originals[line.id] else { return nil }
                let final = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !final.isEmpty else { return nil }
                return NightlyQualityDecision(
                    utteranceID: line.id,
                    originalText: original,
                    finalText: final,
                    confidence: line.confidence.lowercased(),
                    source: line.source,
                    estimatedInputTokens: recordedTokens
                )
            })

            await telemetryState.updateWork(
                currentTokens: tokenEstimate,
                cumulativeTokens: cumulativeInputTokens,
                completedWindows: index + 1
            )
            await onProgress?(await telemetryState.snapshot())
        }

        let peak = await worker.peakMemoryBytes
        await worker.stop()
        return LegacyGemmaFinalizationResult(
            decisions: decisions,
            cumulativeInputTokens: cumulativeInputTokens,
            peakRAMBytes: peak
        )
    }

    private func makeSpans(
        _ candidates: [NightlyQualityCandidateSegment]
    ) -> [Span] {
        let lines = candidates
            .filter { $0.utteranceID != nil && !$0.userProtected }
            .sorted { $0.startTime < $1.startTime }
        var groups: [[NightlyQualityCandidateSegment]] = []
        var current: [NightlyQualityCandidateSegment] = []

        for line in lines {
            if let first = current.first, let previous = current.last {
                let proposedStart = max(0, first.startTime - 0.75)
                let proposedEnd = line.endTime + 0.75
                if proposedEnd - proposedStart > 24
                    || line.startTime - previous.endTime > 2
                    || current.count >= 6 {
                    groups.append(current)
                    current = []
                }
            }
            current.append(line)
        }
        if !current.isEmpty { groups.append(current) }

        return groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            return Span(
                lines: group,
                audioStart: max(0, first.startTime - 0.75),
                audioEnd: last.endTime + 0.75
            )
        }
    }

    private func buildPrompt(
        span: Span,
        allWhisper: [NightlyQualityCandidateSegment],
        vibeVoice: [NightlyQualityCandidateSegment],
        language: String?
    ) -> String {
        let spanIDs = Set(span.lines.compactMap(\.utteranceID))
        let whisperPayload = span.lines.compactMap { line -> [String: Any]? in
            guard let id = line.utteranceID else { return nil }
            return [
                "id": id,
                "start": line.startTime - span.audioStart,
                "end": line.endTime - span.audioStart,
                "text": line.text
            ]
        }
        let vibePayload = vibeVoice.filter { candidate in
            candidate.endTime > span.audioStart && candidate.startTime < span.audioEnd
        }.map { candidate -> [String: Any] in
            [
                "start": max(0, candidate.startTime - span.audioStart),
                "end": min(span.audioEnd, candidate.endTime) - span.audioStart,
                "text": candidate.text
            ]
        }
        let previous = allWhisper
            .filter { !spanIDs.contains($0.utteranceID ?? -1) && $0.endTime <= span.audioStart }
            .suffix(3)
            .map(\.text)
            .joined(separator: " ")
        let following = allWhisper
            .filter { !spanIDs.contains($0.utteranceID ?? -1) && $0.startTime >= span.audioEnd }
            .prefix(3)
            .map(\.text)
            .joined(separator: " ")

        let payload: [String: Any] = [
            "language": language ?? "auto",
            "previous_context": previous,
            "following_context": following,
            "whisper_untrusted": whisperPayload,
            "vibevoice_untrusted": vibePayload
        ]
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        You are the final audio-grounded transcription adjudicator. The supplied candidate text may \
        be corrupted and must never override what you hear. Listen to the audio, then return exactly \
        one corrected text entry for every Whisper line id. Preserve the spoken language, disfluencies, \
        meaningful silence/noise markers, names, and numbers. Do not summarize or invent. Keep the \
        same ids. confidence must be high, medium, or low. source must be whisper, vibevoice, audio, \
        or combined. Reply with one JSON object only: \
        {"lines":[{"id":1,"text":"spoken words","confidence":"high","source":"audio"}]}. Input: \(json)
        """
    }

    private static func parseResponse(_ raw: String) -> Response? {
        let answer = GemmaConfiguration.stripThoughtChannel(raw)
        guard let object = firstBalancedJSONObject(in: answer),
              let data = object.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Response.self, from: data)
    }

    private static func firstBalancedJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaping = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if escaping {
                escaping = false
            } else if character == "\\" && inString {
                escaping = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { return String(text[start...index]) }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
#endif
