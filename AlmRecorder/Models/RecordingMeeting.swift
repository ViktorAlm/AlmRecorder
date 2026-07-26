import Foundation

/// Represents a link between a recording and a calendar meeting
struct RecordingMeeting: Codable, Identifiable {
    let id: Int64?
    let recordingId: Int64
    let meetingId: Int64
    let linkType: LinkType
    let matchConfidence: MatchConfidence
    let isDismissed: Bool

    enum LinkType: String, Codable {
        case auto = "auto"
        case manual = "manual"
    }

    /// Confidence level for how closely a recording matches a calendar meeting.
    /// Higher confidence means tighter time overlap.
    enum MatchConfidence: String, Codable, CaseIterable, Comparable {
        /// 5-minute buffer overlap — strong match
        case matched = "matched"
        /// 45-minute buffer overlap — likely match
        case suggested = "suggested"
        /// Same-day / 12-hour window — weak match
        case possible = "possible"

        // MARK: Comparable

        /// Ordering: matched > suggested > possible (higher confidence is "greater")
        private var sortOrder: Int {
            switch self {
            case .matched: return 2
            case .suggested: return 1
            case .possible: return 0
            }
        }

        static func < (lhs: MatchConfidence, rhs: MatchConfidence) -> Bool {
            lhs.sortOrder < rhs.sortOrder
        }
    }

    init(
        id: Int64? = nil,
        recordingId: Int64,
        meetingId: Int64,
        linkType: LinkType,
        matchConfidence: MatchConfidence = .matched,
        isDismissed: Bool = false
    ) {
        self.id = id
        self.recordingId = recordingId
        self.meetingId = meetingId
        self.linkType = linkType
        self.matchConfidence = matchConfidence
        self.isDismissed = isDismissed
    }
}
