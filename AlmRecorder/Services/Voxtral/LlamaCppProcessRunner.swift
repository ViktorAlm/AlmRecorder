import Foundation

/// Handles execution of llama-mtmd-cli process
class LlamaCppProcessRunner {
    
    private let logger = VoxtralLogger.shared
    private let outputParser = LlamaCppOutputParser()
    private var currentProcess: Process?
    
    /// Path to llama-mtmd-cli executable
    private(set) var llamaMtmdPath: String
    
    /// Check if llama-mtmd-cli is installed
    var isLlamaInstalled: Bool {
        !llamaMtmdPath.isEmpty && FileManager.default.fileExists(atPath: llamaMtmdPath)
    }
    
    /// Per-engine argument builder (Voxtral by default; Gemma injects its own sampler + --jinja).
    private let engineParameters: LLMTranscriptionParameters

    init(engineParameters: LLMTranscriptionParameters = VoxtralConfiguration.processParameters) {
        self.engineParameters = engineParameters
        self.llamaMtmdPath = Self.findLlamaMtmdCli()
    }
    
    /// Find llama-mtmd-cli executable
    private static func findLlamaMtmdCli() -> String {
        let logger = VoxtralLogger.shared
        logger.debug("Searching for llama-mtmd-cli...")

        // Resolve consistently with the other llama tools (bundled Resources/Binaries, dev build, Homebrew).
        if let resolved = LlamaRuntime.findBinary(named: "llama-mtmd-cli",
                                                  systemSearchPaths: VoxtralConfiguration.llamaMtmdSearchPaths) {
            logger.info("Found llama-mtmd-cli at: \(resolved)")
            return resolved
        }
        
        // Check common locations
        for path in VoxtralConfiguration.llamaMtmdSearchPaths {
            if FileManager.default.fileExists(atPath: path) {
                logger.info("Found llama-mtmd-cli at: \(path)")
                return path
            }
        }
        
        // Check bundle
        let bundlePath = Bundle.main.bundlePath + "/Contents/MacOS/llama-mtmd-cli"
        if FileManager.default.fileExists(atPath: bundlePath) {
            logger.info("Found llama-mtmd-cli in bundle: \(bundlePath)")
            return bundlePath
        }
        
        // Try to find with 'which' command
        if let path = findWithWhich() {
            logger.info("Found llama-mtmd-cli via which: \(path)")
            return path
        }
        
        logger.warning("llama-mtmd-cli not found, using default path")
        return "/usr/local/bin/llama-mtmd-cli"  // Default fallback
    }
    
    private static func findWithWhich() -> String? {
        let task = Process()
        task.launchPath = "/usr/bin/which"
        task.arguments = ["llama-mtmd-cli"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()  // Suppress errors
        
        do {
            try task.run()
            task.waitUntilExit()
            
            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    return path
                }
            }
        } catch {
            // Ignore errors
        }
        
        return nil
    }
    
    /// Run transcription process
    /// - Parameters:
    ///   - modelPath: Path to the model file
    ///   - mmprojPath: Path to the mmproj file
    ///   - audioPath: Path to the audio file
    ///   - contextPrompt: Optional custom prompt
    ///   - timeout: Maximum time to wait for transcription (default: 300 seconds)
    ///   - verbosePrompt: Enable verbose prompt output to see tokens
    ///   - progressHandler: Optional handler for progress updates
    /// - Returns: Transcription output
    func runTranscription(modelPath: String,
                         mmprojPath: String,
                         audioPath: String,
                         contextPrompt: String? = nil,
                         timeout: TimeInterval = 300,
                         verbosePrompt: Bool = false,
                         progressHandler: ((String) -> Void)? = nil,
                         runSettings: RunSettings? = nil,
                         returnRawOutput: Bool = false) async throws -> String {
        
        // Validate paths
        guard FileManager.default.fileExists(atPath: llamaMtmdPath) else {
            logger.error("llama-mtmd-cli not found at: \(llamaMtmdPath)")
            throw TranscriptionError.llamaCppNotFound
        }
        
        guard FileManager.default.fileExists(atPath: modelPath) else {
            logger.error("Model file not found: \(modelPath)")
            throw TranscriptionError.modelNotFound
        }
        
        guard FileManager.default.fileExists(atPath: mmprojPath) else {
            logger.error("MMProj file not found: \(mmprojPath)")
            throw TranscriptionError.modelNotFound
        }
        
        guard FileManager.default.fileExists(atPath: audioPath) else {
            logger.error("Audio file not found: \(audioPath)")
            throw TranscriptionError.invalidURL
        }
        
        // Validate and warn about empty prompts
        if let prompt = contextPrompt, prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logger.warning("Empty or whitespace-only prompt detected - this may cause unexpected behavior")
        }
        
        // Build arguments with optional context prompt or run settings
        var arguments: [String]
        if let runSettings = runSettings {
            // Use run settings if provided (overrides prompt with settings.prompt)
            var settingsToUse = runSettings
            if let contextPrompt = contextPrompt {
                // Override prompt if contextPrompt is explicitly provided
                settingsToUse = RunSettings(
                    temperature: runSettings.temperature,
                    topK: runSettings.topK,
                    topP: runSettings.topP,
                    maxTokens: runSettings.maxTokens,
                    contextKeep: runSettings.contextKeep,
                    gpuLayers: runSettings.gpuLayers,
                    seed: runSettings.seed,
                    prompt: contextPrompt
                )
            }
            arguments = self.engineParameters.buildArguments(
                modelPath: modelPath,
                mmprojPath: mmprojPath,
                audioPath: audioPath,
                runSettings: settingsToUse
            )
        } else {
            // Fall back to default parameters
            arguments = self.engineParameters.buildArguments(
                modelPath: modelPath,
                mmprojPath: mmprojPath,
                audioPath: audioPath,
                contextPrompt: contextPrompt
            )
        }
        
        // Add verbose prompt flag if requested (to see token IDs)
        if verbosePrompt {
            arguments.append("--verbose-prompt")
        }
        
        logger.debug("Command: \(llamaMtmdPath) \(arguments.joined(separator: " "))")
        
        // Create process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: llamaMtmdPath)
        process.arguments = arguments

        // Ensure a bundled binary resolves its own ggml/llama dylibs (no-op for Homebrew binaries).
        LlamaRuntime.applyLibraryPath(to: process, binaryPath: llamaMtmdPath)
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        // Store reference for potential cancellation
        currentProcess = process
        
        // Ensure we clear the process reference when done
        defer {
            currentProcess = nil
            ChildProcessReaper.shared.untrack(process)
        }
        
        // Prepare to capture output
        var outputData = Data()
        var errorData = Data()
        var lastProgressTime = Date()
        let maxOutputSize = 1_048_576 // 1MB max output size
        var outputExceeded = false
        
        // Set up handlers to read output as it comes
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            outputData.append(data)
            
            // Check for excessive output
            if outputData.count > maxOutputSize && !outputExceeded {
                outputExceeded = true
                self.logger.error("Output size exceeded 1MB (\(outputData.count) bytes) - possible runaway generation")
                // Don't terminate immediately, let timeout handle it
            }
            
            // Parse progress if we have data
            if let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty {
                // Parse and enhance progress messages
                if chunk.contains("encoding audio") || chunk.contains("decoding audio") || chunk.contains("processing") {
                    let lines = chunk.components(separatedBy: .newlines)
                    for line in lines where !line.isEmpty {
                        self.logger.debug("Progress: \(line)")
                        
                        // Enhance progress messages for user
                        if line.contains("encoding audio slice") {
                            progressHandler?("🎵 Encoding audio...")
                        } else if line.contains("audio slice encoded") {
                            if let timeMatch = line.range(of: "[0-9]+ ms", options: .regularExpression) {
                                let time = String(line[timeMatch])
                                progressHandler?("✅ Audio encoded in \(time)")
                            } else {
                                progressHandler?("✅ Audio encoded")
                            }
                        } else if line.contains("decoding audio batch") {
                            progressHandler?("🔤 Generating transcript...")
                        } else if line.contains("audio decoded") {
                            if let timeMatch = line.range(of: "[0-9]+ ms", options: .regularExpression) {
                                let time = String(line[timeMatch])
                                progressHandler?("✅ Transcript generated in \(time)")
                            } else {
                                progressHandler?("✅ Transcript generated")
                            }
                        } else {
                            progressHandler?(line)
                        }
                    }
                    lastProgressTime = Date()
                }
            }
        }
        
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            errorData.append(data)
            
            // Log error messages immediately
            if let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty {
                let lines = chunk.components(separatedBy: .newlines)
                for line in lines where !line.isEmpty {
                    self.logger.warning("Process stderr: \(line)")
                }
            }
        }
        
        do {
            // Run process
            logger.info("Starting transcription process...")
            progressHandler?("Starting transcription...")
            try process.run()
            ChildProcessReaper.shared.track(process, label: "llama-mtmd")

            // Wait for completion with timeout
            let startTime = Date()
            var isCompleted = false
            
            while process.isRunning {
                // Check timeout
                if Date().timeIntervalSince(startTime) > timeout {
                    logger.error("Transcription timeout after \(timeout) seconds — terminating")
                    process.terminate()
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s grace
                    if process.isRunning {
                        logger.error("[ProcessRunner] still alive after SIGTERM — SIGKILL pid \(process.processIdentifier)")
                        kill(process.processIdentifier, SIGKILL)   // Metal-wedged llama ignores SIGTERM
                    }
                    throw TranscriptionError.processFailed("Transcription timeout - file may be too long")
                }
                
                // Check if we're stuck (no progress for 30 seconds)
                if Date().timeIntervalSince(lastProgressTime) > 30 {
                    let elapsedTime = Int(Date().timeIntervalSince(startTime))
                    let minutes = elapsedTime / 60
                    let seconds = elapsedTime % 60
                    logger.warning("[ProcessRunner] No progress for 30s - elapsed: \(minutes)m \(seconds)s")
                    progressHandler?("Processing... (\(minutes)m \(seconds)s elapsed) - this may take a while for long audio files")
                    lastProgressTime = Date()
                    
                    // Log current output/error state
                    logger.debug("[ProcessRunner] Current output size: \(outputData.count) bytes")
                    logger.debug("[ProcessRunner] Current error size: \(errorData.count) bytes")
                }
                
                // Small delay to prevent busy waiting. Cancellation-safe: if a higher-priority GPU
                // consumer preempts us, the sleep throws — reap the child so it can't orphan at
                // 0% CPU still holding the GPU.
                do {
                    try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
                } catch {
                    logger.error("[ProcessRunner] cancelled — terminating llama child")
                    process.terminate()
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    throw TranscriptionError.processFailed("Transcription cancelled")
                }
            }
            
            // Clean up handlers
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            
            // Read any remaining data
            outputData.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
            errorData.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
            
            let terminationStatus = process.terminationStatus
            logger.debug("Process exited with status: \(terminationStatus)")
            
            // Warn about excessive output
            if outputExceeded {
                logger.warning("Final output size: \(outputData.count) bytes - truncating to prevent memory issues")
                // Truncate to reasonable size for processing
                if outputData.count > maxOutputSize {
                    outputData = outputData.prefix(maxOutputSize)
                }
            }
            
            // Convert data to strings
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            
            // Parse the output using the new parser
            let parseResult = outputParser.parse(
                stdout: output,
                stderr: errorOutput,
                exitCode: terminationStatus
            )

            // A projector the binary can't load (e.g. mmproj newer than the bundled llama.cpp)
            // fails on EVERY run after a full model load — latch it so audio features can turn
            // themselves off instead of retrying span by span.
            if parseResult.error != nil {
                LlamaAudioHealthMonitor.shared.recordIfProjectorFailure(
                    stdout: output, stderr: errorOutput,
                    binaryPath: llamaMtmdPath, mmprojPath: mmprojPath)
            }
            
            // Metal OOM (the 2026-06-10 panic trigger) gets a typed error so the background
            // queues requeue (not fail) their job, and the memory gate opens its cooldown.
            // A clean exit ends any OOM streak.
            if terminationStatus != 0, BackgroundGPUAdmission.isMetalOOM(errorOutput) {
                SystemMemoryGate.shared.reportMetalOOM(source: "llama-mtmd-cli")
                throw TranscriptionError.gpuOutOfMemory("llama-mtmd-cli exit \(terminationStatus)")
            }
            if terminationStatus == 0 {
                SystemMemoryGate.shared.reportGPUJobSuccess()
            }

            // Log any warnings
            for warning in parseResult.warnings {
                logger.warning("Process warning: \(warning)")
            }
            
            // Log processing info if available
            if let modelTime = parseResult.processingInfo.modelLoadTime {
                logger.debug("Model loaded in \(String(format: "%.2f", modelTime)) seconds")
            }
            if let tokens = parseResult.processingInfo.tokensGenerated {
                logger.debug("Generated \(tokens) tokens")
            }
            
            // Raw mode: the caller parses a structured reply (e.g. the verifier's JSON verdict)
            // itself. The transcript-shaped checks below would mangle it — extractTranscript drops
            // bare JSON lines as "debug output" — so only REAL process failures throw here.
            if returnRawOutput {
                if terminationStatus != 0, let error = parseResult.error {
                    throw mapParsedError(error)
                }
                return output
            }

            // Check for errors
            if let error = parseResult.error {
                throw mapParsedError(error)
            }
            
            // Check if we have a valid transcript
            guard let transcript = parseResult.transcript, !transcript.isEmpty else {
                logger.warning("No transcript generated")
                throw TranscriptionError.processFailed("No transcription output - the audio may be silent or corrupted")
            }
            
            logger.info("Transcription completed successfully")
            return transcript
            
        } catch let error as TranscriptionError {
            throw error
        } catch {
            logger.error("Failed to run transcription: \(error.localizedDescription)")
            throw TranscriptionError.processFailed(error.localizedDescription)
        }
    }
    
    /// Map the parser's structured error to the thrown TranscriptionError (logging the detail,
    /// which the thrown case doesn't always carry).
    private func mapParsedError(_ error: LlamaCppOutputParser.ParsedError) -> TranscriptionError {
        switch error.type {
        case .fileNotFound:
            logger.error("File not found: \(error.details ?? error.message)")
            return TranscriptionError.invalidURL
        case .modelError:
            logger.error("Model error: \(error.message)")
            return TranscriptionError.modelNotFound
        case .memoryError:
            let message = error.details ?? "Insufficient memory to process audio"
            logger.error("Memory error: \(message)")
            return TranscriptionError.processFailed(message)
        case .audioFormatError:
            let message = error.details ?? "Unsupported audio format"
            logger.error("Audio format error: \(message)")
            return TranscriptionError.processFailed(message)
        case .processTimeout:
            let message = "Processing timeout - file may be too long"
            logger.error(message)
            return TranscriptionError.processFailed(message)
        case .unknown:
            let message = error.details ?? error.message
            logger.error("Unknown error: \(message)")
            return TranscriptionError.processFailed(message)
        }
    }

    /// Cancel the current transcription process
    func cancelTranscription() {
        if let process = currentProcess, process.isRunning {
            logger.info("Cancelling transcription process")
            process.terminate()                                   // SIGTERM
            currentProcess = nil
            let pid = process.processIdentifier
            // Escalate to SIGKILL if a Metal-wedged child ignores SIGTERM (else it orphans, still
            // holding the GPU — same class as the whisper 62-min orphan).
            Task.detached {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }
    
    /// Install llama.cpp using Homebrew
    func installLlamaCpp() async throws {
        logger.info("Attempting to install llama.cpp via Homebrew")
        
        // Check for Homebrew
        let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        var brewPath: String?
        
        for path in brewPaths {
            if FileManager.default.fileExists(atPath: path) {
                brewPath = path
                break
            }
        }
        
        guard let brew = brewPath else {
            logger.error("Homebrew not found")
            throw TranscriptionError.homebrewNotFound
        }
        
        // Install llama.cpp
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["install", "llama.cpp"]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
            logger.info("Running: \(brew) install llama.cpp")
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                logger.error("Installation failed: \(errorString)")
                throw TranscriptionError.installationFailed
            }
            
            logger.info("Successfully installed llama.cpp")
            
            // Update path
            self.llamaMtmdPath = Self.findLlamaMtmdCli()
            
        } catch {
            logger.error("Failed to install llama.cpp: \(error.localizedDescription)")
            throw TranscriptionError.installationFailed
        }
    }
}