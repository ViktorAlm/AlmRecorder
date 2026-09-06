import Foundation
import Combine

#if false
// DEFERRED: Gemma audio transcription.
//
// This historical implementation is intentionally excluded from the build. Gemma is currently
// text-only in AlmRecorder. Re-enable only behind a reviewed feature flag plus private audio
// benchmarks; never expose this service through a transcription picker or queue snapshot.

/// Orchestrates Gemma 4 audio transcription. Mirrors VoxtralCppService but with Gemma's engine
/// parameters (`--jinja`, non-greedy sampler), a <=30s VAD chunking config, and Gemma stop-token
/// cleanup. Reuses the generic VoxtralAudioConverter, VADAudioSplitter, and LlamaCppProcessRunner.
class GemmaCppService: ObservableObject {

    // MARK: - Published Properties

    @Published var isModelLoaded: Bool = false
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var currentModel: String = ""
    @Published var isTranscribing: Bool = false
    @Published var transcriptionStatus: String = ""
    @Published var transcriptionProgress: Double = 0.0

    /// Last transcription result (kept for parity with VoxtralCppService; Gemma diarization is not wired).
    var lastTranscriptionResult: TranscriptionResult?

    // MARK: - Components

    private let modelManager: GemmaModelManager
    private let audioConverter: VoxtralAudioConverter
    private let processRunner: LlamaCppProcessRunner
    private let logger: VoxtralLogger

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Computed Properties

    var isLlamaInstalled: Bool { processRunner.isLlamaInstalled }
    var availableModels: [String: LLMModelConfig] { GemmaConfiguration.models }

    // MARK: - Initialization

    init() {
        self.modelManager = GemmaModelManager()
        self.audioConverter = VoxtralAudioConverter()
        self.processRunner = LlamaCppProcessRunner(engineParameters: GemmaConfiguration.processParameters)
        self.logger = VoxtralLogger.shared

        setupBindings()
        logger.info("GemmaCppService initialized")
    }

    private func setupBindings() {
        modelManager.$isModelLoaded.assign(to: &$isModelLoaded)
        modelManager.$isDownloading.assign(to: &$isDownloading)
        modelManager.$downloadProgress.assign(to: &$downloadProgress)
        modelManager.$currentModel.assign(to: &$currentModel)
    }

    // MARK: - Model Management

    func downloadModel(quantization: String = GemmaConfiguration.defaultModel) async throws {
        logger.info("[Gemma] Downloading model: \(quantization)")
        try await modelManager.downloadModel(quantization)
    }

    func deleteModel(_ modelKey: String) throws {
        try modelManager.deleteModel(modelKey)
    }

    func isModelDownloaded(_ modelKey: String) -> Bool {
        modelManager.isModelDownloaded(modelKey)
    }

    func getModelSize(_ modelKey: String) -> Int64 {
        modelManager.getModelSize(modelKey)
    }

    // MARK: - Transcription

    /// Transcribe an audio file with Gemma. Files longer than ~28s are VAD-split into <30s chunks.
    func transcribe(audioFile: String, modelKey: String? = nil, runSettings: RunSettings? = nil) async throws -> String {
        let requested = modelKey ?? currentModel
        logger.info("[Gemma] Starting transcription for: \(audioFile) with model: \(requested)")

        await updateStatus("Checking model...", progress: 0.1)

        if !requested.isEmpty && !modelManager.isModelDownloaded(requested) {
            logger.error("[Gemma] Requested model not downloaded: \(requested)")
            throw TranscriptionError.modelNotFound
        }
        if requested.isEmpty {
            try await ensureModelLoaded()
        }

        let activeModel = requested.isEmpty ? currentModel : requested
        guard let modelPath = modelManager.getModelPath(for: activeModel),
              let mmprojPath = modelManager.getMmprojPath(for: activeModel) else {
            logger.error("[Gemma] Model paths not found for: \(activeModel)")
            await updateStatus("Model not found", progress: 0.0)
            throw TranscriptionError.modelNotFound
        }

        await MainActor.run { isTranscribing = true }

        do {
            await updateStatus("Validating audio file...", progress: 0.15)
            try audioConverter.validateAudioFile(audioFile)

            let duration = audioConverter.getAudioDuration(filePath: audioFile) ?? 0
            logger.info("[Gemma] Audio duration: \(Int(duration))s; chunking: \(duration > GemmaConfiguration.singleShotMaxDuration)")

            let transcript: String
            if duration > GemmaConfiguration.singleShotMaxDuration {
                transcript = try await transcribeChunked(
                    audioFile: audioFile,
                    modelPath: modelPath.path,
                    mmprojPath: mmprojPath.path,
                    runSettings: runSettings
                )
                lastTranscriptionResult = makeResult(transcript, audioFile: audioFile, usedVAD: true)
            } else {
                transcript = try await transcribeSingle(
                    audioFile: audioFile,
                    modelPath: modelPath.path,
                    mmprojPath: mmprojPath.path,
                    runSettings: runSettings
                )
                lastTranscriptionResult = makeResult(transcript, audioFile: audioFile, usedVAD: false)
            }

            await MainActor.run {
                isTranscribing = false
                transcriptionStatus = "Completed!"
                transcriptionProgress = 1.0
            }
            return transcript

        } catch {
            await MainActor.run {
                isTranscribing = false
                transcriptionStatus = "Error: \(error.localizedDescription)"
                transcriptionProgress = 0.0
            }
            logger.error("[Gemma] Transcription failed: \(error.localizedDescription)")
            throw error
        }
    }

    func cancelTranscription() {
        logger.info("[Gemma] Cancelling transcription")
        processRunner.cancelTranscription()
        isTranscribing = false
    }

    // MARK: - Single-file transcription

    private func transcribeSingle(audioFile: String, modelPath: String, mmprojPath: String, runSettings: RunSettings?) async throws -> String {
        await updateStatus("Converting audio to WAV (16kHz mono)...", progress: 0.3)
        let wavFile = try await audioConverter.convertToWAV(audioFile: audioFile)

        await updateStatus("Running Gemma transcription...", progress: 0.5)
        let rawOutput = try await processRunner.runTranscription(
            modelPath: modelPath,
            mmprojPath: mmprojPath,
            audioPath: wavFile,
            contextPrompt: GemmaConfiguration.processParameters.defaultPrompt,
            progressHandler: { progress in
                Task { @MainActor in self.transcriptionStatus = "Processing: \(progress)" }
            },
            runSettings: runSettings
        )

        await updateStatus("Processing transcript...", progress: 0.9)
        let cleaned = cleanTranscript(rawOutput)
        audioConverter.cleanupTemporaryFiles()
        return cleaned
    }

    // MARK: - Chunked transcription

    private func transcribeChunked(audioFile: String, modelPath: String, mmprojPath: String, runSettings: RunSettings?) async throws -> String {
        await updateStatus("Analyzing audio for split points...", progress: 0.2)

        let vadSplitter = VADAudioSplitter(config: GemmaConfiguration.vadConfiguration)
        let chunks = try await vadSplitter.splitAudioWithVAD(sourceURL: URL(fileURLWithPath: audioFile))
        logger.info("[Gemma] Split audio into \(chunks.count) chunks")

        var transcripts: [String] = []
        var failedChunks: [Int] = []
        var previousContext: String?

        for (index, chunkURL) in chunks.enumerated() {
            let chunkNumber = index + 1
            let chunkProgress = 0.3 + (0.6 * Double(index) / Double(max(chunks.count, 1)))
            await updateStatus("Processing chunk \(chunkNumber)/\(chunks.count)...", progress: chunkProgress)

            let contextPrompt = buildContextPrompt(previous: previousContext)

            do {
                let cleaned = try await transcribeChunk(
                    chunkURL: chunkURL,
                    modelPath: modelPath,
                    mmprojPath: mmprojPath,
                    contextPrompt: contextPrompt,
                    runSettings: runSettings,
                    label: "Chunk \(chunkNumber)/\(chunks.count)"
                )
                transcripts.append(cleaned)
                if cleaned.count > 10 { previousContext = cleaned }
            } catch {
                logger.warning("[Gemma] Chunk \(chunkNumber) failed, retrying once: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                do {
                    let cleaned = try await transcribeChunk(
                        chunkURL: chunkURL,
                        modelPath: modelPath,
                        mmprojPath: mmprojPath,
                        contextPrompt: contextPrompt,
                        runSettings: runSettings,
                        label: "Retry chunk \(chunkNumber)/\(chunks.count)"
                    )
                    transcripts.append(cleaned)
                    if cleaned.count > 10 { previousContext = cleaned }
                } catch {
                    failedChunks.append(chunkNumber)
                    transcripts.append("[Chunk \(chunkNumber) failed: \(error.localizedDescription)]")
                }
            }

            try? FileManager.default.removeItem(at: chunkURL)
            audioConverter.cleanupTemporaryFiles()
        }

        let successful = chunks.count - failedChunks.count
        logger.info("[Gemma] Transcription summary: \(successful)/\(chunks.count) chunks succeeded")

        await updateStatus("Combining transcripts...", progress: 0.9)
        audioConverter.cleanupTemporaryFiles()
        return formatChunkedTranscript(transcripts)
    }

    /// Convert one chunk to WAV and transcribe it. Throws on conversion/transcription failure.
    private func transcribeChunk(chunkURL: URL, modelPath: String, mmprojPath: String, contextPrompt: String, runSettings: RunSettings?, label: String) async throws -> String {
        guard FileManager.default.fileExists(atPath: chunkURL.path) else {
            throw TranscriptionError.invalidURL
        }
        let wavFile = try await audioConverter.convertToWAV(audioFile: chunkURL.path, deleteOriginal: false)
        guard FileManager.default.fileExists(atPath: wavFile) else {
            throw TranscriptionError.processFailed("Failed to convert audio to WAV format")
        }

        let output = try await processRunner.runTranscription(
            modelPath: modelPath,
            mmprojPath: mmprojPath,
            audioPath: wavFile,
            contextPrompt: contextPrompt,
            progressHandler: { progress in
                Task { @MainActor in self.transcriptionStatus = "\(label): \(progress)" }
            },
            runSettings: runSettings
        )

        if FileManager.default.fileExists(atPath: wavFile) {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: wavFile))
        }
        return cleanTranscript(output)
    }

    // MARK: - Helpers

    private func ensureModelLoaded() async throws {
        if !isModelLoaded || currentModel.isEmpty {
            logger.info("[Gemma] No model loaded, downloading default model")
            try await downloadModel()
        }
        guard isModelLoaded else { throw TranscriptionError.modelNotLoaded }
        guard processRunner.isLlamaInstalled else {
            logger.error("[Gemma] llama-mtmd-cli not installed")
            throw TranscriptionError.llamaCppNotFound
        }
    }

    private func buildContextPrompt(previous: String?) -> String {
        guard let previous = previous else {
            return GemmaConfiguration.processParameters.defaultPrompt
        }
        let snippet = String(previous.suffix(200))
        return "Continue transcribing the recording. The previous segment ended with: '\(snippet)'. Transcribe the following audio exactly, with no comments or notes."
    }

    private func cleanTranscript(_ output: String) -> String {
        // Reasoning first: the thought block may contain a DRAFT transcript that must never leak.
        var cleaned = GemmaConfiguration.stripThoughtChannel(output)

        let processingPatterns = [
            "main: loading model:",
            "encoding audio slice...",
            "audio slice encoded in",
            "decoding audio batch",
            "audio decoded (batch",
        ]
        let lines = cleaned.components(separatedBy: .newlines)
        cleaned = lines.filter { line in
            !processingPatterns.contains(where: { line.contains($0) })
        }.joined(separator: "\n")

        for token in GemmaConfiguration.systemTokensToRemove {
            cleaned = cleaned.replacingOccurrences(of: token, with: "")
        }

        return cleaned
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "  ", with: " ")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }

    private func formatChunkedTranscript(_ transcripts: [String]) -> String {
        guard transcripts.count > 1 else { return transcripts.first ?? "" }
        return transcripts.joined(separator: "\n\n")
    }

    private func makeResult(_ transcript: String, audioFile: String, usedVAD: Bool) -> TranscriptionResult {
        TranscriptionResult(
            fullTranscript: transcript,
            chunks: [],
            totalDuration: audioConverter.getAudioDuration(filePath: audioFile) ?? 0,
            language: nil,
            usedVAD: usedVAD,
            detectedSpeakerCount: nil,
            speakerEmbeddings: nil
        )
    }

    private func updateStatus(_ status: String, progress: Double) async {
        await MainActor.run {
            self.transcriptionStatus = status
            self.transcriptionProgress = progress
        }
        logger.debug("[Gemma] Status: \(status) (\(Int(progress * 100))%)")
    }
}
#endif
