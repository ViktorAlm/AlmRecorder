import Foundation

/// Structured insights generated for a recording in a single LLM call.
struct RecordingInsights {
    let title: String
    let summary: String
    let topics: [String]
    let tags: [TagSuggestion]
}

/// A tag the model suggests: a short name plus (for newly-coined tags) a one-line description.
struct TagSuggestion: Decodable {
    let name: String
    let description: String?

    init(name: String, description: String? = nil) {
        self.name = name
        self.description = description
    }

    /// Tolerant decode: accepts {"name": "...", "description": "..."} OR a bare "name" string.
    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self), let n = try? c.decode(String.self, forKey: .name) {
            name = n
            description = try? c.decode(String.self, forKey: .description)
        } else {
            let s = try decoder.singleValueContainer()
            name = try s.decode(String.self)
            description = nil
        }
    }

    private enum CodingKeys: String, CodingKey { case name, description }
}

/// Runs the selected Gemma model as a general text LLM (text prompt in → generated text out) via a
/// one-shot `llama-completion` invocation — no audio, no mmproj. Reuses the same GGUF weights downloaded for
/// transcription. Modeled on EmbeddingService's process-runner + dylib-isolation pattern.
///
/// Voxtral is intentionally NOT used here: it is a 3B audio-specialized model and a poor text LLM.
/// Text features default to Gemma (`GlobalModelSettings.selectedTextLLMModel`).
class LLMTextService {
    static let shared = LLMTextService()

    private let logger = VoxtralLogger.shared
    private let modelManager = GemmaModelManager()
    private let binaryPath: String?
    private let queue = DispatchQueue(label: "com.almrecorder.llmtext", qos: .userInitiated)
    private var currentProcess: Process?

    /// Hard cap on transcript characters fed to the model so a long recording can't overflow context.
    private let maxTranscriptChars = 12_000
    private let contextLength = 16384 // room for the transcript + the full existing-tag vocabulary
    private let timeoutSeconds: TimeInterval = 240

    private init() {
        self.binaryPath = LlamaRuntime.findBinary(named: "llama-completion")
        if let p = binaryPath {
            logger.info("[LLMText] Using llama-completion: \(p)")
        } else {
            logger.warning("[LLMText] llama-completion not found — text generation unavailable")
        }
    }

    /// True when both a llama-completion binary and the selected Gemma text model are present.
    var isAvailable: Bool {
        guard let binaryPath = binaryPath, FileManager.default.fileExists(atPath: binaryPath) else { return false }
        return modelManager.isModelDownloaded(GlobalModelSettings.shared.selectedTextLLMModel)
    }

    // MARK: - Public API

    /// Run the selected Gemma model on a text prompt and return the cleaned completion.
    func generateText(prompt: String, modelKey: String? = nil, maxTokens: Int? = nil) async throws -> String {
        let key = modelKey ?? GlobalModelSettings.shared.selectedTextLLMModel
        guard let modelPath = modelManager.getModelPath(for: key) else {
            logger.error("[LLMText] Text model not downloaded: \(key)")
            throw TranscriptionError.modelNotFound
        }
        guard let binaryPath = binaryPath, FileManager.default.fileExists(atPath: binaryPath) else {
            logger.error("[LLMText] llama-completion not found")
            throw TranscriptionError.llamaCppNotFound
        }
        return try await runProcess(binaryPath: binaryPath, modelPath: modelPath.path, prompt: prompt, maxTokens: maxTokens)
    }

    /// Summary + topics + tags for a transcript in one model load. Falls back to a keyword heuristic
    /// if the model is unavailable or its output can't be parsed.
    func generateRecordingInsights(transcript: String, knownTags: [String] = []) async throws -> RecordingInsights {
        let clipped = String(transcript.prefix(maxTranscriptChars))
        let prompt = Self.insightsPrompt(transcript: clipped, knownTags: knownTags)
        let raw = try await generateText(prompt: prompt)
        if let parsed = Self.parseInsights(from: raw) {
            return parsed
        }
        logger.warning("[LLMText] Could not parse insights JSON; falling back to heuristic summary")
        return Self.heuristicInsights(from: transcript)
    }

    func cancel() {
        guard let process = currentProcess else { return }
        currentProcess = nil
        process.terminate()                                   // SIGTERM
        let pid = process.processIdentifier
        // A Metal-wedged Gemma child ignores SIGTERM — escalate to SIGKILL so it can't keep
        // holding the GPU (the LLM-path version of the whisper 62-min-orphan bug).
        Task.detached {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    // MARK: - Prompt + parsing

    static func insightsPrompt(transcript: String, knownTags: [String] = []) -> String {
        // Inject the FULL existing tag vocabulary so the model reuses tags instead of inventing
        // near-duplicates. A capped list would be worse than none: any tag outside the cap gets
        // re-created as a variant, so the long tail grows forever.
        let tagGuidance: String
        if knownTags.isEmpty {
            tagGuidance = ""
        } else {
            tagGuidance = "\n\nExisting tags — REUSE the exact name whenever one applies; do NOT invent a near-duplicate (a plural, different casing/hyphenation, or reworded version of one below). Only add a brand-new tag for a concept none of these cover:\n\(knownTags.joined(separator: ", "))"
        }
        return """
        You analyze meeting and voice-note transcripts. Read the transcript and reply with a SINGLE JSON object and nothing else, in exactly this shape:
        {"title": "<3-8 word title>", "summary": "<2-4 sentence summary>", "topics": ["<topic>", ...], "tags": [{"name": "<short keyword>", "description": "<one-line meaning of the tag>"}]}
        The title is a concise human-readable name for the recording (no file extension, no surrounding quotes). Use at most 5 topics and 6 short tags. For an existing tag reuse its exact name (you may omit description); for a NEW tag include a short description of what it means. Do not output any text outside the JSON.\(tagGuidance)

        Transcript:
        \"\"\"
        \(transcript)
        \"\"\"
        """
    }

    /// Extract the first balanced `{...}` block and decode it. Tolerant of leading/trailing prose.
    static func parseInsights(from output: String) -> RecordingInsights? {
        guard let start = output.firstIndex(of: "{") else { return nil }
        var depth = 0
        var end: String.Index?
        var idx = start
        while idx < output.endIndex {
            let c = output[idx]
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { end = idx; break }
            }
            idx = output.index(after: idx)
        }
        guard let endIdx = end else { return nil }
        let jsonString = String(output[start...endIdx])
        guard let data = jsonString.data(using: .utf8) else { return nil }

        struct Raw: Decodable {
            let title: String?
            let summary: String?
            let topics: [String]?
            let tags: [TagSuggestion]?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        let summary = (raw.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return nil }
        return RecordingInsights(
            title: (raw.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            summary: summary,
            topics: (raw.topics ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            tags: (raw.tags ?? []).compactMap { sug in
                let n = sug.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !n.isEmpty else { return nil }
                let d = sug.description?.trimmingCharacters(in: .whitespacesAndNewlines)
                return TagSuggestion(name: n, description: (d?.isEmpty == false) ? d : nil)
            }
        )
    }

    /// Cheap fallback: first few sentences as a summary, no topics/tags. Used only when the LLM is
    /// unavailable so auto-generation degrades gracefully instead of failing.
    static func heuristicInsights(from transcript: String) -> RecordingInsights {
        let sentences = transcript
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 10 }
        let summary = sentences.prefix(3).joined(separator: ". ")
        let trimmed = String(summary.prefix(300))
        let firstWords = (sentences.first ?? "").split(separator: " ").prefix(6).joined(separator: " ")
        return RecordingInsights(title: firstWords, summary: trimmed.isEmpty ? "(No summary available)" : trimmed, topics: [], tags: [])
    }

    // MARK: - Process

    private func runProcess(binaryPath: String, modelPath: String, prompt: String, maxTokens: Int?) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: TranscriptionError.processFailed("Service deallocated"))
                    return
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: binaryPath)
                process.arguments = [
                    "-m", modelPath,
                    "-p", prompt,
                    "--jinja",
                    "-no-cnv",                 // completion mode (no interactive chat loop)
                    "--no-display-prompt",     // don't echo the prompt back into stdout
                    "-ngl", GemmaConfiguration.textParameters.gpuLayers,
                    "--temp", GemmaConfiguration.textParameters.temperature,
                    "--top-p", GemmaConfiguration.textParameters.topP,
                    "--top-k", GemmaConfiguration.textParameters.topK,
                    "-n", String(maxTokens ?? Int(GemmaConfiguration.textParameters.maxTokens) ?? 1024),
                    "-c", "\(self.contextLength)",
                    "--no-warmup",
                ]

                // Resolve the matching ggml/llama dylibs for a bundled binary.
                LlamaRuntime.applyLibraryPath(to: process, binaryPath: binaryPath)

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                defer {
                    if process.isRunning {
                        process.terminate()
                        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
                        if process.isRunning { process.interrupt() }
                    }
                }

                do {
                    self.logger.info("[LLMText] Running llama-completion (\(process.arguments?.count ?? 0) args), model=\(URL(fileURLWithPath: modelPath).lastPathComponent)")
                    try process.run()
                    self.currentProcess = process

                    let deadline = Date().addingTimeInterval(self.timeoutSeconds)
                    while process.isRunning && Date() < deadline {
                        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
                    }
                    if process.isRunning {
                        self.logger.error("[LLMText] Timeout after \(self.timeoutSeconds)s — terminating")
                        process.terminate()
                        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
                        if process.isRunning { process.interrupt() }
                        self.currentProcess = nil
                        continuation.resume(throwing: TranscriptionError.processFailed("Text generation timeout"))
                        return
                    }
                    self.currentProcess = nil

                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrString = String(data: errorData, encoding: .utf8) ?? ""

                    if process.terminationStatus != 0 {
                        self.logger.error("[LLMText] Exit \(process.terminationStatus): \(String(stderrString.suffix(300)))")
                        // Metal OOM (the 2026-06-10 panic trigger) gets a typed error so queues
                        // requeue instead of fail, and the memory gate opens its cooldown.
                        if BackgroundGPUAdmission.isMetalOOM(stderrString) {
                            SystemMemoryGate.shared.reportMetalOOM(source: "llama-completion")
                            continuation.resume(throwing: TranscriptionError.gpuOutOfMemory("llama-completion exit \(process.terminationStatus)"))
                        } else {
                            continuation.resume(throwing: TranscriptionError.processFailed("llama-completion exit \(process.terminationStatus)"))
                        }
                        return
                    }

                    SystemMemoryGate.shared.reportGPUJobSuccess()
                    let output = String(data: outputData, encoding: .utf8) ?? ""
                    continuation.resume(returning: self.cleanOutput(output, prompt: prompt))
                } catch {
                    self.currentProcess = nil
                    self.logger.error("[LLMText] Process failed: \(error.localizedDescription)")
                    continuation.resume(throwing: TranscriptionError.processFailed(error.localizedDescription))
                }
            }
        }
    }

    /// Strip Gemma control tokens and any echoed prompt fragment from the raw stdout.
    private func cleanOutput(_ output: String, prompt: String) -> String {
        var cleaned = output
        for token in GemmaConfiguration.systemTokensToRemove {
            cleaned = cleaned.replacingOccurrences(of: token, with: "")
        }
        // llama-completion may echo the prompt before the completion; drop everything up to its end.
        if let range = cleaned.range(of: prompt) {
            cleaned = String(cleaned[range.upperBound...])
        }
        // A reasoning block can hold a draft of the JSON the callers parse — keep only the answer.
        cleaned = GemmaConfiguration.stripThoughtChannel(cleaned)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
