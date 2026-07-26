import Foundation

/// Shared resolver that turns an utterance into the GLOBAL speaker identity for any DISPLAY,
/// EXPORT, or LLM-PROMPT surface. It mirrors `SpeakerProfile.displayName`:
///
///  - a named global cluster shows its name,
///  - an unnamed-but-clustered one shows the stable `"Speaker <uuid.prefix(8)>"`,
///  - and only an un-clustered utterance (no `speakerUuid`) falls back to the raw local
///    diarization label (`Utterance.speaker`), which is the per-recording, non-stable label.
///
/// The local `Utterance.speaker` label is write-only diarization provenance; it must never be the
/// thing a user sees, copies, exports, or that we feed to an LLM. Build a resolver once (from the
/// speakers table) and pass it into views / use it in services so every surface renders the same
/// stable global identity.
struct SpeakerNameResolver {
    /// uuid -> the speaker's name (only non-empty names belong here).
    let namesByUuid: [String: String]

    init(namesByUuid: [String: String] = [:]) {
        self.namesByUuid = namesByUuid
    }

    /// Canonical label for a clustered uuid: the name when known, else the stable uuid-prefix
    /// placeholder. Identical in spirit to `SpeakerProfile.displayName`.
    func displayName(forUuid uuid: String) -> String {
        if let name = namesByUuid[uuid], !name.isEmpty { return name }
        return "Speaker \(uuid.prefix(8))"
    }

    /// Resolve an utterance. Returns `nil` only when there is neither a uuid nor a local label.
    func displayName(for utterance: Utterance) -> String? {
        displayName(speakerUuid: utterance.speakerUuid, localLabel: utterance.speaker)
    }

    /// Resolve a `(uuid, localLabel)` pair directly — for chunk / Line contexts that don't carry a
    /// full `Utterance`.
    func displayName(speakerUuid: String?, localLabel: String?) -> String? {
        if let uuid = speakerUuid, !uuid.isEmpty {
            return displayName(forUuid: uuid)
        }
        return localLabel
    }
}

/// Builds the persisted `recording.fullTranscript` "[Speaker] text" blob. Used in TWO places that
/// must agree: WhisperService when it WRITES the blob, and RecordingInsightsService when it
/// RE-DERIVES it from utterances for the LLM. Both resolve each segment to its GLOBAL identity so
/// the per-recording local "Speaker N" label never lands in storage or a prompt.
enum LabeledTranscript {
    struct Segment: Equatable {
        let speakerUuid: String?
        let localLabel: String?
        let text: String
    }

    static func render(_ segments: [Segment], resolver: SpeakerNameResolver) -> String {
        segments.map { seg in
            if let label = resolver.displayName(speakerUuid: seg.speakerUuid, localLabel: seg.localLabel) {
                return "[\(label)] \(seg.text)"
            }
            return seg.text
        }.joined(separator: "\n\n")
    }
}

extension SpeakerNameResolver {
    /// Build from loaded UI profiles (indexes only non-empty names).
    init(profiles: [SpeakerProfile]) {
        var map: [String: String] = [:]
        for p in profiles {
            if let n = p.name, !n.isEmpty { map[p.uuid] = n }
        }
        self.init(namesByUuid: map)
    }

    /// Build from DB speaker records (indexes only non-empty names).
    init(speakers: [Speaker]) {
        var map: [String: String] = [:]
        for s in speakers {
            if let n = s.name, !n.isEmpty { map[s.uuid] = n }
        }
        self.init(namesByUuid: map)
    }
}
