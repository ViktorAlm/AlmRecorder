import Foundation

enum SpeakerAssignmentSource: String, Codable, Sendable {
    case model
    case sourceAnchor = "source_anchor"
    case manual
    case reviewCarryover = "review_carryover"
    /// Cross-recording identity assignment made by the evidence-backed global linker.
    case globalAutomatic = "global_automatic"
    /// Cross-recording identity assignment explicitly confirmed by a user.
    case globalManual = "global_manual"
}

/// The state of one immutable recording-local voice cluster's assignment to a global person.
/// The local cluster survives every global merge/unmerge; only this projection changes.
enum GlobalSpeakerAssignmentState: String, Codable, Sendable {
    /// A recording-local fragment that has not yet accumulated enough cross-recording evidence.
    case isolated
    /// Imported from the pre-v31 destructive speaker model. Kept, but not treated as human truth.
    case legacy
    /// Reversible automatic global link backed by stored score/margin/support evidence.
    case automatic
    /// Explicit user decision. This is locked enrollment evidence.
    case manual
    /// Whole-conversation gold confirmation. This is locked enrollment evidence.
    case gold

    var isTrustedEnrollment: Bool {
        switch self {
        case .manual, .gold: return true
        case .isolated, .legacy, .automatic: return false
        }
    }
}

enum GlobalSpeakerLinkSource: String, Codable, Sendable {
    case automatic
    case manual
    case migration
}

enum RecordingSpeakerReviewStatus: String, Codable, Sendable {
    case inProgress = "in_progress"
    case needsCorrection = "needs_correction"
    /// Explicit whole-conversation confirmation after reviewing the visible utterance labels.
    case gold
    /// Historical speaker-wizard value. It confirmed cluster identities, not every turn, and is
    /// deliberately never admitted to the automatic gold set.
    case complete
}

enum MeetingTrackSource: String, Codable, Sendable {
    case microphone
    case system
    case mixed
    case unknown

    static func classify(fileName: String) -> MeetingTrackSource {
        let stem = URL(fileURLWithPath: fileName)
            .deletingPathExtension()
            .lastPathComponent
            .lowercased()
        if stem.hasSuffix("_mic") { return .microphone }
        if stem.hasSuffix("_system") { return .system }
        return .unknown
    }
}
