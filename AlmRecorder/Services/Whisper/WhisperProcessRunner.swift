import Foundation

private struct WhisperProcessOutput {
    let text: String
    let detectedLanguage: String?
    let detectedLanguageConfidence: Float?
}

/// Handles execution of whisper-cli process
final class WhisperProcessRunner: @unchecked Sendable {
    
    private let currentProcessState = LockedValue<Process?>(nil)
    private var currentProcess: Process? {
        get { currentProcessState.snapshot }
        set { currentProcessState.withValue { $0 = newValue } }
    }
    private let whisperPath: String
    private let logger = VoxtralLogger.shared
    
    /// Check if whisper-cli is available
    var isWhisperAvailable: Bool {
        FileManager.default.fileExists(atPath: whisperPath)
    }
    
    init() {
        self.whisperPath = WhisperConfiguration.whisperCLIPath
        logger.info("[WhisperProcessRunner] Using whisper-cli at: \(self.whisperPath)")
    }
    
    /// Run transcription process
    /// - Parameters:
    ///   - modelPath: Path to the Whisper model file
    ///   - audioPath: Path to the audio file (must be 16kHz WAV)
    ///   - language: Optional language code (e.g., "sv", "en")
    ///   - enableDiarization: Enable speaker diarization with tinydiarize
    ///   - wordTimestamps: Enable word-level timestamps
    ///   - prompt: Optional prompt text for context continuity
    ///   - progressHandler: Optional handler for progress updates
    /// - Returns: Transcription text
    func runTranscription(
        modelPath: String,
        audioPath: String,
        language: String? = nil,
        enableDiarization: Bool = false,
        wordTimestamps: Bool = false,
        prompt: String? = nil,
        progressHandler: ((String) -> Void)? = nil
    ) async throws -> String {
        let result = try await runTranscriptionCore(
            modelPath: modelPath,
            audioPath: audioPath,
            language: language,
            enableDiarization: enableDiarization,
            wordTimestamps: wordTimestamps,
            prompt: prompt,
            jsonOutputBase: nil,
            progressHandler: progressHandler
        )
        return result.text
    }

    /// Like `runTranscription`, but also captures whisper's per-token probabilities via a
    /// `-ojf` JSON sidecar file. The sidecar is best-effort: if it is missing or unparseable,
    /// `tokenStats` is nil and the transcription still succeeds (stdout is unaffected).
    func runTranscriptionDetailed(
        modelPath: String,
        audioPath: String,
        language: String? = nil,
        enableDiarization: Bool = false,
        wordTimestamps: Bool = false,
        prompt: String? = nil,
        progressHandler: ((String) -> Void)? = nil
    ) async throws -> WhisperDetailedTranscription {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper_json_\(UUID().uuidString)").path
        let sidecarPath = base + ".json"
        defer { try? FileManager.default.removeItem(atPath: sidecarPath) }

        let coreResult = try await runTranscriptionCore(
            modelPath: modelPath,
            audioPath: audioPath,
            language: language,
            enableDiarization: enableDiarization,
            wordTimestamps: wordTimestamps,
            prompt: prompt,
            jsonOutputBase: base,
            progressHandler: progressHandler
        )

        var tokenStats: WhisperTokenStats? = nil
        var timedSegments: [WhisperTimedSegment] = []
        var sidecarLanguage: String?
        if let sidecarData = FileManager.default.contents(atPath: sidecarPath) {
            tokenStats = WhisperJSONParser.parseStats(sidecarData)
            timedSegments = WhisperJSONParser.parseTimedSegments(sidecarData) ?? []
            sidecarLanguage = WhisperJSONParser.parseDetectedLanguage(sidecarData)
            if tokenStats == nil {
                logger.warning("[WhisperProcessRunner] JSON sidecar present but yielded no token stats (\(sidecarData.count) bytes)")
            }
        } else {
            logger.warning("[WhisperProcessRunner] JSON sidecar missing at \(sidecarPath) — proceeding without token stats")
        }
        return WhisperDetailedTranscription(
            text: coreResult.text,
            tokenStats: tokenStats,
            timedSegments: timedSegments,
            detectedLanguage: sidecarLanguage ?? coreResult.detectedLanguage,
            detectedLanguageConfidence: coreResult.detectedLanguageConfidence
        )
    }

    private func runTranscriptionCore(
        modelPath: String,
        audioPath: String,
        language: String?,
        enableDiarization: Bool,
        wordTimestamps: Bool,
        prompt: String?,
        jsonOutputBase: String?,
        progressHandler: ((String) -> Void)?
    ) async throws -> WhisperProcessOutput {

        // Validate paths
        guard FileManager.default.fileExists(atPath: whisperPath) else {
            logger.error("[WhisperProcessRunner] ERROR: whisper-cli not found at: \(whisperPath)")
            progressHandler?("Error: Whisper CLI not found. Please reinstall the app.")
            throw TranscriptionError.whisperNotFound
        }
        
        guard FileManager.default.fileExists(atPath: modelPath) else {
            logger.error("[WhisperProcessRunner] ERROR: Model file not found: \(modelPath)")
            progressHandler?("Error: Model not found. Please download a model first.")
            throw TranscriptionError.modelNotFound
        }
        
        guard FileManager.default.fileExists(atPath: audioPath) else {
            logger.error("[WhisperProcessRunner] ERROR: Audio file not found: \(audioPath)")
            progressHandler?("Error: Audio file not found.")
            throw TranscriptionError.invalidURL
        }
        
        // Check if whisper-cli is executable
        if !FileManager.default.isExecutableFile(atPath: whisperPath) {
            logger.warning("[WhisperProcessRunner] WARNING: whisper-cli is not executable, attempting to fix...")
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: whisperPath)
        }
        
        // Build arguments
        let arguments = WhisperConfiguration.processParameters.buildArguments(
            modelPath: modelPath,
            audioPath: audioPath,
            language: language,
            enableDiarization: enableDiarization,
            wordTimestamps: wordTimestamps,
            prompt: prompt,
            jsonOutputBase: jsonOutputBase
        )

        // Log the language parameter being used
        let effectiveLanguage = language ?? "auto"
        logger.info("[WhisperProcessRunner] Language parameter: \(effectiveLanguage) (input: \(language ?? "nil"))")
        
        // Log comprehensive command information for debugging
        logger.info("[WhisperProcessRunner] === TRANSCRIPTION COMMAND START ===")
        logger.info("[WhisperProcessRunner] Executable: \(self.whisperPath)")
        logger.info("[WhisperProcessRunner] Arguments: \(arguments.joined(separator: " "))")
        logger.info("[WhisperProcessRunner] Model path: \(modelPath) (exists: \(FileManager.default.fileExists(atPath: modelPath)))")
        logger.info("[WhisperProcessRunner] Audio path: \(audioPath) (exists: \(FileManager.default.fileExists(atPath: audioPath)))")
        
        // Log file sizes for diagnostics
        if let audioAttrs = try? FileManager.default.attributesOfItem(atPath: audioPath),
           let audioSize = audioAttrs[.size] as? Int64 {
            logger.info("[WhisperProcessRunner] Audio file size: \(audioSize) bytes (\(audioSize / 1024)KB)")
        }
        if let modelAttrs = try? FileManager.default.attributesOfItem(atPath: modelPath),
           let modelSize = modelAttrs[.size] as? Int64 {
            logger.info("[WhisperProcessRunner] Model file size: \(modelSize / 1024 / 1024)MB")
        }
        logger.info("[WhisperProcessRunner] === TRANSCRIPTION COMMAND END ===")
        
        // Create process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = arguments
        
        // Set up environment to find dynamic libraries
        var environment = ProcessInfo.processInfo.environment
        
        // Get path to bundled libraries
        let libraryPaths: [String]
        if let bundleResourcePath = Bundle.main.resourcePath {
            // Production: Use bundled libraries
            let bundledLibPath = "\(bundleResourcePath)/Libraries"
            libraryPaths = [bundledLibPath]
        } else {
            // Development: Use both bundled and build paths
            let bundledLibPath = DevPaths.resourcesLibraries
            let buildPaths = [
                "\(DevPaths.whisperBuild)/src",
                "\(DevPaths.whisperBuild)/ggml/src",
                "\(DevPaths.whisperBuild)/ggml/src/ggml-metal",
                "\(DevPaths.whisperBuild)/ggml/src/ggml-blas"
            ]
            libraryPaths = [bundledLibPath] + buildPaths
        }
        
        // Set DYLD_LIBRARY_PATH
        let dyldPath = libraryPaths.joined(separator: ":")
        environment["DYLD_LIBRARY_PATH"] = dyldPath
        process.environment = environment
        
        logger.info("[WhisperProcessRunner] DYLD_LIBRARY_PATH: \(dyldPath)")
        
        // Verify libraries exist
        let missingLibs = libraryPaths.filter { !FileManager.default.fileExists(atPath: $0) }
        if !missingLibs.isEmpty {
            logger.warning("[WhisperProcessRunner] Missing library paths: \(missingLibs.joined(separator: ", "))")
        }
        
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
        let outputBuffer = LockedValue(Data())
        let errorBuffer = LockedValue(Data())
        
        // Set up handlers to read output as it comes
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            outputBuffer.withValue { $0.append(data) }
        }
        
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            errorBuffer.withValue { $0.append(data) }
            
            // Parse progress from stderr
            if let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty {
                // Whisper outputs progress to stderr
                // Look for patterns like "[00:00.000 --> 00:05.000]"
                if chunk.contains("-->") || chunk.contains("%") || chunk.contains("Processing") {
                    progressHandler?(chunk.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
        
        // Set up cleanup for after process completion (moved out of defer)
        // defer blocks with RunLoop can interfere with process execution
        
        do {
            // Run process
            logger.info("[WhisperProcessRunner] Starting transcription process...")
            progressHandler?("Starting transcription...")
            
            // Verify process can start
            guard FileManager.default.isExecutableFile(atPath: whisperPath) else {
                logger.error("[WhisperProcessRunner] whisper-cli is not executable")
                throw TranscriptionError.whisperNotFound
            }
            
            try process.run()
            logger.info("[WhisperProcessRunner] Process started successfully, PID: \(process.processIdentifier)")

            ChildProcessReaper.shared.track(process, label: "whisper")
            try await awaitWhisperExitOrReap(process, audioPath: audioPath, label: "transcription")

            // Read any remaining data
            outputBuffer.withValue {
                $0.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
            }
            errorBuffer.withValue {
                $0.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
            }
            
            let terminationStatus = process.terminationStatus
            logger.info("[WhisperProcessRunner] Process exited with status: \(terminationStatus)")
            
            // Convert output to string
            let output = String(data: outputBuffer.snapshot, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorBuffer.snapshot, encoding: .utf8) ?? ""
            
            // Log output for debugging
            if !output.isEmpty {
                logger.debug("[WhisperProcessRunner] Output (first 500 chars): \(String(output.prefix(500)))")
            } else {
                logger.warning("[WhisperProcessRunner] No output received from whisper-cli")
            }
            
            if !errorOutput.isEmpty {
                logger.info("[WhisperProcessRunner] Error output: \(errorOutput)")
            }
            
            // Check for errors
            if terminationStatus != 0 {
                // Feed the shared Metal-OOM cooldown so background queues back off too. Transcription
                // itself stays exempt from the gate (user-initiated), but its OOMs are the loudest
                // signal that the GPU is starved.
                if BackgroundGPUAdmission.isMetalOOM(errorOutput) {
                    SystemMemoryGate.shared.reportMetalOOM(source: "whisper-cli")
                }
                logger.error("[WhisperProcessRunner] === TRANSCRIPTION FAILED ===")
                logger.error("[WhisperProcessRunner] Exit code: \(terminationStatus)")
                logger.error("[WhisperProcessRunner] Command: \(self.whisperPath) \(arguments.joined(separator: " "))")
                logger.error("[WhisperProcessRunner] Model: \(modelPath)")
                logger.error("[WhisperProcessRunner] Audio: \(audioPath)")
                logger.error("[WhisperProcessRunner] Error output (first 2000 chars): \(String(errorOutput.prefix(2000)))")
                logger.error("[WhisperProcessRunner] Stdout (first 1000 chars): \(String(output.prefix(1000)))")
                logger.error("[WhisperProcessRunner] DYLD_LIBRARY_PATH was: \(environment["DYLD_LIBRARY_PATH"] ?? "not set")")
                logger.error("[WhisperProcessRunner] === END TRANSCRIPTION FAILED ===")
                
                if errorOutput.contains("Failed to load model") {
                    throw TranscriptionError.modelNotFound
                } else if errorOutput.contains("Failed to open file") {
                    throw TranscriptionError.invalidURL
                } else {
                    throw TranscriptionError.processFailed(errorOutput.isEmpty ? "Process failed with code \(terminationStatus)" : errorOutput)
                }
            }
            
            // Clean the transcript
            let transcript = cleanTranscript(output)
            
            if transcript.isEmpty {
                logger.error("[WhisperProcessRunner] === EMPTY TRANSCRIPT ===")
                logger.error("[WhisperProcessRunner] Raw output length: \(output.count) chars")
                logger.error("[WhisperProcessRunner] Raw output (first 500 chars): \(String(output.prefix(500)))")
                logger.error("[WhisperProcessRunner] Error output: \(errorOutput)")
                logger.error("[WhisperProcessRunner] Command was: \(self.whisperPath) \(arguments.joined(separator: " "))")
                logger.error("[WhisperProcessRunner] Model: \(modelPath)")
                logger.error("[WhisperProcessRunner] Audio: \(audioPath)")
                logger.error("[WhisperProcessRunner] === END EMPTY TRANSCRIPT ===")
                throw TranscriptionError.processFailed("No transcription output generated")
            }
            
            logger.info("[WhisperProcessRunner] Transcription completed successfully, transcript length: \(transcript.count) chars")
            
            // Cleanup after successful completion
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            currentProcess = nil
            
            let languageDetection = WhisperJSONParser.parseDetectedLanguageLog(errorOutput)
            return WhisperProcessOutput(
                text: transcript,
                detectedLanguage: languageDetection?.code,
                detectedLanguageConfidence: languageDetection?.confidence
            )
            
        } catch let error as TranscriptionError {
            // Cleanup after process completion
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            currentProcess = nil
            throw error
        } catch {
            logger.error("[WhisperProcessRunner] === UNEXPECTED ERROR ===")
            logger.error("[WhisperProcessRunner] Error: \(error)")
            logger.error("[WhisperProcessRunner] Error type: \(type(of: error))")
            logger.error("[WhisperProcessRunner] Command was: \(self.whisperPath) \(arguments.joined(separator: " "))")
            logger.error("[WhisperProcessRunner] Model: \(modelPath)")
            logger.error("[WhisperProcessRunner] Audio: \(audioPath)")
            logger.error("[WhisperProcessRunner] === END UNEXPECTED ERROR ===")
            // Cleanup after process completion
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            currentProcess = nil
            throw TranscriptionError.processFailed(error.localizedDescription)
        }
    }
    
    /// Run transcription with JSON output for structured data
    /// - Parameters:
    ///   - modelPath: Path to the Whisper model file
    ///   - audioPath: Path to the audio file (must be 16kHz WAV)
    ///   - language: Optional language code
    ///   - enableDiarization: Enable speaker diarization with tinydiarize
    ///   - wordTimestamps: Enable word-level timestamps
    ///   - prompt: Optional prompt text for context continuity
    /// - Returns: Tuple of text transcript and optional JSON data
    func runTranscriptionWithJSON(
        modelPath: String,
        audioPath: String,
        language: String? = nil,
        enableDiarization: Bool = false,
        wordTimestamps: Bool = false,
        prompt: String? = nil
    ) async throws -> (text: String, json: Data?) {
        
        // Validate paths
        guard FileManager.default.fileExists(atPath: whisperPath) else {
            throw TranscriptionError.whisperNotFound
        }
        
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw TranscriptionError.modelNotFound
        }
        
        guard FileManager.default.fileExists(atPath: audioPath) else {
            throw TranscriptionError.invalidURL
        }
        
        // Build arguments with JSON output
        var arguments = WhisperConfiguration.processParameters.buildArguments(
            modelPath: modelPath,
            audioPath: audioPath,
            language: language,
            enableDiarization: enableDiarization,
            wordTimestamps: wordTimestamps,
            prompt: prompt
        )
        
        // For diarization, use text output to get proper speaker segments
        // For other cases, use JSON for structured data
        if !enableDiarization {
            if let ofIndex = arguments.firstIndex(of: "-of") {
                arguments[ofIndex + 1] = "json"
            }
        }
        
        let outputFormat = enableDiarization ? "text" : "JSON"
        logger.info("[WhisperProcessRunner] Running with \(outputFormat) output: \(arguments.joined(separator: " "))")
        
        // Create process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = arguments
        
        // Set up environment to find dynamic libraries (same as above)
        var environment = ProcessInfo.processInfo.environment
        let libraryPaths: [String]
        if let bundleResourcePath = Bundle.main.resourcePath {
            let bundledLibPath = "\(bundleResourcePath)/Libraries"
            libraryPaths = [bundledLibPath]
        } else {
            let bundledLibPath = DevPaths.resourcesLibraries
            let buildPaths = [
                "\(DevPaths.whisperBuild)/src",
                "\(DevPaths.whisperBuild)/ggml/src",
                "\(DevPaths.whisperBuild)/ggml/src/ggml-metal",
                "\(DevPaths.whisperBuild)/ggml/src/ggml-blas"
            ]
            libraryPaths = [bundledLibPath] + buildPaths
        }
        environment["DYLD_LIBRARY_PATH"] = libraryPaths.joined(separator: ":")
        process.environment = environment
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        currentProcess = process
        defer { currentProcess = nil; ChildProcessReaper.shared.untrack(process) }

        // Run process
        do {
            logger.info("[WhisperProcessRunner] Starting JSON transcription process...")
            try process.run()
            // Was a bare waitUntilExit() with NO timeout — a wedged whisper here blocked forever
            // (the observed 12h orphan). Now bounded + cancellation-safe + SIGKILL, same as the core.
            ChildProcessReaper.shared.track(process, label: "whisper-json")
            try await awaitWhisperExitOrReap(process, audioPath: audioPath, label: "JSON")
            logger.info("[WhisperProcessRunner] JSON process completed with status: \(process.terminationStatus)")
            
            // Read JSON output
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            
            // Try to parse as JSON
            var jsonData: Data? = nil
            var textTranscript = ""
            
            if let jsonString = String(data: outputData, encoding: .utf8) {
                // The output might be JSON
                if jsonString.trimmingCharacters(in: .whitespacesAndNewlines).starts(with: "{") {
                    jsonData = outputData
                    
                    // Try to extract text from JSON
                    if let json = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any],
                       let text = json["text"] as? String {
                        textTranscript = text
                    }
                } else {
                    // Plain text output
                    textTranscript = jsonString
                }
            }
            
            // Also create text file output
            if textTranscript.isEmpty && jsonData == nil {
                // Try running again with text output
                if let jsonIndex = arguments.firstIndex(of: "json") {
                    arguments[jsonIndex] = "txt"
                } else {
                    // If json wasn't in arguments, add txt format
                    arguments.append(contentsOf: ["-of", "txt"])
                }
                let textResult = try await runTranscription(
                    modelPath: modelPath,
                    audioPath: audioPath,
                    language: language,
                    enableDiarization: enableDiarization,
                    wordTimestamps: wordTimestamps,
                    prompt: prompt,
                    progressHandler: nil
                )
                textTranscript = textResult
            }
            
            return (text: textTranscript, json: jsonData)
            
        } catch {
            logger.error("[WhisperProcessRunner] Failed to run with JSON: \(error)")
            currentProcess = nil
            throw TranscriptionError.processFailed(error.localizedDescription)
        }
    }
    
    /// Wait for a whisper child to exit, bounded by an adaptive timeout. Cancellation-safe and
    /// escalates SIGTERM→SIGKILL so a Metal-wedged whisper can never hold the GPU indefinitely —
    /// even if this task was CPU-starved during a system freeze, the loop reaps it once rescheduled
    /// (deadline long passed). Shared by the core and JSON paths.
    private func awaitWhisperExitOrReap(_ process: Process, audioPath: String, label: String) async throws {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioPath)[.size] as? Int64) ?? 0
        let fileSizeMB = fileSize / (1024 * 1024)
        let timeoutSeconds = min(300.0 + Double(fileSizeMB / 10) * 60.0, 1800.0) // 5min + 1min/10MB, cap 30min
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        var cancelledWhileWaiting = false
        do {
            while process.isRunning && Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            }
        } catch {
            cancelledWhileWaiting = true   // task cancelled — still reap below, don't orphan the child
        }

        if process.isRunning {
            let reason = cancelledWhileWaiting ? "cancelled" : "timeout after \(Int(timeoutSeconds))s"
            logger.error("[WhisperProcessRunner] \(label): \(reason) — terminating pid \(process.processIdentifier)")
            process.terminate()                                   // SIGTERM
            try? await Task.sleep(nanoseconds: 1_000_000_000)     // 1s grace
            if process.isRunning {
                logger.error("[WhisperProcessRunner] \(label): still alive after SIGTERM — SIGKILL")
                kill(process.processIdentifier, SIGKILL)
            }
            throw TranscriptionError.processFailed("Transcription \(reason)")
        }
    }

    /// Cancel the current transcription process
    func cancelTranscription() {
        if let process = currentProcess, process.isRunning {
            logger.info("[WhisperProcessRunner] Cancelling transcription process")
            process.terminate()                                   // SIGTERM
            currentProcess = nil
            let pid = process.processIdentifier
            // Escalate to SIGKILL if a Metal-wedged whisper ignores SIGTERM (else it orphans,
            // still holding the GPU).
            Task.detached {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }
    
    /// Clean transcript output
    private func cleanTranscript(_ output: String) -> String {
        var cleaned = output
        
        // Remove timestamps if present (e.g., "[00:00.000 --> 00:05.000]")
        let timestampPattern = "\\[\\d{2}:\\d{2}\\.\\d{3} --> \\d{2}:\\d{2}\\.\\d{3}\\]"
        if let regex = try? NSRegularExpression(pattern: timestampPattern, options: []) {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: NSRange(location: 0, length: cleaned.utf16.count),
                withTemplate: ""
            )
        }
        
        // Remove multiple newlines
        cleaned = cleaned.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        cleaned = cleaned.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        
        // Trim whitespace
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return cleaned
    }
}

// MARK: - TranscriptionError Extension
