import Foundation

/// A single downloadable LLM model: the main GGUF plus its audio multimodal projector (mmproj).
///
/// Model catalog record shared with Voxtral and Gemma. Text-only Gemma tasks need only the main
/// GGUF; audio-grounded consensus additionally requires the matching projector.
struct LLMModelConfig {
    let name: String
    let modelFile: String
    let mmprojFile: String
    let modelURL: String
    let mmprojURL: String
    let sizeGB: Double
    let mmprojSizeGB: Double
}

/// Builds the `llama-mtmd-cli` argument list for an audio transcription engine (currently Voxtral).
protocol LLMTranscriptionParameters {
    /// Default sampling for this engine, with an optional context-aware prompt.
    func buildArguments(modelPath: String, mmprojPath: String, audioPath: String, contextPrompt: String?) -> [String]
    /// Caller-supplied sampling (e.g. from the Prompt Lab / run settings UI).
    func buildArguments(modelPath: String, mmprojPath: String, audioPath: String, runSettings: RunSettings) -> [String]
}
