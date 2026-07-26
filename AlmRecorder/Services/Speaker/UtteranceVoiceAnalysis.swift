import Foundation

/// Per-utterance verdict from comparing its voice vector to speaker means.
struct UtteranceVoiceVerdict {
    let utteranceId: Int
    /// Cosine to the assigned speaker's mean (-1 when the own mean is unknown).
    let selfSim: Float
    /// The non-owner speaker whose mean is closest to this utterance, if any.
    let nearestOtherUuid: String?
    let nearestOtherSim: Float
    /// True when this line probably belongs to someone else (or matches no one well).
    let isSuspect: Bool
    /// Higher = more suspicious; used to sort the "needs review" list.
    let suspectScore: Float
}

/// Pure diarization-QA: flag utterances whose voice doesn't match their assigned speaker, and rank
/// candidate speakers for a reassignment. Uses `SpeakerUnifier.cosine` so it matches the matcher.
enum UtteranceVoiceAnalysis {
    /// - margin: how much better another speaker must match before we flag the line.
    /// - floor: a self-similarity below this is suspicious even if no other speaker is closer.
    static func analyze(
        utterances: [(utteranceId: Int, vec: [Float])],
        ownUuid: String,
        means: [String: [Float]],
        margin: Float = 0.05,
        floor: Float = 0.5
    ) -> [UtteranceVoiceVerdict] {
        let ownMean = means[ownUuid]
        return utterances.map { u in
            let selfSim = ownMean.map { SpeakerUnifier.cosine(u.vec, $0) } ?? -1

            var bestOtherUuid: String?
            var bestOtherSim: Float = -1
            for (uuid, mean) in means where uuid != ownUuid {
                let s = SpeakerUnifier.cosine(u.vec, mean)
                if s > bestOtherSim { bestOtherSim = s; bestOtherUuid = uuid }
            }

            let closerToOther = bestOtherUuid != nil && bestOtherSim > selfSim + margin
            let lowSelf = selfSim >= 0 && selfSim < floor
            let isSuspect = closerToOther || lowSelf
            let score = max(0, bestOtherSim - selfSim) + max(0, floor - max(selfSim, 0)) * 0.5

            return UtteranceVoiceVerdict(
                utteranceId: u.utteranceId,
                selfSim: selfSim,
                nearestOtherUuid: bestOtherUuid,
                nearestOtherSim: bestOtherSim,
                isSuspect: isSuspect,
                suspectScore: score
            )
        }
    }

    /// Candidate speakers for one utterance, ranked by cosine similarity to each speaker's mean (desc).
    static func rankCandidates(vec: [Float], means: [String: [Float]]) -> [(uuid: String, sim: Float)] {
        means.map { (uuid: $0.key, sim: SpeakerUnifier.cosine(vec, $0.value)) }
            .sorted { $0.sim > $1.sim }
    }
}
