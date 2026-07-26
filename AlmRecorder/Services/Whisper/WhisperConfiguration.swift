import Foundation

/// Configuration for Whisper models and processing
enum WhisperConfiguration {
    
    // MARK: - Model Types (Legacy - kept for compatibility)
    
    enum ModelType: String, CaseIterable {
        case kblab = "KBLab Swedish"
        case openai = "OpenAI Whisper"
        
        var description: String {
            switch self {
            case .kblab:
                return "Optimized for Swedish language"
            case .openai:
                return "General multilingual support"
            }
        }
    }
    
    // MARK: - Model Configuration (Legacy - kept for compatibility)
    
    struct ModelConfig {
        let key: String
        let name: String
        let type: ModelType
        let size: String
        let language: String?
        let modelFile: String
        let downloadURL: String
        let fileSize: Int64 // in bytes
        let description: String
        
        /// Convert legacy ModelConfig to new WhisperModelVariant
        var toVariant: WhisperModelVariant? {
            let family: WhisperModelFamily = type == .kblab ? .kblab : .openai
            
            guard let modelSize = WhisperModelSize(rawValue: size) else { return nil }
            
            // Detect version from key
            let version: WhisperModelVersion
            if key.contains("v3") {
                version = .v3
            } else if key.contains("v2") {
                version = .v2
            } else {
                version = .v1
            }
            
            // All legacy models are q5_0
            let quantization = WhisperQuantization.q5_0
            
            return WhisperModelVariant(
                family: family,
                size: modelSize,
                version: version,
                quantization: quantization
            )
        }
    }
    
    // MARK: - Available Models (Legacy - for backward compatibility)
    
    static let models: [String: ModelConfig] = [
        // KBLab Swedish Models
        "kb-whisper-large": ModelConfig(
            key: "kb-whisper-large",
            name: "KB Whisper Large",
            type: .kblab,
            size: "large",
            language: "sv",
            modelFile: "kb-whisper-large-q5_0.bin",
            downloadURL: "https://huggingface.co/KBLab/kb-whisper-large/resolve/main/ggml-model-q5_0.bin",
            fileSize: 1_073_741_824, // ~1GB
            description: "Best accuracy for Swedish, 47% better than OpenAI large-v3"
        ),
        "kb-whisper-medium": ModelConfig(
            key: "kb-whisper-medium",
            name: "KB Whisper Medium",
            type: .kblab,
            size: "medium",
            language: "sv",
            modelFile: "kb-whisper-medium-q5_0.bin",
            downloadURL: "https://huggingface.co/KBLab/kb-whisper-medium/resolve/main/ggml-model-q5_0.bin",
            fileSize: 536_870_912, // ~512MB
            description: "Balanced speed and accuracy for Swedish"
        ),
        "kb-whisper-small": ModelConfig(
            key: "kb-whisper-small",
            name: "KB Whisper Small",
            type: .kblab,
            size: "small",
            language: "sv",
            modelFile: "kb-whisper-small-q5_0.bin",
            downloadURL: "https://huggingface.co/KBLab/kb-whisper-small/resolve/main/ggml-model-q5_0.bin",
            fileSize: 268_435_456, // ~256MB
            description: "Fast Swedish transcription, still beats OpenAI large-v3"
        ),
        
        // OpenAI Whisper Models
        "whisper-large-v3": ModelConfig(
            key: String("whisper-large-v3"), // gitleaks:allow -- public model identifier.
            name: "Whisper Large v3",
            type: .openai,
            size: "large",
            language: nil,
            modelFile: "ggml-large-v3-q5_0.bin",
            downloadURL: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin",
            fileSize: 1_073_741_824, // ~1GB
            description: "Best multilingual accuracy, supports 99+ languages"
        ),
        "whisper-medium": ModelConfig(
            key: "whisper-medium",
            name: "Whisper Medium",
            type: .openai,
            size: "medium",
            language: nil,
            modelFile: "ggml-medium-q5_0.bin",
            downloadURL: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium-q5_0.bin",
            fileSize: 536_870_912, // ~512MB
            description: "Balanced multilingual transcription"
        ),
        "whisper-base": ModelConfig(
            key: "whisper-base",
            name: "Whisper Base",
            type: .openai,
            size: "base",
            language: nil,
            modelFile: "ggml-base-q5_0.bin",
            downloadURL: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_0.bin",
            fileSize: 134_217_728, // ~128MB
            description: "Fast multilingual transcription"
        ),
        "whisper-tiny": ModelConfig(
            key: "whisper-tiny",
            name: "Whisper Tiny",
            type: .openai,
            size: "tiny",
            language: nil,
            modelFile: "ggml-tiny-q5_0.bin",
            downloadURL: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny-q5_0.bin",
            fileSize: 67_108_864, // ~64MB
            description: "Ultra-fast basic transcription"
        )
    ]
    
    // MARK: - New Model System
    
    /// Get all available model variants
    static func availableVariants() -> [WhisperModelVariant] {
        return WhisperModelVariant.availableVariants()
    }
    
    /// Get recommended variant for a language
    static func recommendedVariant(for language: String?, profile: WhisperPerformanceProfile = .balanced) -> WhisperModelVariant {
        return WhisperModelRecommendation.recommend(for: language, prioritize: profile)
    }
    
    // MARK: - Defaults
    
    static let defaultSwedishModel = "kb-whisper-small"
    static let defaultGeneralModel = "whisper-base"
    
    /// Default variant using new system
    static var defaultVariant: WhisperModelVariant {
        WhisperModelVariant(
            family: .openai,
            size: .base,
            version: .v3,
            quantization: .q5_0
        )
    }
    
    static var defaultSwedishVariant: WhisperModelVariant {
        WhisperModelVariant(
            family: .kblab,
            size: .small,
            version: .v1,
            quantization: .q5_0
        )
    }
    
    // MARK: - Paths
    
    static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AlmRecorder/WhisperModels")
    }
    
    static func modelPath(for type: ModelType) -> URL {
        switch type {
        case .kblab:
            return modelsDirectory.appendingPathComponent("kblab")
        case .openai:
            return modelsDirectory.appendingPathComponent("openai")
        }
    }
    
    // MARK: - Whisper CLI Path
    
    static var whisperCLIPath: String {
        // First check if it's in the app bundle Resources/Binaries
        if let bundlePath = Bundle.main.path(forResource: "whisper-cli", ofType: nil, inDirectory: "Binaries") {
            print("[WhisperConfiguration] Using bundled whisper-cli: \(bundlePath)")
            return bundlePath
        }
        
        // Check in Resources directly
        if let bundlePath = Bundle.main.path(forResource: "whisper-cli", ofType: nil) {
            print("[WhisperConfiguration] Using bundled whisper-cli: \(bundlePath)")
            return bundlePath
        }
        
        // Development path - check the built binary first
        let buildPath = "\(DevPaths.whisperBuild)/bin/whisper-cli"
        if FileManager.default.fileExists(atPath: buildPath) {
            print("[WhisperConfiguration] Using development whisper-cli: \(buildPath)")
            return buildPath
        }
        
        // Check in AlmRecorder/Resources/Binaries for development
        let resourcePath = "\(DevPaths.resourcesBinaries)/whisper-cli"
        if FileManager.default.fileExists(atPath: resourcePath) {
            print("[WhisperConfiguration] Using resource whisper-cli: \(resourcePath)")
            return resourcePath
        }
        
        // Fallback to system path
        print("[WhisperConfiguration] Warning: Using fallback whisper-cli path: /usr/local/bin/whisper-cli")
        return "/usr/local/bin/whisper-cli"
    }
    
    // MARK: - Process Parameters
    
    struct ProcessParameters {
        let threads: Int = 4
        let processors: Int = 1
        let outputFormat: String = "txt"
        let language: String? = "auto" // explicitly force auto-detection to prevent translation
        
        func buildArguments(
            modelPath: String,
            audioPath: String,
            language: String? = nil,
            enableDiarization: Bool = false,
            wordTimestamps: Bool = false,
            prompt: String? = nil,
            jsonOutputBase: String? = nil
        ) -> [String] {
            var args = [
                "-m", modelPath,
                "-f", audioPath,
                "-t", String(threads),
                "-p", String(processors),
            ]

            // `-of` is the output-file BASENAME (today's "-of txt" is a harmless no-op since no
            // output format flag is ever set). With a base path we also pass -ojf so whisper-cli
            // writes a full-JSON sidecar (per-token probabilities) next to it; stdout is unchanged.
            if let jsonOutputBase {
                args.append(contentsOf: ["-of", jsonOutputBase, "-ojf"])
            } else {
                args.append(contentsOf: ["-of", outputFormat])
            }

            // Disable carrying decoded text across windows (`--max-context 0`). Whisper's default of
            // conditioning on previously-decoded text makes it loop on silence/non-speech ("ready to work
            // ready to work …"); zeroing the text context is the standard whisper.cpp fix for runaway
            // repetition. The per-chunk `--prompt` below still seeds punctuation/casing.
            args.append(contentsOf: ["-mc", "0"])

            // ALWAYS add language parameter to prevent unwanted translation
            // Use "auto" for auto-detection without translation
            let effectiveLanguage = language ?? self.language ?? "auto"
            args.append(contentsOf: ["-l", effectiveLanguage])
            
            // Enable tinydiarize for speaker segmentation
            if enableDiarization {
                args.append("-tdrz")
            }
            
            // Enable word-level timestamps
            if wordTimestamps {
                args.append(contentsOf: ["-ml", "1"])
            } else {
                args.append("--no-timestamps")
            }
            
            // Add prompt for context continuity
            if let prompt = prompt, !prompt.isEmpty {
                // Whisper uses the prompt to maintain context between segments
                // This helps with proper punctuation, casing, and context understanding
                args.append(contentsOf: ["--prompt", prompt])
            }
            
            return args
        }
    }
    
    static let processParameters = ProcessParameters()
    
    // MARK: - Language Detection
    
    static func detectLanguage(from audioPath: String) async -> String? {
        // Use tiny model for fast language detection
        // This would run whisper with --detect-language flag
        // For now, return nil to use auto-detection
        return nil
    }
    
    // MARK: - Model Selection
    
    static func selectModel(for language: String?) -> String {
        if let lang = language {
            if lang == "sv" || lang == "swedish" {
                return defaultSwedishModel
            }
        }
        return defaultGeneralModel
    }
}
