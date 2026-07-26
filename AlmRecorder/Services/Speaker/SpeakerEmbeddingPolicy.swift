import Foundation

/// Single source of truth for the speaker-embedding dimension used by the identity DB.
///
/// The identity DB must hold exactly ONE embedding dimension: cosine similarity between
/// vectors of different lengths is meaningless, so a stray 192-dim Pyannote vector among
/// 256-dim WeSpeaker vectors silently orphans speakers (they can never match again).
/// All writes into the speakers table go through `validate(_:)`.
enum SpeakerEmbeddingPolicy {
    /// WeSpeaker (FluidAudio) embedding size.
    static let dimension = 256

    enum Error: Swift.Error, LocalizedError {
        case dimensionMismatch(got: Int, expected: Int)

        var errorDescription: String? {
            switch self {
            case let .dimensionMismatch(got, expected):
                return "Speaker embedding has \(got) dimensions, expected \(expected). "
                     + "Refusing to write it to the identity DB (would corrupt cross-recording matching)."
            }
        }
    }

    /// Throws if `embedding` is not exactly `dimension` long.
    static func validate(_ embedding: [Float]) throws {
        guard embedding.count == dimension else {
            throw Error.dimensionMismatch(got: embedding.count, expected: dimension)
        }
    }
}
