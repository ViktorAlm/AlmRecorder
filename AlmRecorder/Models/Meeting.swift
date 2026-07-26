import Foundation

/// Represents a cached Apple Calendar event
struct Meeting: Codable, Identifiable {
    let id: Int64?
    let calendarEventId: String
    let title: String
    let startDate: Date
    let endDate: Date
    let calendarName: String?
    let calendarColor: String?
    let location: String?
    let notes: String?
    let attendees: String?  // JSON array of names/emails
    let isRecurring: Bool
    let lastSyncedAt: Date

    var formattedTimeRange: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let start = formatter.string(from: startDate)
        let end = formatter.string(from: endDate)
        return "\(start) – \(end)"
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: startDate)
    }

    var duration: TimeInterval {
        endDate.timeIntervalSince(startDate)
    }

    var formattedDuration: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? "--"
    }

    /// Attendees as name+email. Tolerant of both formats: the new `[{name,email}]` and legacy
    /// `["name"]` rows (the meetings cache self-heals to the new shape on the next calendar sync).
    var parsedParticipants: [MeetingAttendee] {
        guard let attendees, let data = attendees.data(using: .utf8) else { return [] }
        if let list = try? JSONDecoder().decode([MeetingAttendee].self, from: data) {
            return list
        }
        if let names = try? JSONDecoder().decode([String].self, from: data) {
            return names.map { MeetingAttendee(name: $0, email: nil) }
        }
        return []
    }

    /// Names only — kept for existing callers; derived from `parsedParticipants`.
    var parsedAttendees: [String] {
        parsedParticipants.map(\.name)
    }
}
