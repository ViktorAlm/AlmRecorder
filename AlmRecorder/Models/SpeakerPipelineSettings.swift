import Combine
import Foundation

/// Named, reproducible speaker-identification pipelines.  A profile is stored with each
/// recording so evaluation results can always be traced back to the settings that produced them.
enum SpeakerPipelineProfile: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    case legacy
    case balanced
    case accuracy
    case targetedSortformer
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .legacy: return "Legacy"
        case .balanced: return "Balanced"
        case .accuracy: return "Highest accuracy"
        case .targetedSortformer: return "Targeted Sortformer"
        case .custom: return "Custom"
        }
    }

    var explanation: String {
        switch self {
        case .legacy:
            return "Original streaming FluidAudio + TinyDiarize path. Kept as the control for A/B tests."
        case .balanced:
            return "Offline VBx diarization with constrained evidence-graph identity matching. Repeated evidence joins locally over-split voices across recordings."
        case .accuracy:
            return "Denser offline windows, zero-vote recovery, and constrained evidence-graph reconciliation across recordings."
        case .targetedSortformer:
            return "Highest-accuracy VBx plus short, context-padded Sortformer passes aimed at recording-local utterances. Splits sequential voices and preserves simultaneous speech before global identity matching."
        case .custom:
            return "Choose every diarization, alignment, clustering, and identity setting independently."
        }
    }
}

enum SpeakerDiarizationBackend: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    case segmentDBSCAN
    case legacyStreaming
    case offlineVBx
    case offlineVBxTargetedSortformer
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .segmentDBSCAN: return "TinyDiarize + DBSCAN"
        case .legacyStreaming: return "Legacy streaming"
        case .offlineVBx: return "Offline VBx"
        case .offlineVBxTargetedSortformer: return "VBx + targeted Sortformer"
        }
    }
}

enum SpeakerTranscriptionSegmentation: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    case tinyDiarizeTurns
    case whisperTimedSegments
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .tinyDiarizeTurns: return "TinyDiarize turns"
        case .whisperTimedSegments: return "ASR timed segments"
        }
    }
}

enum SpeakerAlignmentStrategy: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    case maximumOverlap
    case splitAtSpeakerBoundaries
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .maximumOverlap: return "Maximum overlap"
        case .splitAtSpeakerBoundaries: return "Speaker-boundary aware"
        }
    }
}

/// Controls how word-timed ASR pieces are assembled into transcript rows after speaker
/// alignment. This is intentionally independent from diarization: local over-segmentation is
/// recoverable through the shared global speaker UUID, while a row containing several speakers is
/// not.
enum SpeakerUtteranceSegmentation: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    case legacyCoalesced
    case readable
    case speakerSafe

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .legacyCoalesced: return "Legacy coalescing"
        case .readable: return "Readable sentences"
        case .speakerSafe: return "Speaker-safe"
        }
    }

    var explanation: String {
        switch self {
        case .legacyCoalesced:
            return "Merge same-label words across gaps up to one second. Reproduces the original behavior."
        case .readable:
            return "Keep sentence-sized rows and split long passages, pauses, and changes in simultaneous speech."
        case .speakerSafe:
            return "Prefer short, speaker-homogeneous rows. Global voice matching still joins fragments across the call and across recordings."
        }
    }
}

enum SpeakerCentroidPolicy: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    case equalTurns
    case durationWeighted
    case qualityDurationWeighted
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .equalTurns: return "Equal turns"
        case .durationWeighted: return "Duration weighted"
        case .qualityDurationWeighted: return "Quality × duration"
        }
    }
}

enum SpeakerIdentityMatcher: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    case greedy
    case optimalWithMargin
    case prototypeConsensus
    case evidenceGraph
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .greedy: return "Greedy"
        case .optimalWithMargin: return "Optimal + ambiguity margin"
        case .prototypeConsensus: return "Multi-prototype + margin"
        case .evidenceGraph: return "Constrained evidence graph"
        }
    }
}

enum PersonaLinkage: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    case single
    case complete
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .single: return "Single linkage"
        case .complete: return "Complete linkage"
        }
    }
}

/// Complete serializable configuration for one run of the speaker pipeline.
struct SpeakerPipelineConfiguration: Codable, Equatable, Sendable {
    var diarizationBackend: SpeakerDiarizationBackend
    var transcriptionSegmentation: SpeakerTranscriptionSegmentation
    var alignmentStrategy: SpeakerAlignmentStrategy
    /// Optional preserves decoding of v1 custom configurations. `effectiveUtteranceSegmentation`
    /// supplies the safe default for configurations saved before this control existed.
    var utteranceSegmentation: SpeakerUtteranceSegmentation? = nil
    var centroidPolicy: SpeakerCentroidPolicy
    var identityMatcher: SpeakerIdentityMatcher
    var personaLinkage: PersonaLinkage

    /// FluidAudio streaming cosine threshold.
    var streamingClusteringThreshold: Float
    /// FluidAudio offline Euclidean clustering threshold.
    var offlineClusteringThreshold: Double
    var offlineStepRatio: Double
    var offlineMinimumSegmentDuration: Double
    var enableZeroVoteReembedding: Bool
    var minimumSpeakers: Int?
    var maximumSpeakers: Int?

    var identitySimilarityThreshold: Float
    var identityAmbiguityMargin: Float
    var personaSimilarityThreshold: Float
    var updateCentroidsAfterIngest: Bool
    /// Retained in the serialized v1 schema for backward compatibility. It is always forced off:
    /// a computer microphone can contain the host plus any number of in-room participants.
    var anchorMicrophoneTrackToOwner: Bool

    static let legacy = SpeakerPipelineConfiguration(
        diarizationBackend: .legacyStreaming,
        transcriptionSegmentation: .tinyDiarizeTurns,
        alignmentStrategy: .maximumOverlap,
        utteranceSegmentation: .legacyCoalesced,
        centroidPolicy: .equalTurns,
        identityMatcher: .greedy,
        personaLinkage: .single,
        streamingClusteringThreshold: 0.70,
        offlineClusteringThreshold: 0.60,
        offlineStepRatio: 0.20,
        offlineMinimumSegmentDuration: 1.0,
        enableZeroVoteReembedding: false,
        minimumSpeakers: nil,
        maximumSpeakers: nil,
        identitySimilarityThreshold: 0.85,
        identityAmbiguityMargin: 0,
        personaSimilarityThreshold: 0.80,
        updateCentroidsAfterIngest: false,
        anchorMicrophoneTrackToOwner: false
    )

    static let balanced = SpeakerPipelineConfiguration(
        diarizationBackend: .offlineVBx,
        transcriptionSegmentation: .whisperTimedSegments,
        alignmentStrategy: .splitAtSpeakerBoundaries,
        utteranceSegmentation: .speakerSafe,
        centroidPolicy: .durationWeighted,
        identityMatcher: .evidenceGraph,
        personaLinkage: .complete,
        streamingClusteringThreshold: 0.70,
        offlineClusteringThreshold: 0.70,
        offlineStepRatio: 0.20,
        offlineMinimumSegmentDuration: 1.0,
        enableZeroVoteReembedding: false,
        minimumSpeakers: nil,
        maximumSpeakers: nil,
        identitySimilarityThreshold: 0.46,
        identityAmbiguityMargin: 0.135,
        personaSimilarityThreshold: 0.95,
        updateCentroidsAfterIngest: true,
        anchorMicrophoneTrackToOwner: false
    )

    static let accuracy = SpeakerPipelineConfiguration(
        diarizationBackend: .offlineVBx,
        transcriptionSegmentation: .whisperTimedSegments,
        alignmentStrategy: .splitAtSpeakerBoundaries,
        utteranceSegmentation: .speakerSafe,
        centroidPolicy: .qualityDurationWeighted,
        identityMatcher: .evidenceGraph,
        personaLinkage: .complete,
        streamingClusteringThreshold: 0.70,
        offlineClusteringThreshold: 0.75,
        offlineStepRatio: 0.10,
        offlineMinimumSegmentDuration: 0.0,
        enableZeroVoteReembedding: true,
        minimumSpeakers: nil,
        maximumSpeakers: nil,
        identitySimilarityThreshold: 0.46,
        identityAmbiguityMargin: 0.135,
        personaSimilarityThreshold: 0.82,
        updateCentroidsAfterIngest: true,
        anchorMicrophoneTrackToOwner: false
    )

    static let targetedSortformer: SpeakerPipelineConfiguration = {
        var configuration = SpeakerPipelineConfiguration.accuracy
        configuration.diarizationBackend = .offlineVBxTargetedSortformer
        return configuration
    }()

    var effectiveUtteranceSegmentation: SpeakerUtteranceSegmentation {
        utteranceSegmentation
            ?? (alignmentStrategy == .splitAtSpeakerBoundaries ? .speakerSafe : .legacyCoalesced)
    }
}

/// Persistent selection used by transcription, identity inference, and the evaluator.
/// UserDefaults is intentional here: the selection must be readable before the database opens.
final class SpeakerPipelineSettings: ObservableObject {
    static let shared = SpeakerPipelineSettings()

    static let profileKey = "speakerPipeline.profile"
    static let customConfigurationKey = "speakerPipeline.customConfiguration.v1"
    static let continuousReconciliationKey =
        "speakerPipeline.continuousCalibratedReconciliation"

    @Published var selectedProfile: SpeakerPipelineProfile {
        didSet { defaults.set(selectedProfile.rawValue, forKey: Self.profileKey) }
    }

    @Published var customConfiguration: SpeakerPipelineConfiguration {
        didSet {
            if let data = try? JSONEncoder().encode(customConfiguration) {
                defaults.set(data, forKey: Self.customConfigurationKey)
            }
        }
    }

    /// Runs the held-out-gated, reversible reconciler after new recordings arrive. When it is
    /// enabled but the developer/user has not supplied enough private gold, the safety gate leaves
    /// assignments untouched; it never falls back to the older merge-only evidence graph.
    @Published var continuousReconciliationEnabled: Bool {
        didSet {
            defaults.set(
                continuousReconciliationEnabled,
                forKey: Self.continuousReconciliationKey
            )
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        continuousReconciliationEnabled =
            defaults.object(forKey: Self.continuousReconciliationKey) as? Bool ?? true

        if let raw = defaults.string(forKey: Self.profileKey),
           let profile = SpeakerPipelineProfile(rawValue: raw) {
            selectedProfile = profile
        } else if defaults.object(forKey: "feature.useFluidAudioDiarization") as? Bool == false {
            selectedProfile = .legacy
        } else {
            selectedProfile = .balanced
        }

        if let data = defaults.data(forKey: Self.customConfigurationKey),
           let decoded = try? JSONDecoder().decode(SpeakerPipelineConfiguration.self, from: data) {
            customConfiguration = Self.enforcingMultiSpeakerMicrophoneSafety(decoded)
        } else {
            customConfiguration = .balanced
        }
    }

    var activeConfiguration: SpeakerPipelineConfiguration {
        switch selectedProfile {
        case .legacy: return .legacy
        case .balanced: return .balanced
        case .accuracy: return .accuracy
        case .targetedSortformer: return .targetedSortformer
        case .custom: return Self.enforcingMultiSpeakerMicrophoneSafety(customConfiguration)
        }
    }

    static func configuration(for profile: SpeakerPipelineProfile) -> SpeakerPipelineConfiguration {
        switch profile {
        case .legacy: return .legacy
        case .balanced: return .balanced
        case .accuracy: return .accuracy
        case .targetedSortformer: return .targetedSortformer
        case .custom: return enforcingMultiSpeakerMicrophoneSafety(shared.customConfiguration)
        }
    }

    private static func enforcingMultiSpeakerMicrophoneSafety(
        _ configuration: SpeakerPipelineConfiguration
    ) -> SpeakerPipelineConfiguration {
        var safe = configuration
        safe.anchorMicrophoneTrackToOwner = false
        return safe
    }
}
