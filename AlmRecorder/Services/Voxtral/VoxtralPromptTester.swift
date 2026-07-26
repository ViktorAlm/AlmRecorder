import Foundation
import Combine
import AlmRecorderEvaluationKit

/// Test configuration for different prompt strategies
struct PromptTestConfig: Codable {
    let id: String
    let name: String
    let prompt: String
    let description: String
    let isSpecialToken: Bool
    let group: TestGroup
    
    enum TestGroup: String, CaseIterable, Codable {
        case specialTokens = "Special Tokens"
        case textPrompts = "Text Prompts"
        case instructionFormat = "Instruction Format"
        case verbatimVariants = "Verbatim Variants"
        case contextHistory = "Context/History"
    }
}

/// Result from a prompt test
struct PromptTestResult: Identifiable, Hashable {
    let id = UUID()
    let configId: String
    let configName: String
    let prompt: String
    let transcript: String
    let processingTime: TimeInterval
    let tokenCount: Int
    let characterCount: Int
    let wordCount: Int
    let tokenSequence: String? // If we can extract it
    let error: String?
    let timestamp: Date
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: PromptTestResult, rhs: PromptTestResult) -> Bool {
        lhs.id == rhs.id
    }
}

/// Manages prompt testing for Voxtral
class VoxtralPromptTester: ObservableObject {
    
    // MARK: - Singleton
    static let shared = VoxtralPromptTester()
    
    // MARK: - Published Properties
    @Published var isRunning = false
    @Published var currentTest: String = ""
    @Published var progress: Double = 0.0
    @Published var results: [PromptTestResult] = []
    @Published var selectedAudioPath: String = ""
    @Published private(set) var testConfigs: [PromptTestConfig] = []
    @Published private(set) var configurationError: String?
    
    // MARK: - Private Properties
    private let processRunner = LlamaCppProcessRunner()
    private let modelManager = VoxtralModelManager()
    private let audioConverter = VoxtralAudioConverter()
    private let vadSplitter = VADAudioSplitter()
    private let logger = VoxtralLogger.shared
    
    private init() {
        reloadLocalConfigurations()
    }

    /// Load this developer's prompt configurations from the external evaluation workspace.
    /// Missing or invalid data produces an empty list; there is no embedded fallback corpus.
    func reloadLocalConfigurations() {
        do {
            let store = try JSONEvaluationArtifactStore<
                VersionedEvaluationEnvelope<[PromptTestConfig]>
            >(
                workspace: EvaluationWorkspace.current(),
                fileName: "prompt-configurations.json"
            )
            guard let bundle = try store.load() else {
                testConfigs = []
                configurationError = "No local prompt configuration file is installed."
                return
            }
            guard bundle.schemaVersion == 1,
                  bundle.kind == "prompt-configurations" else {
                testConfigs = []
                configurationError = "The local prompt configuration schema is unsupported."
                return
            }
            let uniqueIDs = Set(bundle.payload.map(\.id))
            guard uniqueIDs.count == bundle.payload.count else {
                testConfigs = []
                configurationError = "Local prompt configuration identifiers must be unique."
                return
            }
            testConfigs = bundle.payload
            configurationError = nil
        } catch {
            testConfigs = []
            configurationError = error.localizedDescription
        }
    }

    func reportLocalConfigurationError(_ error: Error) {
        configurationError = error.localizedDescription
    }
    
    // MARK: - Public Methods
    
    /// Submit a test to the queue system
    @MainActor
    func submitTestToQueue(_ config: PromptTestConfig, modelKey: String = VoxtralConfiguration.defaultModel, runSettings: RunSettings? = nil) -> UUID? {
        guard !selectedAudioPath.isEmpty else {
            logger.error("[PromptTester] No audio file selected")
            return nil
        }
        
        let appState = AppState.shared
        let job = appState.runPromptTest(
            audioFile: selectedAudioPath,
            config: config,
            modelKey: modelKey,
            priority: .low,  // Prompt tests are low priority
            runSettings: runSettings
        )
        
        logger.info("[PromptTester] Submitted test to queue: \(config.name) with job ID: \(job.id)")
        return job.id
    }
    
    /// Submit all tests to the queue
    func submitAllTestsToQueue(modelKey: String = VoxtralConfiguration.defaultModel, runSettings: RunSettings? = nil) async -> [UUID] {
        guard !selectedAudioPath.isEmpty else {
            logger.error("[PromptTester] No audio file selected")
            return []
        }
        
        var jobIds: [UUID] = []
        let appState = AppState.shared
        
        // Submit jobs sequentially with small delays to avoid blocking UI
        for (index, config) in testConfigs.enumerated() {
            // Small delay between submissions to let UI update
            if index > 0 {
                try? await Task.sleep(nanoseconds: 5_000_000) // 5ms delay
            }
            
            // Submit on main actor since AppState operations need it
            let job = await MainActor.run {
                appState.runPromptTest(
                    audioFile: selectedAudioPath,
                    config: config,
                    modelKey: modelKey,
                    priority: .low,
                    runSettings: runSettings
                )
            }
            
            jobIds.append(job.id)
            logger.info("[PromptTester] Submitted test \(index + 1)/\(testConfigs.count): \(config.name)")
            
            // Yield to allow UI updates every few submissions
            if index % 3 == 0 {
                await Task.yield()
            }
        }
        
        logger.info("[PromptTester] Submitted \(jobIds.count) tests to queue")
        return jobIds
    }
    
    /// Run a single test configuration with progress callback
    /// - Parameters:
    ///   - config: The prompt configuration to test
    ///   - extractTokens: Whether to extract token sequences
    ///   - maxChunks: Maximum chunks to process (0 = all chunks, default 3 for speed)
    ///   - modelKey: The model key to use for testing (defaults to VoxtralConfiguration.defaultModel)
    ///   - progressCallback: Optional callback for progress updates
    func runSingleTest(
        _ config: PromptTestConfig,
        extractTokens: Bool = true,
        maxChunks: Int = 3,
        modelKey: String = VoxtralConfiguration.defaultModel,
        progressCallback: ((TranscriptionJob.ProgressPhase, Double, String) -> Void)? = nil,
        runSettings: RunSettings? = nil
    ) async throws -> PromptTestResult {
        logger.info("[PromptTester] Running test: \(config.name)")
        
        guard !selectedAudioPath.isEmpty else {
            throw TranscriptionError.invalidURL
        }
        
        // Phase: Preparing Audio
        progressCallback?(.preparingAudio, 0.05, "Verifying model...")
        
        // First verify the model is actually downloaded
        guard modelManager.isModelDownloaded(modelKey) else {
            logger.error("[PromptTester] Model not downloaded: \(modelKey)")
            throw TranscriptionError.modelNotFound
        }
        
        // Get model paths (will now return nil if files don't exist)
        guard let modelPath = modelManager.getModelPath(for: modelKey),
              let mmprojPath = modelManager.getMmprojPath(for: modelKey) else {
            logger.error("[PromptTester] Model files not found: \(modelKey)")
            throw TranscriptionError.modelNotFound
        }
        
        logger.info("[PromptTester] Using model: \(modelKey)")
        
        // Check audio duration
        let duration = audioConverter.getAudioDuration(filePath: selectedAudioPath) ?? 0
        logger.info("[PromptTester] Audio duration: \(Int(duration)) seconds")
        
        // Phase: Splitting Chunks
        progressCallback?(.splittingChunks, 0.10, "Analyzing audio...")
        
        // Decide whether to use VAD splitting
        let minSplitDuration: TimeInterval = 30 // Split if longer than 30 seconds
        var audioChunks: [URL] = []
        
        if duration > minSplitDuration {
            logger.info("[PromptTester] Using VAD splitting for audio > \(Int(minSplitDuration))s")
            
            // Split audio using VAD
            let sourceURL = URL(fileURLWithPath: selectedAudioPath)
            let allChunks = try await vadSplitter.splitAudioWithVAD(sourceURL: sourceURL)
            
            // Use only first N chunks for testing (unless maxChunks is 0 = use all)
            if maxChunks > 0 {
                audioChunks = Array(allChunks.prefix(maxChunks))
                logger.info("[PromptTester] Split into \(allChunks.count) chunks, using first \(audioChunks.count) for testing")
            } else {
                audioChunks = allChunks
                logger.info("[PromptTester] Split into \(audioChunks.count) chunks, using all for testing")
            }
        } else {
            // Use entire file as single chunk
            let wavPath = try await audioConverter.convertToWAV(audioFile: selectedAudioPath)
            audioChunks = [URL(fileURLWithPath: wavPath)]
            logger.info("[PromptTester] Using entire audio as single chunk")
        }
        
        // Start timing
        let startTime = Date()
        
        do {
            var allTranscripts: [String] = []
            var allTokenSequences: [String] = []
            var previousContext: String? = nil
            var totalTokenCount = 0
            var chunkTimes: [TimeInterval] = []
            
            // Phase: Transcribing Chunks
            progressCallback?(.transcribingChunks, 0.10, "Starting transcription...")
            
            // Process each chunk
            for (index, chunkURL) in audioChunks.enumerated() {
                let chunkStartTime = Date()
                
                // Calculate and report progress
                let baseProgress = 0.10
                let progressRange = 0.80 // 10% to 90% for transcription
                // Progress should show which chunk we're processing (not completed)
                let chunkProgress = Double(index) / Double(audioChunks.count)
                let currentProgress = baseProgress + (chunkProgress * progressRange)
                
                // Calculate ETA if we have previous chunk times
                var etaMessage = "Processing chunk \(index + 1) of \(audioChunks.count)"
                if !chunkTimes.isEmpty {
                    let avgChunkTime = chunkTimes.reduce(0, +) / Double(chunkTimes.count)
                    let remainingChunks = audioChunks.count - index
                    let eta = avgChunkTime * Double(remainingChunks)
                    if eta > 0 {
                        let formatter = DateComponentsFormatter()
                        formatter.allowedUnits = [.minute, .second]
                        formatter.unitsStyle = .abbreviated
                        if let etaString = formatter.string(from: eta) {
                            etaMessage += " - ETA: \(etaString)"
                        }
                    }
                }
                
                progressCallback?(.transcribingChunks, currentProgress, etaMessage)
                logger.info("[PromptTester] Processing chunk \(index + 1)/\(audioChunks.count) - Progress: \(Int(currentProgress * 100))%")
                
                // Convert chunk to WAV
                let wavPath = try await audioConverter.convertToWAV(audioFile: chunkURL.path)
                
                // Build context-aware prompt for chunks after the first
                let contextPrompt: String
                if index == 0 || config.group == .specialTokens {
                    // First chunk or special token test - use original prompt
                    contextPrompt = config.prompt
                } else if let context = previousContext {
                    // Subsequent chunks - add context from previous chunk
                    let contextSnippet = String(context.suffix(200))
                    if config.prompt.isEmpty {
                        contextPrompt = "Continue from: '\(contextSnippet)'"
                    } else {
                        contextPrompt = "\(config.prompt) [Continuing from: '\(contextSnippet)']"
                    }
                } else {
                    contextPrompt = config.prompt
                }
                
                logger.debug("[PromptTester] Chunk \(index + 1) prompt: \(contextPrompt)")
                
                // Run transcription for this chunk
                logger.info("[PromptTester] Starting transcription for chunk \(index + 1)/\(audioChunks.count)...")
                logger.info("[PromptTester] Chunk \(index + 1) audio path: \(wavPath)")
                let transcriptionStartTime = Date()
                
                // Add progress monitoring task
                let progressTask = Task {
                    var lastLog = Date()
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 5_000_000_000) // Check every 5 seconds
                        if Date().timeIntervalSince(lastLog) > 5 {
                            let elapsed = Int(Date().timeIntervalSince(transcriptionStartTime))
                            logger.info("[PromptTester] Chunk \(index + 1) still processing... (\(elapsed)s elapsed)")
                            lastLog = Date()
                        }
                    }
                }
                
                let output: String
                do {
                    output = try await processRunner.runTranscription(
                        modelPath: modelPath.path,
                        mmprojPath: mmprojPath.path,
                        audioPath: wavPath,
                        contextPrompt: contextPrompt,
                        timeout: 60, // Reduced to 60 seconds per chunk
                        verbosePrompt: extractTokens, // Enable verbose to see tokens
                        runSettings: runSettings
                    )
                    progressTask.cancel()
                    let transcriptionTime = Date().timeIntervalSince(transcriptionStartTime)
                    logger.info("[PromptTester] Chunk \(index + 1) transcribed successfully in \(String(format: "%.1f", transcriptionTime))s")
                    logger.info("[PromptTester] Chunk \(index + 1) output length: \(output.count) characters")
                } catch {
                    progressTask.cancel()
                    logger.error("[PromptTester] Failed to transcribe chunk \(index + 1): \(error)")
                    progressCallback?(.transcribingChunks, currentProgress, "Error: \(error.localizedDescription)")
                    throw error
                }
                
                // Update progress after chunk completes
                let chunkCompleteProgress = baseProgress + (Double(index + 1) / Double(audioChunks.count) * progressRange)
                progressCallback?(.transcribingChunks, chunkCompleteProgress, "Completed chunk \(index + 1) of \(audioChunks.count)")
                logger.info("[PromptTester] Chunk \(index + 1)/\(audioChunks.count) complete - Progress: \(Int(chunkCompleteProgress * 100))%")
                
                // Parse and clean the output
                let parser = LlamaCppOutputParser()
                let parseResult = parser.parse(stdout: output, stderr: "", exitCode: 0)
                
                if let transcript = parseResult.transcript {
                    let cleaned = cleanTranscript(transcript)
                    allTranscripts.append(cleaned)
                    previousContext = cleaned // Update context for next chunk
                }
                
                if let tokenSeq = parseResult.processingInfo.tokenSequence {
                    allTokenSequences.append(tokenSeq)
                }
                
                totalTokenCount += parseResult.processingInfo.tokensGenerated ?? 0
                
                // Track chunk processing time
                let chunkEndTime = Date()
                let chunkTime = chunkEndTime.timeIntervalSince(chunkStartTime)
                chunkTimes.append(chunkTime)
                logger.info("[PromptTester] Chunk \(index + 1) completed in \(String(format: "%.2f", chunkTime))s")
            }
            
            // Phase: Combining Results
            progressCallback?(.combiningResults, 0.90, "Combining transcription results...")
            
            let endTime = Date()
            let processingTime = endTime.timeIntervalSince(startTime)
            
            // Combine all transcripts
            let combinedTranscript = allTranscripts.joined(separator: "\n\n")
            
            // Calculate metrics
            let characterCount = combinedTranscript.count
            let wordCount = combinedTranscript.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.count
            
            // Combine token sequences
            let combinedTokenSequence = allTokenSequences.isEmpty ? nil : allTokenSequences.joined(separator: " | ")
            
            // Phase: Finalizing
            progressCallback?(.finalizing, 0.95, "Finalizing results...")
            
            return PromptTestResult(
                configId: config.id,
                configName: config.name,
                prompt: config.prompt,
                transcript: combinedTranscript,
                processingTime: processingTime,
                tokenCount: totalTokenCount,
                characterCount: characterCount,
                wordCount: wordCount,
                tokenSequence: combinedTokenSequence,
                error: nil,
                timestamp: Date()
            )
            
        } catch {
            let endTime = Date()
            let processingTime = endTime.timeIntervalSince(startTime)
            
            return PromptTestResult(
                configId: config.id,
                configName: config.name,
                prompt: config.prompt,
                transcript: "",
                processingTime: processingTime,
                tokenCount: 0,
                characterCount: 0,
                wordCount: 0,
                tokenSequence: nil,
                error: error.localizedDescription,
                timestamp: Date()
            )
        }
    }
    
    // NOTE: Old runAllTests method removed - use submitAllTestsToQueue instead
    // Tests should be submitted to the queue system for processing
    // This ensures proper model downloading and job management
    
    /// Export results to CSV
    func exportResultsAsCSV() -> String {
        var csv = "Config Name,Prompt,Word Count,Character Count,Processing Time,Transcript Preview,Error\n"
        
        for result in results {
            let promptEscaped = result.prompt.replacingOccurrences(of: "\"", with: "\"\"")
            let transcriptPreview = String(result.transcript.prefix(100))
                .replacingOccurrences(of: "\"", with: "\"\"")
                .replacingOccurrences(of: "\n", with: " ")
            
            csv += "\"\(result.configName)\","
            csv += "\"\(promptEscaped)\","
            csv += "\(result.wordCount),"
            csv += "\(result.characterCount),"
            csv += String(format: "%.2f", result.processingTime) + ","
            csv += "\"\(transcriptPreview)\","
            csv += "\"\(result.error ?? "Success")\"\n"
        }
        
        return csv
    }
    
    /// Check if a result uses HuggingFace-compatible token format
    func isHuggingFaceCompatible(_ result: PromptTestResult) -> Bool {
        guard let tokenSeq = result.tokenSequence else { return false }
        
        // Check for known HuggingFace special tokens in the sequence
        // These are the tokens we expect to see in a HuggingFace-compatible format
        let huggingFaceTokens = [
            "[BOS]", "[INST]", "[/INST]", "[TRANSCRIBE]", 
            "[BEGIN_AUDIO]", "[AUDIO]", "lang:en"
        ]
        
        for token in huggingFaceTokens {
            if tokenSeq.contains(token) {
                return true
            }
        }
        
        // Also check if the token sequence looks like the expected format:
        // [BOS][INST][BEGIN_AUDIO][AUDIO]...[/INST][TRANSCRIBE]
        if tokenSeq.contains("[BOS]") && tokenSeq.contains("[INST]") {
            return true
        }
        
        return false
    }
    
    /// Find the most HuggingFace-compatible configuration
    func findBestHuggingFaceConfig() -> (config: PromptTestConfig, result: PromptTestResult)? {
        for result in results {
            if isHuggingFaceCompatible(result) {
                if let config = testConfigs.first(where: { $0.id == result.configId }) {
                    logger.info("[PromptTester] Found HuggingFace-compatible config: \(config.name)")
                    logger.info("[PromptTester] Token sequence: \(result.tokenSequence ?? "none")")
                    return (config, result)
                }
            }
        }
        return nil
    }
    
    /// Export results as Markdown
    func exportResultsAsMarkdown() -> String {
        var markdown = "# Voxtral Prompt Test Results\n\n"
        markdown += "**Test Audio**: \(selectedAudioPath)\n"
        markdown += "**Test Date**: \(Date())\n\n"
        
        // Group results by test group
        let groups = PromptTestConfig.TestGroup.allCases
        
        for group in groups {
            let groupResults = results.filter { result in
                testConfigs.first { $0.id == result.configId }?.group == group
            }
            
            if !groupResults.isEmpty {
                markdown += "## \(group.rawValue)\n\n"
                markdown += "| Config | Prompt | Words | Chars | Time (s) | Status |\n"
                markdown += "|--------|--------|-------|-------|----------|--------|\n"
                
                for result in groupResults {
                    let promptPreview = String(result.prompt.prefix(50))
                    let status = result.error == nil ? "✅" : "❌"
                    
                    markdown += "| \(result.configName) "
                    markdown += "| `\(promptPreview)` "
                    markdown += "| \(result.wordCount) "
                    markdown += "| \(result.characterCount) "
                    markdown += "| \(String(format: "%.2f", result.processingTime)) "
                    markdown += "| \(status) |\n"
                }
                
                markdown += "\n"
            }
        }
        
        // Add transcript samples
        markdown += "## Transcript Samples\n\n"
        for result in results.prefix(5) {
            if !result.transcript.isEmpty {
                markdown += "### \(result.configName)\n"
                markdown += "```\n"
                markdown += String(result.transcript.prefix(200))
                if result.transcript.count > 200 {
                    markdown += "..."
                }
                markdown += "\n```\n\n"
            }
        }
        
        return markdown
    }
    
    // MARK: - Private Methods
    
    private func cleanTranscript(_ output: String) -> String {
        var cleaned = output
        
        // Remove system tokens
        for token in VoxtralConfiguration.systemTokensToRemove {
            cleaned = cleaned.replacingOccurrences(of: token, with: "")
        }
        
        // Clean up whitespace
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return cleaned
    }
}
