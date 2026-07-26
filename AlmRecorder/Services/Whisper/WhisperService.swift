import Foundation
import Combine

/// Main service for Whisper transcription
class WhisperService: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var isReady = false
    @Published var isTranscribing = false
    @Published var transcriptionStatus = ""
    @Published var transcriptionProgress: Double = 0.0
    @Published var currentModel = ""
    @Published var currentVariant: WhisperModelVariant?
    
    // Last transcription result for speaker review
    var lastTranscriptionResult: TranscriptionResult?

    // Checkpoint for resume — set by worker before calling transcribe, cleared after
    var activeCheckpoint: TranscriptionCheckpoint?
    var onVADChunkCompleted: ((Int, [TranscriptionChunk], TimeInterval) async -> Void)?
    
    // MARK: - Private Properties
    
    private let processRunner = WhisperProcessRunner()
    private let modelManager = WhisperModelManager.shared
    private let audioConverter = VoxtralAudioConverter() // Reuse existing converter
    private let vadSplitter = VADAudioSplitter()
    private let speakerDiarizer = SpeakerDiarizer()
    private let speakerSplitter = SpeakerAudioSplitter()
    private let speakerIdentificationService = SpeakerIdentificationService()
    private let logger = VoxtralLogger.shared
    private var cancellables = Set<AnyCancellable>()
    
    // Synchronization to prevent concurrent transcriptions
    private let transcriptionSemaphore = DispatchSemaphore(value: 1)
    
    // MARK: - Singleton
    
    static let shared = WhisperService()
    
    // MARK: - Initialization
    
    private init() {
        setupBindings()
        checkStatus()
    }
    
    private func setupBindings() {
        // Monitor model manager status
        modelManager.$isModelLoaded
            .assign(to: &$isReady)
        
        modelManager.$currentModel
            .assign(to: &$currentModel)
        
        modelManager.$currentVariant
            .assign(to: &$currentVariant)
    }
    
    private func checkStatus() {
        // Check if we have at least one model and whisper-cli is available
        isReady = modelManager.isModelLoaded && processRunner.isWhisperAvailable
        
        if !processRunner.isWhisperAvailable {
            logger.error("[WhisperService] ERROR: whisper-cli not found")
            transcriptionStatus = "Whisper CLI not found - please reinstall"
        } else if !modelManager.isModelLoaded {
            logger.warning("[WhisperService] WARNING: No models downloaded yet")
            transcriptionStatus = "No models available - downloading default model..."
            
            // Auto-download a default model if none exists
            Task {
                do {
                    let defaultVariant = WhisperModelVariant.defaultVariant()
                    try await modelManager.downloadModel(defaultVariant)
                    await MainActor.run {
                        self.checkStatus()
                        self.transcriptionStatus = "Ready"
                    }
                } catch {
                    logger.error("[WhisperService] Failed to download default model: \(error)")
                    await MainActor.run {
                        self.transcriptionStatus = "Failed to download model"
                    }
                }
            }
        } else {
            logger.info("[WhisperService] Ready with model: \(modelManager.currentModel)")
            transcriptionStatus = "Ready"
        }
    }
    
    // MARK: - Public Methods
    
    /// Transcribe an audio file
    /// - Parameters:
    ///   - audioFile: Path to the audio file
    ///   - modelKey: Optional specific model to use
    ///   - language: Optional language code
    /// - Returns: Transcription text
    func transcribe(
        audioFile: String,
        modelKey: String? = nil,
        variant: WhisperModelVariant? = nil,
        language: String? = nil,
        speakerConfiguration: SpeakerPipelineConfiguration? = nil
    ) async throws -> String {
        let result = try await transcribeWithResult(
            audioFile: audioFile,
            modelKey: modelKey,
            variant: variant,
            language: language,
            speakerConfiguration: speakerConfiguration
        )
        return result.fullTranscript
    }
    
    /// Transcribe audio and return structured result with chunk information
    func transcribeWithResult(
        audioFile: String,
        modelKey: String? = nil,
        variant: WhisperModelVariant? = nil,
        language: String? = nil,
        recordingId: Int? = nil,
        speakerConfiguration: SpeakerPipelineConfiguration? = nil
    ) async throws -> TranscriptionResult {
        
        // Log language parameter for debugging
        logger.info("[WhisperService] transcribeWithResult called with language: \(language ?? "nil")")
        
        guard isReady else {
            throw TranscriptionError.serviceNotReady
        }
        
        // Wait for semaphore to prevent concurrent transcriptions
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.transcriptionSemaphore.wait()
                continuation.resume()
            }
        }
        
        defer {
            // Release semaphore when done
            transcriptionSemaphore.signal()
            
            Task { @MainActor in
                isTranscribing = false
                transcriptionProgress = 0.0
                transcriptionStatus = ""
            }
        }
        
        await MainActor.run {
            isTranscribing = true
            transcriptionProgress = 0.0
            transcriptionStatus = "Preparing audio..."
        }
        
        // ALWAYS use the user's selected model from GlobalModelSettings
        let selectedVariant = variant ?? GlobalModelSettings.shared.selectedWhisperVariant ?? WhisperModelVariant.defaultVariant()
        
        // Log selected model and memory requirements (no fallbacks)
        let requiredRAM = selectedVariant.size.estimatedRAMRequirementMB
        let requiredGPU = selectedVariant.size.estimatedGPURequirementMB
        let physicalMemoryMB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
        
        logger.info("[WhisperService] Using selected model: \(selectedVariant.displayName)")
        logger.info("[WhisperService] Model requires ~\(requiredGPU)MB GPU memory")
        logger.info("[WhisperService] System has \(physicalMemoryMB)MB RAM")
        
        // Ensure model is downloaded
        if !modelManager.isModelDownloaded(selectedVariant) {
            await MainActor.run {
                transcriptionStatus = "Downloading model..."
            }
            try await modelManager.downloadModel(selectedVariant)
        }
        
        guard let modelPath = modelManager.getModelPath(for: selectedVariant) else {
            throw TranscriptionError.modelNotFound
        }
        
        logger.info("[WhisperService] Using model: \(selectedVariant.displayName)")
        await MainActor.run {
            currentModel = selectedVariant.displayName
            currentVariant = selectedVariant
        }
        
        // Convert audio to 16kHz WAV (Whisper requirement)
        await MainActor.run {
            transcriptionStatus = "Converting audio..."
            transcriptionProgress = 0.1
        }
        
        // Check file size for warnings
        let fileURL = URL(fileURLWithPath: audioFile)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: audioFile) {
            let fileSize = (attrs[.size] as? Int64 ?? 0)
            let fileSizeMB = fileSize / (1024 * 1024)
            if fileSizeMB > 50 {
                logger.warning("[WhisperService] WARNING: Large audio file (\(fileSizeMB)MB) may take longer to process: \(fileURL.lastPathComponent)")
            }
        }
        
        do {
            // Always use the unified VAD + Diarization + Transcription pipeline
            // This ensures consistent speaker attribution regardless of audio length
            let result = try await transcribeWithVADAndDiarization(
                audioFile: audioFile,
                modelVariant: selectedVariant,
                language: language,
                recordingId: recordingId,
                speakerConfiguration: speakerConfiguration,
                checkpoint: activeCheckpoint,
                onChunkCompleted: onVADChunkCompleted
            )

            // Clear checkpoint state after successful completion
            activeCheckpoint = nil
            onVADChunkCompleted = nil

            // Store result for speaker review on success
            lastTranscriptionResult = result

            return result
            
        } catch {
            // Clear lastTranscriptionResult on error
            lastTranscriptionResult = nil
            
            // Collect diagnostic information
            let diagnostics = TranscriptionDiagnostics.shared.collectDiagnostics(
                for: audioFile,
                modelPath: modelManager.getModelPath(for: selectedVariant)?.path,
                backend: .whisper,
                error: error
            )
            
            // Log detailed error information
            logger.error("[WhisperService] === TRANSCRIPTION FAILED ===")
            logger.error("[WhisperService] File: \(fileURL.lastPathComponent)")
            logger.error("[WhisperService] Error: \(error)")
            logger.error("[WhisperService] Error type: \(type(of: error))")
            logger.error("[WhisperService] Model: \(selectedVariant.displayName)")
            
            if let fileSize = diagnostics["audio_size_kb"] as? Int64 {
                logger.error("[WhisperService] File size: \(fileSize)KB")
            }
            
            // NOTE: File size check removed. This method always uses the VAD pipeline
            // (transcribeWithVADAndDiarization) which splits files into small chunks.
            // Individual chunks are well within memory limits regardless of original file size.
            // The old check was incorrectly rejecting large files that were already chunked.
            
            // Log formatted diagnostics
            let formattedDiagnostics = TranscriptionDiagnostics.shared.formatDiagnostics(diagnostics)
            print(formattedDiagnostics)
            
            logger.error("[WhisperService] === END TRANSCRIPTION FAILED ===")
            
            // Re-throw the original error
            throw error
        }
    }
    
    /// Cancel current transcription
    func cancelTranscription() {
        processRunner.cancelTranscription()
        
        Task { @MainActor in
            isTranscribing = false
            transcriptionProgress = 0.0
            transcriptionStatus = "Cancelled"
        }
    }
    
    // MARK: - Private Methods
    
    private func transcribeDirect(
        audioFile: String,
        modelPath: String,
        language: String?,
        enableDiarization: Bool = false
    ) async throws -> String {
        
        await MainActor.run {
            transcriptionStatus = "Starting transcription..."
            transcriptionProgress = 0.1
        }
        
        // Report audio conversion progress
        await MainActor.run {
            transcriptionStatus = "Converting audio..."
            transcriptionProgress = 0.15
        }
        
        // Ensure we pass "auto" if language is nil to prevent default English
        let effectiveLanguage = language ?? "auto"
        logger.info("[WhisperService.transcribeDirect] Using language: \(effectiveLanguage)")
        
        let transcript = try await processRunner.runTranscription(
            modelPath: modelPath,
            audioPath: audioFile,
            language: effectiveLanguage,
            enableDiarization: enableDiarization,
            wordTimestamps: enableDiarization, // Enable word timestamps when diarizing
            progressHandler: { [weak self] status in
                Task { @MainActor in
                    self?.transcriptionStatus = status
                    
                    // Better progress parsing
                    if status.contains("Processing") || status.contains("Transcribing") {
                        // Extract percentage if available
                        let percentPattern = #"(\d+(?:\.\d+)?)\s*%"#
                        if let regex = try? NSRegularExpression(pattern: percentPattern),
                           let match = regex.firstMatch(in: status, range: NSRange(status.startIndex..., in: status)),
                           let percentRange = Range(match.range(at: 1), in: status),
                           let percent = Double(status[percentRange]) {
                            // Map 0-100% of transcription to 20-70% of total progress
                            self?.transcriptionProgress = 0.2 + (percent / 100.0 * 0.5)
                        } else {
                            // Increment progress gradually if no percentage found
                            let currentProgress = self?.transcriptionProgress ?? 0.2
                            if currentProgress < 0.7 {
                                self?.transcriptionProgress = min(currentProgress + 0.05, 0.7)
                            }
                        }
                    }
                    
                    self?.logger.debug("[WhisperService] Progress: \(self?.transcriptionProgress ?? 0) - Status: \(status)")
                }
            }
        )
        
        await MainActor.run {
            transcriptionProgress = 0.75
            transcriptionStatus = "Finalizing transcription..."
        }
        
        return transcript
    }
    
    /// Transcribe with chunks and return structured result with timing
    private func transcribeWithChunksStructured(
        audioFile: String,
        modelPath: String,
        language: String?,
        originalDuration: TimeInterval,
        enableDiarization: Bool = false
    ) async throws -> TranscriptionResult {
        
        await MainActor.run {
            transcriptionStatus = "Splitting audio with VAD..."
            transcriptionProgress = 0.1
        }
        
        // Split audio using VAD
        let sourceURL = URL(fileURLWithPath: audioFile)
        let chunks = try await vadSplitter.splitAudioWithVAD(sourceURL: sourceURL)
        
        logger.info("[WhisperService] Split audio into \(chunks.count) chunks using VAD")
        
        var transcriptionChunks: [TranscriptionChunk] = []
        let maxRetries = 2
        
        // Calculate chunk timings based on VAD
        var currentOffset: TimeInterval = 0
        
        for (index, chunkURL) in chunks.enumerated() {
            let chunkProgress = Double(index) / Double(chunks.count)
            
            await MainActor.run {
                transcriptionStatus = "Processing chunk \(index + 1) of \(chunks.count)"
                transcriptionProgress = 0.2 + (chunkProgress * 0.6)
            }
            
            // Get chunk duration
            let chunkDuration = audioConverter.getAudioDuration(filePath: chunkURL.path) ?? 0
            
            // Convert chunk to WAV
            let chunkWav = try await audioConverter.convertToWAV(audioFile: chunkURL.path)
            
            // Try to transcribe chunk with retries
            var chunkTranscript: String? = nil
            var lastError: Error?
            
            for attempt in 0..<maxRetries {
                do {
                    let effectiveLanguage = language ?? "auto"
                    chunkTranscript = try await processRunner.runTranscription(
                        modelPath: modelPath,
                        audioPath: chunkWav,
                        language: effectiveLanguage,
                        enableDiarization: enableDiarization,
                        wordTimestamps: enableDiarization,
                        progressHandler: nil
                    )
                    
                    // Clean up chunk WAV
                    try? FileManager.default.removeItem(atPath: chunkWav)
                    break
                } catch {
                    lastError = error
                    if attempt < maxRetries - 1 {
                        logger.info("[WhisperService] Chunk \(index) failed (attempt \(attempt + 1)), retrying...")
                        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
                    }
                }
            }
            
            // Create transcription chunk with timing
            if let text = chunkTranscript, !text.isEmpty {
                let chunk = TranscriptionChunk(
                    text: text,
                    startTime: currentOffset,
                    endTime: currentOffset + chunkDuration,
                    speaker: nil,
                    speakerUUID: nil,
                    confidence: nil
                )
                transcriptionChunks.append(chunk)
            } else {
                // Failed chunk - mark in result
                let errorText = "[Chunk \(index + 1) transcription failed]"
                let chunk = TranscriptionChunk(
                    text: errorText,
                    startTime: currentOffset,
                    endTime: currentOffset + chunkDuration,
                    speaker: nil,
                    speakerUUID: nil,
                    confidence: 0.0
                )
                transcriptionChunks.append(chunk)
            }
            
            currentOffset += chunkDuration
            
            // Clean up chunk file
            try? FileManager.default.removeItem(at: chunkURL)
        }
        
        await MainActor.run {
            transcriptionProgress = 0.9
            transcriptionStatus = "Finalizing transcription..."
        }
        
        // Build structured result
        let result = TranscriptionResult.fromChunks(transcriptionChunks, language: language)
        
        print("[WhisperService] Transcription complete with \(transcriptionChunks.count) chunks")
        
        return result
    }
    
    // Keep the old method for backward compatibility
    private func transcribeWithChunks(
        audioFile: String,
        modelPath: String,
        language: String?
    ) async throws -> String {
        
        await MainActor.run {
            transcriptionStatus = "Splitting audio..."
            transcriptionProgress = 0.1
        }
        
        // Split audio using VAD
        let sourceURL = URL(fileURLWithPath: audioFile)
        let chunks = try await vadSplitter.splitAudioWithVAD(sourceURL: sourceURL)
        
        print("[WhisperService] Split audio into \(chunks.count) chunks")
        
        var transcripts: [String] = []
        let maxRetries = 2
        
        // Keep track of previous text for context continuity
        var previousContext: String? = nil
        let maxPromptWords = 200 // Limit prompt size to avoid overwhelming the model
        
        for (index, chunkURL) in chunks.enumerated() {
            let chunkProgress = Double(index) / Double(chunks.count)
            
            await MainActor.run {
                transcriptionStatus = "Processing chunk \(index + 1) of \(chunks.count)"
                transcriptionProgress = 0.2 + (chunkProgress * 0.7)
            }
            
            // Convert chunk to WAV
            let chunkWav = try await audioConverter.convertToWAV(audioFile: chunkURL.path)
            
            // Try to transcribe chunk with retries
            var chunkTranscript: String? = nil
            var lastError: Error?
            
            for attempt in 0..<maxRetries {
                do {
                    if attempt > 0 {
                        logger.info("[WhisperService] Retrying chunk \(index + 1), attempt \(attempt + 1)")
                        await MainActor.run {
                            transcriptionStatus = "Retrying chunk \(index + 1) (attempt \(attempt + 1))"
                        }
                    }
                    
                    // Prepare prompt from previous context
                    var prompt: String? = nil
                    if let context = previousContext {
                        // Take last N words from previous transcript as prompt
                        let words = context.split(separator: " ")
                        let promptWords = words.suffix(maxPromptWords)
                        prompt = promptWords.joined(separator: " ")
                        logger.info("[WhisperService] Using prompt context (\(promptWords.count) words) for chunk \(index + 1)")
                    }
                    
                    // Transcribe chunk with prompt for context continuity
                    let effectiveLanguage = language ?? "auto"
                    chunkTranscript = try await processRunner.runTranscription(
                        modelPath: modelPath,
                        audioPath: chunkWav,
                        language: effectiveLanguage,
                        prompt: prompt
                    )
                    
                    // Success - break out of retry loop
                    break
                    
                } catch {
                    lastError = error
                    logger.info("[WhisperService] Chunk \(index + 1) failed on attempt \(attempt + 1): \(error)")
                    
                    // Wait a bit before retry
                    if attempt < maxRetries - 1 {
                        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                    }
                }
            }
            
            // Use the transcript if successful, otherwise add error marker
            if let transcript = chunkTranscript, !transcript.isEmpty {
                transcripts.append(transcript)
                // Update context for next chunk
                previousContext = transcript
                logger.info("[WhisperService] Updated context for next chunk")
            } else {
                // Add marker for failed chunk but continue with others
                let errorMessage = lastError?.localizedDescription ?? "Unknown error"
                transcripts.append("[Chunk \(index + 1) failed: \(errorMessage)]")
                logger.info("[WhisperService] WARNING: Chunk \(index + 1) failed after all retries")
                // Don't update context for failed chunks
            }
        }
        
        await MainActor.run {
            transcriptionProgress = 0.95
            transcriptionStatus = "Combining results..."
        }
        
        // Combine transcripts
        let finalTranscript = transcripts.joined(separator: "\n\n")
        
        await MainActor.run {
            transcriptionProgress = 1.0
            transcriptionStatus = "Completed"
        }
        
        return finalTranscript
    }
    
    // MARK: - Unified VAD + Diarization + Transcription Pipeline
    
    /// Perform VAD → Diarization → Transcription pipeline
    /// This is the new unified approach that combines all three steps
    /// Legacy-ASR speaker path: diarize the whole file with FluidAudio, relabel each transcription
    /// chunk by temporal overlap, and build one configured weighted centroid per speaker. Stable
    /// cross-recording UUIDs are assigned after this function returns.
    /// Fail-safe: on any error the chunks are returned unchanged with no embeddings.
    private func applyFluidAudioDiarization(
        _ chunks: [TranscriptionChunk],
        audioFile: String,
        configuration: SpeakerPipelineConfiguration
    ) async -> (
        chunks: [TranscriptionChunk],
        speakerEmbeddings: [TranscriptionSpeakerEmbedding],
        identityClusters: [SpeakerIdentityCluster]
    ) {
        do {
            let service = try await FluidAudioEmbeddingService(configuration: configuration)
            let turns = try await service.diarize(
                URL(fileURLWithPath: audioFile),
                configuration: configuration
            )
            guard !turns.isEmpty else { return (chunks, [], []) }

            // Relabel each chunk by the speaker that overlaps it most, and capture that turn's
            // 256-dim voice embedding so we can persist a per-utterance voice fingerprint.
            var relabeled = chunks
            for i in relabeled.indices {
                let (speaker, embedding) = SpeakerAlignment.speakerAndEmbedding(
                    forUtteranceStart: relabeled[i].startTime,
                    end: relabeled[i].endTime,
                    turns: turns
                )
                if let speaker {
                    relabeled[i].speaker = "Speaker \(speaker)"
                }
                if let embedding, embedding.count == SpeakerEmbeddingPolicy.dimension {
                    relabeled[i].voiceEmbedding = embedding
                }
                if let rawSpeaker = speaker {
                    relabeled[i].voiceEmbeddingQuality = SpeakerAlignment.quality(
                        for: rawSpeaker,
                        start: relabeled[i].startTime,
                        end: relabeled[i].endTime,
                        turns: turns
                    )
                }
                let overlap = SpeakerAlignment.overlapEvidence(
                    start: relabeled[i].startTime,
                    end: relabeled[i].endTime,
                    turns: turns
                )
                relabeled[i].speakerOverlapRatio = overlap.ratio
                relabeled[i].activeSpeakerCount = overlap.maximumActiveSpeakerCount
                relabeled[i].overlappingSpeakerLabels = overlap.speakerLabels.map {
                    "Speaker \($0)"
                }
            }

            let centroids = SpeakerAlignment.clusterEmbeddings(
                from: turns,
                policy: configuration.centroidPolicy
            )
            let speakerEmbeddings: [TranscriptionSpeakerEmbedding] = centroids.map { centroid in
                return TranscriptionSpeakerEmbedding(
                    speakerId: "Speaker \(centroid.speaker)",
                    embedding: centroid.embedding,
                    startTime: centroid.start,
                    endTime: centroid.end,
                    confidence: centroid.confidence
                )
            }

            print("[WhisperService] FluidAudio diarization: \(turns.count) turns, \(centroids.count) speakers across \(relabeled.count) chunks")
            return (
                relabeled,
                speakerEmbeddings,
                SpeakerAlignment.identityClusters(
                    from: turns,
                    policy: configuration.centroidPolicy,
                    labelPrefix: "Speaker "
                )
            )
        } catch {
            print("[WhisperService] FluidAudio diarization unavailable: \(error) - keeping legacy labels")
            return (chunks, [], [])
        }
    }

    /// Accuracy-oriented path: transcribe each VAD block once with timestamped Whisper output,
    /// diarize the original file once, and align the two timelines. This avoids cutting audio at
    /// imperfect speaker boundaries and avoids one Whisper invocation per diarization turn.
    private func transcribeWithTimedSpeakerAlignment(
        audioFile: String,
        vadChunks: [URL],
        qualityModelPath: URL,
        language: String?,
        recordingId: Int?,
        checkpoint: TranscriptionCheckpoint?,
        onChunkCompleted: ((Int, [TranscriptionChunk], TimeInterval) async -> Void)?,
        configuration: SpeakerPipelineConfiguration
    ) async throws -> TranscriptionResult {
        let sourceURL = URL(fileURLWithPath: audioFile).standardizedFileURL
        let totalDuration = audioConverter.getAudioDuration(filePath: audioFile) ?? 0

        var turns: [DiarizationTurn] = []
        var speakerService: FluidAudioEmbeddingService?
        var baselineDiarizationRun: SpeakerDiarizationRun?
        await MainActor.run {
            transcriptionStatus = configuration.diarizationBackend == .offlineVBx
                || configuration.diarizationBackend == .offlineVBxTargetedSortformer
                ? "Running offline VBx speaker diarization..."
                : "Running legacy speaker diarization..."
            transcriptionProgress = 0.12
        }
        do {
            let service = try await FluidAudioEmbeddingService(configuration: configuration)
            let run = try await service.diarizeDetailed(
                sourceURL,
                configuration: configuration
            )
            speakerService = service
            baselineDiarizationRun = run
            turns = run.turns
        } catch {
            logger.warning("[WhisperService] Full-file diarization failed; using one local speaker: \(error)")
            turns = [DiarizationTurn(
                speaker: "1",
                start: 0,
                end: max(totalDuration, 0.01),
                qualityScore: 0
            )]
        }

        func makeChunks(_ segments: [WhisperTimedSegment]) -> [TranscriptionChunk] {
            return SpeakerAlignment.align(
                segments,
                to: turns,
                strategy: configuration.alignmentStrategy,
                utteranceSegmentation: configuration.effectiveUtteranceSegmentation
            ).map { item in
                let rawSpeaker = item.speaker
                return TranscriptionChunk(
                    text: item.text,
                    startTime: item.startTime,
                    endTime: item.endTime,
                    speaker: rawSpeaker.map { "Speaker \($0)" },
                    speakerUUID: nil,
                    voiceEmbedding: item.embedding,
                    voiceEmbeddingQuality: rawSpeaker.flatMap {
                        SpeakerAlignment.quality(
                            for: $0,
                            start: item.startTime,
                            end: item.endTime,
                            turns: turns
                        )
                    },
                    speakerOverlapRatio: item.speakerOverlapRatio,
                    activeSpeakerCount: item.activeSpeakerCount,
                    overlappingSpeakerLabels: item.overlappingSpeakers.map {
                        "Speaker \($0)"
                    },
                    speakerAssignmentSource: SpeakerAssignmentSource.model.rawValue,
                    confidence: item.confidence,
                    tokenStats: item.tokenStats
                )
            }
        }

        var timedSegments: [WhisperTimedSegment] = []
        var currentGlobalOffset: TimeInterval = 0
        let completed = checkpoint?.processedChunks ?? []

        for (vadIndex, vadChunk) in vadChunks.enumerated() {
            let chunkURL = vadChunk.standardizedFileURL
            let chunkDuration = audioConverter.getAudioDuration(filePath: chunkURL.path) ?? 0

            if completed.contains(vadIndex),
               let saved = checkpoint?.chunkTranscripts[vadIndex],
               !saved.isEmpty {
                timedSegments.append(contentsOf: saved.map {
                    WhisperTimedSegment(
                        text: $0.text,
                        startTime: $0.startTime,
                        endTime: $0.endTime,
                        tokenStats: nil
                    )
                })
                currentGlobalOffset = checkpoint?.chunkOffsets[vadIndex]
                    ?? (currentGlobalOffset + chunkDuration)
                if chunkURL != sourceURL { try? FileManager.default.removeItem(at: chunkURL) }
                continue
            }

            await MainActor.run {
                transcriptionStatus = "Chunk \(vadIndex + 1)/\(vadChunks.count): transcribing timed speech..."
                transcriptionProgress = 0.20
                    + (Double(vadIndex) / Double(max(1, vadChunks.count))) * 0.65
            }

            let wavPath = try await audioConverter.convertToWAV(audioFile: chunkURL.path)
            let wavURL = URL(fileURLWithPath: wavPath).standardizedFileURL
            do {
                let detailed = try await processRunner.runTranscriptionDetailed(
                    modelPath: qualityModelPath.path,
                    audioPath: wavPath,
                    language: language ?? "auto",
                    enableDiarization: false,
                    wordTimestamps: true
                )
                let localSegments: [WhisperTimedSegment]
                if detailed.timedSegments.isEmpty {
                    localSegments = SpeakerAlignment.approximateWordSegments(
                        text: detailed.text,
                        start: 0,
                        end: chunkDuration,
                        tokenStats: detailed.tokenStats
                    )
                } else {
                    localSegments = detailed.timedSegments
                }
                let globalSegments = localSegments.map {
                    WhisperTimedSegment(
                        text: $0.text,
                        startTime: currentGlobalOffset + $0.startTime,
                        endTime: currentGlobalOffset + $0.endTime,
                        tokenStats: $0.tokenStats
                    )
                }
                timedSegments.append(contentsOf: globalSegments)
                currentGlobalOffset += chunkDuration
                if !globalSegments.isEmpty, let onChunkCompleted {
                    await onChunkCompleted(vadIndex, makeChunks(globalSegments), currentGlobalOffset)
                }
            } catch {
                if Task.isCancelled { throw error }
                logger.warning("[WhisperService] Timed chunk \(vadIndex + 1) failed and was skipped: \(error)")
                currentGlobalOffset += chunkDuration
            }

            if wavURL != chunkURL && wavURL != sourceURL {
                try? FileManager.default.removeItem(at: wavURL)
            }
            if chunkURL != sourceURL { try? FileManager.default.removeItem(at: chunkURL) }
        }

        if configuration.diarizationBackend == .offlineVBxTargetedSortformer,
           let speakerService,
           let baselineDiarizationRun {
            await MainActor.run {
                transcriptionStatus = "Targeting mixed utterances with Sortformer..."
                transcriptionProgress = 0.88
            }
            // Whisper's `-ml 1` output is word-sized. First coalesce those words by the baseline
            // VBx label to recover the recording-local utterances shown in the UI, then aim the
            // short, context-padded Sortformer windows at those spans.
            let baselineUtterances = SpeakerAlignment.align(
                timedSegments,
                to: turns,
                strategy: configuration.alignmentStrategy,
                utteranceSegmentation: configuration.effectiveUtteranceSegmentation
            ).map {
                WhisperTimedSegment(
                    text: $0.text,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    tokenStats: $0.tokenStats
                )
            }
            do {
                let repaired = try await speakerService.repairWithTargetedSortformer(
                    sourceURL,
                    baseline: baselineDiarizationRun,
                    targetSegments: baselineUtterances,
                    configuration: configuration
                )
                turns = repaired.turns
            } catch {
                if Task.isCancelled { throw error }
                logger.warning(
                    "[WhisperService] Targeted Sortformer repair failed; keeping VBx: \(error)"
                )
            }
        }

        var chunks = makeChunks(timedSegments)
        let centroids = SpeakerAlignment.clusterEmbeddings(
            from: turns,
            policy: configuration.centroidPolicy
        )
        let speakerEmbeddings = centroids.map {
            TranscriptionSpeakerEmbedding(
                speakerId: "Speaker \($0.speaker)",
                embedding: $0.embedding,
                startTime: $0.start,
                endTime: $0.end,
                confidence: $0.confidence
            )
        }

        if !speakerEmbeddings.isEmpty {
            let labelToUUID = speakerIdentificationService.resolveClusters(
                SpeakerAlignment.identityClusters(
                    from: turns,
                    policy: configuration.centroidPolicy,
                    labelPrefix: "Speaker "
                ),
                recordingId: recordingId,
                configuration: configuration
            )
            for index in chunks.indices {
                if let label = chunks[index].speaker {
                    chunks[index].speakerUUID = labelToUUID[label]
                }
            }
        }

        let resolver = SpeakerNameResolver(
            speakers: (try? GRDBSpeakerRepository().getAll()) ?? []
        )
        let transcript = LabeledTranscript.render(
            chunks.map {
                LabeledTranscript.Segment(
                    speakerUuid: $0.speakerUUID,
                    localLabel: $0.speaker,
                    text: $0.text
                )
            },
            resolver: resolver
        )
        let identities = Set(chunks.compactMap {
            $0.speakerUUID.map { "uuid:\($0)" } ?? $0.speaker.map { "label:\($0)" }
        })

        return TranscriptionResult(
            fullTranscript: transcript,
            chunks: chunks,
            totalDuration: max(totalDuration, currentGlobalOffset),
            language: language,
            usedVAD: true,
            detectedSpeakerCount: identities.count,
            speakerEmbeddings: speakerEmbeddings
        )
    }

    private func transcribeWithVADAndDiarization(
        audioFile: String,
        modelVariant: WhisperModelVariant? = nil,
        language: String? = nil,
        recordingId: Int? = nil,
        speakerConfiguration: SpeakerPipelineConfiguration? = nil,
        checkpoint: TranscriptionCheckpoint? = nil,
        onChunkCompleted: ((Int, [TranscriptionChunk], TimeInterval) async -> Void)? = nil
    ) async throws -> TranscriptionResult {
        
        guard isReady else {
            throw TranscriptionError.serviceNotReady
        }
        
        // Note: Semaphore is already held by the calling transcribeWithResult method
        // So we don't need to acquire it here
        
        await MainActor.run {
            isTranscribing = true
            transcriptionProgress = 0.0
            transcriptionStatus = "Starting unified transcription pipeline..."
        }
        
        defer {
            Task { @MainActor in
                isTranscribing = false
                transcriptionProgress = 0.0
                transcriptionStatus = ""
            }
        }
        
        // Step 1: VAD - Split audio into manageable chunks
        await MainActor.run {
            transcriptionStatus = "Analyzing voice activity..."
            transcriptionProgress = 0.05
        }
        
        let sourceURL = URL(fileURLWithPath: audioFile)
        let vadChunks = try await vadSplitter.splitAudioWithVAD(sourceURL: sourceURL)
        
        print("[WhisperService] VAD: Split audio into \(vadChunks.count) chunks")

        // The caller snapshots this before work starts. Falling back to the shared setting keeps
        // direct/test callers source-compatible, while queued app runs remain reproducible even if
        // the user changes profiles during a long transcription.
        let pipelineConfiguration = speakerConfiguration
            ?? SpeakerPipelineSettings.shared.activeConfiguration
        if pipelineConfiguration.transcriptionSegmentation == .whisperTimedSegments,
           pipelineConfiguration.diarizationBackend != .segmentDBSCAN {
            let qualityVariant = modelVariant
                ?? GlobalModelSettings.shared.selectedWhisperVariant
                ?? modelManager.currentVariant
                ?? WhisperModelVariant.defaultVariant()
            if !modelManager.isModelDownloaded(qualityVariant) {
                await MainActor.run {
                    transcriptionStatus = "Downloading transcription model..."
                    transcriptionProgress = 0.10
                }
                try await modelManager.downloadModel(qualityVariant)
            }
            guard let qualityModelPath = modelManager.getModelPath(for: qualityVariant) else {
                throw TranscriptionError.modelNotFound
            }
            return try await transcribeWithTimedSpeakerAlignment(
                audioFile: audioFile,
                vadChunks: vadChunks,
                qualityModelPath: qualityModelPath,
                language: language,
                recordingId: recordingId,
                checkpoint: checkpoint,
                onChunkCompleted: onChunkCompleted,
                configuration: pipelineConfiguration
            )
        }
        
        // Step 2: Prepare models
        // Download TinyDiarize model if needed
        await MainActor.run {
            transcriptionStatus = "Preparing speaker segmentation model..."
            transcriptionProgress = 0.1
        }
        
        let tinyDiarizeVariant = modelManager.availableModels.first { 
            $0.version == .tdrz && $0.size == .small
        } ?? WhisperModelVariant(
            family: .openai,
            size: .small,
            version: .tdrz,
            quantization: .q5_0
        )
        
        if !modelManager.isModelDownloaded(tinyDiarizeVariant) {
            try await modelManager.downloadModel(tinyDiarizeVariant)
        }
        
        guard let diarizeModelPath = modelManager.getModelPath(for: tinyDiarizeVariant) else {
            throw TranscriptionError.modelNotFound
        }
        
        // Prepare quality model for transcription  
        // Use user's selected model - download if needed
        let qualityVariant = modelVariant ?? GlobalModelSettings.shared.selectedWhisperVariant ?? modelManager.currentVariant ?? WhisperModelVariant.defaultVariant()
        
        if !modelManager.isModelDownloaded(qualityVariant) {
            await MainActor.run {
                transcriptionStatus = "Downloading transcription model..."
                transcriptionProgress = 0.15
            }
            try await modelManager.downloadModel(qualityVariant)
        }
        
        guard let qualityModelPath = modelManager.getModelPath(for: qualityVariant) else {
            throw TranscriptionError.modelNotFound
        }
        
        // Step 3: Process each VAD chunk through diarization and transcription
        var allTranscriptionChunks: [TranscriptionChunk] = []
        var currentGlobalOffset: TimeInterval = 0
        // Track unique speakers across all chunks BEFORE unification
        var allDiarizedSpeakers = Set<String>()
        
        // Initialize speaker embedding service with fallback chain
        var embeddingService: (any SpeakerEmbeddingService)?
        var allChunkSpeakers: [SpeakerUnificationService.ChunkSpeaker] = []
        var embeddingFailureCount = 0
        var embeddingAttemptCount = 0
        // Maps each transcription chunk index to its corresponding ChunkSpeaker index
        // (only set for chunks that have a successfully extracted embedding)
        var chunkToEmbeddingMap: [Int: Int] = [:]

        let useFullFileDiarization = pipelineConfiguration.diarizationBackend != .segmentDBSCAN
        if useFullFileDiarization {
            // FluidAudio full-diarization is the standard path: the legacy per-segment
            // embedding + DBSCAN unification + auto-identity is replaced by
            // applyFluidAudioDiarization() after the loop. Skip the legacy embedding work here.
            embeddingService = nil
            print("[WhisperService] FluidAudio full-diarization standard path - legacy per-segment embedding skipped")
        } else {
            do {
                embeddingService = try await FluidAudioEmbeddingService()
                print("[WhisperService] FluidAudio speaker embedding service initialized")
            } catch {
                // No Pyannote fallback on purpose: it emits 192-dim vectors that are incompatible
                // with the 256-dim WeSpeaker identity DB and silently orphan speakers (cosine of
                // mismatched dimensions is meaningless). Skipping is strictly better than
                // corrupting the cross-recording matcher.
                print("[WhisperService] FluidAudio speaker embedding unavailable: \(error). Skipping speaker embeddings (no 192-dim Pyannote fallback).")
                embeddingService = nil
            }
        }
        
        // Track total segments processed for accurate progress
        var totalSegmentsProcessed = 0
        var totalSegmentsCount = 0  // Will be calculated as we go

        // Restore checkpoint data if resuming an interrupted job
        if let checkpoint = checkpoint, !checkpoint.processedChunks.isEmpty {
            print("[WhisperService] Resuming from checkpoint: \(checkpoint.processedChunks.count) chunks already processed")
            for vadIndex in checkpoint.processedChunks.sorted() {
                if let saved = checkpoint.chunkTranscripts[vadIndex] {
                    for r in saved {
                        allTranscriptionChunks.append(TranscriptionChunk(
                            text: r.text,
                            startTime: r.startTime,
                            endTime: r.endTime,
                            speaker: r.speaker,
                            speakerUUID: r.speakerUUID,
                            confidence: nil
                        ))
                    }
                }
                if let offset = checkpoint.chunkOffsets[vadIndex] {
                    currentGlobalOffset = offset
                }
            }
            print("[WhisperService] Restored \(allTranscriptionChunks.count) chunks, offset at \(currentGlobalOffset)s")
        }

        for (vadIndex, vadChunk) in vadChunks.enumerated() {
            // Calculate base progress for this VAD chunk
            // We allocate 0.2-0.9 (70%) for all transcription work
            let vadProgress = Double(vadIndex) / Double(vadChunks.count)
            let baseProgress = 0.2 + (vadProgress * 0.6) // 20% to 80% for VAD chunks
            
            // Skip chunks that were already processed in a previous run
            if let checkpoint = checkpoint, checkpoint.processedChunks.contains(vadIndex) {
                let vadChunkDuration = audioConverter.getAudioDuration(filePath: vadChunk.path) ?? 0
                currentGlobalOffset = checkpoint.chunkOffsets[vadIndex] ?? (currentGlobalOffset + vadChunkDuration)
                if vadChunk.standardizedFileURL != sourceURL.standardizedFileURL {
                    try? FileManager.default.removeItem(at: vadChunk)
                }
                print("[WhisperService] Skipping already-processed VAD chunk \(vadIndex + 1)/\(vadChunks.count)")
                continue
            }

            await MainActor.run {
                transcriptionStatus = "Processing chunk \(vadIndex + 1)/\(vadChunks.count): Identifying speakers..."
                transcriptionProgress = baseProgress
            }

            // Get VAD chunk duration for offset calculation
            let vadChunkDuration = audioConverter.getAudioDuration(filePath: vadChunk.path) ?? 0
            
            // Convert VAD chunk to WAV for diarization
            let vadWavPath = try await audioConverter.convertToWAV(audioFile: vadChunk.path)
            
            // Run diarization on this VAD chunk with error recovery
            var speakerSegments: [SpeakerDiarizer.SpeakerSegment] = []
            
            do {
                let diarizationResult = try await speakerDiarizer.performDiarization(
                    audioFile: vadWavPath,
                    modelPath: diarizeModelPath.path
                )
                
                logger.info("[WhisperService] VAD Chunk \(vadIndex + 1): Found \(diarizationResult.speakerCount) speakers, \(diarizationResult.segments.count) segments")
                
                // Log unique speakers in this chunk
                let uniqueSpeakersInChunk = Set(diarizationResult.segments.map { $0.speakerId })
                logger.info("[WhisperService] VAD Chunk \(vadIndex + 1) speakers: \(uniqueSpeakersInChunk.sorted().joined(separator: ", "))")
                
                // Track all unique speakers from diarization (before unification)
                allDiarizedSpeakers.formUnion(uniqueSpeakersInChunk)
                
                // Use raw diarization segments to preserve speaker boundaries
                speakerSegments = diarizationResult.segments
                
                // Validate segments
                if speakerSegments.isEmpty {
                    throw TranscriptionError.diarizationFailed("No speaker segments found")
                }
                
            } catch {
                // Diarization failed - fall back to treating entire VAD chunk as single segment
                logger.info("[WhisperService] WARNING: Diarization failed for chunk \(vadIndex + 1), using fallback: \(error)")
                
                // Create a single segment for the entire VAD chunk
                speakerSegments = [
                    SpeakerDiarizer.SpeakerSegment(
                        speakerId: "Speaker 1",  // Default to Speaker 1 for fallback
                        startTime: 0,
                        endTime: vadChunkDuration,
                        text: nil
                    )
                ]
            }
            
            // Track unique speakers in this chunk and update global counter
            let chunkSpeakerIds = Set(speakerSegments.map { $0.speakerId })
            var speakerMapping: [String: String] = [:]
            
            // Keep local speaker IDs for now - unification will handle global mapping
            for localSpeakerId in chunkSpeakerIds.sorted() {
                // Ensure we have valid speaker IDs
                let mappedId = localSpeakerId.isEmpty ? "Speaker Unknown" : localSpeakerId
                speakerMapping[localSpeakerId] = mappedId
            }
            
            // Split VAD chunk by speaker segments
            let vadChunkURL = URL(fileURLWithPath: vadWavPath)
            let speakerSegmentFiles = try await speakerSplitter.splitAudioBySpeakers(
                sourceURL: vadChunkURL,
                segments: speakerSegments
            )
            
            // Track identified speakers for this chunk to avoid re-identifying
            // We'll collect embeddings for batch processing at the end
            
            // Update total segment count
            totalSegmentsCount += speakerSegments.count
            
            // Record chunk count before this VAD chunk for callback
            let chunksBeforeThisVAD = allTranscriptionChunks.count

            // Transcribe each speaker segment
            for (segmentIndex, segment) in speakerSegments.enumerated() {
                // Calculate progress based on overall completion
                // Reserve 20-80% for transcription, then 80-90% for finalization
                let segmentProgress = 0.2 + (Double(totalSegmentsProcessed + segmentIndex) / Double(max(1, totalSegmentsCount)) * 0.6)
                
                await MainActor.run {
                    transcriptionStatus = "Chunk \(vadIndex + 1)/\(vadChunks.count): Transcribing \(segment.speakerId)..."
                    transcriptionProgress = min(0.8, segmentProgress)  // Cap at 80% during transcription
                }
                
                // Get the audio file for this segment
                guard let segmentAudioURL = speakerSegmentFiles[segmentIndex] else {
                    logger.info("[WhisperService] Warning: No audio file for segment \(segmentIndex)")
                    continue
                }
                
                // Convert segment to WAV if needed
                let segmentWavPath = try await audioConverter.convertToWAV(
                    audioFile: segmentAudioURL.path
                )
                
                // Extract speaker embedding for later unification
                if let embeddingService = embeddingService {
                    // FluidAudioEmbeddingService handles padding/truncation for any duration
                    let segmentDuration = segment.endTime - segment.startTime
                    
                    do {
                        let embedding = try await embeddingService.extractEmbedding(from: URL(fileURLWithPath: segmentWavPath))
                    
                        // Store for unification at the end
                        let chunkSpeaker = SpeakerUnificationService.ChunkSpeaker(
                            chunkId: vadIndex,
                            localSpeakerId: segment.speakerId,
                            embedding: embedding.vector,
                            startTime: currentGlobalOffset + segment.startTime,
                            endTime: currentGlobalOffset + segment.endTime,
                            confidence: embedding.confidence
                        )
                        allChunkSpeakers.append(chunkSpeaker)
                        
                        logger.info("[WhisperService] Extracted embedding for \(segment.speakerId) (\(String(format: "%.2f", segmentDuration))s, confidence: \(embedding.confidence))")
                    
                    } catch {
                        embeddingFailureCount += 1
                        logger.info("[WhisperService] Failed to extract embedding for \(String(format: "%.2f", segmentDuration))s segment (\(embeddingFailureCount)/\(embeddingAttemptCount) failures): \(error)")
                    }
                    embeddingAttemptCount += 1
                }
                
                // Transcribe the segment
                // Ensure we pass "auto" if language is nil to prevent default English
                let effectiveLanguage = language ?? "auto"
                logger.info("[WhisperService] Transcribing segment with language: \(effectiveLanguage)")
                
                // A single silent/failed VAD segment must NOT discard the whole recording. Long
                // files have dozens of segments; one empty one used to throw "No transcription
                // output generated" and fail the entire job — losing 30+ good chunks. Skip the bad
                // segment and keep going; only genuine cancellation (app quit / user stop) aborts.
                let segmentTranscript: String
                let segmentTokenStats: WhisperTokenStats?
                do {
                    let detailed = try await processRunner.runTranscriptionDetailed(
                        modelPath: qualityModelPath.path,
                        audioPath: segmentWavPath,
                        language: effectiveLanguage,
                        enableDiarization: false, // Already diarized
                        wordTimestamps: false
                    )
                    segmentTranscript = detailed.text
                    segmentTokenStats = detailed.tokenStats
                } catch {
                    try? FileManager.default.removeItem(atPath: segmentWavPath)
                    try? FileManager.default.removeItem(at: segmentAudioURL)
                    if Task.isCancelled { throw error }
                    logger.warning("[WhisperService] Segment \(segmentIndex + 1) of chunk \(vadIndex + 1) produced no transcript (\(error.localizedDescription)) — skipping, keeping the rest")
                    continue
                }

                // Clean up temporary files
                try? FileManager.default.removeItem(atPath: segmentWavPath)
                try? FileManager.default.removeItem(at: segmentAudioURL)
                
                // Create transcription chunk with temporal speaker ID
                // Will be updated after unification and database matching
                var temporalSpeakerLabel = speakerMapping[segment.speakerId] ?? segment.speakerId
                
                // Ensure we always have a non-empty speaker label
                if temporalSpeakerLabel.isEmpty {
                    temporalSpeakerLabel = "Speaker Unknown"
                    logger.info("[WhisperService] Warning: Empty speaker ID for segment, using 'Speaker Unknown'")
                }
                
                let chunk = TranscriptionChunk(
                    text: segmentTranscript,
                    startTime: currentGlobalOffset + segment.startTime,
                    endTime: currentGlobalOffset + segment.endTime,
                    speaker: temporalSpeakerLabel,  // Use temporal ID for now
                    speakerUUID: nil,  // Will be set after unification
                    confidence: segmentTokenStats?.meanP,
                    tokenStats: segmentTokenStats
                )
                // Record which embedding index corresponds to this chunk
                // The chunk index is the current count, the embedding index is the last one added
                let chunkIndex = allTranscriptionChunks.count
                if !allChunkSpeakers.isEmpty {
                    // If the last ChunkSpeaker was just added for this segment,
                    // map this chunk to it
                    let lastEmbedding = allChunkSpeakers.last!
                    let segmentStart = currentGlobalOffset + segment.startTime
                    let segmentEnd = currentGlobalOffset + segment.endTime
                    if lastEmbedding.startTime == segmentStart && lastEmbedding.endTime == segmentEnd {
                        chunkToEmbeddingMap[chunkIndex] = allChunkSpeakers.count - 1
                    }
                }
                allTranscriptionChunks.append(chunk)
            }

            // Update segment counter for accurate progress tracking
            totalSegmentsProcessed += speakerSegments.count
            
            // Update global offset for next VAD chunk
            currentGlobalOffset += vadChunkDuration

            // Fire checkpoint callback with newly transcribed chunks from this VAD chunk
            if chunksBeforeThisVAD < allTranscriptionChunks.count, let onChunkCompleted = onChunkCompleted {
                let newChunks = Array(allTranscriptionChunks[chunksBeforeThisVAD...])
                await onChunkCompleted(vadIndex, newChunks, currentGlobalOffset)
            }

            // Clean up VAD chunk files
            let vadWavURL = URL(fileURLWithPath: vadWavPath).standardizedFileURL
            if vadWavURL != sourceURL.standardizedFileURL,
               vadWavURL != vadChunk.standardizedFileURL {
                try? FileManager.default.removeItem(at: vadWavURL)
            }
            if vadChunk.standardizedFileURL != sourceURL.standardizedFileURL {
                try? FileManager.default.removeItem(at: vadChunk)
            }
        }
        
        // Log embedding extraction statistics
        if embeddingAttemptCount > 0 {
            let failureRate = Float(embeddingFailureCount) / Float(embeddingAttemptCount)
            if failureRate > 0.5 {
                logger.warning("[WhisperService] High embedding failure rate: \(embeddingFailureCount)/\(embeddingAttemptCount) (\(Int(failureRate * 100))%) - speaker unification may be incomplete")
            }
        }

        // Step 4: Unify speakers across chunks if embeddings are available
        if !allChunkSpeakers.isEmpty && embeddingService != nil {
            await MainActor.run {
                transcriptionStatus = "Unifying speaker identities..."
                transcriptionProgress = 0.85  // 85% after all transcription
            }
            
            do {
                // Use the same embedding service for unification
                // DBSCAN will automatically find the optimal number of clusters
                let unificationService = try SpeakerUnificationService(
                    embeddingService: embeddingService
                )
                let unificationResult = unificationService.unifySpeakers(from: allChunkSpeakers)
                
                logger.info("[WhisperService] Speaker unification complete:")
                print("  - Original segment embeddings: \(allChunkSpeakers.count)")
                print("  - Unique local speaker IDs: \(Set(allChunkSpeakers.map { $0.localSpeakerId }).count)")
                print("  - Unified speakers: \(unificationResult.speakerProfiles.count)")
                
                // Log the mapping
                for (key, value) in unificationResult.globalSpeakerMap.sorted(by: { $0.key < $1.key }) {
                    print("    - \(key) → \(value)")
                }
                
                // "Merge Later" approach: create unnamed speakers for each unified cluster.
                // No auto-matching against database. Users merge explicitly later.
                let speakerRepo = GRDBSpeakerRepository()
                var unifiedToUUID: [String: String] = [:]

                for profile in unificationResult.speakerProfiles {
                    let speakerUUID = UUID().uuidString
                    let _ = try speakerRepo.create(
                        uuid: speakerUUID,
                        name: nil,
                        embedding: profile.averageEmbedding,
                        confidence: profile.confidence,
                        sourceRecordingId: recordingId.map { Int64($0) }
                    )
                    unifiedToUUID[profile.globalId] = speakerUUID
                }

                logger.info("[WhisperService] Created \(unifiedToUUID.count) unnamed speaker profiles for later merging")

                // Update transcription chunks with unified speaker IDs and new UUIDs
                for i in 0..<allTranscriptionChunks.count {
                    guard let speaker = allTranscriptionChunks[i].speaker, !speaker.isEmpty else {
                        continue
                    }

                    guard let embeddingIndex = chunkToEmbeddingMap[i] else {
                        continue
                    }
                    let match = allChunkSpeakers[embeddingIndex]
                    let key = "\(match.chunkId)_\(match.localSpeakerId)"

                    if let unifiedId = unificationResult.globalSpeakerMap[key],
                       let speakerUUID = unifiedToUUID[unifiedId] {
                        allTranscriptionChunks[i].speaker = unifiedId
                        allTranscriptionChunks[i].speakerUUID = speakerUUID
                    } else if let unifiedId = unificationResult.globalSpeakerMap[key] {
                        allTranscriptionChunks[i].speaker = unifiedId
                    }
                }
                
                // Second pass: assign UUIDs to chunks that have a speaker label but missed embedding extraction
                // (Bug 2 fix: chunks skipped by chunkToEmbeddingMap get linked via speaker label text)
                var speakerLabelToUUID: [String: String] = [:]
                for chunk in allTranscriptionChunks {
                    if let speaker = chunk.speaker, let uuid = chunk.speakerUUID {
                        speakerLabelToUUID[speaker] = uuid
                    }
                }
                for i in 0..<allTranscriptionChunks.count {
                    if allTranscriptionChunks[i].speakerUUID == nil,
                       let speaker = allTranscriptionChunks[i].speaker,
                       let uuid = speakerLabelToUUID[speaker] {
                        allTranscriptionChunks[i].speakerUUID = uuid
                    }
                }

                // Log the unification report
                let report = unificationService.generateReport(from: unificationResult)
                logger.info("[WhisperService] \(report)")
                
            } catch {
                logger.warning("[WhisperService] Speaker unification failed: \(error)")
                // Fallback: create unnamed speaker records for each unique local speaker
                // so embeddings are preserved in the database for later merging
                let uniqueSpeakers = Dictionary(grouping: allChunkSpeakers, by: { $0.localSpeakerId })
                var localIdToUUID: [String: String] = [:]

                for (localId, segments) in uniqueSpeakers {
                    if let bestSegment = segments.max(by: { $0.confidence < $1.confidence }) {
                        do {
                            let profile = try speakerIdentificationService.createSpeaker(
                                embedding: bestSegment.embedding,
                                name: nil,
                                metadata: nil,
                                recordingId: recordingId != nil ? Int(recordingId!) : nil
                            )
                            localIdToUUID[localId] = profile.uuid
                            logger.info("[WhisperService] Created fallback speaker record for \(localId) → \(profile.uuid)")
                        } catch {
                            logger.warning("[WhisperService] Failed to create fallback speaker for \(localId): \(error)")
                        }
                    }
                }

                // Link fallback speaker UUIDs back to chunks via embedding index mapping.
                // NOTE: We intentionally do NOT do a second-pass by speaker label text here,
                // because in the fallback path (no unification), temporal labels like "Speaker 0"
                // are ambiguous across VAD chunks — two different people could share the same label.
                // Chunks without embeddings will get speaker_uuid via the backfill on next app launch.
                for i in 0..<allTranscriptionChunks.count {
                    guard let speaker = allTranscriptionChunks[i].speaker, !speaker.isEmpty else { continue }
                    if let embeddingIndex = chunkToEmbeddingMap[i] {
                        let match = allChunkSpeakers[embeddingIndex]
                        if let uuid = localIdToUUID[match.localSpeakerId] {
                            allTranscriptionChunks[i].speakerUUID = uuid
                        }
                    }
                }
            }
        }

        // Handle case where diarization produced speakers but no embeddings were available
        // (Bug 3 fix: create placeholder speaker records so utterances can be linked)
        if allChunkSpeakers.isEmpty && !allDiarizedSpeakers.isEmpty && !useFullFileDiarization {
            let hasUnlinkedSpeakers = allTranscriptionChunks.contains { $0.speaker != nil && $0.speakerUUID == nil }
            if hasUnlinkedSpeakers {
                logger.info("[WhisperService] No embeddings available, creating placeholder speakers for \(allDiarizedSpeakers.count) diarized speakers")
                let speakerRepo = GRDBSpeakerRepository()
                var labelToUUID: [String: String] = [:]

                for speakerLabel in allDiarizedSpeakers {
                    let speakerUUID = UUID().uuidString
                    do {
                        let _ = try speakerRepo.create(
                            uuid: speakerUUID,
                            name: nil,
                            embedding: [Float](repeating: 0, count: SpeakerEmbeddingPolicy.dimension),
                            confidence: 0.0,
                            sourceRecordingId: recordingId.map { Int64($0) }
                        )
                        labelToUUID[speakerLabel] = speakerUUID
                    } catch {
                        logger.warning("[WhisperService] Failed to create placeholder speaker for \(speakerLabel): \(error)")
                    }
                }

                for i in 0..<allTranscriptionChunks.count {
                    if let speaker = allTranscriptionChunks[i].speaker,
                       let uuid = labelToUUID[speaker] {
                        allTranscriptionChunks[i].speakerUUID = uuid
                    }
                }
                logger.info("[WhisperService] Linked \(labelToUUID.count) placeholder speakers to chunks")
            }
        }

        // Step 5: Build final result
        await MainActor.run {
            transcriptionStatus = "Finalizing transcription..."
            transcriptionProgress = 0.95
        }

        // FluidAudio full diarization (standard path): relabel chunks by speaker turns and build
        // per-speaker embeddings for the review wizard. Fail-safe — keeps original labels on error.
        var fluidSpeakerEmbeddings: [TranscriptionSpeakerEmbedding]? = nil
        if useFullFileDiarization {
            let fa = await applyFluidAudioDiarization(
                allTranscriptionChunks,
                audioFile: audioFile,
                configuration: pipelineConfiguration
            )
            allTranscriptionChunks = fa.chunks
            fluidSpeakerEmbeddings = fa.speakerEmbeddings

            // Auto-unify: resolve this file's speaker clusters to stable cross-file UUIDs and stamp
            // speaker_uuid onto chunks, so utterances persist identity now (browseable + mergeable in
            // the wizard) instead of deferring everything. Same matcher the backfill uses.
            if !fa.speakerEmbeddings.isEmpty {
                let labelToUUID = speakerIdentificationService.resolveClusters(
                    fa.identityClusters,
                    recordingId: recordingId,
                    configuration: pipelineConfiguration
                )
                for i in allTranscriptionChunks.indices {
                    if let label = allTranscriptionChunks[i].speaker, let uuid = labelToUUID[label] {
                        allTranscriptionChunks[i].speakerUUID = uuid
                    }
                }
                print("[WhisperService] Auto-unified \(labelToUUID.count) speaker(s) → cross-file UUIDs")
            }
        }

        // Combine all chunks into the persisted transcript, labelling each by its GLOBAL identity
        // (speaker_uuid → name / stable "Speaker <uuid8>") rather than the per-recording local label.
        // chunk.speakerUUID was stamped above (auto-unify / placeholder paths); returning named voices
        // resolve to their name, new ones to a stable global placeholder.
        let transcriptResolver = SpeakerNameResolver(speakers: (try? GRDBSpeakerRepository().getAll()) ?? [])
        let fullTranscript = LabeledTranscript.render(
            allTranscriptionChunks.map {
                LabeledTranscript.Segment(speakerUuid: $0.speakerUUID, localLabel: $0.speaker, text: $0.text)
            },
            resolver: transcriptResolver)
        
        // Count unique speakers across all chunks
        let uniqueSpeakers = Set(allTranscriptionChunks.compactMap { $0.speaker })
        
        // Convert chunk speakers to TranscriptionSpeakerEmbedding for the review wizard.
        // When FluidAudio is the standard path, use its per-speaker embeddings instead.
        let speakerEmbeddings: [TranscriptionSpeakerEmbedding] = fluidSpeakerEmbeddings ?? allChunkSpeakers.map { chunkSpeaker in
            TranscriptionSpeakerEmbedding(
                speakerId: chunkSpeaker.localSpeakerId,
                embedding: chunkSpeaker.embedding,
                startTime: chunkSpeaker.startTime,
                endTime: chunkSpeaker.endTime,
                confidence: chunkSpeaker.confidence
            )
        }
        
        // Log detailed speaker information for debugging
        print("[WhisperService] Speaker Detection Summary:")
        print("  - Diarization detected speakers (pre-unification): \(allDiarizedSpeakers.count) [\(allDiarizedSpeakers.sorted().joined(separator: ", "))]")
        print("  - Unified speakers: \(uniqueSpeakers.count) [\(uniqueSpeakers.sorted().joined(separator: ", "))]")
        print("  - Speaker embeddings collected: \(speakerEmbeddings.count)")
        print("  - All chunk speakers: \(allChunkSpeakers.count)")
        
        // Count distinct identities keyed by the GLOBAL uuid when present, else the local label: a
        // merged uuid collapses its chunks to one (no re-inflation from max()), while a labeled-but-
        // UUID-less chunk (unification fallback / wrong-dimension cluster) still contributes one.
        // Fall back to the local max as a DBSCAN-failure floor only when nothing carries an identity.
        let uniqueIdentities = Set(allTranscriptionChunks.compactMap { chunk -> String? in
            if let uuid = chunk.speakerUUID, !uuid.isEmpty { return "uuid:\(uuid)" }
            return chunk.speaker.map { "label:\($0)" }
        })
        let finalSpeakerCount = uniqueIdentities.isEmpty
            ? max(allDiarizedSpeakers.count, uniqueSpeakers.count)
            : uniqueIdentities.count
        print("  - Final speaker count for detection: \(finalSpeakerCount)")
        
        // Group embeddings by speaker for analysis
        var speakerEmbeddingGroups: [String: Int] = [:]
        for embedding in speakerEmbeddings {
            speakerEmbeddingGroups[embedding.speakerId, default: 0] += 1
        }
        for (speaker, count) in speakerEmbeddingGroups.sorted(by: { $0.key < $1.key }) {
            print("    - \(speaker): \(count) embeddings")
        }
        
        var result = TranscriptionResult(
            fullTranscript: fullTranscript,
            chunks: allTranscriptionChunks,
            totalDuration: currentGlobalOffset,
            language: language,
            usedVAD: true,
            detectedSpeakerCount: finalSpeakerCount,  // Use the max of diarized or unified count
            speakerEmbeddings: speakerEmbeddings.isEmpty ? nil : speakerEmbeddings
        )
        
        print("[WhisperService] VAD+Diarization pipeline complete: \(vadChunks.count) VAD chunks, \(uniqueSpeakers.count) speakers, \(allTranscriptionChunks.count) total segments")
        
        // Store result for speaker review
        lastTranscriptionResult = result
        
        return result
    }
}

// MARK: - TranscriptionError Extension
