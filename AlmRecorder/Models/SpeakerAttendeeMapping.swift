import Foundation

/// A global mapping between a detected speaker voice and a calendar attendee name.
/// Once established, the mapping applies across all meetings.
struct SpeakerAttendeeMapping: Codable, Identifiable {
    let id: Int64?
    let speakerUuid: String
    let attendeeName: String
    let attendeeEmail: String?
    let source: MappingSource
    let createdAt: Date

    enum MappingSource: String, Codable {
        case manual = "manual"
        case inferred = "inferred"
    }

    init(
        id: Int64? = nil,
        speakerUuid: String,
        attendeeName: String,
        attendeeEmail: String? = nil,
        source: MappingSource = .manual,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.speakerUuid = speakerUuid
        self.attendeeName = attendeeName
        self.attendeeEmail = attendeeEmail
        self.source = source
        self.createdAt = createdAt
    }
}
