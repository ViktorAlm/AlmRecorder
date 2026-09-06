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
    /// VibeVoice provides the best immediately useful transcript and native speaker-turn
    /// structure. Whisper remains the independent, noise-robust nightly evidence pass.
    static let backend: TranscriptionBackend = .vibeVoice
    static let vibeVoiceQuantization: VibeVoiceQuantization = .fourBit
    static let vibeVoiceSpeakerMode: VibeVoiceSpeakerMode = .fused

    /// One-time rollout marker for both new and existing installations. Model readiness remains a
    /// visible queue state; silently falling back would make provenance and comparisons dishonest.
    static let rolloutKey = "transcriptionDefaults.vibeVoiceForegroundQuality.v1"

    static func shouldAdopt(
        hasStoredBackend: Bool,
        hasFourBitModel: Bool
    ) -> Bool {
        // Retain the parameters until older callers have migrated. The explicit product rollout
        // must select VibeVoice even before its model download completes so the queue can explain
        // exactly what it is waiting for.
        _ = hasStoredBackend
        _ = hasFourBitModel
        return true
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
        // Gemma audio transcription is deferred. Never create a new queue snapshot that can route
        // recording audio to Gemma, even if a stale in-memory preference still says `.gemma`.
        let llmEngine: LLMEngine = .voxtral
        let llmModel: String? = settings.selectedVoxtralTranscriptionModel
        return TranscriptionEngineSelection(
            backend: settings.transcriptionBackend,
            whisperVariantIdentifier: settings.selectedWhisperVariant?.toIdentifier(),
            llmEngine: llmEngine,
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
