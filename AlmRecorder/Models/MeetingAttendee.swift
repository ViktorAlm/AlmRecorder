import Foundation

/// One attendee of a calendar meeting — name plus (when available) email. This is the persisted JSON
/// shape stored in `Meeting.attendees`; it is distinct from the speaker-linking `AttendeeInfo`.
struct MeetingAttendee: Codable, Equatable {
    let name: String
    let email: String?

    /// EventKit doesn't always include the organizer in `event.attendees` (notably for events you
    /// created yourself), which makes them invisible to speaker-identity inference. Merge them in,
    /// deduping by email (case-insensitive) or name. RSVP status is never consulted anywhere —
    /// invitees who haven't responded still count.
    static func mergingOrganizer(into attendees: [MeetingAttendee],
                                 organizerName: String?, organizerEmail: String?) -> [MeetingAttendee] {
        let name = organizerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let email = organizerEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty || email?.isEmpty == false else { return attendees }
        let alreadyListed = attendees.contains { a in
            if let email, !email.isEmpty, a.email?.lowercased() == email.lowercased() { return true }
            return !name.isEmpty && a.name.lowercased() == name.lowercased()
        }
        guard !alreadyListed else { return attendees }
        return attendees + [MeetingAttendee(name: name, email: email?.isEmpty == false ? email : nil)]
    }

    /// Extract an email from an EKParticipant URL.
    /// Returns nil for non-mailto URLs so non-person participants (rooms, resources) are ignored.
    static func email(from url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "mailto" else { return nil }
        // Take everything after the first colon in the mailto URL.
        let s = url.absoluteString
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let raw = String(s[s.index(after: colon)...])
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
