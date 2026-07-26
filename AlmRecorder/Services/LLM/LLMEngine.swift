import Foundation

/// A single downloadable LLM model: the main GGUF plus its audio multimodal projector (mmproj).
///
/// Shared by every llama.cpp-backed transcription engine (Voxtral, Gemma). `modelFile`/`mmprojFile`
/// are the LOCAL filenames on disk (which may differ from the URL basename so that two engines'
/// identically-named projectors — both repos ship `mmproj-BF16.gguf` — don't collide in one folder).
struct LLMModelConfig {
    let name: String
    let modelFile: String
    let mmprojFile: String
    let modelURL: String
    let mmprojURL: String
    let sizeGB: Double
}

/// Builds the `llama-mtmd-cli` argument list for one engine. Voxtral and Gemma both shell out to the
/// same multimodal binary but with different sampling/flags (Gemma needs `--jinja` and a non-greedy
/// sampler), so the argument construction is the per-engine seam injected into `LlamaCppProcessRunner`.
protocol LLMTranscriptionParameters {
    /// Default sampling for this engine, with an optional context-aware prompt.
    func buildArguments(modelPath: String, mmprojPath: String, audioPath: String, contextPrompt: String?) -> [String]
    /// Caller-supplied sampling (e.g. from the Prompt Lab / run settings UI).
    func buildArguments(modelPath: String, mmprojPath: String, audioPath: String, runSettings: RunSettings) -> [String]
}
