import Foundation

/// A calendar attendee for the meeting linked to the recording under review.
struct AttendeeInfo: Equatable {
    let name: String
    let email: String?
    /// The speaker this attendee is already mapped to (speaker_attendee_mappings), if any.
    let mappedSpeakerUuid: String?
}

/// A voice-embedding match against the identity DB (from SpeakerIdentificationService).
struct VoiceMatch: Equatable {
    let speakerUuid: String
    let displayName: String
    let similarity: Float
}

/// A ranked speaker suggestion shown in the review wizard.
struct SpeakerSuggestion: Equatable, Identifiable {
    enum Kind: Equatable {
        /// Assign/merge to an existing speaker.
        case existingSpeaker(uuid: String)
        /// Create a new speaker named from a calendar attendee.
        case newFromAttendee(name: String)
    }

    let title: String          // display name
    let kind: Kind
    let reason: String         // e.g. "Voice 92% · in this meeting"
    let inMeeting: Bool        // attendee of the linked meeting
    let similarity: Float?     // present when voice-based
    let score: Double          // ranking (higher first)

    var id: String {
        switch kind {
        case .existingSpeaker(let uuid): return "existing:\(uuid)"
        case .newFromAttendee(let name): return "new:\(name)"
        }
    }
}

/// Fuses voice matches with the meeting's calendar attendees into ranked suggestions.
///
/// Ranking (calendar membership is the primary signal, voice orders within it):
///   voice + calendar  >  calendar-only (mapped)  >  new-from-attendee  >  voice-only
enum SpeakerSuggestionRanker {
    /// `extra` is an optional cross-meeting inference for THIS voice (from the global identity engine) —
    /// surfaced as a top suggestion when the person isn't already covered by the meeting's attendees/voice.
    static func rank(voiceMatches: [VoiceMatch], attendees: [AttendeeInfo], extra: SpeakerSuggestion? = nil) -> [SpeakerSuggestion] {
        // Map mapped-speaker-uuid -> attendee, so we can tell which voice matches are on the invite.
        var attendeeByUuid: [String: AttendeeInfo] = [:]
        for a in attendees {
            if let uuid = a.mappedSpeakerUuid { attendeeByUuid[uuid] = a }
        }

        var suggestions: [SpeakerSuggestion] = []
        var coveredUuids = Set<String>()

        // 1) Voice matches — some are also meeting attendees.
        for match in voiceMatches {
            let attendee = attendeeByUuid[match.speakerUuid]
            let inMeeting = attendee != nil
            let pct = Int((match.similarity * 100).rounded())
            let reason = inMeeting ? "Voice \(pct)% · in this meeting" : "Voice \(pct)%"
            let score = (inMeeting ? 100.0 : 0.0) + Double(match.similarity)
            suggestions.append(SpeakerSuggestion(
                title: attendee?.name ?? match.displayName,
                kind: .existingSpeaker(uuid: match.speakerUuid),
                reason: reason,
                inMeeting: inMeeting,
                similarity: match.similarity,
                score: score
            ))
            coveredUuids.insert(match.speakerUuid)
        }

        // 2) Attendees not already covered by a voice match.
        for a in attendees {
            if let uuid = a.mappedSpeakerUuid {
                guard !coveredUuids.contains(uuid) else { continue } // already listed via voice
                suggestions.append(SpeakerSuggestion(
                    title: a.name,
                    kind: .existingSpeaker(uuid: uuid),
                    reason: "In this meeting",
                    inMeeting: true,
                    similarity: nil,
                    score: 80
                ))
                coveredUuids.insert(uuid)
            } else {
                suggestions.append(SpeakerSuggestion(
                    title: a.name,
                    kind: .newFromAttendee(name: a.name),
                    reason: "In this meeting · new",
                    inMeeting: true,
                    similarity: nil,
                    score: 70
                ))
            }
        }

        // 3) A cross-meeting inference for this voice — added unless the person is already on the list
        // (same speaker, or same name as an attendee/voice suggestion).
        if let extra, !suggestions.contains(where: { $0.kind == extra.kind || $0.title.lowercased() == extra.title.lowercased() }) {
            suggestions.append(extra)
        }

        return suggestions.sorted { $0.score != $1.score ? $0.score > $1.score : $0.title < $1.title }
    }
}
