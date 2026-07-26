import Foundation

// MARK: - Speaker Review Data Models

/// Represents a detected speaker from transcription that needs review
struct DetectedSpeaker: Identifiable {
    let id = UUID()
    let tempId: String // Temporary ID from transcription (e.g., "SPEAKER_00")
    let chunks: [TranscriptionChunk]
    let embedding: [Float]
    let totalDuration: TimeInterval
    let utteranceCount: Int
    var exampleSegments: [AudioSegment] = []

    /// Global display name for the wizard header. On-demand (merge) mode sets this to the
    /// SpeakerProfile.displayName so the card shows the name / stable "Speaker <uuid8>" instead of a
    /// raw UUID. Post-transcription review leaves it nil — `tempId` is the in-recording local label,
    /// which is meaningful within the single recording being reviewed.
    var resolvedName: String? = nil

    /// Assignment decision made by user
    var assignment: SpeakerAssignment?

    /// Label shown in the wizard header: the resolved global name when available, else the temp id.
    var displayLabel: String { (resolvedName?.isEmpty == false) ? resolvedName! : tempId }

    /// Avatar initials derived from `displayLabel` (so they match the shown name).
    var displayInitials: String {
        let parts = displayLabel.split(separator: " ")
        if parts.count >= 2 { return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased() }
        return String(displayLabel.prefix(2)).uppercased()
    }

    /// Computed properties
    var formattedDuration: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: totalDuration) ?? "0s"
    }
    
    /// Get the longest continuous segment for preview
    var longestSegment: TranscriptionChunk? {
        chunks.max { $0.duration < $1.duration }
    }
    
    /// Get a representative text sample
    var sampleText: String {
        // Find a chunk with reasonable length (not too short, not too long)
        let idealLength = 50...150
        let goodChunk = chunks.first { 
            idealLength.contains($0.text.count) 
        } ?? chunks.first
        
        return goodChunk?.text ?? "No text available"
    }
}

/// Audio segment for playback
struct AudioSegment: Identifiable {
    let id = UUID()
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let speakerTempId: String
    var audioData: Data? // Cached audio data
    
    var duration: TimeInterval {
        endTime - startTime
    }
    
    var formattedTimeRange: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        
        let start = formatter.string(from: startTime) ?? "0:00"
        let end = formatter.string(from: endTime) ?? "0:00"
        
        return "\(start) - \(end)"
    }
}

/// Potential speaker match from database
struct SpeakerMatch: Identifiable {
    var id: String { profile.uuid }
    let profile: SpeakerProfile
    let similarity: Float // Cosine similarity score (0-1)
    let exampleRecordings: [RecordingReference]
    
    var similarityPercentage: Int {
        Int(similarity * 100)
    }
    
    var isHighConfidence: Bool {
        similarity >= 0.85
    }
    
    var isMediumConfidence: Bool {
        similarity >= 0.70 && similarity < 0.85
    }
}

/// Reference to a recording where speaker appears
struct RecordingReference: Identifiable {
    let id: Int
    let title: String
    let date: Date
    let audioFilePath: String?
    let speakerDuration: TimeInterval
    
    var formattedDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// User's assignment decision for a detected speaker
enum SpeakerAssignment {
    case existing(speakerUUID: String, speakerName: String)
    case new(name: String, notes: String?)
    case skip // Don't assign, leave as unknown
    
    var displayName: String {
        switch self {
        case .existing(_, let name):
            return name
        case .new(let name, _):
            return name.isEmpty ? "New Speaker" : name
        case .skip:
            return "Skipped"
        }
    }
}

/// Session data for speaker review wizard
struct SpeakerReviewSession {
    let id = UUID()
    let recordingId: Int64
    let audioFilePath: String
    let detectedSpeakers: [DetectedSpeaker]
    let transcriptionResult: TranscriptionResult
    var assignments: [String: SpeakerAssignment] = [:] // tempId -> assignment
    let createdAt = Date()
    
    /// Check if all speakers have been reviewed
    var allSpeakersReviewed: Bool {
        detectedSpeakers.allSatisfy { speaker in
            assignments[speaker.tempId] != nil
        }
    }
    
    /// Get speakers that still need review
    var unreviewedSpeakers: [DetectedSpeaker] {
        detectedSpeakers.filter { speaker in
            assignments[speaker.tempId] == nil
        }
    }
    
    /// Count of speakers assigned to existing profiles
    var existingAssignments: Int {
        assignments.values.filter { 
            if case .existing = $0 { return true }
            return false
        }.count
    }
    
    /// Count of new speakers to create
    var newSpeakers: Int {
        assignments.values.filter {
            if case .new = $0 { return true }
            return false
        }.count
    }
}

/// Result of applying speaker assignments
struct SpeakerAssignmentResult {
    let recordingId: Int64
    let speakerMappings: [String: String] // tempId -> final UUID
    let newSpeakersCreated: Int
    let existingMatches: Int
    let skipped: Int
}