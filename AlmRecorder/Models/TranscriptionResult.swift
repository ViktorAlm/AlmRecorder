import Foundation

/// Speaker embedding data for re-clustering
struct TranscriptionSpeakerEmbedding {
    let speakerId: String
    let embedding: [Float]
    let startTime: TimeInterval
    let endTime: TimeInterval
    let confidence: Float
}

/// Structured transcription result that preserves chunk boundaries and timing
struct TranscriptionResult {
    /// The complete transcript text
    let fullTranscript: String
    
    /// Individual chunks with their timing and text
    let chunks: [TranscriptionChunk]
    
    /// Total duration of the audio
    let totalDuration: TimeInterval
    
    /// Language detected or specified
    let language: String?
    
    /// Whether VAD was used for chunking
    let usedVAD: Bool
    
    /// Number of unique speakers detected
    var detectedSpeakerCount: Int?
    
    /// Speaker embeddings for re-clustering if needed
    var speakerEmbeddings: [TranscriptionSpeakerEmbedding]?
}

/// Individual transcription chunk with timing information
struct TranscriptionChunk {
    /// The transcribed text for this chunk
    let text: String
    
    /// Start time in seconds from beginning of audio
    let startTime: TimeInterval
    
    /// End time in seconds from beginning of audio  
    let endTime: TimeInterval
    
    /// Optional speaker identifier if diarization was performed
    var speaker: String?
    
    /// Optional speaker UUID for persistent speaker identification
    var speakerUUID: String?

    /// Original recording-local label emitted by the ASR engine before AlmRecorder speaker fusion.
    /// This is diagnostic provenance only and must never be treated as a cross-recording identity.
    var nativeSpeakerLabel: String? = nil

    /// Optional 256-dim voice embedding (WeSpeaker) of the diarization turn that best overlaps this
    /// chunk. Persisted per-utterance so we can later detect/fix mis-assigned lines.
    var voiceEmbedding: [Float]?

    /// Quality supplied by the diarizer for the selected voice embedding.
    var voiceEmbeddingQuality: Float? = nil

    /// Fraction of this chunk where two or more diarizer speakers are active. Offline VBx can
    /// represent simultaneous speech; keeping that evidence prevents an overlap-heavy excerpt
    /// from being used as clean global-speaker enrollment.
    var speakerOverlapRatio: Float = 0

    /// Maximum number of diarizer speakers active at once inside this chunk.
    var activeSpeakerCount: Int = 1

    /// Recording-local labels heard during overlapping speech. The primary `speaker` remains the
    /// exclusive display label, while this list preserves the non-exclusive diarization evidence.
    var overlappingSpeakerLabels: [String] = []

    /// Provenance of the current speaker label/UUID.
    var speakerAssignmentSource: String = SpeakerAssignmentSource.model.rawValue

    /// Confidence score if available
    let confidence: Float?

    /// Whisper per-token probability aggregate for the invocation that produced this chunk
    /// (`-ojf` sidecar). nil on non-whisper backends and legacy paths.
    var tokenStats: WhisperTokenStats? = nil

    /// Duration of this chunk
    var duration: TimeInterval {
        endTime - startTime
    }
}

extension TranscriptionResult {
    /// Create a simple result from just text (no chunks)
    static func fromText(_ text: String, language: String? = nil) -> TranscriptionResult {
        return TranscriptionResult(
            fullTranscript: text,
            chunks: [],
            totalDuration: 0,
            language: language,
            usedVAD: false
        )
    }
    
    /// Build full transcript from chunks
    static func fromChunks(_ chunks: [TranscriptionChunk], language: String? = nil) -> TranscriptionResult {
        let fullText = chunks.map { $0.text }.joined(separator: " ")
        let totalDuration = chunks.last?.endTime ?? 0
        
        return TranscriptionResult(
            fullTranscript: fullText,
            chunks: chunks,
            totalDuration: totalDuration,
            language: language,
            usedVAD: true
        )
    }
}
