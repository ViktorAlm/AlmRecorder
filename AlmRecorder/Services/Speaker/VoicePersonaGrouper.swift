import Foundation

/// Groups persistent voice clusters that are acoustically the SAME PERSON into "personas", so identity
/// inference (and anything else) stops assuming one person == one cluster.
///
/// Diarization over-splits: a single person routinely lands in several clusters — across recordings, or
/// even *within one recording* when their voiceprint shifts mid-call (they walk from a quiet room into a
/// noisy car, switch from laptop to phone, etc.). Crucially that means two clusters of the same person can
/// be recorded *together* in one meeting, so "were they ever in the same meeting?" is NOT evidence that two
/// clusters are different people — the only reliable signal is acoustic similarity. We therefore group
/// purely by embedding cosine and never use co-occurrence.
///
/// Pure and deterministic. Supports the original single-linkage union-find and conservative complete
/// linkage, where every member must match every other member. The threshold sits just below the cross-recording
/// assignment bar (0.85) so it reclaims near-miss splits, while staying well clear of the different-speaker
/// range — fusing two distinct people (one would inherit the other's identity) is the costlier error, so we
/// bias toward leaving a borderline pair split.
enum VoicePersonaGrouper {
    /// Cosine bar for "same person". Tunable: lower catches more drift (e.g. the in-the-car case) but risks
    /// fusing distinct voices; higher is safer but leaves more over-split. Single-linkage can chain
    /// (A~B, B~C ⟹ {A,B,C} even if A≁C), which is why the bar is kept conservative.
    static let sameSpeakerThreshold: Float = 0.8

    /// One persona — the set of voice UUIDs judged to be the same person. `id` is a stable representative
    /// (the lexicographically smallest member) so callers can key on it deterministically.
    struct Persona: Equatable {
        let id: String
        let members: [String]   // sorted ascending; always contains `id` as its first element
        var isSplit: Bool { members.count > 1 }
    }

    /// Group voices into personas. A voice with an empty / zero / dimension-mismatched centroid never
    /// matches (cosine returns 0) and comes back as its own singleton, so a speaker lacking an embedding is
    /// left exactly as-is.
    static func group(
        _ voices: [(uuid: String, centroid: [Float])],
        threshold: Float = sameSpeakerThreshold,
        linkage: PersonaLinkage = .single
    ) -> [Persona] {
        switch linkage {
        case .single:
            return singleLinkage(voices, threshold: threshold)
        case .complete:
            return completeLinkage(voices, threshold: threshold)
        }
    }

    private static func singleLinkage(
        _ voices: [(uuid: String, centroid: [Float])],
        threshold: Float
    ) -> [Persona] {
        let n = voices.count
        guard n > 0 else { return [] }

        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }

        for i in 0..<n {
            for j in (i + 1)..<n where SpeakerUnifier.cosine(voices[i].centroid, voices[j].centroid) >= threshold {
                union(i, j)
            }
        }

        var groups: [Int: [String]] = [:]
        for i in 0..<n { groups[find(i), default: []].append(voices[i].uuid) }
        return groups.values
            .map { members -> Persona in let sorted = members.sorted(); return Persona(id: sorted[0], members: sorted) }
            .sorted { $0.id < $1.id }
    }

    /// Agglomerative complete linkage prevents the A≈B≈C chaining failure when A and C are
    /// actually different people. Candidate merges are deterministic: strongest minimum pair
    /// similarity first, then lexical member IDs.
    private static func completeLinkage(
        _ voices: [(uuid: String, centroid: [Float])],
        threshold: Float
    ) -> [Persona] {
        guard !voices.isEmpty else { return [] }
        let sortedVoices = voices.sorted { $0.uuid < $1.uuid }
        var groups = sortedVoices.indices.map { [$0] }

        while true {
            var best: (left: Int, right: Int, minimumSimilarity: Float, key: String)?
            for left in groups.indices {
                guard left + 1 < groups.count else { continue }
                for right in (left + 1)..<groups.count {
                    let pairSimilarities = groups[left].flatMap { lhs in
                        groups[right].map { rhs in
                            SpeakerUnifier.cosine(
                                sortedVoices[lhs].centroid,
                                sortedVoices[rhs].centroid
                            )
                        }
                    }
                    guard let minimum = pairSimilarities.min(), minimum >= threshold else { continue }
                    let key = (groups[left] + groups[right])
                        .map { sortedVoices[$0].uuid }
                        .sorted()
                        .joined(separator: "\u{0}")
                    if best == nil
                        || minimum > best!.minimumSimilarity
                        || (minimum == best!.minimumSimilarity && key < best!.key) {
                        best = (left, right, minimum, key)
                    }
                }
            }
            guard let best else { break }
            groups[best.left].append(contentsOf: groups[best.right])
            groups.remove(at: best.right)
        }

        return groups.map { indices in
            let members = indices.map { sortedVoices[$0].uuid }.sorted()
            return Persona(id: members[0], members: members)
        }
        .sorted { $0.id < $1.id }
    }

    /// uuid → persona representative id (every input uuid maps to exactly one id).
    static func representativeMap(_ personas: [Persona]) -> [String: String] {
        var map: [String: String] = [:]
        for p in personas { for m in p.members { map[m] = p.id } }
        return map
    }
}
