import Foundation
import Combine
import Darwin // For memory tracking

/// Main orchestrator for Voxtral transcription services
class VoxtralCppService: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var isModelLoaded: Bool = false
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var currentModel: String = ""
    @Published var isTranscribing: Bool = false
    @Published var transcriptionStatus: String = ""
    @Published var transcriptionProgress: Double = 0.0
    @Published var currentMemoryUsage: Double = 0.0 // Memory usage in MB
    
    // Last transcription result for speaker review
    var lastTranscriptionResult: TranscriptionResult?
    
    // MARK: - Components
    
    private let modelManager: VoxtralModelManager
    private let audioConverter: VoxtralAudioConverter
    private let processRunner: LlamaCppProcessRunner
    private let logger: VoxtralLogger
    
    // MARK: - Private Properties
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Computed Properties
    
    /// Check if llama.cpp is installed
    var isLlamaInstalled: Bool {
        processRunner.isLlamaInstalled
    }
    
    /// Get available models
    var availableModels: [String: VoxtralModelConfig] {
        VoxtralConfiguration.models
    }
    
    // MARK: - Initialization
    
    init() {
        self.modelManager = VoxtralModelManager()
        self.audioConverter = VoxtralAudioConverter()
        self.processRunner = LlamaCppProcessRunner()
        self.logger = VoxtralLogger.shared
        
        // Set up bindings
        setupBindings()
        
        // Configure logger for debug mode in DEBUG builds
        #if DEBUG
        logger.logLevel = .debug
        logger.enableConsoleOutput = true
        #else
        logger.logLevel = .info
        logger.enableConsoleOutput = false
        #endif
        
        logger.info("VoxtralCppService initialized")
    }
    
    // MARK: - Setup
    
    private func setupBindings() {
        // Sync model manager state
        modelManager.$isModelLoaded
            .assign(to: &$isModelLoaded)
        
        modelManager.$isDownloading
            .assign(to: &$isDownloading)
        
        modelManager.$downloadProgress
            .assign(to: &$downloadProgress)
        
        modelManager.$currentModel
            .assign(to: &$currentModel)
    }
    
    // MARK: - Model Management
    
    /// Download a model
    func downloadModel(quantization: String = VoxtralConfiguration.defaultModel) async throws {
        logger.info("Downloading model: \(quantization)")
        try await modelManager.downloadModel(quantization)
    }
    
    /// Delete a model
    func deleteModel(_ modelKey: String) throws {
        logger.info("Deleting model: \(modelKey)")
        try modelManager.deleteModel(modelKey)
    }
    
    /// Check if a model is downloaded
    func isModelDownloaded(_ modelKey: String) -> Bool {
        modelManager.isModelDownloaded(modelKey)
    }
    
    /// Get model size in bytes
    func getModelSize(_ modelKey: String) -> Int64 {
        modelManager.getModelSize(modelKey)
    }
    
    // MARK: - Transcription
    
    /// Transcribe an audio file
    func transcribe(audioFile: String, modelKey: String? = nil, runSettings: RunSettings? = nil) async throws -> String {
        let modelToUse = modelKey ?? currentModel
        logger.info("Starting transcription for: \(audioFile) with model: \(modelToUse)")
        
        // Update status
        await updateTranscriptionStatus("Checking model...", progress: 0.1)
        
        // Check if specified model is available
        if !modelToUse.isEmpty && !modelManager.isModelDownloaded(modelToUse) {
            logger.error("Requested model not downloaded: \(modelToUse)")
            throw TranscriptionError.modelNotFound
        }
        
        // Ensure some model is loaded
        if modelToUse.isEmpty {
            try await ensureModelLoaded()
        }
        
        // Get model paths for the specified model
        let actualModel = modelToUse.isEmpty ? currentModel : modelToUse
        guard let modelPath = modelManager.getModelPath(for: actualModel),
              let mmprojPath = modelManager.getMmprojPath(for: actualModel) else {
            logger.error("Model paths not found for: \(actualModel)")
            await updateTranscriptionStatus("Model not found", progress: 0.0)
            throw TranscriptionError.modelNotFound
        }
        
        // Mark as transcribing
        await MainActor.run {
            isTranscribing = true
        }
        
        do {
            // Validate audio file
            await updateTranscriptionStatus("Validating audio file...", progress: 0.15)
            try audioConverter.validateAudioFile(audioFile)
            
            // Check audio duration
            let duration = audioConverter.getAudioDuration(filePath: audioFile) ?? 0
            // Always use VAD splitting for better accuracy and consistency
            // Note: VoxtralCppService uses VAD but not speaker diarization (that's WhisperService-specific)
            let minChunkingDuration: TimeInterval = 60 // Reduced to 1 minute - always use VAD for consistency
            
            logger.info("Audio file: \(audioFile)")
            logger.info("Audio duration: \(Int(duration)) seconds (\(Int(duration/60)) minutes)")
            logger.info("Will use VAD chunking: \(duration > minChunkingDuration)")
            
            // Always use VAD-based splitting for consistency with WhisperService approach
            if duration > minChunkingDuration {
                logger.info("Audio is longer than \(Int(minChunkingDuration/60)) minutes, using VAD-based splitting...")
                await updateTranscriptionStatus("Analyzing audio for optimal split points...", progress: 0.2)
                
                // Use VAD-based splitter for intelligent chunking
                let vadSplitter = VADAudioSplitter()
                let sourceURL = URL(fileURLWithPath: audioFile)
                let chunks = try await vadSplitter.splitAudioWithVAD(
                    sourceURL: sourceURL
                )
                
                logger.info("Split audio into \(chunks.count) chunks based on voice activity")
                
                // Log memory usage before processing
                logMemoryUsage("Before chunk processing")
                
                // Transcribe each chunk with context from previous chunk
                var transcripts: [String] = []
                var failedChunks: [Int] = []
                var previousContext: String? = nil  // Track context from previous chunk
                
                for (index, chunkURL) in chunks.enumerated() {
                    let chunkNumber = index + 1
                    let chunkProgress = 0.3 + (0.6 * Double(index) / Double(chunks.count))
                    
                    do {
                        // Log memory and chunk info
                        logMemoryUsage("Before chunk \(chunkNumber)/\(chunks.count)")
                        let chunkSize = getFileSize(chunkURL)
                        logger.info("Processing chunk \(chunkNumber)/\(chunks.count), size: \(formatBytes(chunkSize))")
                        
                        await updateTranscriptionStatus(
                            "Processing chunk \(chunkNumber)/\(chunks.count) (\(formatBytes(chunkSize)))...",
                            progress: chunkProgress
                        )
                        
                        // Validate chunk file exists before conversion
                        guard FileManager.default.fileExists(atPath: chunkURL.path) else {
                            logger.error("Chunk file does not exist: \(chunkURL.path)")
                            throw TranscriptionError.invalidURL
                        }
                        
                        // Convert chunk to WAV (keep original until transcription succeeds)
                        let wavFile = try await audioConverter.convertToWAV(
                            audioFile: chunkURL.path,
                            deleteOriginal: false // Keep temp chunk until transcription succeeds
                        )
                        
                        // Validate WAV file was created
                        guard FileManager.default.fileExists(atPath: wavFile) else {
                            logger.error("WAV file was not created: \(wavFile)")
                            throw TranscriptionError.processFailed("Failed to convert audio to WAV format")
                        }
                        
                        // Build context-aware prompt if we have previous context
                        let contextPrompt: String?
                        if let context = previousContext {
                            // Use last ~200 characters of previous chunk as context
                            let contextSnippet = String(context.suffix(200))
                            contextPrompt = "Continue transcribing from where the previous segment ended. Previous context: '\(contextSnippet)'. Now transcribe the following audio verbatim:"
                        } else {
                            // First chunk - use clear instruction
                            contextPrompt = "Transcribe the following audio verbatim. Output only the transcription without any explanations, notes, or commentary:"
                        }
                        
                        // Final validation before transcription
                        guard FileManager.default.fileExists(atPath: wavFile) else {
                            logger.error("WAV file missing before transcription: \(wavFile)")
                            throw TranscriptionError.processFailed("Audio file was deleted before processing")
                        }
                        
                        // Transcribe chunk with context and progress handler
                        let chunkOutput = try await processRunner.runTranscription(
                            modelPath: modelPath.path,
                            mmprojPath: mmprojPath.path,
                            audioPath: wavFile,
                            contextPrompt: contextPrompt,
                            progressHandler: { progress in
                                Task { @MainActor in
                                    self.transcriptionStatus = "Chunk \(index + 1)/\(chunks.count): \(progress)"
                                }
                            },
                            runSettings: runSettings
                        )
                        
                        let cleanedTranscript = cleanTranscript(chunkOutput)
                        transcripts.append(cleanedTranscript)
                        
                        // Update context for next chunk (only if we got meaningful content)
                        if cleanedTranscript.count > 10 {
                            previousContext = cleanedTranscript
                        }
                    
                        // Log transcript snippet for debugging
                        let snippet = String(cleanedTranscript.prefix(100))
                        logger.info("Chunk \(chunkNumber) transcript snippet: \(snippet)...")
                        logger.info("Chunk \(chunkNumber) transcript length: \(cleanedTranscript.count) characters")
                        
                        // Clean up files after successful transcription
                        try? FileManager.default.removeItem(at: chunkURL)
                        logger.debug("Cleaned up chunk \(chunkNumber) file")
                        
                        // Clean up WAV file after successful transcription
                        if FileManager.default.fileExists(atPath: wavFile) {
                            try? FileManager.default.removeItem(at: URL(fileURLWithPath: wavFile))
                            logger.debug("Cleaned up WAV file for chunk \(chunkNumber)")
                        }
                    
                    // Log memory after chunk
                    logMemoryUsage("After chunk \(chunkNumber)/\(chunks.count)")
                    
                        // Force cleanup of audio converter's temp files
                        audioConverter.cleanupTemporaryFiles()
                        
                    } catch {
                        // Log the error
                        logger.error("Failed to transcribe chunk \(chunkNumber): \(error.localizedDescription)")
                        
                        // Check if it's likely a silence/empty audio issue
                        let isLikelySilence = error.localizedDescription.contains("no output") || 
                                            error.localizedDescription.contains("silent")
                        
                        // Retry once if it might be a transient issue (not silence)
                        if !isLikelySilence && !failedChunks.contains(chunkNumber) {
                            logger.info("Retrying chunk \(chunkNumber)...")
                            
                            // Small delay before retry
                            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                            
                            // Re-convert to WAV since the file might have been corrupted
                            let retryWavFile = try? await audioConverter.convertToWAV(
                                audioFile: chunkURL.path,
                                deleteOriginal: false
                            )
                            
                            if let wavPath = retryWavFile {
                                do {
                                    // Build context for retry
                                    let retryContextPrompt: String?
                                    if let context = previousContext {
                                        let contextSnippet = String(context.suffix(200))
                                        retryContextPrompt = "Continue transcribing from where the previous segment ended. Previous context: '\(contextSnippet)'. Now transcribe the following audio verbatim:"
                                    } else {
                                        retryContextPrompt = "Transcribe the following audio verbatim. Output only the transcription without any explanations, notes, or commentary:"
                                    }
                                    
                                    // Retry the transcription
                                    let retryOutput = try await processRunner.runTranscription(
                                        modelPath: modelPath.path,
                                        mmprojPath: mmprojPath.path,
                                        audioPath: wavPath,
                                        contextPrompt: retryContextPrompt,
                                        progressHandler: { progress in
                                            Task { @MainActor in
                                                self.transcriptionStatus = "Retry chunk \(index + 1)/\(chunks.count): \(progress)"
                                            }
                                        },
                                        runSettings: runSettings
                                    )
                                    
                                    let cleanedTranscript = cleanTranscript(retryOutput)
                                    transcripts.append(cleanedTranscript)
                                    
                                    // Update context for successful retry
                                    if cleanedTranscript.count > 10 {
                                        previousContext = cleanedTranscript
                                    }
                                    
                                    logger.info("Chunk \(chunkNumber) retry successful")
                                    
                                    // Clean up files after successful retry
                                    try? FileManager.default.removeItem(at: chunkURL)
                                    if FileManager.default.fileExists(atPath: wavPath) {
                                        try? FileManager.default.removeItem(at: URL(fileURLWithPath: wavPath))
                                    }
                                    audioConverter.cleanupTemporaryFiles()
                                    
                                    continue // Move to next chunk
                                } catch {
                                    logger.error("Retry failed for chunk \(chunkNumber): \(error.localizedDescription)")
                                    // Fall through to error handling
                                }
                            } else {
                                logger.error("Failed to convert audio for retry")
                            }
                        }
                        
                        // Record failure
                        failedChunks.append(chunkNumber)
                        
                        // Extract more detailed error message
                        let errorMessage: String
                        if isLikelySilence {
                            errorMessage = "Silent or empty audio segment"
                        } else if let transcriptionError = error as? TranscriptionError {
                            errorMessage = transcriptionError.localizedDescription
                        } else {
                            errorMessage = error.localizedDescription
                        }
                        transcripts.append("[Chunk \(chunkNumber) failed: \(errorMessage)]")
                        
                        // Still clean up files
                        try? FileManager.default.removeItem(at: chunkURL)
                        audioConverter.cleanupTemporaryFiles()
                        
                        // Continue with next chunk
                        continue
                    }
                }
                
                // Log summary
                let successfulChunks = chunks.count - failedChunks.count
                logger.info("Transcription summary: \(successfulChunks)/\(chunks.count) chunks succeeded")
                if !failedChunks.isEmpty {
                    logger.warning("Failed chunks: \(failedChunks)")
                }
                
                // Combine transcripts
                await updateTranscriptionStatus("Combining transcripts...", progress: 0.9)
                let combinedTranscript = formatChunkedTranscript(transcripts)
                
                // Final cleanup
                audioConverter.cleanupTemporaryFiles()
                logMemoryUsage("After all chunks processed")
                
                // Update status based on results
                let statusMessage = failedChunks.isEmpty ? "Completed!" : "Partial success: \(successfulChunks)/\(chunks.count) chunks"
                
                await MainActor.run {
                    isTranscribing = false
                    transcriptionStatus = statusMessage
                    transcriptionProgress = 1.0
                }
                
                logger.info("Transcription completed with \(successfulChunks) successful chunks")
                
                // Create TranscriptionResult for speaker detection (Voxtral doesn't do diarization)
                lastTranscriptionResult = TranscriptionResult(
                    fullTranscript: combinedTranscript,
                    chunks: [],  // No speaker-specific chunks from Voxtral
                    totalDuration: audioConverter.getAudioDuration(filePath: audioFile) ?? 0,
                    language: nil,
                    usedVAD: true,
                    detectedSpeakerCount: nil,  // No speaker detection in Voxtral
                    speakerEmbeddings: nil
                )
                
                return combinedTranscript
                
            } else {
                // Process as single file
                await updateTranscriptionStatus("Converting audio format to WAV (16kHz, mono)...", progress: 0.3)
                let wavFile = try await audioConverter.convertToWAV(audioFile: audioFile)
                
                // Run transcription with clear prompt for single file
                await updateTranscriptionStatus("Running AI transcription model...", progress: 0.5)
                let contextPrompt = "Transcribe the following audio verbatim. Output only the transcription without any explanations, notes, or commentary:"
                let rawOutput = try await processRunner.runTranscription(
                    modelPath: modelPath.path,
                    mmprojPath: mmprojPath.path,
                    audioPath: wavFile,
                    contextPrompt: contextPrompt,
                    progressHandler: { progress in
                        Task { @MainActor in
                            self.transcriptionStatus = "Processing: \(progress)"
                        }
                    },
                    runSettings: runSettings
                )
                
                // Clean transcript
                await updateTranscriptionStatus("Processing transcript...", progress: 0.9)
                let cleanedTranscript = cleanTranscript(rawOutput)
                
                // Cleanup temporary files
                audioConverter.cleanupTemporaryFiles()
                
                logger.info("Transcription completed successfully")
                
                // Create TranscriptionResult for speaker detection (Voxtral doesn't do diarization)
                lastTranscriptionResult = TranscriptionResult(
                    fullTranscript: cleanedTranscript,
                    chunks: [],  // No speaker-specific chunks from Voxtral
                    totalDuration: audioConverter.getAudioDuration(filePath: audioFile) ?? 0,
                    language: nil,
                    usedVAD: false,
                    detectedSpeakerCount: nil,  // No speaker detection in Voxtral
                    speakerEmbeddings: nil
                )
                
                await MainActor.run {
                    isTranscribing = false
                    transcriptionStatus = "Completed!"
                    transcriptionProgress = 1.0
                }
                
                return cleanedTranscript
            }
            
        } catch {
            await MainActor.run {
                isTranscribing = false
                transcriptionStatus = "Error: \(error.localizedDescription)"
                transcriptionProgress = 0.0
            }
            
            logger.error("Transcription failed: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Update transcription status
    private func updateTranscriptionStatus(_ status: String, progress: Double) async {
        await MainActor.run {
            self.transcriptionStatus = status
            self.transcriptionProgress = progress
        }
        logger.debug("Status: \(status) (\(Int(progress * 100))%)")
    }
    
    /// Transcribe multiple audio chunks
    func transcribeChunks(audioChunks: [URL], progressHandler: ((Double) -> Void)? = nil) async throws -> String {
        logger.info("Starting batch transcription for \(audioChunks.count) chunks")
        
        // Ensure model is loaded
        try await ensureModelLoaded()
        
        var transcripts: [String] = []
        let totalChunks = audioChunks.count
        
        for (index, chunkURL) in audioChunks.enumerated() {
            logger.debug("Transcribing chunk \(index + 1)/\(totalChunks)")
            
            // Transcribe each chunk
            let chunkTranscript = try await transcribe(audioFile: chunkURL.path)
            transcripts.append(chunkTranscript)
            
            // Report progress
            let progress = Double(index + 1) / Double(totalChunks)
            progressHandler?(progress)
        }
        
        // Combine transcripts
        let combinedTranscript = formatChunkedTranscript(transcripts)
        
        logger.info("Batch transcription completed")
        return combinedTranscript
    }
    
    /// Cancel current transcription
    func cancelTranscription() {
        logger.info("Cancelling transcription")
        processRunner.cancelTranscription()
        isTranscribing = false
    }
    
    // MARK: - Installation
    
    /// Install llama.cpp
    func installLlamaCpp() async throws {
        logger.info("Installing llama.cpp")
        try await processRunner.installLlamaCpp()
    }
    
    // MARK: - Private Methods
    
    /// Ensure a model is loaded, downloading if necessary
    private func ensureModelLoaded() async throws {
        if !isModelLoaded || currentModel.isEmpty {
            logger.info("No model loaded, downloading default model")
            try await downloadModel()
        }
        
        guard isModelLoaded else {
            throw TranscriptionError.modelNotLoaded
        }
        
        guard processRunner.isLlamaInstalled else {
            logger.error("llama-mtmd-cli not installed")
            throw TranscriptionError.llamaCppNotFound
        }
    }
    
    /// Clean transcript output
    private func cleanTranscript(_ output: String) -> String {
        var cleaned = output
        
        // Remove llama.cpp processing logs if they somehow end up in stdout
        let processingPatterns = [
            "main: loading model:",
            "encoding audio slice...",
            "audio slice encoded in",
            "decoding audio batch",
            "audio decoded (batch"
        ]
        
        // Split into lines and filter out processing logs
        let lines = cleaned.components(separatedBy: .newlines)
        let filteredLines = lines.filter { line in
            !processingPatterns.contains(where: { line.contains($0) })
        }
        cleaned = filteredLines.joined(separator: "\n")
        
        // Remove system tokens
        for token in VoxtralConfiguration.systemTokensToRemove {
            cleaned = cleaned.replacingOccurrences(of: token, with: "")
        }
        
        // Remove prompt text if present
        if let range = cleaned.range(of: "Transcribe") {
            cleaned.removeSubrange(cleaned.startIndex..<cleaned.index(after: range.upperBound))
        }
        
        // Clean up whitespace
        cleaned = cleaned
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "  ", with: " ")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
        
        return cleaned
    }
    
    /// Format chunked transcript with markers
    private func formatChunkedTranscript(_ transcripts: [String]) -> String {
        guard transcripts.count > 1 else {
            return transcripts.first ?? ""
        }
        
        // Just join the transcripts with simple spacing, no chunk markers
        return transcripts.joined(separator: "\n\n")
    }
    
    /// Get file size in bytes
    private func getFileSize(_ url: URL) -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }
    
    /// Format bytes to human readable string
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    /// Log current memory usage
    private func logMemoryUsage(_ context: String) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         intPtr,
                         &count)
            }
        }
        
        if result == KERN_SUCCESS {
            let usedMemory = Double(info.resident_size) / 1024.0 / 1024.0
            logger.info("\(context) - Memory: \(String(format: "%.1f", usedMemory)) MB")
            
            // Update published memory usage for UI
            Task { @MainActor in
                self.currentMemoryUsage = usedMemory
            }
        }
    }
}