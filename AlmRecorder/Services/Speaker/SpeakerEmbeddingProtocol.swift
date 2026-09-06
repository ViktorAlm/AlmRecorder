import Foundation

/// Protocol for speaker embedding services
protocol SpeakerEmbeddingService {
    /// Extract speaker embedding from audio file
    func extractEmbedding(from audioURL: URL) async throws -> SpeakerEmbedding
    
    /// Compare two embeddings for similarity
    func similarity(_ embedding1: [Float], _ embedding2: [Float]) -> Float
    
    /// Check if two embeddings are from the same speaker
    func isSameSpeaker(_ embedding1: [Float], _ embedding2: [Float], threshold: Float) -> Bool
}

/// Common speaker embedding structure
struct SpeakerEmbedding {
    let vector: [Float]
    let audioPath: String
    let duration: TimeInterval
    let confidence: Float
    
    var dimension: Int { vector.count }
}

// Extension to make FluidAudioEmbeddingService conform to the protocol
extension FluidAudioEmbeddingService: SpeakerEmbeddingService {
    // Already implements the protocol methods correctly
}
