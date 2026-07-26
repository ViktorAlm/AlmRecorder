import Foundation

/// One meeting's identity context: who was *invited* (calendar attendees) and which persistent voices
/// were actually *recorded* in it (collapsed across all recordings linked to the meeting).
struct MeetingContext: Equatable {
    let meetingId: Int64
    let confidence: RecordingMeeting.MatchConfidence
    let attendees: [MeetingAttendee]
    let voiceUuids: [String]
}

/// The device owner ("you"): which voice is yours, and who you are on the calendar. Any field may be nil
/// when undetermined. The owner is the anchor for inference and is never proposed as someone else.
struct OwnerIdentity: Equatable {
    let speakerUuid: String?
    let name: String?
    let email: String?

    static let none = OwnerIdentity(speakerUuid: nil, name: nil, email: nil)
}

/// A proposed identity for a voice: "voice `speakerUuid` is the person `attendeeName`", with how sure we
/// are and a human-readable reason mirroring `SpeakerSuggestion.reason`.
struct IdentityInference: Equatable {
    let speakerUuid: String
    let attendeeName: String
    let attendeeEmail: String?
    let confidence: Tier
    let reason: String
    /// Coverage (0–1): the fraction of *this voice's* meetings the attendee also attended — shown as a
    /// confidence %. Deductive (`.forced`) matches use 1.0. EXCLUDED from `==` so it never affects
    /// identity-equality unit tests.
    var score: Double = 0

    static func == (lhs: IdentityInference, rhs: IdentityInference) -> Bool {
        lhs.speakerUuid == rhs.speakerUuid && lhs.attendeeName == rhs.attendeeName
            && lhs.attendeeEmail == rhs.attendeeEmail && lhs.confidence == rhs.confidence && lhs.reason == rhs.reason
    }

    /// Ordered weakest→strongest. `.forced` = logically certain (owner anchor / 1:1 deduction).
    enum Tier: Int, Comparable {
        case weak = 0, likely, strong, forced
        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }
}

/// Pure, deterministic identity inference. No DB, no I/O — the coordinator fetches inputs and applies the
/// results. Strongest evidence first: deductive propagation, then confidence-weighted statistical scoring.
enum SpeakerIdentityInferenceEngine {
    static func infer(
        meetings: [MeetingContext],
        existingMappings: [SpeakerAttendeeMapping] = [],
        owner: OwnerIdentity = .none,
        minConfidence: IdentityInference.Tier = .likely
    ) -> [IdentityInference] {
        // voice -> the attendee a voice is already pinned to (owner + manual mappings); and the set of
        // attendee identities already taken. Seeds the deduction so the owner is never a candidate.
        var knownVoiceKey: [String: String] = [:]
        var claimedKeys: Set<String> = []
        if let ownerKey = Self.attendeeKey(name: owner.name, email: owner.email) {
            if let ownerVoice = owner.speakerUuid { knownVoiceKey[ownerVoice] = ownerKey }
            claimedKeys.insert(ownerKey)
        }
        for m in existingMappings {
            let k = Self.attendeeKey(name: m.attendeeName, email: m.attendeeEmail) ?? m.attendeeName.lowercased()
            knownVoiceKey[m.speakerUuid] = k
            claimedKeys.insert(k)
        }

        var inferences: [IdentityInference] = []

        // Layer 1 — deductive 1:1 anchor: in a meeting where exactly one voice and one attendee remain
        // unidentified, that voice *must* be that attendee. Each deduction can remove a name from another
        // meeting, so iterate to a fixpoint (repeat until a full pass assigns nothing new).
        var changed = true
        while changed {
            changed = false
            for m in meetings {
                let unknownVoices = m.voiceUuids.filter { $0 != owner.speakerUuid && knownVoiceKey[$0] == nil }
                let unknownAttendees = m.attendees.filter { att in
                    guard let k = Self.attendeeKey(name: att.name, email: att.email) else { return false }
                    return !claimedKeys.contains(k)
                }
                guard unknownVoices.count == 1, unknownAttendees.count == 1, let attendee = unknownAttendees.first else {
                    continue
                }
                let voice = unknownVoices[0]
                let k = Self.attendeeKey(name: attendee.name, email: attendee.email)!
                let person = Self.attendeeDisplayName(attendee)
                knownVoiceKey[voice] = k
                claimedKeys.insert(k)
                inferences.append(IdentityInference(
                    speakerUuid: voice,
                    attendeeName: person,
                    attendeeEmail: attendee.email,
                    confidence: .forced,
                    reason: Self.forcedReason(meeting: m, person: person),
                    score: 1.0
                ))
                changed = true
            }
        }

        // Layer 2 — statistical scoring: for voices deduction couldn't pin, rank each candidate attendee by
        // how well their attendance tracks the voice's appearances, then assign greedily one-to-one so no
        // attendee or voice is claimed twice.
        //
        // We rank by COVERAGE — the fraction of *this voice's* meetings the attendee also attended — not by
        // symmetric Jaccard. Jaccard's union term punishes frequent contacts: the colleague you actually meet
        // with constantly attends many *other* meetings too, which inflates the union and sinks their score
        // below a near-stranger who happens to share one small meeting (the real bug — a voice in 24 meetings
        // whose true identity attends 11 of them lost to someone in 3 meetings total). Coverage asks the
        // question the user reasons about ("of the times I recorded this voice, how often was this person
        // there?"). To also reward corroboration, the greedy sorts by coverage × shared-count, so a
        // high-coverage fluke from a single co-occurrence can't outbid a well-attested match for the same
        // person. `specificity` (how exclusive the attendee is to this voice) guards auto-apply against
        // ubiquitous "attends everything" invitees.
        var voiceMeetings: [String: [Int64: Double]] = [:]    // voice -> (meetingId -> weight)
        var attendeeMeetings: [String: [Int64: Double]] = [:] // attendeeKey -> (meetingId -> weight)
        var attendeeByKey: [String: MeetingAttendee] = [:]
        for m in meetings {
            let w = Self.weight(m.confidence)
            for v in Set(m.voiceUuids) { voiceMeetings[v, default: [:]][m.meetingId] = w }
            for a in m.attendees {
                guard let k = Self.attendeeKey(name: a.name, email: a.email) else { continue }
                attendeeMeetings[k, default: [:]][m.meetingId] = w
                if attendeeByKey[k] == nil { attendeeByKey[k] = a }
            }
        }

        struct Cand {
            let voice: String, key: String
            let coverage: Double    // inter / voiceWeight  — fraction of the voice's meetings the attendee attends
            let specificity: Double // inter / attendeeWeight — how exclusive the attendee is to this voice
            let rank: Double        // coverage × shared    — coverage, biased toward more corroboration
            let shared: Int, total: Int
        }
        var cands: [Cand] = []
        for (voice, vMeet) in voiceMeetings where voice != owner.speakerUuid && knownVoiceKey[voice] == nil {
            let vWeight = vMeet.values.reduce(0, +)
            guard vWeight > 0 else { continue }
            for (key, aMeet) in attendeeMeetings where !claimedKeys.contains(key) {
                var inter = 0.0, shared = 0
                for (id, vw) in vMeet where aMeet[id] != nil { inter += max(vw, aMeet[id] ?? 0); shared += 1 }
                guard inter > 0 else { continue }
                let aWeight = aMeet.values.reduce(0, +)
                let coverage = inter / vWeight
                cands.append(Cand(
                    voice: voice, key: key,
                    coverage: coverage,
                    specificity: aWeight > 0 ? inter / aWeight : 0,
                    rank: coverage * Double(shared),
                    shared: shared, total: vMeet.count
                ))
            }
        }
        // Greedy: best evidence first (coverage × corroboration), then most exclusive, then most shared;
        // deterministic tie-break by voice then attendee key.
        cands.sort {
            if $0.rank != $1.rank { return $0.rank > $1.rank }
            if $0.specificity != $1.specificity { return $0.specificity > $1.specificity }
            if $0.shared != $1.shared { return $0.shared > $1.shared }
            if $0.voice != $1.voice { return $0.voice < $1.voice }
            return $0.key < $1.key
        }
        // Best rival (a DIFFERENT attendee) per voice — people who co-attend everything are
        // indistinguishable by attendance, and confidently picking one of them is exactly the
        // "you = your most frequent colleague" failure. A near-tie demotes the winner.
        var bestRivals: [String: [(rank: Double, key: String)]] = [:]
        for c in cands {
            var list = bestRivals[c.voice] ?? []
            if list.count < 2, !list.contains(where: { $0.key == c.key }) {
                list.append((c.rank, c.key))
                bestRivals[c.voice] = list
            }
        }

        for c in cands {
            guard knownVoiceKey[c.voice] == nil, !claimedKeys.contains(c.key), let attendee = attendeeByKey[c.key] else {
                continue
            }
            knownVoiceKey[c.voice] = c.key
            claimedKeys.insert(c.key)
            // Tier by coverage. `.strong` is the only auto-applied statistical tier, so it's the strictest:
            // the attendee must attend most of the voice's meetings (≥0.7), be corroborated across ≥2 of them
            // (a single shared meeting is coincidental), and be reasonably exclusive to this voice (≥0.5 — so a
            // ubiquitous invitee who attends everything is demoted to a suggestion rather than auto-named).
            var tier: IdentityInference.Tier
            if c.coverage >= 0.7 && c.shared >= 2 && c.specificity >= 0.5 {
                tier = .strong
            } else if c.coverage >= 0.4 {
                tier = .likely
            } else {
                tier = .weak
            }

            // Ambiguity margin: when another attendee tracks this voice almost as well (within
            // 15%), attendance can't tell them apart — never auto-apply (strong → likely) and
            // say who else it could be. The LLM transcript check or the user breaks the tie.
            var reason = "In \(c.shared) of this voice's \(c.total) meeting\(c.total == 1 ? "" : "s")"
            if let rival = bestRivals[c.voice]?.first(where: { $0.key != c.key }),
               rival.rank >= c.rank * 0.85,
               let rivalAttendee = attendeeByKey[rival.key] {
                if tier == .strong { tier = .likely }
                reason += " — could also be \(Self.attendeeDisplayName(rivalAttendee))"
            }

            inferences.append(IdentityInference(
                speakerUuid: c.voice,
                attendeeName: Self.attendeeDisplayName(attendee),
                attendeeEmail: attendee.email,
                confidence: tier,
                reason: reason,
                score: c.coverage
            ))
        }

        // Honor the caller's surfacing bar: auto-apply (recompute) and the unit tests use the default
        // `.likely`, dropping noisy `.weak` best-guesses; the inbox/profile pass `.weak` to also show clearly
        // labelled low-confidence guesses ("who's most likely"). `.forced` deductions always clear the bar.
        return inferences.filter { $0.confidence >= minConfidence }
    }

    /// Display name for an attendee: their name, or the email when the calendar provided no name. Never
    /// blank — a blank "Might be …" suggestion is worse than showing the email.
    static func attendeeDisplayName(_ a: MeetingAttendee) -> String {
        let name = a.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return a.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Per-meeting evidence weight from its recording↔meeting link confidence.
    static func weight(_ c: RecordingMeeting.MatchConfidence) -> Double {
        switch c {
        case .matched: return 1.0
        case .suggested: return 0.6
        case .possible: return 0.3
        }
    }

    // MARK: - Helpers

    /// Stable identity key for an attendee: email (lowercased) when present, else normalized name.
    /// Mirrors `MeetingSuggestionProvider`'s dedup rule. Returns nil when both are empty.
    static func attendeeKey(name: String?, email: String?) -> String? {
        if let e = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !e.isEmpty { return e }
        if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !n.isEmpty { return n }
        return nil
    }

    private static func forcedReason(meeting: MeetingContext, person: String) -> String {
        meeting.attendees.count == 2
            ? "Only unidentified person in your 1:1 with \(person)"
            : "Only unidentified person in a \(meeting.attendees.count)-person meeting"
    }
}
