import Foundation

/// Durable stages for the maximum-quality background pipeline. New VibeVoice foreground
/// recordings reuse their exact committed turns and skip the duplicate VibeVoice stage; the stage
/// remains durable as a compatibility fallback for historical recordings from another engine.
enum NightlyQualityStage: String, Codable, CaseIterable {
    case whisper
    case vibeVoice
    case gemmaFinalization
    case cleanup
    case completed

    var displayName: String {
        switch self {
        case .whisper: return "Whisper candidate"
        case .vibeVoice: return "VibeVoice candidate"
        case .gemmaFinalization: return "Audio-grounded speaker-safe repair"
        case .cleanup: return "Final cleanup"
        case .completed: return "Complete"
        }
    }
}

/// User-requested invalidation scope for one private comparison. Each scope retains independent
/// upstream candidates where possible and discards every output that depends on the rerun stage.
enum NightlyQualityRerunScope: String, CaseIterable, Identifiable {
    case whisper
    case vibeVoice
    case consensus
    case allCandidates

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisper: return "Whisper"
        case .vibeVoice: return "VibeVoice"
        case .consensus: return "Consensus"
        case .allCandidates: return "all candidate models"
        }
    }
}

/// Prompt/validator contract for audio-grounded consensus. All strategies keep VibeVoice
/// timestamps, speakers, and turn boundaries immutable; they differ only in repair freedom.
enum ConsensusRepairStrategy: String, Codable, CaseIterable, Identifiable {
    case evidenceRepair = "evidence_repair"
    case coherentVerbatim = "coherent_verbatim"
    case readableReconstruction = "readable_reconstruction"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .evidenceRepair: return "Evidence repair"
        case .coherentVerbatim: return "Coherent verbatim"
        case .readableReconstruction: return "Editorial cleanup"
        }
    }

    var shortDescription: String {
        switch self {
        case .evidenceRepair:
            return "Minimal recognition, spelling, name, and punctuation fixes."
        case .coherentVerbatim:
            return "Reconstructs the intended spoken sentence from both ASR candidates and context."
        case .readableReconstruction:
            return "Rewrites broken ASR into grammatical, coherent speech without changing its facts."
        }
    }
}

/// Legacy persisted quality choices. Both now use the same speaker-preserving audio consensus;
/// keeping the raw cases lets existing settings decode without silently rebuilding the library.
enum NightlyQualityMode: String, Codable, CaseIterable, Identifiable {
    case quality
    case maximum

    var id: String { rawValue }

    var displayName: String {
        "VibeVoice native turns + Gemma audio consensus"
    }

    var runsBlindGemma: Bool { false }
}

/// Automatic transcript mutation is deliberately a separate choice from model quality.
enum NightlyQualityCommitPolicy: String, Codable, CaseIterable, Identifiable {
    case shadow
    case automaticHighConfidence

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shadow: return "Shadow benchmark · do not change transcripts"
        case .automaticHighConfidence: return "Apply safe one-to-one corrections"
        }
    }
}

/// Keeps a new quality pipeline from accidentally turning into a multi-week historical backfill.
enum NightlyQualityScope: String, Codable, CaseIterable, Identifiable {
    case evaluationCohort
    case newRecordings
    case entireLibrary

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .evaluationCohort: return "Gold and manually edited calls"
        case .newRecordings: return "Recordings added after enabling"
        case .entireLibrary: return "Entire library backfill"
        }
    }
}

struct NightlyQualityConfiguration: Codable, Equatable {
    var enabled: Bool
    var window: NightlyProcessingWindow
    var excludeSpeakerGold: Bool
    var preventIdleSleepWhileProcessing: Bool
    /// Conservative text-token ceiling around one locked VibeVoice turn. Audio clips have their
    /// own hard duration and per-request count limits.
    var maximumInputTokens: Int
    /// Audio-capable Gemma GGUF used for the speaker-safe consensus pass.
    var gemmaAudioModelKey: String
    var mode: NightlyQualityMode
    var commitPolicy: NightlyQualityCommitPolicy
    var scope: NightlyQualityScope
    /// Calls explicitly enrolled for private comparison without falsely marking their transcript
    /// or speaker labels as user-reviewed gold.
    var additionalEvaluationRecordingIDs: Set<Int64>
    /// Boundary for `.newRecordings`; changing scope does not silently move this date.
    var enrollmentDate: Date

    init(
        enabled: Bool = true,
        window: NightlyProcessingWindow = .defaultWindow,
        excludeSpeakerGold: Bool = true,
        preventIdleSleepWhileProcessing: Bool = true,
        maximumInputTokens: Int = 12_000,
        gemmaAudioModelKey: String = GemmaConfiguration.defaultAudioModel,
        mode: NightlyQualityMode = .maximum,
        commitPolicy: NightlyQualityCommitPolicy = .automaticHighConfidence,
        scope: NightlyQualityScope = .newRecordings,
        additionalEvaluationRecordingIDs: Set<Int64> = [],
        enrollmentDate: Date = Date()
    ) {
        self.enabled = enabled
        self.window = window
        self.excludeSpeakerGold = excludeSpeakerGold
        self.preventIdleSleepWhileProcessing = preventIdleSleepWhileProcessing
        self.maximumInputTokens = maximumInputTokens
        self.gemmaAudioModelKey = GemmaConfiguration.validatedAudioModelKey(
            gemmaAudioModelKey
        )
        self.mode = mode
        self.commitPolicy = commitPolicy
        self.scope = scope
        self.additionalEvaluationRecordingIDs = additionalEvaluationRecordingIDs
        self.enrollmentDate = enrollmentDate
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case window
        case excludeSpeakerGold
        case preventIdleSleepWhileProcessing
        case maximumInputTokens
        case gemmaAudioModelKey
        case mode
        case commitPolicy
        case scope
        case additionalEvaluationRecordingIDs
        case enrollmentDate
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        window = try values.decodeIfPresent(
            NightlyProcessingWindow.self,
            forKey: .window
        ) ?? .defaultWindow
        excludeSpeakerGold = try values.decodeIfPresent(
            Bool.self,
            forKey: .excludeSpeakerGold
        ) ?? true
        preventIdleSleepWhileProcessing = try values.decodeIfPresent(
            Bool.self,
            forKey: .preventIdleSleepWhileProcessing
        ) ?? true
        maximumInputTokens = min(
            14_000,
            max(
                4_096,
                try values.decodeIfPresent(
                    Int.self,
                    forKey: .maximumInputTokens
                ) ?? 12_000
            )
        )
        gemmaAudioModelKey = GemmaConfiguration.validatedAudioModelKey(
            try values.decodeIfPresent(String.self, forKey: .gemmaAudioModelKey)
        )
        // Persisted v1 plans predate trustworthy provenance and a gold gate. Migrating them into
        // shadow + evaluation scope prevents an old "enabled" bit from launching the whole library.
        mode = try values.decodeIfPresent(NightlyQualityMode.self, forKey: .mode) ?? .maximum
        commitPolicy = try values.decodeIfPresent(
            NightlyQualityCommitPolicy.self,
            forKey: .commitPolicy
        ) ?? .shadow
        scope = try values.decodeIfPresent(
            NightlyQualityScope.self,
            forKey: .scope
        ) ?? .evaluationCohort
        additionalEvaluationRecordingIDs = try values.decodeIfPresent(
            Set<Int64>.self,
            forKey: .additionalEvaluationRecordingIDs
        ) ?? []
        enrollmentDate = try values.decodeIfPresent(
            Date.self,
            forKey: .enrollmentDate
        ) ?? Date()
    }
}

struct NightlyQualityTelemetry: Codable, Equatable {
    var currentInputTokens = 0
    var maximumInputTokens = 12_000
    var cumulativeInputTokens = 0
    var completedWindows = 0
    var totalWindows = 0
    var currentClip: Int?
    var totalClips: Int?
    var currentPhase: String?
    var currentRAMBytes: UInt64?
    var peakRAMBytes: UInt64?
    var systemAvailableBytes: UInt64?
    var estimatedModelPeakBytes: UInt64?

    var tokenReadiness: Double {
        guard maximumInputTokens > 0 else { return 0 }
        return min(1, max(0, Double(currentInputTokens) / Double(maximumInputTokens)))
    }
}

struct NightlyQualityAggregateMetric: Identifiable, Equatable {
    let candidate: String
    let recordingCount: Int
    let referenceSegmentCount: Int
    let wordErrors: Int
    let referenceWordCount: Int
    let characterErrors: Int
    let referenceCharacterCount: Int
    let matchedBoundaries: Int
    let referenceBoundaryCount: Int
    let candidateBoundaryCount: Int

    var id: String { candidate }
    var wordErrorRate: Double? {
        referenceWordCount > 0 ? Double(wordErrors) / Double(referenceWordCount) : nil
    }
    var characterErrorRate: Double? {
        referenceCharacterCount > 0
            ? Double(characterErrors) / Double(referenceCharacterCount)
            : nil
    }
    var boundaryF1: Double? {
        guard referenceBoundaryCount > 0, candidateBoundaryCount > 0 else { return nil }
        let precision = Double(matchedBoundaries) / Double(candidateBoundaryCount)
        let recall = Double(matchedBoundaries) / Double(referenceBoundaryCount)
        return precision + recall > 0
            ? 2 * precision * recall / (precision + recall)
            : 0
    }
}

struct NightlyQualityItem: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        case pending
        case active
        case waitingForCleanup
        case completed
        case failed
        case skipped
    }

    let id: Int64
    let title: String
    let duration: TimeInterval
    var stage: NightlyQualityStage = .whisper
    var state: State = .pending
    var attempts = 0
    var lastError: String?
    var cleanupJobID: UUID?
    var telemetry = NightlyQualityTelemetry()

    var isTerminal: Bool {
        state == .completed || state == .failed || state == .skipped
    }
}

struct NightlyQualityManifest: Codable, Equatable {
    let id: UUID
    let createdAt: Date
    let vibeVoiceQuantization: VibeVoiceQuantization
    var whisperVariantIdentifier: String? = nil
    let gemmaModelKey: String
    var qualityMode: NightlyQualityMode? = nil
    var commitPolicy: NightlyQualityCommitPolicy? = nil
    var scope: NightlyQualityScope? = nil
    var items: [NightlyQualityItem]
    var activeRecordingID: Int64?
    var activeStartedAt: Date?
    var observedRealTimeFactor: Double?
    var completedWallClockSeconds: TimeInterval = 0
    var completedAudioWorkSeconds: TimeInterval? = nil

    var completedCount: Int {
        items.filter { $0.state == .completed }.count
    }

    var failedCount: Int {
        items.filter { $0.state == .failed }.count
    }

    var terminalCount: Int {
        items.filter(\.isTerminal).count
    }

    var isComplete: Bool {
        terminalCount == items.count
    }

    var hasPipelineSnapshot: Bool {
        qualityMode != nil && commitPolicy != nil && scope != nil
    }

    var remainingAudioSeconds: TimeInterval {
        items.filter { !$0.isTerminal }.reduce(0) { $0 + $1.duration }
    }

    /// One audio-work unit represents one full-duration model pass. Cleanup is intentionally
    /// excluded because its verifier touches only a small, data-dependent subset of utterances.
    var remainingModelAudioWorkSeconds: TimeInterval {
        items.reduce(0) { total, item in
            guard !item.isTerminal else { return total }
            switch item.stage {
            case .whisper:
                return total + item.duration * 3
            case .vibeVoice:
                return total + item.duration * 2
            case .gemmaFinalization:
                return total + item.duration
            case .cleanup, .completed:
                return total
            }
        }
    }
}

/// Text tokenization is model-specific, so the planner uses a conservative UTF-8 estimate. Audio
/// is budgeted separately by the <30-second item limit and maximum items per request.
enum GemmaInputBudget {
    static let fixedPromptTokens = 256

    static func estimatedTextTokens(_ text: String) -> Int {
        max(1, Int(ceil(Double(text.utf8.count) / 3.0)))
    }

    static func estimatedInputTokens(prompt: String) -> Int {
        fixedPromptTokens + estimatedTextTokens(prompt)
    }

    static func fits(prompt: String, maximumInputTokens: Int) -> Bool {
        estimatedInputTokens(prompt: prompt) <= maximumInputTokens
    }
}
