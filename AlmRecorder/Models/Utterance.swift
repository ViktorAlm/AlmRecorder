import Foundation

/// Represents a segment/utterance within a recording
struct Utterance: Codable, Identifiable {
    let id: Int64?
    let recordingId: Int64
    let utteranceIndex: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let speaker: String?
    let speakerUuid: String?
    let text: String
    let confidence: Float?
    var hasEmbedding: Bool = false

    // Transcript-cleanup provenance (migration v24). Defaults describe a pristine ASR row,
    // so existing call sites of the memberwise init keep compiling unchanged.
    var originalText: String? = nil      // pre-rewrite text; nil = never rewritten
    var textSource: String = "asr"       // UtteranceTextSource rawValue
    var isHidden: Bool = false           // soft delete — excluded from transcript + search
    var asrMinP: Float? = nil            // min whisper token probability
    var asrLowFrac: Float? = nil         // fraction of tokens with p < 0.4
    var suspicion: Double? = nil         // last detector score 0…1
    var suspicionReasons: String? = nil  // JSON array of TranscriptSuspicionScorer.Reason rawValues
    var reviewStatus: String? = nil      // UtteranceReviewStatus rawValue
    var verifierResult: String? = nil    // JSON verdict from the Gemma verification pass
    var reviewedAt: Date? = nil

    // Speaker-identification provenance (migration v28).
    var audioSource: String? = nil
    var speakerAssignmentSource: String = SpeakerAssignmentSource.model.rawValue
    var speakerReviewedAt: Date? = nil
    var voiceEmbeddingQuality: Float? = nil
    /// Fraction of this utterance covered by simultaneous diarizer speakers.
    var speakerOverlapRatio: Float = 0
    /// Maximum number of diarizer speakers active at once in the utterance.
    var activeSpeakerCount: Int = 1
    /// JSON-encoded recording-local labels active during overlap.
    var overlappingSpeakerLabelsJSON: String? = nil
    /// Immutable diarizer identity inside this recording. Unlike `speakerUuid`, global linking
    /// never rewrites this value.
    var localSpeakerLabel: String? = nil
    /// Stable row in `speaker_local_clusters`; populated after v31 reconciliation.
    var localSpeakerClusterId: Int64? = nil

    /// Computed properties
    var duration: TimeInterval {
        endTime - startTime
    }
    
    var formattedTimeRange: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        let start = formatter.string(from: startTime) ?? "00:00"
        let end = formatter.string(from: endTime) ?? "00:00"
        return "\(start) - \(end)"
    }
    
    var formattedDuration: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: duration) ?? "00:00"
    }
    
    /// Preview text for UI display
    var previewText: String {
        let maxLength = 100
        if text.count <= maxLength {
            return text
        }
        return String(text.prefix(maxLength)) + "..."
    }
    
    /// Clean text for embedding generation (remove extra whitespace, etc.)
    var cleanedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

// MARK: - Database Row Conversion
extension Utterance {
    /// Initialize from database row
    init?(row: [String: Any?]) {
        guard let recordingId = row["recording_id"] as? Int64,
              let utteranceIndex = row["utterance_index"] as? Int,
              let startTime = row["start_time"] as? TimeInterval,
              let endTime = row["end_time"] as? TimeInterval,
              let text = row["text"] as? String else {
            return nil
        }
        
        self.id = row["id"] as? Int64
        self.recordingId = recordingId
        self.utteranceIndex = utteranceIndex
        self.startTime = startTime
        self.endTime = endTime
        self.speaker = row["speaker"] as? String
        self.speakerUuid = row["speaker_uuid"] as? String
        self.text = text
        self.confidence = row["confidence"] as? Float
        
        // Handle both Bool and Int types from SQLite (SQLite uses 0/1 for booleans)
        if let boolValue = row["has_embedding"] as? Bool {
            self.hasEmbedding = boolValue
        } else if let intValue = row["has_embedding"] as? Int {
            self.hasEmbedding = intValue != 0
        } else if let int64Value = row["has_embedding"] as? Int64 {
            self.hasEmbedding = int64Value != 0
        } else {
            self.hasEmbedding = false
        }

        self.originalText = row["original_text"] as? String
        self.textSource = (row["text_source"] as? String) ?? "asr"
        if let boolValue = row["is_hidden"] as? Bool {
            self.isHidden = boolValue
        } else if let intValue = row["is_hidden"] as? Int {
            self.isHidden = intValue != 0
        } else if let int64Value = row["is_hidden"] as? Int64 {
            self.isHidden = int64Value != 0
        }
        self.asrMinP = (row["asr_min_p"] as? Float) ?? (row["asr_min_p"] as? Double).map(Float.init)
        self.asrLowFrac = (row["asr_low_frac"] as? Float) ?? (row["asr_low_frac"] as? Double).map(Float.init)
        self.suspicion = row["suspicion"] as? Double
        self.suspicionReasons = row["suspicion_reasons"] as? String
        self.reviewStatus = row["review_status"] as? String
        self.verifierResult = row["verifier_result"] as? String
        self.reviewedAt = row["reviewed_at"] as? Date
        self.audioSource = row["audio_source"] as? String
        self.speakerAssignmentSource = (row["speaker_assignment_source"] as? String)
            ?? SpeakerAssignmentSource.model.rawValue
        self.speakerReviewedAt = row["speaker_reviewed_at"] as? Date
        self.voiceEmbeddingQuality = (row["voice_embedding_quality"] as? Float)
            ?? (row["voice_embedding_quality"] as? Double).map(Float.init)
        self.speakerOverlapRatio = (row["speaker_overlap_ratio"] as? Float)
            ?? (row["speaker_overlap_ratio"] as? Double).map(Float.init)
            ?? 0
        self.activeSpeakerCount = (row["active_speaker_count"] as? Int)
            ?? (row["active_speaker_count"] as? Int64).map(Int.init)
            ?? 1
        self.overlappingSpeakerLabelsJSON = row["overlapping_speaker_labels_json"] as? String
        self.localSpeakerLabel = row["local_speaker_label"] as? String
        self.localSpeakerClusterId = row["local_speaker_cluster_id"] as? Int64
    }
}

// MARK: - Search Result
/// Represents a search result combining utterance with its recording info
struct UtteranceSearchResult {
    let utterance: Utterance
    let recording: Recording
    let distance: Float  // Vector similarity distance (0 = identical, higher = less similar)
    let relevanceScore: Float  // Normalized relevance score (0-1, higher is better)
    
    var formattedDistance: String {
        String(format: "%.2f", distance)
    }
    
    var formattedRelevance: String {
        String(format: "%.0f%%", relevanceScore * 100)
    }
}
