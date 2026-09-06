import Foundation

/// Central configuration for Gemma 4 text generation and audio-grounded nightly consensus.
///
/// Ordinary summaries and insights still use `LLMTextService`. The nightly quality pass uses the
/// current llama.cpp server multimodal API with a selected audio-capable model and its projector.
struct GemmaConfiguration {

    #if false
    // DEFERRED: Gemma audio-ASR prompt. No live code may invoke it.
    /// Canonical Gemma 4 ASR instruction published by Google. Keep one source of truth so direct
    /// Gemma transcription and the nightly blind benchmark cannot silently drift apart.
    static func canonicalASRPrompt(language: String?) -> String {
        let value = language?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalized = value.lowercased()
        let firstLine: String
        if value.isEmpty
            || normalized == "auto"
            || normalized == "auto-detected"
            || normalized == "unknown" {
            firstLine = "Transcribe the following speech segment in its original language."
        } else {
            firstLine = "Transcribe the following speech segment in \(value) into \(value) text."
        }
        return """
        \(firstLine)

        Follow these specific instructions for formatting the answer:
        * Only output the transcription, with no newlines.
        * When transcribing numbers, write the digits, i.e. write 1.7 and not one point seven, and write 3 instead of three.
        """
    }
    #endif

    // MARK: - Model catalog

    /// Available Gemma GGUFs. Audio-consensus entries download and validate their matching mmproj;
    /// every entry remains usable as a text-only summary/insight model.
    static let models: [String: LLMModelConfig] = [
        "12B-Q4_K_M": LLMModelConfig(
            name: "Gemma 4 12B Q4_K_M",
            modelFile: "gemma-4-12b-it-Q4_K_M.gguf",
            mmprojFile: "mmproj-gemma-4-12b-it-BF16.gguf",
            modelURL: "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/fc034cfff751157913579611efad8462ac1be606/gemma-4-12b-it-Q4_K_M.gguf",
            mmprojURL: "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/fc034cfff751157913579611efad8462ac1be606/mmproj-BF16.gguf",
            sizeGB: 7.12,
            mmprojSizeGB: 0.175
        ),
        "12B-Q5_K_M": LLMModelConfig(
            name: "Gemma 4 12B Q5_K_M",
            modelFile: "gemma-4-12b-it-Q5_K_M.gguf",
            mmprojFile: "mmproj-gemma-4-12b-it-BF16.gguf",
            modelURL: "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/fc034cfff751157913579611efad8462ac1be606/gemma-4-12b-it-Q5_K_M.gguf",
            mmprojURL: "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/fc034cfff751157913579611efad8462ac1be606/mmproj-BF16.gguf",
            sizeGB: 8.41,
            mmprojSizeGB: 0.175
        ),
        "12B-Q8_0": LLMModelConfig(
            name: "Gemma 4 12B Q8_0 (8-bit)",
            modelFile: "gemma-4-12b-it-Q8_0.gguf",
            mmprojFile: "mmproj-gemma-4-12b-it-BF16.gguf",
            modelURL: "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/fc034cfff751157913579611efad8462ac1be606/gemma-4-12b-it-Q8_0.gguf",
            mmprojURL: "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/fc034cfff751157913579611efad8462ac1be606/mmproj-BF16.gguf",
            sizeGB: 12.67,
            mmprojSizeGB: 0.175
        ),
        "E4B-Q4_K_M": LLMModelConfig(
            name: "Gemma 4 E4B Q4_K_M (audio consensus)",
            modelFile: "gemma-4-E4B-it-Q4_K_M.gguf",
            mmprojFile: "mmproj-gemma-4-E4B-it-F16.gguf",
            modelURL: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/bfc15c382204943c3a8fff0c750b94ae2364d7a3/gemma-4-E4B-it-Q4_K_M.gguf",
            mmprojURL: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/bfc15c382204943c3a8fff0c750b94ae2364d7a3/mmproj-gemma-4-E4B-it-F16.gguf",
            sizeGB: 5.95,
            mmprojSizeGB: 0.990
        ),
        "E4B-Q8_0": LLMModelConfig(
            name: "Gemma 4 E4B Q8_0 (light, 8-bit)",
            modelFile: "gemma-4-E4B-it-Q8_0.gguf",
            mmprojFile: "mmproj-gemma-4-E4B-it-BF16.gguf",
            modelURL: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/bfc15c382204943c3a8fff0c750b94ae2364d7a3/gemma-4-E4B-it-Q8_0.gguf",
            mmprojURL: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/bfc15c382204943c3a8fff0c750b94ae2364d7a3/mmproj-BF16.gguf",
            sizeGB: 4.5,
            mmprojSizeGB: 0.175
        ),
    ]

    /// Default text-generation model.
    static let defaultModel = "12B-Q5_K_M"
    /// Maximum-quality default for audio-grounded consensus. Admission remains conservative: a
    /// 24 GB Mac may run 12B only when enough live headroom exists.
    static let defaultAudioModel = "12B-Q5_K_M"
    static let safeAudioModel = "E4B-Q4_K_M"
    static let audioConsensusModelKeys = [
        "12B-Q5_K_M",
        "12B-Q4_K_M",
        "E4B-Q4_K_M"
    ]

    static func isAudioConsensusModel(_ key: String) -> Bool {
        audioConsensusModelKeys.contains(key)
    }

    static func validatedAudioModelKey(_ key: String?) -> String {
        guard let key, isAudioConsensusModel(key) else { return defaultAudioModel }
        return key
    }

    static let audioSampleRate: Double = 16_000
    static let audioChannels = 1
    /// Gemma 4 documents a maximum of 30 seconds per audio item. Leave room for edge padding.
    static let maximumAudioClipDuration: TimeInterval = 29
    static let targetAudioClipDuration: TimeInterval = 24
    static let maximumAudioClipsPerRequest = 3

    // MARK: - Paths

    static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AlmRecorder/GemmaModels")
    }

    #if false
    // MARK: - DEFERRED audio settings and transcription parameters

    static let audioSampleRate: Double = 16000
    static let audioChannels: Int = 1

    /// Gemma 4 accepts at most ~30s of audio per inference, so chunk well under that. (Voxtral runs
    /// ~60s chunks via the default VADConfiguration.)
    static let vadConfiguration = VADConfiguration(
        minChunkDuration: 8,
        maxChunkDuration: 28,
        targetChunkDuration: 24
    )

    /// Below this duration Gemma transcribes the file in one shot; above it we VAD-split.
    static let singleShotMaxDuration: TimeInterval = 28

    // MARK: - Transcription parameters

    /// Gemma audio transcription args for `llama-mtmd-cli`. Differs from Voxtral: non-greedy sampler
    /// (`--temp 1.0 --top-k 64 --top-p 0.95`) and `--jinja` for the Gemma chat template.
    struct ProcessParameters: LLMTranscriptionParameters {
        let defaultPrompt = GemmaConfiguration.canonicalASRPrompt(language: nil)
        let gpuLayers = "99"
        let temperature = "1.0"
        let topK = "64"
        let topP = "0.95"
        let maxTokens = "512"
        /// llama.cpp replaces this marker with the loaded audio embeddings. Supplying it ourselves
        /// prevents mtmd-cli's generic single-turn fallback from prepending audio before the text.
        private let trailingAudioMarker = "<__media__>"

        private func sanitized(_ prompt: String?) -> String {
            let p = (prompt ?? defaultPrompt)
            return p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? GemmaConfiguration.canonicalASRPrompt(language: nil)
                : p
        }

        func buildArguments(modelPath: String, mmprojPath: String, audioPath: String, contextPrompt: String?) -> [String] {
            return [
                "-m", modelPath,
                "--mmproj", mmprojPath,
                "--audio", audioPath,
                "-p", sanitized(contextPrompt) + trailingAudioMarker,
                "-ngl", gpuLayers,
                "--temp", temperature,
                "--top-k", topK,
                "--top-p", topP,
                "-n", maxTokens,
                "--jinja",
            ]
        }

        func buildArguments(modelPath: String, mmprojPath: String, audioPath: String, runSettings: RunSettings) -> [String] {
            var args = [
                "-m", modelPath,
                "--mmproj", mmprojPath,
                "--audio", audioPath,
                "-p", sanitized(runSettings.prompt) + trailingAudioMarker,
                "-ngl", String(runSettings.gpuLayers),
                "--temp", String(runSettings.temperature),
                "--top-k", String(runSettings.topK),
                "-n", String(runSettings.maxTokens),
                "--jinja",
            ]
            if let topP = runSettings.topP {
                args.append(contentsOf: ["--top-p", String(topP)])
            }
            if let seed = runSettings.seed {
                args.append(contentsOf: ["--seed", String(seed)])
            }
            return args
        }
    }

    static let processParameters = ProcessParameters()
    #endif

    // MARK: - Text-generation parameters (llama-cli, no audio/mmproj)

    /// Sampling for text tasks (summaries/topics/tags/consensus).
    struct TextParameters {
        let temperature = "0.4"
        let topP = "0.95"
        let topK = "64"
        let maxTokens = "1024"
        let gpuLayers = "99"
    }

    static let textParameters = TextParameters()

    // MARK: - Transcript cleaning

    /// Gemma chat/control tokens to strip from raw text output.
    static let systemTokensToRemove = [
        "<start_of_turn>",
        "<end_of_turn>",
        "<eos>",
        "<bos>",
        "<pad>",
        "[BLANK_AUDIO]",
        "[INAUDIBLE]",
        "[end of text]",
    ]

    /// Gemma 4 under `--jinja` (llama.cpp ≥ b9493 templates) prefixes replies with a reasoning
    /// block — `<|channel>thought … <channel|>answer`. The block must go BEFORE any content
    /// parsing: it can contain a draft of the transcript or of the JSON verdict that disagrees
    /// with the final answer. Keeps only what follows the last closing marker; an unclosed block
    /// (generation cut off mid-thought) keeps the text before it, which is usually empty and
    /// correctly reads as "no output".
    static func stripThoughtChannel(_ text: String) -> String {
        // The answer always follows the LAST close marker — checked first and independently of the
        // opening marker, because upstream line filtering can swallow the opening line.
        if let close = text.range(of: "<channel|>", options: .backwards) {
            return String(text[close.upperBound...])
        }
        if let open = text.range(of: "<|channel>") {
            return String(text[..<open.lowerBound])
        }
        return text
    }
}
