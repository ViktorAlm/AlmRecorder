import Foundation

enum AudioImportPolicy {
    static let supportedExtensions: Set<String> = [
        "aif", "aiff", "flac", "m4a", "mp3", "ogg", "opus", "qta", "wav",
    ]

    static func supports(_ url: URL) -> Bool {
        url.isFileURL && supportedExtensions.contains(url.pathExtension.lowercased())
    }
}
