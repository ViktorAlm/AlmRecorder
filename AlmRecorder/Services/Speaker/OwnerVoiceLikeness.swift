import Foundation

/// Diarization splits the OWNER across many clusters (mic vs system audio, rooms, headsets) and
/// the persona grouper only merges acoustically-near shards. The leftover shards look like
/// "an unknown voice in most meetings" — whose best attendance match is the owner's most
/// frequent colleague. This helper finds candidate voices that
/// SOUND like the owner, so the coordinator proposes them as the owner instead.
enum OwnerVoiceLikeness {

    /// Conservative: 256-dim WeSpeaker cosine ≥ 0.6 is reliably the same speaker.
    static let similarityFloor: Double = 0.6

    /// Voices whose embedding is owner-like, with their similarity.
    static func ownerLikeVoices(voices: [(uuid: String, embedding: [Float])],
                                ownerEmbedding: [Float],
                                floor: Double = similarityFloor) -> [String: Double] {
        guard !ownerEmbedding.isEmpty else { return [:] }
        var result: [String: Double] = [:]
        for voice in voices where voice.embedding.count == ownerEmbedding.count {
            let similarity = cosine(voice.embedding, ownerEmbedding)
            if similarity >= floor {
                result[voice.uuid] = similarity
            }
        }
        return result
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denominator = normA.squareRoot() * normB.squareRoot()
        guard denominator > 0 else { return 0 }
        return Double(dot / denominator)
    }
}
