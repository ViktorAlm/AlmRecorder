import AVFoundation
import Combine
import Foundation

final class VibeVoiceService: ObservableObject {
    static let shared = VibeVoiceService()

    @Published private(set) var isTranscribing = false
    @Published private(set) var transcriptionStatus = ""
    @Published private(set) var transcriptionProgress: Double = 0

    private(set) var lastTranscriptionResult: TranscriptionResult?
    private(set) var lastPeakMemoryGB: Double?
    private(set) var lastModelProcessingSeconds: TimeInterval?

    private let modelManager: VibeVoiceModelManager
    private let runner: VibeVoiceHelperRunner

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

    func transcribe(
        audioFile: String,
        selection: TranscriptionEngineSelection,
        runSettings: RunSettings?,
        speakerConfiguration: SpeakerPipelineConfiguration
    ) async throws -> String {
        lastTranscriptionResult = nil
        lastPeakMemoryGB = nil
        lastModelProcessingSeconds = nil
        let quantization = selection.vibeVoiceQuantization ?? .sixBit
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
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            if let deferral = SystemMemoryGate.shared.transcriptionDeferral(
                profile: resourceProfile
            ) {
                throw TranscriptionError.resourcesUnavailable(deferral.reason)
            }
            let windowDuration = try await duration(of: window)
            await update(
                status: "VibeVoice pass \(index + 1) of \(windows.count)…",
                progress: 0.05 + 0.65 * Double(index) / Double(max(1, windows.count)),
                active: true
            )
            let parsed = try await transcribeWindow(
                window,
                duration: windowDuration,
                offset: offset,
                quantization: quantization,
                context: selection.vibeVoiceContext,
                resourceProfile: resourceProfile
            )
            rawChunks.append(contentsOf: parsed.chunks)
            language = parsed.language ?? language
            if let peak = parsed.peakMemoryGB {
                peakMemoryGB = max(peakMemoryGB ?? 0, peak)
            }
            modelProcessingSeconds += parsed.processingSeconds ?? 0
            offset += windowDuration
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
        await update(status: "VibeVoice complete", progress: 1, active: false)
        return transcript
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
        SystemMemoryGate.shared.reportGPUJobSuccess()
        return output
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
    /// A duration-scaled ceiling prevents a short malformed response from generating tens of
    /// thousands of tokens while retaining nearly the full 32K allowance for hour-long audio.
    /// This deliberately does not reuse the Voxtral-oriented Run Settings token preference.
    static func generationTokenBudget(audioDuration: TimeInterval) -> Int {
        let durationMinutes = max(0, audioDuration) / 60
        let durationScaledBudget = 512 + Int(ceil(durationMinutes * 512))
        return min(32_768, max(768, durationScaledBudget))
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
