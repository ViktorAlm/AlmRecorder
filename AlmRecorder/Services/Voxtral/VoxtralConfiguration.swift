import Foundation

/// Configuration for Voxtral models
struct VoxtralModelConfig {
    let name: String
    let modelFile: String
    let mmprojFile: String
    let modelURL: String
    let mmprojURL: String
    let sizeGB: Double
    let mmprojSizeGB: Double
}

/// Central configuration for Voxtral services
struct VoxtralConfiguration {
    
    // MARK: - Model Configurations
    
    /// Available Voxtral models
    static let models: [String: VoxtralModelConfig] = [
        "Q4_K_M": VoxtralModelConfig(
            name: "Voxtral Mini 3B Q4_K_M",
            modelFile: "mistralai_Voxtral-Mini-3B-2507-Q4_K_M.gguf",
            mmprojFile: "mmproj-mistralai_Voxtral-Mini-3B-2507-f16.gguf",
            modelURL: "https://huggingface.co/bartowski/mistralai_Voxtral-Mini-3B-2507-GGUF/resolve/1d0032d997b7f72804d356fc790486e6d697cea5/mistralai_Voxtral-Mini-3B-2507-Q4_K_M.gguf",
            mmprojURL: "https://huggingface.co/bartowski/mistralai_Voxtral-Mini-3B-2507-GGUF/resolve/1d0032d997b7f72804d356fc790486e6d697cea5/mmproj-mistralai_Voxtral-Mini-3B-2507-f16.gguf",
            sizeGB: 2.47,
            mmprojSizeGB: 1.329
        ),
        "Q5_K_M": VoxtralModelConfig(
            name: "Voxtral Mini 3B Q5_K_M", 
            modelFile: "mistralai_Voxtral-Mini-3B-2507-Q5_K_M.gguf",
            mmprojFile: "mmproj-mistralai_Voxtral-Mini-3B-2507-f16.gguf",
            modelURL: "https://huggingface.co/bartowski/mistralai_Voxtral-Mini-3B-2507-GGUF/resolve/1d0032d997b7f72804d356fc790486e6d697cea5/mistralai_Voxtral-Mini-3B-2507-Q5_K_M.gguf",
            mmprojURL: "https://huggingface.co/bartowski/mistralai_Voxtral-Mini-3B-2507-GGUF/resolve/1d0032d997b7f72804d356fc790486e6d697cea5/mmproj-mistralai_Voxtral-Mini-3B-2507-f16.gguf",
            sizeGB: 2.87,
            mmprojSizeGB: 1.329
        ),
        "Q8_0": VoxtralModelConfig(
            name: "Voxtral Mini 3B Q8_0 (8-bit)",
            modelFile: "mistralai_Voxtral-Mini-3B-2507-Q8_0.gguf",
            mmprojFile: "mmproj-mistralai_Voxtral-Mini-3B-2507-f16.gguf",
            modelURL: "https://huggingface.co/bartowski/mistralai_Voxtral-Mini-3B-2507-GGUF/resolve/1d0032d997b7f72804d356fc790486e6d697cea5/mistralai_Voxtral-Mini-3B-2507-Q8_0.gguf",
            mmprojURL: "https://huggingface.co/bartowski/mistralai_Voxtral-Mini-3B-2507-GGUF/resolve/1d0032d997b7f72804d356fc790486e6d697cea5/mmproj-mistralai_Voxtral-Mini-3B-2507-f16.gguf",
            sizeGB: 4.27,
            mmprojSizeGB: 1.329
        ),
        "BF16": VoxtralModelConfig(
            name: "Voxtral Mini 3B BF16 (Full Precision)",
            modelFile: "mistralai_Voxtral-Mini-3B-2507-BF16.gguf",
            mmprojFile: "mmproj-mistralai_Voxtral-Mini-3B-2507-bf16.gguf",
            modelURL: "https://huggingface.co/bartowski/mistralai_Voxtral-Mini-3B-2507-GGUF/resolve/1d0032d997b7f72804d356fc790486e6d697cea5/mistralai_Voxtral-Mini-3B-2507-BF16.gguf",
            mmprojURL: "https://huggingface.co/bartowski/mistralai_Voxtral-Mini-3B-2507-GGUF/resolve/1d0032d997b7f72804d356fc790486e6d697cea5/mmproj-mistralai_Voxtral-Mini-3B-2507-bf16.gguf",
            sizeGB: 8.04,
            mmprojSizeGB: 1.329
        )
    ]
    
    /// Default model to use
    static let defaultModel = "Q5_K_M"
    
    // MARK: - Paths
    
    /// Common paths to search for llama-mtmd-cli
    static let llamaMtmdSearchPaths = [
        "/usr/local/bin/llama-mtmd-cli",
        "/opt/homebrew/bin/llama-mtmd-cli",
        "/usr/bin/llama-mtmd-cli"
    ]
    
    /// Get the models directory path
    static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AlmRecorder/VoxtralModels")
    }
    
    // MARK: - Audio Settings
    
    /// Sample rate for Voxtral (16kHz)
    static let audioSampleRate: Double = 16000
    
    /// Number of audio channels (mono)
    static let audioChannels: Int = 1
    
    // MARK: - Process Parameters
    
    /// Parameters for llama-mtmd-cli
    struct ProcessParameters: LLMTranscriptionParameters {
        let defaultPrompt: String = "Transcribe the following audio verbatim. Output only the transcription without any explanations or notes."
        let gpuLayers: String = "-1"  // Use all GPU layers
        let temperature: String = "0.0"  // Deterministic output
        let topK: String = "1"  // Force most likely token
        let maxTokens: String = "15000"  // Max tokens for long transcriptions
        let contextKeep: String = "512"  // Keep initial context tokens
        
        func buildArguments(modelPath: String, mmprojPath: String, audioPath: String, contextPrompt: String? = nil) -> [String] {
            // Use context-aware prompt if provided, otherwise use default
            var prompt = contextPrompt ?? defaultPrompt
            
            // Handle empty or whitespace-only prompts
            if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Use a minimal transcribe instruction for empty prompts
                prompt = "Transcribe"
                print("⚠️ [VoxtralConfiguration] Empty prompt detected, using minimal default: 'Transcribe'")
            }
            
            return [
                "-m", modelPath,
                "--mmproj", mmprojPath,
                "--audio", audioPath,
                "-p", prompt,
                "-ngl", gpuLayers,
                "--temp", temperature,
                "--top-k", topK,
                "-n", maxTokens,
                "--keep", contextKeep  // Maintain context tokens
                // Removed --log-disable to see actual output
            ]
        }
        
        func buildArguments(modelPath: String, mmprojPath: String, audioPath: String, runSettings: RunSettings) -> [String] {
            // Handle empty or whitespace-only prompts
            var prompt = runSettings.prompt
            if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                prompt = "Transcribe"
                print("⚠️ [VoxtralConfiguration] Empty prompt in RunSettings, using minimal default: 'Transcribe'")
            }
            
            var args = [
                "-m", modelPath,
                "--mmproj", mmprojPath,
                "--audio", audioPath,
                "-p", prompt,
                "-ngl", String(runSettings.gpuLayers),
                "--temp", String(runSettings.temperature),
                "--top-k", String(runSettings.topK),
                "-n", String(runSettings.maxTokens),
                "--keep", String(runSettings.contextKeep)
            ]
            
            // Add optional parameters
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
    
    // MARK: - Test Prompt Configurations
    
    /// Predefined prompts for testing
    struct TestPrompts {
        // HuggingFace reference format
        static let huggingFaceBaseline = "Transcribe"
        static let huggingFaceWithLanguage = "lang:en[TRANSCRIBE]"
        
        // Special tokens
        static let transcribeToken = "[TRANSCRIBE]"
        static let emptyPrompt = ""
        
        // Simple variations
        static let transcribeColon = "Transcribe:"
        static let transcribeVerbatim = "Transcribe verbatim"
        
        // Instruction formats
        static let withInstTags = "[INST]Transcribe[/INST]"
        static let afterInstTag = "[/INST]Transcribe"
        
        // Our current default
        static let currentDefault = "Transcribe the following audio verbatim. Output only the transcription without any explanations or notes."
    }
    
    // MARK: - Transcript Cleaning
    
    /// System tokens to remove from transcripts
    static let systemTokensToRemove = [
        "<|im_start|>",
        "<|im_end|>",
        "</s>",
        "<s>",
        "[BLANK_AUDIO]",
        "[INAUDIBLE]"
    ]
}
