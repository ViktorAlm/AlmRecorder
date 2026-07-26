import Foundation

/// MLX quantizations offered for VibeVoice-ASR. The repository identifiers are deliberately
/// explicit so queued jobs and benchmarks remain reproducible if the catalog changes later.
enum VibeVoiceQuantization: String, CaseIterable, Codable, Identifiable {
    case fourBit = "4bit"
    case sixBit = "6bit"
    case eightBit = "8bit"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fourBit: return "4-bit · Default"
        case .sixBit: return "6-bit · Higher precision"
        case .eightBit: return "8-bit · Maximum quality"
        }
    }

    var repositoryID: String {
        "mlx-community/VibeVoice-ASR-\(rawValue)"
    }

    var estimatedDownloadBytes: Int64 {
        switch self {
        case .fourBit: return 5_710_000_000
        case .sixBit: return 7_620_000_000
        case .eightBit: return 9_520_000_000
        }
    }
}

/// The production transcription choice for new installations. Keep this centralized so first-run
/// setup, settings fallbacks, queue snapshots, and tests cannot silently drift apart.
enum TranscriptionProductionDefaults {
    static let backend: TranscriptionBackend = .vibeVoice
    static let vibeVoiceQuantization: VibeVoiceQuantization = .fourBit
    static let vibeVoiceSpeakerMode: VibeVoiceSpeakerMode = .fused

    /// One-time rollout marker. Existing installations adopt the new default only when the 4-bit
    /// model is already present, avoiding a surprise unusable backend for people who have not
    /// downloaded VibeVoice. Fresh installations always use the production default.
    static let rolloutKey = "transcriptionDefaults.vibeVoice4BitFused.v1"

    static func shouldAdopt(
        hasStoredBackend: Bool,
        hasFourBitModel: Bool
    ) -> Bool {
        !hasStoredBackend || hasFourBitModel
    }
}

/// VibeVoice speaker labels are only recording-local. Fused mode replaces their identity evidence
/// with AlmRecorder's overlap-aware FluidAudio embeddings before global reconciliation.
enum VibeVoiceSpeakerMode: String, CaseIterable, Codable, Identifiable {
    case fused = "fused"
    case native = "native"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fused: return "AlmRecorder fused"
        case .native: return "VibeVoice native · local only"
        }
    }
}

/// Immutable selection copied into each queue job. Older persisted jobs decode with this field nil
/// and keep their historical behavior; new jobs never silently switch engines while waiting.
struct TranscriptionEngineSelection: Codable, Equatable {
    let backend: TranscriptionBackend
    let whisperVariantIdentifier: String?
    let llmEngine: LLMEngine?
    let llmModelKey: String?
    let vibeVoiceQuantization: VibeVoiceQuantization?
    let vibeVoiceSpeakerMode: VibeVoiceSpeakerMode?
    let vibeVoiceModelRevision: String?
    let vibeVoiceRuntimeRevision: String?
    let vibeVoiceContext: String?

    static func snapshot(from settings: GlobalModelSettings = .shared) -> Self {
        let llmModel: String?
        switch settings.selectedLLMEngine {
        case .voxtral: llmModel = settings.selectedVoxtralTranscriptionModel
        case .gemma: llmModel = settings.selectedGemmaTranscriptionModel
        }
        return TranscriptionEngineSelection(
            backend: settings.transcriptionBackend,
            whisperVariantIdentifier: settings.selectedWhisperVariant?.toIdentifier(),
            llmEngine: settings.selectedLLMEngine,
            llmModelKey: llmModel,
            vibeVoiceQuantization: settings.selectedVibeVoiceQuantization,
            vibeVoiceSpeakerMode: settings.vibeVoiceSpeakerMode,
            vibeVoiceModelRevision: VibeVoiceConfiguration.modelRevision(
                for: settings.selectedVibeVoiceQuantization
            ),
            vibeVoiceRuntimeRevision: VibeVoiceConfiguration.mlxAudioRevision,
            vibeVoiceContext: settings.vibeVoiceContext.nilIfBlank
        )
    }

    var displayName: String {
        switch backend {
        case .whisper:
            return whisperVariantIdentifier.map { "Whisper · \($0)" } ?? "Whisper"
        case .llm:
            return "\(llmEngine?.rawValue ?? "LLM") · \(llmModelKey ?? "default")"
        case .vibeVoice:
            return "VibeVoice · \(vibeVoiceQuantization?.rawValue ?? TranscriptionProductionDefaults.vibeVoiceQuantization.rawValue) · \(vibeVoiceSpeakerMode?.displayName ?? TranscriptionProductionDefaults.vibeVoiceSpeakerMode.displayName)"
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
