import Foundation
import SwiftUI

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
