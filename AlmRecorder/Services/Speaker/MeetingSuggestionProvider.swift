import Foundation

/// Loads calendar attendees for the meeting(s) linked to a recording, annotated with any
/// existing speaker↔attendee mapping. Seeds the review wizard's suggestions.
struct MeetingSuggestionProvider {
    private let meetingRepo = GRDBMeetingRepository()
    private let attendeeRepo = GRDBSpeakerAttendeeRepository()

    /// Deduped attendees (by case-insensitive name) across all meetings linked to the recording.
    func attendees(forRecording recordingId: Int64) -> [AttendeeInfo] {
        guard recordingId > 0 else { return [] }
        let meetings = (try? meetingRepo.getMeetingsForRecording(recordingId: recordingId)) ?? []

        var seen = Set<String>()
        var result: [AttendeeInfo] = []
        for meeting in meetings {
            for participant in meeting.parsedParticipants {
                let name = participant.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                // Dedup by email when present (most stable identity), else by lowercased name.
                let key = participant.email?.lowercased() ?? name.lowercased()
                guard seen.insert(key).inserted else { continue }
                let mappedUuid = attendeeRepo.getSpeakerForAttendee(name: name)?.speakerUuid
                result.append(AttendeeInfo(name: name, email: participant.email, mappedSpeakerUuid: mappedUuid))
            }
        }
        return result
    }
}
