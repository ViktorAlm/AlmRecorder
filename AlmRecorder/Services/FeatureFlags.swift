import Foundation

/// Runtime feature flags, UserDefaults-backed.
///
/// Toggle from a debug menu or via:
///   `UserDefaults.standard.set(true, forKey: "feature.useFluidAudioDiarization")`
enum FeatureFlags {
    /// Internal database and evaluation surfaces. These are intentionally hidden from the normal
    /// recording/search product so destructive maintenance and benchmark controls do not compete
    /// with user tasks.
    static var developerTools: Bool {
        if let stored = UserDefaults.standard.object(forKey: "feature.developerTools") as? Bool {
            return stored
        }
        return ProcessInfo.processInfo.environment["ALMREC_DEVELOPER_TOOLS"] == "1"
    }

    /// Hold-to-talk dictation powered by the full local VibeVoice ASR 4-bit MLX model.
    /// Enabled by default; users can opt out from Settings → Dictation.
    static var realtimeDictation: Bool {
        realtimeDictation(
            defaults: .standard,
            environment: ProcessInfo.processInfo.environment
        )
    }

    static func realtimeDictation(
        defaults: UserDefaults,
        environment: [String: String]
    ) -> Bool {
        if let stored = defaults.object(
            forKey: "feature.realtimeDictation"
        ) as? Bool {
            return stored
        }
        if let environmentValue = environment["ALMREC_REALTIME_DICTATION"] {
            return environmentValue == "1"
        }
        return true
    }

    /// When ON (the default), speaker segmentation uses FluidAudio's full diarization pipeline
    /// (pyannote-community-1: multilingual, overlap-aware, ANE) for labels AND the per-speaker
    /// embeddings the review wizard matches against, instead of the legacy VAD + DBSCAN path
    /// that over-splits. Set to false to fall back to the legacy path:
    ///   `UserDefaults.standard.set(false, forKey: "feature.useFluidAudioDiarization")`
    static var useFluidAudioDiarization: Bool {
        UserDefaults.standard.object(forKey: "feature.useFluidAudioDiarization") as? Bool ?? true
    }
}
