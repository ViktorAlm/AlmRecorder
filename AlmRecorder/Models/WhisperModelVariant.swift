import Foundation

// MARK: - Model Enums

enum WhisperModelFamily: String, CaseIterable, Codable {
    case openai = "OpenAI Whisper"
    case kblab = "KBLab Swedish"
    case distilWhisper = "Distil-Whisper"
    
    var baseURL: String {
        switch self {
        case .openai, .distilWhisper:
            return "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"
        case .kblab:
            return "https://huggingface.co/KBLab/"
        }
    }
    
    var supportsLanguages: [String] {
        switch self {
        case .openai, .distilWhisper:
            return ["auto", "en", "es", "fr", "de", "it", "pt", "ru", "zh", "ja", "ko", "sv"] // 99+ languages
        case .kblab:
            return ["sv", "auto"] // Swedish optimized
        }
    }
}

enum WhisperModelSize: String, CaseIterable, Codable {
    case tiny = "tiny"
    case base = "base"
    case small = "small"
    case medium = "medium"
    case large = "large"
    
    var displayName: String {
        rawValue.capitalized
    }
    
    /// Number of parameters description
    var parameters: String {
        switch self {
        case .tiny: return "39M"
        case .base: return "74M"
        case .small: return "244M"
        case .medium: return "769M"
        case .large: return "1550M"
        }
    }
    
    /// Base size in MB for f16 models
    var baseSizeMB: Int {
        switch self {
        case .tiny: return 39
        case .base: return 148
        case .small: return 488
        case .medium: return 1530
        case .large: return 3100
        }
    }
    
    /// Relative speed (1.0 = baseline)
    var relativeSpeed: Double {
        switch self {
        case .tiny: return 10.0
        case .base: return 5.0
        case .small: return 2.5
        case .medium: return 1.5
        case .large: return 1.0
        }
    }
    
    /// Estimated RAM requirement in MB (includes overhead)
    var estimatedRAMRequirementMB: Int {
        // Whisper.cpp loads model into memory + overhead for inference
        // Typically requires 1.5-2x model size for safe operation
        switch self {
        case .tiny: return 100    // ~39MB model + overhead
        case .base: return 300    // ~148MB model + overhead
        case .small: return 1000  // ~488MB model + overhead
        case .medium: return 3000 // ~1.5GB model + overhead
        case .large: return 6500  // ~3.1GB model + overhead
        }
    }
    
    /// Estimated GPU memory requirement in MB
    var estimatedGPURequirementMB: Int {
        // Metal backend requires GPU memory allocation
        // Large models can exhaust GPU memory on smaller cards
        switch self {
        case .tiny: return 150
        case .base: return 400
        case .small: return 1200
        case .medium: return 3500
        case .large: return 7500  // 7.5GB - often exceeds available GPU memory
        }
    }
}

enum WhisperModelVersion: String, CaseIterable, Codable {
    case v1 = ""
    case v2 = "v2"
    case v3 = "v3"
    case v3turbo = "v3-turbo"
    case tdrz = "tdrz"  // TinyDiarize variant for speaker segmentation
    
    var displayName: String {
        switch self {
        case .v1: return "v1"
        case .v2: return "v2"
        case .v3: return "v3"
        case .v3turbo: return "v3 Turbo"
        case .tdrz: return "TinyDiarize"
        }
    }
    
    var isDefault: Bool {
        self == .v3
    }
    
    var supportsDiarization: Bool {
        self == .tdrz
    }
}

enum WhisperQuantization: String, CaseIterable, Codable {
    case f16 = ""        // 16-bit float (original/default GGML format - no suffix)
    case q8_0 = "q8_0"   // 8-bit quantization
    case q5_0 = "q5_0"   // 5-bit quantization (method 0) - medium/large only
    case q5_1 = "q5_1"   // 5-bit quantization (method 1) - tiny/base/small only
    
    var displayName: String {
        switch self {
        case .f16: return "Full Quality (F16)"
        case .q8_0: return "High Quality (Q8_0)"
        case .q5_0: return "Balanced (Q5_0)"
        case .q5_1: return "Balanced (Q5_1)"
        }
    }
    
    var qualityDescription: String {
        switch self {
        case .f16: return "Original quality, largest size"
        case .q8_0: return "Near-perfect quality, ~45% smaller"
        case .q5_0, .q5_1: return "Excellent quality, ~65% smaller"
        }
    }
    
    var description: String {
        return qualityDescription
    }
    
    /// Size multiplier relative to f16
    var sizeMultiplier: Double {
        switch self {
        case .f16: return 1.0
        case .q8_0: return 0.55
        case .q5_0: return 0.35
        case .q5_1: return 0.39
        }
    }
    
    /// Quality score from 0.0 to 1.0
    var qualityScore: Double {
        switch self {
        case .f16: return 1.00
        case .q8_0: return 0.98
        case .q5_0: return 0.93
        case .q5_1: return 0.94
        }
    }
    
    var isRecommended: Bool {
        self == .q5_0 || self == .q5_1
    }
}

// MARK: - Model Variant

struct WhisperModelVariant: Codable, Hashable, Identifiable, Comparable, Equatable {
    let family: WhisperModelFamily
    let size: WhisperModelSize
    let version: WhisperModelVersion?
    let quantization: WhisperQuantization
    
    var id: String {
        let versionPart = version?.rawValue ?? ""
        let versionSeparator = versionPart.isEmpty ? "" : "-"
        return "\(family.rawValue)-\(size.rawValue)\(versionSeparator)\(versionPart)-\(quantization.rawValue)"
    }
    
    var displayName: String {
        // Special case for TinyDiarize models
        if version == .tdrz {
            return "\(size.displayName) TinyDiarize (Speaker Segmentation)"
        }
        
        let versionStr = (version != nil && version != .v1) ? " \(version!.displayName)" : ""
        let quantStr = quantization == .f16 ? "" : " (\(quantization.rawValue.uppercased()))"
        return "\(family == .kblab ? "KB " : "")\(size.displayName)\(versionStr)\(quantStr)"
    }
    
    var filename: String {
        switch family {
        case .openai, .distilWhisper:
            // Handle version suffix
            let versionSuffix: String
            let tdrzSuffix: String
            
            // Check for tinydiarize models
            if version == .tdrz {
                tdrzSuffix = "-tdrz"
                versionSuffix = ""
            } else {
                tdrzSuffix = ""
                if size == .large {
                    // Large models have explicit version in filename
                    if version == .v3turbo {
                        versionSuffix = "-v3-turbo"
                    } else if let v = version, v != .v1 {
                        versionSuffix = "-\(v.rawValue)"
                    } else if version == .v1 {
                        versionSuffix = "-v1"
                    } else {
                        versionSuffix = ""
                    }
                } else {
                    // Non-large models don't have version in filename
                    versionSuffix = ""
                }
            }
            
            // Handle quantization suffix (empty string for f16)
            let quantSuffix = quantization.rawValue.isEmpty ? "" : "-\(quantization.rawValue)"
            
            // For tinydiarize models, use special filename format
            if version == .tdrz {
                return "ggml-\(size.rawValue).en\(tdrzSuffix).bin"
            }
            
            return "ggml-\(size.rawValue)\(versionSuffix)\(quantSuffix).bin"
            
        case .kblab:
            let quantSuffix = quantization.rawValue.isEmpty ? "" : "-\(quantization.rawValue)"
            return "ggml-model\(quantSuffix).bin"
        }
    }
    
    var downloadURL: URL? {
        let urlString: String
        
        // TinyDiarize models are hosted on a different repository
        if version == .tdrz {
            urlString = "https://huggingface.co/akashmjn/tinydiarize-whisper.cpp/resolve/main/\(filename)"
            return URL(string: urlString)
        }
        
        switch family {
        case .openai, .distilWhisper:
            urlString = family.baseURL + filename
            
        case .kblab:
            // KBLab models have different URL structure
            let modelName = "kb-whisper-\(size.rawValue)"
            urlString = "\(family.baseURL)\(modelName)/resolve/main/\(filename)"
        }
        return URL(string: urlString)
    }
    
    var estimatedSizeMB: Int {
        Int(Double(size.baseSizeMB) * quantization.sizeMultiplier)
    }
    
    var estimatedSize: Int64 {
        Int64(estimatedSizeMB * 1024 * 1024)
    }
    
    var localPath: URL {
        // Build path without quantization as a directory (it's part of the filename)
        var path = WhisperConfiguration.modelsDirectory
            .appendingPathComponent(family.rawValue)
            .appendingPathComponent(size.rawValue)
        
        // Only add version directory for:
        // 1. Large models (always have version)
        // 2. Explicitly versioned non-v1 models
        if size == .large {
            // Large models always have version directory
            path = path.appendingPathComponent(version?.rawValue ?? "v1")
        } else if let version = version, version != .v1 {
            // Non-large models only get version directory if explicitly versioned and not v1
            path = path.appendingPathComponent(version.rawValue)
        }
        // For non-large models with v1 or nil version, no version directory
        
        // Add the filename (which includes quantization suffix)
        return path.appendingPathComponent(filename)
    }
    
    var isAvailable: Bool {
        // Based on actual HuggingFace availability
        switch (family, size, version, quantization) {
        // OpenAI Tiny models
        case (.openai, .tiny, _, .f16), (.openai, .tiny, _, .q5_1), (.openai, .tiny, _, .q8_0):
            return true
            
        // OpenAI Base models
        case (.openai, .base, _, .f16), (.openai, .base, _, .q5_1), (.openai, .base, _, .q8_0):
            return true
            
        // OpenAI Small models
        case (.openai, .small, _, .f16), (.openai, .small, _, .q5_1), (.openai, .small, _, .q8_0):
            return true
            
        // OpenAI Medium models
        case (.openai, .medium, _, .f16), (.openai, .medium, _, .q5_0), (.openai, .medium, _, .q8_0):
            return true
            
        // OpenAI Large models
        case (.openai, .large, .v1, .f16):
            return true
        case (.openai, .large, .v2, .f16), (.openai, .large, .v2, .q5_0), (.openai, .large, .v2, .q8_0):
            return true
        case (.openai, .large, .v3, .f16), (.openai, .large, .v3, .q5_0):
            return true
        case (.openai, .large, .v3turbo, .f16), (.openai, .large, .v3turbo, .q5_0), (.openai, .large, .v3turbo, .q8_0):
            return true
            
        // KBLab models (assuming they follow similar pattern)
        case (.kblab, _, _, .f16), (.kblab, _, _, .q5_0), (.kblab, _, _, .q5_1):
            return true
            
        default:
            return false
        }
    }
    
    func isDownloaded() -> Bool {
        FileManager.default.fileExists(atPath: localPath.path)
    }
    
    // MARK: - Parsing Methods
    
    /// Parse a variant from an identifier string (e.g., "openai-large-v3-q5_0")
    static func fromIdentifier(_ identifier: String) -> WhisperModelVariant? {
        let components = identifier.split(separator: "-").map(String.init)
        guard components.count >= 3 else { return nil }
        
        // Parse family
        guard let family = WhisperModelFamily(rawValue: components[0]) else {
            // Try legacy format
            if identifier.hasPrefix("kb-whisper") {
                return fromLegacyKey(identifier)
            }
            return nil
        }
        
        // Parse size
        guard let size = WhisperModelSize(rawValue: components[1]) else { return nil }
        
        // Parse version and quantization from remaining components
        var version: WhisperModelVersion? = nil
        var quantization: WhisperQuantization = .q5_0
        
        for i in 2..<components.count {
            let component = components[i]
            
            // Check if it's a version
            if let v = WhisperModelVersion(rawValue: component) {
                version = v
            }
            // Check if it's a quantization
            else if component == "fp16" {
                quantization = .f16
            }
            else if let q = WhisperQuantization(rawValue: component) {
                quantization = q
            }
        }
        
        return WhisperModelVariant(
            family: family,
            size: size,
            version: version,
            quantization: quantization
        )
    }
    
    /// Convert to identifier string for storage/lookup
    func toIdentifier() -> String {
        var parts = [family.rawValue, size.rawValue]
        if let v = version, v != .v1 {
            parts.append(v.rawValue)
        }
        // Always include quantization, use "fp16" for empty f16 raw value
        if quantization == .f16 {
            parts.append("fp16")
        } else {
            parts.append(quantization.rawValue)
        }
        return parts.joined(separator: "-")
    }
    
    /// Parse from legacy model key (e.g., "kb-whisper-large")
    static func fromLegacyKey(_ key: String) -> WhisperModelVariant? {
        // Check if it's in the legacy models dictionary
        if let config = WhisperConfiguration.models[key] {
            return config.toVariant
        }
        
        // Try to parse manually
        if key.hasPrefix("kb-whisper-") {
            let sizePart = key.replacingOccurrences(of: "kb-whisper-", with: "")
            if let size = WhisperModelSize(rawValue: sizePart) {
                return WhisperModelVariant(
                    family: .kblab,
                    size: size,
                    version: nil,
                    quantization: .q5_0
                )
            }
        } else if key.hasPrefix("whisper-") {
            let remainder = key.replacingOccurrences(of: "whisper-", with: "")
            let parts = remainder.split(separator: "-").map(String.init)
            
            if let size = WhisperModelSize(rawValue: parts[0]) {
                var version: WhisperModelVersion? = nil
                if parts.count > 1, let v = WhisperModelVersion(rawValue: parts[1]) {
                    version = v
                }
                return WhisperModelVariant(
                    family: .openai,
                    size: size,
                    version: version,
                    quantization: .q5_0
                )
            }
        }
        
        return nil
    }
    
    /// Convert to legacy key format for backward compatibility
    func toLegacyKey() -> String? {
        // Try to find matching legacy key
        for (key, config) in WhisperConfiguration.models {
            if let configVariant = config.toVariant,
               configVariant == self {
                return key
            }
        }
        
        // Generate a key based on pattern
        switch family {
        case .kblab:
            return "kb-whisper-\(size.rawValue)"
        case .openai:
            if let v = version, v != .v1 {
                return "whisper-\(size.rawValue)-\(v.rawValue)"
            }
            return "whisper-\(size.rawValue)"
        case .distilWhisper:
            return "distil-whisper-\(size.rawValue)"
        }
    }
    
    // MARK: - Equatable
    
    static func == (lhs: WhisperModelVariant, rhs: WhisperModelVariant) -> Bool {
        return lhs.family == rhs.family &&
               lhs.size == rhs.size &&
               lhs.version == rhs.version &&
               lhs.quantization == rhs.quantization
    }
    
    // MARK: - Comparable
    
    static func < (lhs: WhisperModelVariant, rhs: WhisperModelVariant) -> Bool {
        // Compare by family first
        if lhs.family.rawValue != rhs.family.rawValue {
            return lhs.family.rawValue < rhs.family.rawValue
        }
        
        // Then by size (larger models first)
        if lhs.size.baseSizeMB != rhs.size.baseSizeMB {
            return lhs.size.baseSizeMB > rhs.size.baseSizeMB
        }
        
        // Then by version (newer first)
        let lhsVersion = lhs.version?.rawValue ?? ""
        let rhsVersion = rhs.version?.rawValue ?? ""
        if lhsVersion != rhsVersion {
            return lhsVersion > rhsVersion
        }
        
        // Finally by quantization (higher quality first)
        return lhs.quantization.qualityScore > rhs.quantization.qualityScore
    }
}

// MARK: - WhisperModelVariant Extensions

extension WhisperModelVariant {
    // MARK: - Convenience Methods
    
    static func defaultVariant() -> WhisperModelVariant {
        return WhisperModelVariant(
            family: .openai,
            size: .base,
            version: nil,
            quantization: .q5_1  // q5_1 for base models, not q5_0
        )
    }
    
    static func swedishVariant() -> WhisperModelVariant {
        return WhisperModelVariant(
            family: .kblab,
            size: .large,
            version: nil,
            quantization: .q5_0
        )
    }
    
    static func turboVariant() -> WhisperModelVariant {
        return WhisperModelVariant(
            family: .distilWhisper,
            size: .large,
            version: .v3turbo,
            quantization: .q5_0
        )
    }
    
    // MARK: - Recommended Models
    
    static var recommendedModels: [WhisperModelVariant] {
        return [
            // OpenAI Large models - Latest versions with all quantizations
            WhisperModelVariant(family: .openai, size: .large, version: .v3, quantization: .f16),
            WhisperModelVariant(family: .openai, size: .large, version: .v3, quantization: .q5_0),
            WhisperModelVariant(family: .openai, size: .large, version: .v3turbo, quantization: .f16),
            WhisperModelVariant(family: .openai, size: .large, version: .v3turbo, quantization: .q8_0),
            WhisperModelVariant(family: .openai, size: .large, version: .v3turbo, quantization: .q5_0),
            
            // OpenAI Medium models
            WhisperModelVariant(family: .openai, size: .medium, version: nil, quantization: .f16),
            WhisperModelVariant(family: .openai, size: .medium, version: nil, quantization: .q8_0),
            WhisperModelVariant(family: .openai, size: .medium, version: nil, quantization: .q5_0),
            
            // OpenAI Small models
            WhisperModelVariant(family: .openai, size: .small, version: nil, quantization: .f16),
            WhisperModelVariant(family: .openai, size: .small, version: nil, quantization: .q8_0),
            WhisperModelVariant(family: .openai, size: .small, version: nil, quantization: .q5_1),
            
            // OpenAI Base models
            WhisperModelVariant(family: .openai, size: .base, version: nil, quantization: .f16),
            WhisperModelVariant(family: .openai, size: .base, version: nil, quantization: .q8_0),
            WhisperModelVariant(family: .openai, size: .base, version: nil, quantization: .q5_1),
            
            // OpenAI Tiny models
            WhisperModelVariant(family: .openai, size: .tiny, version: nil, quantization: .f16),
            WhisperModelVariant(family: .openai, size: .tiny, version: nil, quantization: .q8_0),
            WhisperModelVariant(family: .openai, size: .tiny, version: nil, quantization: .q5_1),
            
            // TinyDiarize models for speaker segmentation (English only)
            WhisperModelVariant(family: .openai, size: .small, version: .tdrz, quantization: .f16),
            WhisperModelVariant(family: .openai, size: .base, version: .tdrz, quantization: .f16),
            WhisperModelVariant(family: .openai, size: .tiny, version: .tdrz, quantization: .f16),
            
            // KBLab Swedish models
            WhisperModelVariant(family: .kblab, size: .large, version: nil, quantization: .f16),
            WhisperModelVariant(family: .kblab, size: .large, version: nil, quantization: .q5_0),
            WhisperModelVariant(family: .kblab, size: .medium, version: nil, quantization: .f16),
            WhisperModelVariant(family: .kblab, size: .medium, version: nil, quantization: .q5_0),
            WhisperModelVariant(family: .kblab, size: .small, version: nil, quantization: .f16),
            WhisperModelVariant(family: .kblab, size: .small, version: nil, quantization: .q5_0)
        ].filter { $0.isAvailable }
    }
    
    static func availableVariants(for family: WhisperModelFamily? = nil) -> [WhisperModelVariant] {
        var variants: [WhisperModelVariant] = []
        
        let families = family != nil ? [family!] : WhisperModelFamily.allCases
        
        for fam in families {
            for size in WhisperModelSize.allCases {
                // Skip certain combinations that don't exist
                if fam == .kblab && size == .tiny {
                    continue // KBLab doesn't have tiny models
                }
                
                for version in WhisperModelVersion.allCases {
                    // KBLab only has v1
                    if fam == .kblab && version != .v1 {
                        continue
                    }
                    
                    // Only large models have v3-turbo
                    if version == .v3turbo && size != .large {
                        continue
                    }
                    
                    for quant in WhisperQuantization.allCases {
                        let variant = WhisperModelVariant(
                            family: fam,
                            size: size,
                            version: version,
                            quantization: quant
                        )
                        
                        if variant.isAvailable {
                            variants.append(variant)
                        }
                    }
                }
            }
        }
        
        return variants
    }
    
    // MARK: - Legacy Model Migration
    
    static func fromLegacyFilename(_ filename: String, type: WhisperConfiguration.ModelType) -> WhisperModelVariant? {
        // Parse legacy filenames like "ggml-large-v3-q5_0.bin" or "ggml-model-whisper-large-q5_0.bin"
        let name = filename.replacingOccurrences(of: ".bin", with: "")
        let parts = name.split(separator: "-")
        
        var size: WhisperModelSize?
        var version: WhisperModelVersion?
        var quantization: WhisperQuantization = .q5_0
        
        // Determine family
        let family: WhisperModelFamily = type == .kblab ? .kblab : .openai
        
        // Parse parts
        for part in parts {
            let partString = String(part)
            
            // Check for size
            if let modelSize = WhisperModelSize(rawValue: partString) {
                size = modelSize
            }
            // Check for version
            else if partString.hasPrefix("v") {
                version = WhisperModelVersion(rawValue: partString)
            }
            // Check for quantization
            else if let quant = WhisperQuantization(rawValue: partString) {
                quantization = quant
            }
        }
        
        // Default values for missing parts
        if size == nil {
            // Try to infer from filename patterns
            if filename.contains("large") { size = .large }
            else if filename.contains("medium") { size = .medium }
            else if filename.contains("small") { size = .small }
            else if filename.contains("base") { size = .base }
            else if filename.contains("tiny") { size = .tiny }
        }
        
        guard let modelSize = size else { return nil }
        
        return WhisperModelVariant(
            family: family,
            size: modelSize,
            version: version,
            quantization: quantization
        )
    }
}

// MARK: - Performance Profiles

enum WhisperPerformanceProfile: String, CaseIterable {
    case accuracyFirst = "Maximum Accuracy"
    case balanced = "Balanced"
    case speedFirst = "Maximum Speed"
    case minimalStorage = "Minimal Storage"
    
    var recommendedVariant: WhisperModelVariant {
        switch self {
        case .accuracyFirst:
            return WhisperModelVariant(
                family: .openai,
                size: .large,
                version: .v3,
                quantization: .f16
            )
        case .balanced:
            return WhisperModelVariant(
                family: .openai,
                size: .medium,
                version: .v3,
                quantization: .q5_0
            )
        case .speedFirst:
            return WhisperModelVariant(
                family: .openai,
                size: .small,
                version: nil,
                quantization: .q5_1
            )
        case .minimalStorage:
            return WhisperModelVariant(
                family: .openai,
                size: .tiny,
                version: nil,
                quantization: .q5_1
            )
        }
    }
    
    var description: String {
        switch self {
        case .accuracyFirst:
            return "Best transcription quality, requires more storage and processing time"
        case .balanced:
            return "Good balance between quality, speed, and storage"
        case .speedFirst:
            return "Fast transcription with acceptable quality"
        case .minimalStorage:
            return "Minimal disk space usage, basic transcription quality"
        }
    }
}

// MARK: - Model Recommendations

struct WhisperModelRecommendation {
    static func recommend(
        for language: String?,
        prioritize: WhisperPerformanceProfile = .balanced
    ) -> WhisperModelVariant {
        
        // Swedish-specific recommendation
        if let lang = language, (lang == "sv" || lang == "swedish") {
            switch prioritize {
            case .accuracyFirst:
                return WhisperModelVariant(
                    family: .kblab,
                    size: .large,
                    version: .v1,
                    quantization: .f16
                )
            case .balanced:
                return WhisperModelVariant(
                    family: .kblab,
                    size: .medium,
                    version: .v1,
                    quantization: .q5_0
                )
            case .speedFirst:
                return WhisperModelVariant(
                    family: .kblab,
                    size: .small,
                    version: .v1,
                    quantization: .q5_0
                )
            case .minimalStorage:
                return WhisperModelVariant(
                    family: .kblab,
                    size: .small,
                    version: .v1,
                    quantization: .q5_0
                )
            }
        }
        
        // Default to performance profile recommendation
        return prioritize.recommendedVariant
    }
}