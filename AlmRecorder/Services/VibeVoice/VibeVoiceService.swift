import AVFoundation
import Combine
import Foundation

final class VibeVoiceService: ObservableObject {
    static let shared = VibeVoiceService()
    static let maximumRecoveryDepth = 3
    static let terminalRecoveryRetryLimit = 1

    @Published private(set) var isTranscribing = false
    @Published private(set) var transcriptionStatus = ""
    @Published private(set) var transcriptionProgress: Double = 0

    private(set) var lastTranscriptionResult: TranscriptionResult?
    private(set) var lastPeakMemoryGB: Double?
    private(set) var lastModelProcessingSeconds: TimeInterval?

    private let modelManager: VibeVoiceModelManager
    private let runner: VibeVoiceHelperRunner
    private let logger = VoxtralLogger.shared

    // Durable outer-window resume state, supplied by TranscriptionWorker. Recovery subwindows are
    // intentionally committed only after their complete parent window succeeds.
    var activeCheckpoint: TranscriptionCheckpoint?
    var onWindowCompleted: ((Int, [TranscriptionChunk], TimeInterval) async -> Void)?
    var onWindowRecoveryDepthIncreased: ((Int, Int) async -> Void)?

    init(
        modelManager: VibeVoiceModelManager = .shared,
        runner: VibeVoiceHelperRunner = VibeVoiceHelperRunner()
    ) {
        self.modelManager = modelManager
        self.runner = runner
    }

    var isRuntimeInstalled: Bool {
        VibeVoiceHelperRunner.resolveCommand() != nil
    }

    func validateRuntime() async throws {
        try await runner.probe()
    }

    func cancel() {
        runner.cancel()
    }

    func setMemoryTelemetryHandler(
        _ handler: VibeVoiceHelperRunner.MemoryTelemetryHandler?
    ) {
        runner.setMemoryTelemetryHandler(handler)
    }

    func transcribe(
        audioFile: String,
        selection: TranscriptionEngineSelection,
        runSettings: RunSettings?,
        speakerConfiguration: SpeakerPipelineConfiguration
    ) async throws -> String {
        lastTranscriptionResult = nil
        lastPeakMemoryGB = nil
        lastModelProcessingSeconds = nil
        let quantization = selection.vibeVoiceQuantization
            ?? TranscriptionProductionDefaults.vibeVoiceQuantization
        let installedModelRevision = VibeVoiceConfiguration.modelRevision(for: quantization)
        if let requestedRevision = selection.vibeVoiceModelRevision,
           requestedRevision != installedModelRevision {
            throw TranscriptionError.transcriptionFailed(
                "This queued job requires VibeVoice model revision \(requestedRevision), "
                    + "but this app provides \(installedModelRevision). Requeue it explicitly "
                    + "to use the new model."
            )
        }
        if let requestedRuntime = selection.vibeVoiceRuntimeRevision,
           requestedRuntime != VibeVoiceConfiguration.mlxAudioRevision {
            throw TranscriptionError.transcriptionFailed(
                "This queued job requires MLX-Audio revision \(requestedRuntime), "
                    + "but this app provides \(VibeVoiceConfiguration.mlxAudioRevision). "
                    + "Requeue it explicitly to use the new runtime."
            )
        }
        guard modelManager.isModelDownloaded(quantization) else {
            throw TranscriptionError.modelNotLoaded
        }
        let resourceProfile = TranscriptionResourceProfile.vibeVoice(quantization)
        if let deferral = SystemMemoryGate.shared.transcriptionDeferral(
            profile: resourceProfile
        ) {
            throw TranscriptionError.resourcesUnavailable(deferral.reason)
        }
        try await validateRuntime()
        let originalSourceURL = URL(fileURLWithPath: audioFile)
        guard FileManager.default.fileExists(atPath: originalSourceURL.path) else {
            throw TranscriptionError.invalidURL
        }

        await update(status: "Preparing VibeVoice…", progress: 0.02, active: true)
        defer {
            Task { await self.update(status: "", progress: 0, active: false) }
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("almrec-vibevoice-windows-\(UUID().uuidString)",
                                    isDirectory: true)
        defer {
            if FileManager.default.fileExists(atPath: temporaryDirectory.path) {
                do {
                    try FileManager.default.removeItem(at: temporaryDirectory)
                } catch {
                    // Temporary cleanup must never turn a successful transcription into a failed
                    // queue job. The OS will reclaim anything that remains in this directory.
                }
            }
        }
        var sourceURL = originalSourceURL
        let directlySupportedExtensions = Set(["wav", "m4a", "mp3"])
        if !directlySupportedExtensions.contains(originalSourceURL.pathExtension.lowercased()) {
            await update(
                status: "Converting audio to 16 kHz mono…",
                progress: 0.03,
                active: true
            )
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )
            sourceURL = try await AudioPreprocessor().convertToWAV(
                sourceURL: originalSourceURL,
                sampleRate: 16_000,
                outputURL: temporaryDirectory.appendingPathComponent("vibevoice-input.wav")
            )
        }
        let totalDuration = try await duration(of: sourceURL)
        var windows: [URL] = [sourceURL]
        if totalDuration > VibeVoiceConfiguration.maximumSinglePassDuration {
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )
            await update(status: "Splitting long recording…", progress: 0.04, active: true)
            windows = try await AudioPreprocessor().splitAudioFile(
                sourceURL: sourceURL,
                chunkDuration: VibeVoiceConfiguration.longRecordingTargetDuration,
                outputDirectory: temporaryDirectory
            )
        }
        var rawChunks: [TranscriptionChunk] = []
        var language: String?
        var peakMemoryGB: Double?
        var modelProcessingSeconds: TimeInterval = 0
        var offset: TimeInterval = 0
        let checkpoint = activeCheckpoint?.backend == .vibeVoice
            ? activeCheckpoint
            : nil
        let restorableWindows = Set(
            Self.restorableWindowIndices(
                checkpoint: checkpoint,
                windowCount: windows.count
            )
        )
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            let windowDuration = try await duration(of: window)
            if restorableWindows.contains(index),
               let saved = checkpoint?.chunkTranscripts[index] {
                rawChunks.append(contentsOf: saved.map(\.transcriptionChunk))
                offset = checkpoint?.chunkOffsets[index] ?? (offset + windowDuration)
                await update(
                    status: "Restored VibeVoice pass \(index + 1) of \(windows.count)…",
                    progress: 0.05 + 0.65 * Double(index + 1) / Double(max(1, windows.count)),
                    active: true
                )
                logger.info(
                    "[VibeVoice] Restored completed pass \(index + 1)/\(windows.count) "
                        + "from durable checkpoint"
                )
                continue
            }
            if let deferral = SystemMemoryGate.shared.transcriptionDeferral(
                profile: resourceProfile
            ) {
                throw TranscriptionError.resourcesUnavailable(deferral.reason)
            }
            await update(
                status: "VibeVoice pass \(index + 1) of \(windows.count)…",
                progress: 0.05 + 0.65 * Double(index) / Double(max(1, windows.count)),
                active: true
            )
            let parsed = try await transcribeWindowRecoveringMalformedOutput(
                window,
                duration: windowDuration,
                offset: offset,
                quantization: quantization,
                context: selection.vibeVoiceContext,
                resourceProfile: resourceProfile,
                recoveryDepth: 0,
                minimumRecoveryDepth: min(
                    Self.maximumRecoveryDepth,
                    max(0, checkpoint?.vibeVoiceRecoveryDepths?[index] ?? 0)
                ),
                outerWindowIndex: index,
                terminalRetryAttempt: 0,
                speakerConfiguration: speakerConfiguration
            )
            rawChunks.append(contentsOf: parsed.chunks)
            language = parsed.language ?? language
            if let peak = parsed.peakMemoryGB {
                peakMemoryGB = max(peakMemoryGB ?? 0, peak)
            }
            modelProcessingSeconds += parsed.processingSeconds ?? 0
            offset += windowDuration
            await onWindowCompleted?(index, parsed.chunks, offset)
        }

        let speakerMode = selection.vibeVoiceSpeakerMode ?? .fused
        let finalChunks: [TranscriptionChunk]
        let speakerEmbeddings: [TranscriptionSpeakerEmbedding]
        if speakerMode == .fused {
            await update(status: "Fusing speaker evidence…", progress: 0.74, active: true)
            let fused = try await SpeakerPostProcessor.fuse(
                chunks: rawChunks,
                audioURL: sourceURL,
                configuration: speakerConfiguration
            )
            finalChunks = fused.chunks
            speakerEmbeddings = fused.speakerEmbeddings
        } else {
            finalChunks = rawChunks
            speakerEmbeddings = []
        }

        let transcript = LabeledTranscript.render(
            finalChunks.map {
                LabeledTranscript.Segment(
                    speakerUuid: $0.speakerUUID,
                    localLabel: $0.speaker,
                    text: $0.text
                )
            },
            resolver: SpeakerNameResolver()
        )
        lastTranscriptionResult = TranscriptionResult(
            fullTranscript: transcript,
            chunks: finalChunks,
            totalDuration: totalDuration,
            language: language,
            usedVAD: windows.count > 1,
            detectedSpeakerCount: Set(finalChunks.compactMap(\.speaker)).count,
            speakerEmbeddings: speakerEmbeddings.isEmpty ? nil : speakerEmbeddings
        )
        lastPeakMemoryGB = peakMemoryGB
        lastModelProcessingSeconds = modelProcessingSeconds > 0
            ? modelProcessingSeconds
            : nil
        activeCheckpoint = nil
        onWindowCompleted = nil
        onWindowRecoveryDepthIncreased = nil
        await update(status: "VibeVoice complete", progress: 1, active: false)
        return transcript
    }

    static func restorableWindowIndices(
        checkpoint: TranscriptionCheckpoint?,
        windowCount: Int
    ) -> [Int] {
        guard checkpoint?.backend == .vibeVoice,
              let checkpoint,
              windowCount > 0 else {
            return []
        }
        let completed = Set(checkpoint.processedChunks)
        var prefix: [Int] = []
        for index in 0..<windowCount {
            guard completed.contains(index),
                  checkpoint.chunkTranscripts[index]?.isEmpty == false else {
                break
            }
            prefix.append(index)
        }
        return prefix
    }

    /// Run one bounded VibeVoice pass. We used to catch an actual OOM here and immediately reload
    /// the model on smaller pieces. That is unsafe when compressor/swap are already saturated:
    /// reloading is another multi-GB allocation spike. The queue now cools down and retries only
    /// after strict admission succeeds.
    private func transcribeWindow(
        _ audioURL: URL,
        duration audioDuration: TimeInterval,
        offset: TimeInterval,
        quantization: VibeVoiceQuantization,
        context: String?,
        resourceProfile: TranscriptionResourceProfile
    ) async throws -> VibeVoiceOutput {
        let data = try await runner.run(
            arguments: helperArguments(
                audioURL: audioURL,
                modelURL: VibeVoiceConfiguration.modelDirectory(for: quantization),
                context: context,
                maxTokens: Self.generationTokenBudget(audioDuration: audioDuration),
                memoryLimitBytes: resourceProfile.estimatedPeakBytes
            ),
            resourceProfile: resourceProfile
        )
        let output = try VibeVoiceOutputParser.parse(
            data,
            duration: audioDuration,
            offset: offset
        )
        if output.outputLikelyTruncated {
            throw VibeVoiceWindowRecoveryError.likelyTruncated(
                generationTokens: output.generationTokens
            )
        }
        SystemMemoryGate.shared.reportGPUJobSuccess()
        return output
    }

    /// A quantized VibeVoice response can occasionally miss EOS or wrap otherwise valid turns in
    /// a shape that mlx-audio cannot decode. Retry only that bounded window in smaller pieces. The
    /// retry is deliberately finite so silence or truly invalid model output cannot loop forever.
    private func transcribeWindowRecoveringMalformedOutput(
        _ audioURL: URL,
        duration audioDuration: TimeInterval,
        offset: TimeInterval,
        quantization: VibeVoiceQuantization,
        context: String?,
        resourceProfile: TranscriptionResourceProfile,
        recoveryDepth: Int,
        minimumRecoveryDepth: Int,
        outerWindowIndex: Int,
        terminalRetryAttempt: Int,
        speakerConfiguration: SpeakerPipelineConfiguration
    ) async throws -> VibeVoiceOutput {
        var recoverableError: Error?
        if recoveryDepth >= minimumRecoveryDepth {
            do {
                return try await transcribeWindow(
                    audioURL,
                    duration: audioDuration,
                    offset: offset,
                    quantization: quantization,
                    context: context,
                    resourceProfile: resourceProfile
                )
            } catch {
                guard Self.isRecoverableOutputError(error) else { throw error }
                recoverableError = error
            }
        } else {
            logger.info(
                "[VibeVoice] Skipping previously failed \(Int(audioDuration))s shape at depth "
                    + "\(recoveryDepth); checkpoint requires depth \(minimumRecoveryDepth)"
            )
        }

        guard let recoveryDuration = Self.recoveryChunkDuration(
            audioDuration: audioDuration,
            recoveryDepth: recoveryDepth
        ) else {
            if recoverableError != nil,
               Self.shouldRetryTerminalWindow(
                   recoveryDepth: recoveryDepth,
                   attempt: terminalRetryAttempt
               ) {
                logger.warning(
                    "[VibeVoice] Retrying smallest \(Int(audioDuration))s window once with a "
                        + "fresh model process after malformed output"
                )
                await update(
                    status: "Retrying smallest VibeVoice section once…",
                    progress: transcriptionProgress,
                    active: true
                )
                return try await transcribeWindowRecoveringMalformedOutput(
                    audioURL,
                    duration: audioDuration,
                    offset: offset,
                    quantization: quantization,
                    context: context,
                    resourceProfile: resourceProfile,
                    recoveryDepth: recoveryDepth,
                    minimumRecoveryDepth: minimumRecoveryDepth,
                    outerWindowIndex: outerWindowIndex,
                    terminalRetryAttempt: terminalRetryAttempt + 1,
                    speakerConfiguration: speakerConfiguration
                )
            }
            if recoverableError != nil {
                return try await transcribeTerminalWindowWithWhisper(
                    audioURL,
                    duration: audioDuration,
                    offset: offset,
                    speakerConfiguration: speakerConfiguration
                )
            }
            throw TranscriptionError.transcriptionFailed(
                "VibeVoice recovery checkpoint exceeded the bounded recovery depth."
            )
        }

        await onWindowRecoveryDepthIncreased?(
            outerWindowIndex,
            recoveryDepth + 1
        )

        logger.warning(
            "[VibeVoice] Retrying malformed \(Int(audioDuration))s output "
                + "as \(Int(recoveryDuration))s windows (depth \(recoveryDepth + 1))"
        )
        await update(
            status: "Retrying VibeVoice in smaller sections…",
            progress: transcriptionProgress,
            active: true
        )

        let recoveryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "almrec-vibevoice-recovery-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: recoveryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: recoveryDirectory) }
        let pieces = try await AudioPreprocessor().splitAudioFile(
            sourceURL: audioURL,
            chunkDuration: recoveryDuration,
            outputDirectory: recoveryDirectory
        )

        var chunks: [TranscriptionChunk] = []
        var language: String?
        var peakMemoryGB: Double?
        var processingSeconds: Double = 0
        var pieceOffset = offset
        var recoveredAnyOutput = false
        for piece in pieces {
            try Task.checkCancellation()
            if let deferral = SystemMemoryGate.shared.transcriptionDeferral(
                profile: resourceProfile
            ) {
                throw TranscriptionError.resourcesUnavailable(deferral.reason)
            }
            let pieceDuration = try await duration(of: piece)
            let result = try await transcribeWindowRecoveringMalformedOutput(
                piece,
                duration: pieceDuration,
                offset: pieceOffset,
                quantization: quantization,
                context: context,
                resourceProfile: resourceProfile,
                recoveryDepth: recoveryDepth + 1,
                minimumRecoveryDepth: minimumRecoveryDepth,
                outerWindowIndex: outerWindowIndex,
                terminalRetryAttempt: 0,
                speakerConfiguration: speakerConfiguration
            )
            chunks.append(contentsOf: result.chunks)
            language = result.language ?? language
            if let peak = result.peakMemoryGB {
                peakMemoryGB = max(peakMemoryGB ?? 0, peak)
            }
            processingSeconds += result.processingSeconds ?? 0
            recoveredAnyOutput = recoveredAnyOutput || result.outputRecovered
            pieceOffset += pieceDuration
        }
        return VibeVoiceOutput(
            chunks: chunks,
            language: language,
            peakMemoryGB: peakMemoryGB,
            processingSeconds: processingSeconds > 0 ? processingSeconds : nil,
            outputRecovered: recoveredAnyOutput
        )
    }

    static func isRecoverableOutputError(_ error: Error) -> Bool {
        if error is VibeVoiceWindowRecoveryError {
            return true
        }
        guard let transcriptionError = error as? TranscriptionError,
              case let .processFailed(detail) = transcriptionError else {
            return false
        }
        return detail.contains("ALMREC_VIBEVOICE_RECOVERABLE_OUTPUT")
            || detail.contains("VibeVoice returned no parseable timestamped segments")
    }

    static func recoveryChunkDuration(
        audioDuration: TimeInterval,
        recoveryDepth: Int
    ) -> TimeInterval? {
        guard audioDuration.isFinite,
              audioDuration > 20,
              recoveryDepth < maximumRecoveryDepth else {
            return nil
        }
        return max(20, min(5 * 60, audioDuration / 3))
    }

    static func shouldRetryTerminalWindow(
        recoveryDepth: Int,
        attempt: Int
    ) -> Bool {
        recoveryDepth >= maximumRecoveryDepth
            && attempt < terminalRecoveryRetryLimit
    }

    /// VibeVoice can repeatedly miss EOS even on a 33-second section. After the fully bounded
    /// shape recovery and one fresh-process retry are exhausted, transcribe only that irreducible
    /// section with the already-selected Whisper model. The full-recording VibeVoice speaker-fusion
    /// pass still runs afterward, so this is a text safety net rather than a backend switch.
    private func transcribeTerminalWindowWithWhisper(
        _ audioURL: URL,
        duration audioDuration: TimeInterval,
        offset: TimeInterval,
        speakerConfiguration: SpeakerPipelineConfiguration
    ) async throws -> VibeVoiceOutput {
        logger.warning(
            "[VibeVoice] Smallest \(Int(audioDuration))s section remained malformed; "
                + "using Whisper Large safety fallback for this section only"
        )
        await update(
            status: "Recovering one section with Whisper Large…",
            progress: transcriptionProgress,
            active: true
        )

        let whisper = WhisperService.shared
        let previousCheckpoint = whisper.activeCheckpoint
        let previousCallback = whisper.onVADChunkCompleted
        whisper.activeCheckpoint = nil
        whisper.onVADChunkCompleted = nil
        defer {
            whisper.activeCheckpoint = previousCheckpoint
            whisper.onVADChunkCompleted = previousCallback
        }

        let result = try await whisper.transcribeWithResult(
            audioFile: audioURL.path,
            language: nil,
            speakerConfiguration: speakerConfiguration,
            persistSpeakerIdentities: false
        )
        let chunks = Self.offsetWhisperFallbackChunks(
            result.chunks,
            offset: offset,
            duration: audioDuration
        )
        guard !chunks.isEmpty else {
            throw TranscriptionError.transcriptionFailed(
                "Both VibeVoice and Whisper Large returned no timestamped speech for a bounded section."
            )
        }
        SystemMemoryGate.shared.reportGPUJobSuccess()
        return VibeVoiceOutput(
            chunks: chunks,
            language: result.language,
            peakMemoryGB: nil,
            processingSeconds: nil,
            outputRecovered: true
        )
    }

    static func offsetWhisperFallbackChunks(
        _ chunks: [TranscriptionChunk],
        offset: TimeInterval,
        duration: TimeInterval
    ) -> [TranscriptionChunk] {
        chunks.compactMap { chunk in
            let start = max(0, chunk.startTime)
            let end = min(duration, chunk.endTime)
            guard start.isFinite, end.isFinite, end > start else { return nil }
            let sourceLabel = chunk.nativeSpeakerLabel ?? chunk.speaker ?? "unknown"
            let fallbackLabel = "Whisper fallback \(sourceLabel)"
            var mapped = TranscriptionChunk(
                text: chunk.text,
                startTime: offset + start,
                endTime: offset + end,
                speaker: fallbackLabel,
                speakerUUID: nil,
                nativeSpeakerLabel: fallbackLabel,
                confidence: chunk.confidence
            )
            mapped.voiceEmbedding = chunk.voiceEmbedding
            mapped.voiceEmbeddingQuality = chunk.voiceEmbeddingQuality
            mapped.speakerOverlapRatio = chunk.speakerOverlapRatio
            mapped.activeSpeakerCount = chunk.activeSpeakerCount
            mapped.overlappingSpeakerLabels = chunk.overlappingSpeakerLabels
            mapped.speakerAssignmentSource = chunk.speakerAssignmentSource
            mapped.tokenStats = chunk.tokenStats
            return mapped
        }
    }

    private func helperArguments(
        audioURL: URL,
        modelURL: URL,
        context: String?,
        maxTokens: Int,
        memoryLimitBytes: UInt64
    ) -> [String] {
        var arguments = [
            "transcribe",
            "--audio", audioURL.path,
            "--model", modelURL.path,
            "--max-tokens", String(maxTokens),
            "--temperature", "0.0",
            "--memory-limit-bytes", String(memoryLimitBytes)
        ]
        if let context, !context.isEmpty {
            arguments.append(contentsOf: ["--context", context])
        }
        return arguments
    }

    /// VibeVoice normally emits an EOS token, but a quantized model can occasionally miss it.
    /// A duration-scaled ceiling prevents a malformed response from generating tens of thousands
    /// of tokens. Short recovery windows still need a generous floor: a real dense 100-second
    /// Voice Memo exhausted the old 1,366-token allowance despite yielding valid timestamped
    /// segments, which made the final bounded recovery fail solely because its budget was too low.
    /// This deliberately does not reuse the Voxtral-oriented Run Settings token preference.
    static func generationTokenBudget(audioDuration: TimeInterval) -> Int {
        let durationMinutes = max(0, audioDuration) / 60
        let durationScaledBudget = 512 + Int(ceil(durationMinutes * 512))
        return min(32_768, max(4_096, durationScaledBudget))
    }

    private func duration(of url: URL) async throws -> TimeInterval {
        let value = try await AVURLAsset(url: url).load(.duration)
        let seconds = CMTimeGetSeconds(value)
        guard seconds.isFinite, seconds > 0 else {
            throw TranscriptionError.transcriptionFailed("Audio duration is invalid.")
        }
        return seconds
    }

    private func update(status: String, progress: Double, active: Bool) async {
        await MainActor.run {
            self.transcriptionStatus = status
            self.transcriptionProgress = progress
            self.isTranscribing = active
        }
    }
}

private enum VibeVoiceWindowRecoveryError: LocalizedError {
    case likelyTruncated(generationTokens: Int?)

    var errorDescription: String? {
        switch self {
        case .likelyTruncated(let generationTokens):
            let count = generationTokens.map(String.init) ?? "unknown"
            return "VibeVoice output was truncated after \(count) generated tokens."
        }
    }
}
