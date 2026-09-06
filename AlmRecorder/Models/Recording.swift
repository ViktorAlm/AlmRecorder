import Foundation
import SwiftUI

/// Exact ASR configuration that produced the currently committed transcript. Older recordings
/// legitimately have nil provenance; callers must display that as unknown instead of guessing.
struct RecordingTranscriptionProvenance: Codable, Equatable {
    static let pipelineVersion = 2

    let pipelineVersion: Int
    let engineSelection: TranscriptionEngineSelection
    let runSettings: RunSettings
    let completedAt: Date
    /// Resolved BCP-47/Whisper language code stored on the recording.
    let detectedLanguage: String?
    /// `whisper_audio`, `user_selected`, `transcript_fallback`, or nil for legacy runs.
    let languageDetectionSource: String?
    /// Whisper audio-language probability when auto detection was used.
    let languageDetectionConfidence: Float?

    init(
        engineSelection: TranscriptionEngineSelection,
        runSettings: RunSettings,
        completedAt: Date = Date(),
        detectedLanguage: String? = nil,
        languageDetectionSource: String? = nil,
        languageDetectionConfidence: Float? = nil
    ) {
        self.pipelineVersion = Self.pipelineVersion
        self.engineSelection = engineSelection
        self.runSettings = runSettings
        self.completedAt = completedAt
        self.detectedLanguage = detectedLanguage
        self.languageDetectionSource = languageDetectionSource
        self.languageDetectionConfidence = languageDetectionConfidence
    }
}

/// Represents a complete recording/transcription session
struct Recording: Codable, Identifiable {
    let id: Int64?
    let title: String
    let fileName: String
    let filePath: String?
    let duration: TimeInterval?
    let language: String?
    let createdAt: Date
    let transcribedAt: Date?
    let source: RecordingSource
    let fullTranscript: String?
    let metadata: RecordingMetadata?

    // Speaker-pipeline provenance (migration v28). Defaults keep existing constructors source-compatible.
    var speakerReviewStatus: String? = nil
    var speakerReviewedAt: Date? = nil
    var speakerPipelineProfile: String? = nil
    var speakerPipelineVersion: Int? = nil
    var speakerPipelineConfiguration: SpeakerPipelineConfiguration? = nil

    // Stable public identity and optimistic-concurrency timestamp (migration v35).
    // MCP clients never need to retain the database's internal integer primary key.
    var externalId: String? = nil
    var updatedAt: Date? = nil

    // Local-only MCP privacy control (migration v41). Blocking tags can still
    // make the effective access false when this explicit switch is true.
    var mcpAccessEnabled: Bool = true

    // Exact foreground ASR provenance (migration v42). Nil is honest legacy provenance.
    var transcriptionProvenance: RecordingTranscriptionProvenance? = nil
    
    enum RecordingSource: String, Codable, CaseIterable {
        case recording = "recording"
        case voiceMemos = "voiceMemos" 
        case imported = "imported"
        
        var displayName: String {
            switch self {
            case .recording: return "Recording"
            case .voiceMemos: return "Voice Memos"
            case .imported: return "Imported"
            }
        }
        
        var icon: String {
            switch self {
            case .recording: return "mic.fill"
            case .voiceMemos: return "waveform"
            case .imported: return "doc.fill"
            }
        }

        var color: Color {
            switch self {
            case .recording: return .red
            case .voiceMemos: return .purple
            case .imported: return .blue
            }
        }
    }
    
    struct RecordingMetadata: Codable {
        var speakers: [String]?
        var topics: [String]?
        var summary: String?
        var customData: [String: String]?
    }
    
    /// Format duration for display
    var formattedDuration: String {
        guard let duration = duration else { return "--:--" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: duration) ?? "--:--"
    }
    
    /// Format creation date
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }
    
    /// Get file size if available
    var fileSize: Int64? {
        guard let filePath = filePath else { return nil }
        let url = URL(fileURLWithPath: filePath)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.size] as? Int64
    }
    
    /// Format file size for display
    var formattedFileSize: String {
        guard let size = fileSize else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
