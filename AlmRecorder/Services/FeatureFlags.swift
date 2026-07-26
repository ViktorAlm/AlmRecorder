import Foundation

/// Runtime feature flags, UserDefaults-backed. All default OFF (false) when unset.
///
/// Toggle from a debug menu or via:
///   `UserDefaults.standard.set(true, forKey: "feature.useFluidAudioDiarization")`
enum FeatureFlags {
    /// When ON (the default), speaker segmentation uses FluidAudio's full diarization pipeline
    /// (pyannote-community-1: multilingual, overlap-aware, ANE) for labels AND the per-speaker
    /// embeddings the review wizard matches against, instead of the legacy VAD + DBSCAN path
    /// that over-splits. Set to false to fall back to the legacy path:
    ///   `UserDefaults.standard.set(false, forKey: "feature.useFluidAudioDiarization")`
    static var useFluidAudioDiarization: Bool {
        UserDefaults.standard.object(forKey: "feature.useFluidAudioDiarization") as? Bool ?? true
    }
}
