import Foundation
import Combine

/// Service for generating embeddings using llama.cpp
final class EmbeddingService: ObservableObject, @unchecked Sendable {
    static let shared = EmbeddingService()
    private let logger = VoxtralLogger.shared
    
    // MARK: - Published Properties
    @Published var isGenerating: Bool = false
    @Published var generationProgress: Double = 0.0
    @Published var currentStatus: String = ""
    
    // MARK: - Private Properties
    private let modelManager = EmbeddingModelManager.shared
    private let embeddingBinaryPath: String
    /// Directory holding the ggml/llama dylibs that MATCH the llama-embedding binary.
    /// Must be kept separate from Whisper's libraries: the two tools are built against
    /// incompatible ggml versions, and loading the wrong libggml-base.dylib makes the
    /// binary abort with "Symbol not found: _ggml_add_id".
    private let embeddingLibraryPath: String?
    private let queue = DispatchQueue(label: "com.almrecorder.embedding", qos: .userInitiated)
    // `currentProcess` is written from the serial `queue` (during a run) and read/cleared from the
    // MainActor (cancelGeneration, now also called by stopProcessing during GPU preemption). Guard
    // it with a lock so those two threads can't race on the Optional (UB) or lost-cancel TOCTOU.
    private let processLock = NSLock()
    private var _currentProcess: Process?
    private var currentProcess: Process? {
        get { processLock.lock(); defer { processLock.unlock() }; return _currentProcess }
        set { processLock.lock(); _currentProcess = newValue; processLock.unlock() }
    }

    // MARK: - Configuration
    private struct Configuration {
        static let maxBatchSize = 32
        // llama.cpp clamps the compute batch to the context size and ASSERTS (aborts) when a
        // prompt has more tokens than the batch. 512 was too small: any long utterance crashed
        // the binary. 2048 fits virtually all utterances; longer ones are truncated below.
        static let contextLength = 2048
        // Hard cap on characters fed to the embedder (~1200 tokens) so a pathologically long
        // utterance can never exceed contextLength and abort the process.
        static let maxInputChars = 3000
        static let nGPULayers = 99 // Use all GPU layers for Metal acceleration
        static let threads = 4
    }
    
    // MARK: - Initialization
    private init() {
        // Get path to llama-embedding binary
        // First check if it's in the app bundle Resources/Binaries
        if let bundlePath = Bundle.main.path(forResource: "llama-embedding", ofType: nil, inDirectory: "Binaries") {
            self.embeddingBinaryPath = bundlePath
            logger.info("[EmbeddingService] Using bundled llama-embedding: \(bundlePath)")
        }
        // Check in Resources directly
        else if let bundlePath = Bundle.main.path(forResource: "llama-embedding", ofType: nil) {
            self.embeddingBinaryPath = bundlePath
            logger.info("[EmbeddingService] Using bundled llama-embedding: \(bundlePath)")
        }
        // Development path - check the source directory
        else {
            let devPath = "\(DevPaths.resourcesBinaries)/llama-embedding"
            if FileManager.default.fileExists(atPath: devPath) {
                self.embeddingBinaryPath = devPath
                logger.info("[EmbeddingService] Using development llama-embedding: \(devPath)")
            } else {
                // Last resort - should not happen in production
                self.embeddingBinaryPath = "/usr/local/bin/llama-embedding"
                logger.warning("[EmbeddingService] Warning: llama-embedding not found in bundle!")
            }
        }

        // Resolve the matching dylib directory for the binary above.
        self.embeddingLibraryPath = Self.resolveEmbeddingLibraryDir()
        if let libPath = embeddingLibraryPath {
            logger.info("[EmbeddingService] llama dylib dir: \(libPath)")
        } else {
            logger.warning("[EmbeddingService] No matching llama dylib dir found - embedding generation may abort with a ggml symbol mismatch")
        }
    }

    /// Locate the directory whose ggml/llama dylibs match the llama-embedding binary.
    /// Order: a llama-specific subdir bundled with the app, then the development build.
    private static func resolveEmbeddingLibraryDir() -> String? {
        let fm = FileManager.default
        func hasLlamaLibs(_ dir: String) -> Bool {
            fm.fileExists(atPath: "\(dir)/libllama.dylib")
                && fm.fileExists(atPath: "\(dir)/libggml-base.dylib")
        }

        var candidates: [String] = []
        if let resourcePath = Bundle.main.resourcePath {
            // Bundled: keep llama's libs in their own subdir so they don't collide
            // with Whisper's ggml in Resources/Libraries.
            candidates.append("\(resourcePath)/Libraries/llama")
        }
        // Development: the binary's own build directory holds a consistent set.
        candidates.append(DevPaths.llamaBuildBin)

        return candidates.first(where: hasLlamaLibs)
    }
    
    // MARK: - Public Methods
    
    /// Generate an embedding for a single text (used for both documents and search queries).
    ///
    /// Note: Qwen3-Embedding supports an asymmetric query instruction prefix, but an A/B test
    /// on this corpus showed it did NOT improve retrieval (results were a wash and it inflated
    /// distances, which would also disturb the search distance thresholds). It is also unsafe
    /// to pass via this binary: a newline in `-p` makes llama-embedding drop everything after
    /// it. So queries are embedded plainly, same as documents.
    func generateEmbedding(for text: String) async throws -> Data {
        guard modelManager.isModelLoaded,
              let modelPath = modelManager.getModelPath(for: modelManager.currentModel) else {
            logger.error("[EmbeddingService] Model not loaded or path not found | current=\(self.modelManager.currentModel)")
            throw EmbeddingError.modelNotDownloaded
        }

        // Collapse newlines to spaces (a newline in `-p` truncates the prompt for this binary),
        // quote-replace for argument safety, and cap length so a long input cannot exceed the
        // model context and abort the process.
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\n", with: " ")
        let cleanedText = String(normalized.prefix(Configuration.maxInputChars))
        guard !cleanedText.isEmpty else {
            throw EmbeddingError.embeddingGenerationFailed("Empty text")
        }

        await MainActor.run {
            isGenerating = true
            currentStatus = "Generating embedding..."
        }
        defer {
            Task { @MainActor in
                isGenerating = false
                currentStatus = ""
            }
        }

        let startTime = Date()
        let embedding = try await runEmbeddingProcess(modelPath: modelPath.path, text: cleanedText)
        logger.info("[EmbeddingService] Embedding generated in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s | dims=\(embedding.count)")
        return floatArrayToData(embedding)
    }
    
    /// Generate embeddings for multiple texts (batch processing)
    /// Generate embeddings for several texts. Returns one element per input text,
    /// in order, with `nil` for any text that failed. Callers MUST skip the nils:
    /// never persist a placeholder/zero vector, or it poisons semantic search and
    /// makes the utterance look embedded when it is not.
    func generateEmbeddings(for texts: [String]) async throws -> [Data?] {
        guard modelManager.isModelLoaded,
              modelManager.getModelPath(for: modelManager.currentModel) != nil else {
            throw EmbeddingError.modelNotDownloaded
        }

        var embeddings: [Data?] = []
        let totalTexts = texts.count
        
        await MainActor.run {
            isGenerating = true
            generationProgress = 0.0
            currentStatus = "Processing \(totalTexts) texts..."
        }
        
        defer {
            Task { @MainActor in
                isGenerating = false
                generationProgress = 0.0
                currentStatus = ""
            }
        }
        
        // Run serially because each invocation uses the shared llama process slot and GPU.
        for (index, text) in texts.enumerated() {
            let progress = Double(index) / Double(totalTexts)
            await MainActor.run {
                generationProgress = progress
                currentStatus = "Processing \(index + 1) of \(totalTexts)..."
            }
            
            do {
                let embedding = try await generateEmbedding(for: text)
                embeddings.append(embedding)
            } catch {
                // Metal OOM is systemic — propagate so the queue requeues the whole job instead
                // of burying it as a per-utterance nil and grinding on into a starved GPU.
                if case TranscriptionError.gpuOutOfMemory = error { throw error }
                logger.error("[EmbeddingService] Failed to generate embedding for text \(index): \(error)")
                logger.error("[EmbeddingService] Failed input length: \(text.count) chars")
                // Signal failure with nil - do NOT store a placeholder vector.
                embeddings.append(nil)
            }
        }
        
        await MainActor.run {
            generationProgress = 1.0
        }
        
        return embeddings
    }
    
    // MARK: - Private Methods
    
    /// Run the llama-embedding process
    private func runEmbeddingProcess(modelPath: String, text: String) async throws -> [Float] {
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: EmbeddingError.embeddingGenerationFailed("Service deallocated"))
                    return
                }
                
                let process = Process()
                process.executableURL = URL(fileURLWithPath: self.embeddingBinaryPath)

                // Force the binary to load ITS matching ggml/llama dylibs. Without this it
                // falls back to its rpath and can pick up Whisper's incompatible ggml from a
                // shared/inherited DYLD_LIBRARY_PATH, aborting with "Symbol not found: _ggml_add_id".
                if let libPath = self.embeddingLibraryPath {
                    var env = ProcessInfo.processInfo.environment
                    if let existing = env["DYLD_LIBRARY_PATH"], !existing.isEmpty {
                        env["DYLD_LIBRARY_PATH"] = "\(libPath):\(existing)"
                    } else {
                        env["DYLD_LIBRARY_PATH"] = libPath
                    }
                    process.environment = env
                }

                // Ensure process is always cleaned up
                defer {
                    if process.isRunning {
                        logger.debug("[EmbeddingService] Cleaning up process in defer block")
                        process.terminate()
                        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
                        if process.isRunning {
                            process.interrupt() // Force kill
                        }
                    }
                }
                
                // Set arguments
                process.arguments = [
                    "-m", modelPath,
                    "-p", text,
                    "-n", "1", // Generate 1 embedding
                    "-t", "\(Configuration.threads)",
                    "-ngl", "\(Configuration.nGPULayers)", // GPU layers for Metal
                    "-c", "\(Configuration.contextLength)",
                    "--no-warmup", // Skip warmup for single embeddings
                    "--embd-output-format", "array" // Output embeddings as array format
                ]
                
                self.logger.info("[EmbeddingService] === LLAMA-EMBEDDING COMMAND ===")
                self.logger.info("[EmbeddingService] Executable: \(self.embeddingBinaryPath)")
                self.logger.info("[EmbeddingService] Arguments prepared (prompt redacted)")
                self.logger.info("[EmbeddingService] Model exists: \(FileManager.default.fileExists(atPath: modelPath))")
                if let attrs = try? FileManager.default.attributesOfItem(atPath: modelPath) {
                    let sizeMB = (attrs[.size] as? Int64 ?? 0) / 1024 / 1024
                    self.logger.info("[EmbeddingService] Model size: \(sizeMB)MB")
                }
                self.logger.info("[EmbeddingService] Text length: \(text.count) chars")
                
                // Capture output
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe // Capture stderr separately
                
                do {
                    try process.run()
                    self.currentProcess = process
                    
                    // Add timeout - kill process if it takes more than 60 seconds
                    let timeoutSeconds = 60.0
                    let deadline = Date().addingTimeInterval(timeoutSeconds)
                    
                    // Wait for process with timeout
                    while process.isRunning && Date() < deadline {
                        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
                    }
                    
                    // If still running after timeout, terminate it
                    if process.isRunning {
                        self.logger.error("[EmbeddingService] Process timeout - terminating")
                        self.logger.error("[EmbeddingService] Model: \(modelPath)")
                        self.logger.error("[EmbeddingService] Text length: \(text.count)")
                        process.terminate()
                        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5)) // Give it time to terminate
                        if process.isRunning {
                            process.interrupt() // Force kill if needed
                        }
                        self.currentProcess = nil
                        continuation.resume(throwing: EmbeddingError.embeddingGenerationFailed("Process timeout after \(timeoutSeconds) seconds"))
                        return
                    }
                    
                    self.currentProcess = nil
                    
                    // Read stdout output (contains embeddings)
                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()

                    // Read stderr for diagnostics
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrString = String(data: errorData, encoding: .utf8) ?? "(non-UTF-8, \(errorData.count) bytes)"

                    // Check exit code first
                    if process.terminationStatus != 0 {
                        self.logger.error("[EmbeddingService] Process exit code: \(process.terminationStatus)")
                        self.logger.error("[EmbeddingService] stderr: \(stderrString)")
                        // Metal OOM gets a typed error so the queue requeues the job (instead of
                        // failing its utterances) and the memory gate opens its cooldown.
                        if BackgroundGPUAdmission.isMetalOOM(stderrString) {
                            SystemMemoryGate.shared.reportMetalOOM(source: "llama-embedding")
                            continuation.resume(throwing: TranscriptionError.gpuOutOfMemory(
                                "llama-embedding exit \(process.terminationStatus)"
                            ))
                        } else {
                            continuation.resume(throwing: EmbeddingError.embeddingGenerationFailed(
                                "Exit code \(process.terminationStatus): \(String(stderrString.suffix(300)))"
                            ))
                        }
                        return
                    }
                    SystemMemoryGate.shared.reportGPUJobSuccess()

                    guard let output = String(data: outputData, encoding: .utf8) else {
                        self.logger.error("[EmbeddingService] stdout not valid UTF-8 | bytes=\(outputData.count)")
                        self.logger.error("[EmbeddingService] stderr: \(stderrString)")
                        continuation.resume(throwing: EmbeddingError.embeddingGenerationFailed(
                            "Invalid output (\(outputData.count) bytes). stderr: \(String(stderrString.suffix(200)))"
                        ))
                        return
                    }
                    
                    // The output may contain metadata before the embedding array
                    // Look for the actual embedding array which starts with [[
                    let lines = output.components(separatedBy: .newlines)
                    var embeddingLine: String? = nil
                    
                    // Find the line that contains the embedding array
                    for line in lines.reversed() { // Start from end as embedding is usually last
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.hasPrefix("[[") && trimmed.hasSuffix("]]") {
                            embeddingLine = trimmed
                            break
                        }
                    }
                    
                    guard let validEmbeddingLine = embeddingLine else {
                        self.logger.error("[EmbeddingService] === PARSING FAILED ===")
                        self.logger.error("[EmbeddingService] No embedding array found in output")
                        self.logger.error("[EmbeddingService] Output length: \(output.count) chars")
                        self.logger.error("[EmbeddingService] First 500 chars: \(String(output.prefix(500)))")
                        self.logger.error("[EmbeddingService] Last 500 chars: \(String(output.suffix(500)))")
                        self.logger.error("[EmbeddingService] Exit code: \(process.terminationStatus)")
                        continuation.resume(throwing: EmbeddingError.embeddingGenerationFailed("No embedding array found"))
                        return
                    }
                    
                    // Parse embedding from the clean embedding line
                    let embedding = self.parseEmbedding(from: validEmbeddingLine)
                    
                    if embedding.isEmpty {
                        continuation.resume(throwing: EmbeddingError.embeddingGenerationFailed("Failed to parse embedding"))
                    } else {
                        continuation.resume(returning: embedding)
                    }
                    
                } catch {
                    self.currentProcess = nil
                    self.logger.error("[EmbeddingService] === PROCESS FAILED ===")
                    self.logger.error("[EmbeddingService] Error: \(error)")
                    self.logger.error("[EmbeddingService] Error type: \(type(of: error))")
                    self.logger.error("[EmbeddingService] Model path: \(modelPath)")
                    self.logger.error("[EmbeddingService] Binary path: \(self.embeddingBinaryPath)")
                    self.logger.error("[EmbeddingService] Binary exists: \(FileManager.default.fileExists(atPath: self.embeddingBinaryPath))")
                    self.logger.error("[EmbeddingService] Binary executable: \(FileManager.default.isExecutableFile(atPath: self.embeddingBinaryPath))")
                    continuation.resume(throwing: EmbeddingError.embeddingGenerationFailed(error.localizedDescription))
                }
            }
        }
    }
    
    /// Parse embedding vector from llama-embedding output
    private func parseEmbedding(from output: String) -> [Float] {
        var embedding: [Float] = []
        
        // With --embd-output-format array, output is [[float,float,...]]
        // Find the array within [[ and ]]
        if let startRange = output.range(of: "[["),
           let endRange = output.range(of: "]]") {
            let arrayContent = String(output[startRange.upperBound..<endRange.lowerBound])
            
            // Parse comma-separated floats
            let components = arrayContent.components(separatedBy: ",")
                .compactMap { Float($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            
            if !components.isEmpty {
                embedding = components
            }
        } else {
            // Fallback to old parsing method
            let lines = output.components(separatedBy: .newlines)
            
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Skip metadata lines
                if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("llama") {
                    continue
                }
                
                // Try to parse as embedding data
                let components = trimmed.components(separatedBy: .whitespaces)
                    .compactMap { Float($0) }
                
                if !components.isEmpty {
                    embedding.append(contentsOf: components)
                }
            }
        }
        
        // Get expected dimensions from current model
        let expectedDimensions = modelManager.availableModels
            .first(where: { $0.id == modelManager.currentModel })?.dimensions ?? 1024
        
        // Validate dimensions match expected
        if embedding.count == expectedDimensions {
            return embedding
        }
        
        // If we got a different size, log warning
        logger.warning("[EmbeddingService] Dimension mismatch: Got \(embedding.count) dimensions, expected \(expectedDimensions)")
        
        // If larger, truncate; if smaller, pad with zeros
        if embedding.count > expectedDimensions {
            return Array(embedding.prefix(expectedDimensions))
        } else if embedding.count < expectedDimensions && !embedding.isEmpty {
            // Pad with zeros if needed
            var padded = embedding
            padded.append(contentsOf: Array(repeating: 0.0, count: expectedDimensions - embedding.count))
            return padded
        }
        
        return embedding
    }
    
    /// Convert float array to Data for storage
    private func floatArrayToData(_ floats: [Float]) -> Data {
        // Store dimensions in metadata
        EmbeddingDimensionManager.shared.currentDimensions = floats.count
        
        // Convert float array to Data
        var data = Data(capacity: floats.count * MemoryLayout<Float>.size)
        floats.withUnsafeBufferPointer { buffer in
            data.append(buffer)
        }
        return data
    }
    
    /// Convert Data back to float array
    func dataToFloatArray(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        var floats = Array<Float>(repeating: 0, count: count)
        _ = floats.withUnsafeMutableBufferPointer { buffer in
            data.copyBytes(to: buffer)
        }
        return floats
    }
    
    /// Cancel current embedding generation
    func cancelGeneration() {
        let process = currentProcess   // locked snapshot
        currentProcess = nil           // locked clear
        process?.terminate()           // terminate outside the lock

        Task { @MainActor in
            isGenerating = false
            currentStatus = "Cancelled"
        }
    }
    
    /// Test if embedding service is working
    func testEmbedding() async throws -> Bool {
        let testText = "This is a test embedding"
        let embedding = try await generateEmbedding(for: testText)
        
        // Check if we got a valid binary embedding (96 bytes for 768 bits)
        return embedding.count == 96
    }
}
