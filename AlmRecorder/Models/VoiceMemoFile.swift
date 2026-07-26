import Foundation
import AVFoundation

struct VoiceMemoFile: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let createdDate: Date
    let modifiedDate: Date
    let duration: TimeInterval?
    let fileSize: Int64
    var isSelected: Bool = false
    var isTranscribing: Bool = false
    var transcriptionProgress: Double = 0.0
    
    init(url: URL) {
        self.url = url
        self.name = url.deletingPathExtension().lastPathComponent
        
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        self.createdDate = attributes?[.creationDate] as? Date ?? Date()
        self.modifiedDate = attributes?[.modificationDate] as? Date ?? Date()
        self.fileSize = attributes?[.size] as? Int64 ?? 0
        
        self.duration = VoiceMemoFile.getAudioDuration(from: url)
    }
    
    static func getAudioDuration(from url: URL) -> TimeInterval? {
        guard url.pathExtension.lowercased() == "m4a" else { return nil }
        
        let asset = AVURLAsset(url: url)
        
        // Use synchronous wrapper for async property loading
        return getAssetDurationSync(asset)
    }
    
    var formattedName: String {
        if name.count > 30 {
            return String(name.prefix(27)) + "..."
        }
        return name
    }
    
    var formattedDuration: String {
        guard let duration = duration else { return "--:--" }
        
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
    
    var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: fileSize)
    }
    
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: createdDate)
    }
    
    var formattedFullDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: createdDate)
    }
    
    var formattedExactDateTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm:ss a"
        return formatter.string(from: createdDate)
    }
    
    var relativeDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: createdDate, relativeTo: Date())
    }
}