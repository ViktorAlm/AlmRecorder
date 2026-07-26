import Foundation
import SwiftUI

struct TranscriptionItem: Identifiable, Codable {
    let id = UUID()
    let fileName: String
    let filePath: String
    let transcript: String
    let language: String
    let duration: TimeInterval
    let fileSize: Int64
    let createdDate: Date
    let transcribedDate: Date
    let source: TranscriptionSource
    let status: TranscriptionStatus
    let error: String?
    
    enum TranscriptionSource: String, Codable {
        case recording = "Recording"
        case voiceMemos = "Voice Memos"
        case imported = "Imported"

        var color: Color {
            switch self {
            case .recording: return .red
            case .voiceMemos: return .purple
            case .imported: return .blue
            }
        }
    }
    
    enum TranscriptionStatus: String, Codable {
        case pending = "Pending"
        case processing = "Processing"
        case completed = "Completed"
        case failed = "Failed"
        case partialSuccess = "Partial Success"
    }
    
    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: fileSize)
    }
    
    var formattedTranscribedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: transcribedDate)
    }
    
    var displayStatus: String {
        switch status {
        case .pending:
            return "Waiting to process"
        case .processing:
            return "Processing..."
        case .completed:
            return "Completed"
        case .failed:
            return error ?? "Failed"
        case .partialSuccess:
            return "Partial success"
        }
    }
    
    var statusColor: String {
        switch status {
        case .pending:
            return "gray"
        case .processing:
            return "blue"
        case .completed:
            return "green"
        case .failed:
            return "red"
        case .partialSuccess:
            return "orange"
        }
    }
    
    var hasError: Bool {
        status == .failed || (status == .partialSuccess && error != nil)
    }
}