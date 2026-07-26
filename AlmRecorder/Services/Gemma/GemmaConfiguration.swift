import Foundation

/// Central configuration for the Gemma 4 LLM engine.
///
/// Gemma 4 (Google, 2026) is an encoder-free multimodal model. For transcription it runs through the
/// SAME `llama-mtmd-cli --audio --mmproj` path as Voxtral, but with a non-greedy sampler + `--jinja`
/// chat template, a BF16-only mmproj (the audio Conformer is precision-sensitive), and <=30s audio
/// chunks. The same GGUF weights also serve as a general text LLM (see LLMTextService) — no extra
/// download. Weights: https://huggingface.co/unsloth/gemma-4-12b-it-GGUF and .../gemma-4-E4B-it-GGUF
struct GemmaConfiguration {

    // MARK: - Model catalog

    /// Available Gemma models. Keys are `<size>-<quant>`. Each 12B/E4B family shares one BF16 mmproj;
    /// the two families' projectors are different files, so they get distinct LOCAL names even though
    /// both repos publish `mmproj-BF16.gguf`.
    static let models: [String: LLMModelConfig] = [
        "12B-Q4_K_M": LLMModelConfig(
            name: "Gemma 4 12B Q4_K_M",
            modelFile: "gemma-4-12b-it-Q4_K_M.gguf",
            mmprojFile: "mmproj-gemma-4-12b-it-BF16.gguf",
            modelURL: "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/gemma-4-12b-it-Q4_K_M.gguf",
            mmprojURL: "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/mmproj-BF16.gguf",
            sizeGB: 7.12
        ),
        "12B-Q5_K_M": LLMModelConfig(
            name: "Gemma 4 12B Q5_K_M",
            modelFile: "gemma-4-12b-it-Q5_K_M.gguf",
            mmprojFile: "mmproj-gemma-4-12b-it-BF16.gguf",
            modelURL: "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/gemma-4-12b-it-Q5_K_M.gguf",
            mmprojURL: "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/mmproj-BF16.gguf",
            sizeGB: 8.41
        ),
        "12B-Q8_0": LLMModelConfig(
            name: "Gemma 4 12B Q8_0 (8-bit)",
            modelFile: "gemma-4-12b-it-Q8_0.gguf",
            mmprojFile: "mmproj-gemma-4-12b-it-BF16.gguf",
            modelURL: "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/gemma-4-12b-it-Q8_0.gguf",
            mmprojURL: "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/mmproj-BF16.gguf",
            sizeGB: 12.67
        ),
        "E4B-Q4_K_M": LLMModelConfig(
            name: "Gemma 4 E4B Q4_K_M (light)",
            modelFile: "gemma-4-E4B-it-Q4_K_M.gguf",
            mmprojFile: "mmproj-gemma-4-E4B-it-BF16.gguf",
            modelURL: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_K_M.gguf",
            mmprojURL: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/mmproj-BF16.gguf",
            sizeGB: 2.7
        ),
        "E4B-Q8_0": LLMModelConfig(
            name: "Gemma 4 E4B Q8_0 (light, 8-bit)",
            modelFile: "gemma-4-E4B-it-Q8_0.gguf",
            mmprojFile: "mmproj-gemma-4-E4B-it-BF16.gguf",
            modelURL: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q8_0.gguf",
            mmprojURL: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/mmproj-BF16.gguf",
            sizeGB: 4.5
        ),
    ]

    /// Default model used for transcription and text generation.
    static let defaultModel = "12B-Q5_K_M"

    // MARK: - Paths

    static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AlmRecorder/GemmaModels")
    }

    // MARK: - Audio settings

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
        let defaultPrompt = "Transcribe this audio exactly. Output only the transcription, with no comments, notes, or formatting."
        let gpuLayers = "99"
        let temperature = "1.0"
        let topK = "64"
        let topP = "0.95"
        let maxTokens = "15000"

        private func sanitized(_ prompt: String?) -> String {
            let p = (prompt ?? defaultPrompt)
            return p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Transcribe this audio exactly." : p
        }

        func buildArguments(modelPath: String, mmprojPath: String, audioPath: String, contextPrompt: String?) -> [String] {
            return [
                "-m", modelPath,
                "--mmproj", mmprojPath,
                "--audio", audioPath,
                "-p", sanitized(contextPrompt),
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
                "-p", sanitized(runSettings.prompt),
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

    // MARK: - Text-generation parameters (llama-cli, no audio/mmproj)

    /// Sampling for text tasks (summaries/topics/tags). Lower temperature than transcription for
    /// faithful, low-variance output.
    struct TextParameters {
        let temperature = "0.4"
        let topP = "0.95"
        let topK = "64"
        let maxTokens = "1024"
        let gpuLayers = "99"
    }

    static let textParameters = TextParameters()

    // MARK: - Transcript cleaning

    /// Gemma chat/control tokens to strip from raw transcription output.
    static let systemTokensToRemove = [
        "<start_of_turn>",
        "<end_of_turn>",
        "<eos>",
        "<bos>",
        "<pad>",
        "[BLANK_AUDIO]",
        "[INAUDIBLE]",
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
