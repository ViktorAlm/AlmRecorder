import Foundation

/// Per-voice recording statistics used to detect the device owner.
struct VoiceStats: Equatable {
    let speakerUuid: String
    /// Distinct recordings this voice appears in (overall ubiquity).
    let recordingCount: Int
    /// Recordings where this voice is the *only* speaker (you talking to yourself — strong owner signal).
    let soloMemoCount: Int
}

/// Pure, deterministic owner-voice detection. The owner is the voice that is the lone speaker in the most
/// solo memos, corroborated by overall ubiquity. Returns nil when there is no clear winner, so the caller
/// can ask the user rather than guess wrong (a wrong owner pollutes the whole inference).
enum OwnerVoiceSelector {
    static func selectOwnerVoice(_ stats: [VoiceStats]) -> String? {
        // Solo memos weigh double — they're the cleanest owner signal — plus overall ubiquity.
        func score(_ s: VoiceStats) -> Int { s.soloMemoCount * 2 + s.recordingCount }
        let ranked = stats.map { ($0.speakerUuid, score($0)) }.sorted {
            $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0
        }
        guard let top = ranked.first, top.1 > 0 else { return nil }
        // Require a clear winner: a tie at the top is ambiguous → let the UI ask.
        if ranked.count > 1, ranked[1].1 == top.1 { return nil }
        return top.0
    }
}
