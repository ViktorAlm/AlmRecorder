import Foundation

/// Capability tier based on installed RAM. Local Whisper + a 12B multimodal LLM are heavy, so the
/// app needs real memory: 16 GB minimum, 24 GB recommended.
enum SystemTier: String {
    case belowMinimum   // < 16 GB — warn; use light models
    case minimum        // 16–24 GB
    case recommended    // >= 24 GB

    var headline: String {
        switch self {
        case .belowMinimum: return "Below minimum"
        case .minimum: return "Meets minimum"
        case .recommended: return "Recommended"
        }
    }
}

/// Live machine specs + the min/recommended thresholds.
enum SystemSpecs {
    static let minimumRAMGB = 16
    static let recommendedRAMGB = 24

    static var physicalMemoryGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) // bytes → GiB
    }

    static var freeDiskGB: Int {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let free = attrs[.systemFreeSize] as? Int64 else { return 0 }
        return Int(free / 1_073_741_824)
    }

    static var activeProcessorCount: Int { ProcessInfo.processInfo.activeProcessorCount }

    /// Pure tier classification (testable without touching the host).
    static func tier(ramGB: Int) -> SystemTier {
        if ramGB >= recommendedRAMGB { return .recommended }
        if ramGB >= minimumRAMGB { return .minimum }
        return .belowMinimum
    }

    static var tier: SystemTier { tier(ramGB: physicalMemoryGB) }
}

/// The model set the setup wizard recommends for a given amount of RAM. VibeVoice 4-bit fused is
/// the default transcription system; the 12B multimodal LLM's quantization scales with RAM,
/// dropping to the light E4B model below the minimum.
struct SetupModelPlan: Equatable {
    let vibeVoiceQuantization: VibeVoiceQuantization
    /// Key into `GemmaConfiguration.models`.
    let gemmaKey: String
    /// Id into `EmbeddingModelManager` catalog.
    let embeddingId: String
}

enum SetupRecommender {
    static let defaultEmbedding = "qwen3-embed-0.6b-q8"

    /// Gemma 12B at the heaviest quantization the RAM comfortably fits, or the light E4B model below
    /// the minimum so the app still works (just lower quality).
    static func gemmaKey(ramGB: Int) -> String {
        switch SystemSpecs.tier(ramGB: ramGB) {
        case .recommended: return "12B-Q5_K_M"
        case .minimum:     return "12B-Q4_K_M"
        case .belowMinimum: return "E4B-Q4_K_M"
        }
    }

    static func plan(ramGB: Int) -> SetupModelPlan {
        SetupModelPlan(
            vibeVoiceQuantization: TranscriptionProductionDefaults.vibeVoiceQuantization,
            gemmaKey: gemmaKey(ramGB: ramGB),
            embeddingId: defaultEmbedding
        )
    }
}
