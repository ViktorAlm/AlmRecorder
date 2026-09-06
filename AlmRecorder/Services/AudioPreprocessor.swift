import Foundation
@preconcurrency import AVFoundation

/// AVAssetReader/Writer objects are deliberately confined to one dedicated serial queue below.
/// AVFoundation does not annotate these reference types as Sendable, so carry them into that
/// queue through an explicit unchecked wrapper that documents the confinement boundary.
private struct AudioQueueTransfer<Value>: @unchecked Sendable {
    let value: Value
}

/// Supported audio formats for conversion
enum AudioFormat {
    case wav
    case m4a
    case mp3
    case aiff
    case caf
    
    var fileExtension: String {
        switch self {
        case .wav: return "wav"
        case .m4a: return "m4a"
        case .mp3: return "mp3"
        case .aiff: return "aiff"
        case .caf: return "caf"
        }
    }
    
    var avFileType: AVFileType {
        switch self {
        case .wav: return .wav
        case .m4a: return .m4a
        case .mp3: return .mp3
        case .aiff: return .aiff
        case .caf: return .caf
        }
    }
    
    var formatID: AudioFormatID {
        switch self {
        case .wav: return kAudioFormatLinearPCM
        case .m4a: return kAudioFormatMPEG4AAC
        case .mp3: return kAudioFormatMPEGLayer3
        case .aiff: return kAudioFormatLinearPCM
        case .caf: return kAudioFormatLinearPCM
        }
    }
}

/// Service for preprocessing audio files (splitting, chunking, format conversion)
class AudioPreprocessor: ObservableObject {
    @Published var isProcessing = false
    @Published var progress: Double = 0.0
    
    /// Split an audio file into chunks of specified duration
    /// - Parameters:
    ///   - sourceURL: URL of the source audio file
    ///   - chunkDuration: Duration of each chunk in seconds
    ///   - outputDirectory: Directory to save chunks (optional, uses temp if nil)
    /// - Returns: Array of URLs for the created chunks
    func splitAudioFile(
        sourceURL: URL,
        chunkDuration: TimeInterval,
        outputDirectory: URL? = nil
    ) async throws -> [URL] {
        let asset = AVAsset(url: sourceURL)
        
        // Get the audio duration
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        
        // Calculate number of chunks needed
        let chunkCount = Int(ceil(durationSeconds / chunkDuration))
        var chunkURLs: [URL] = []
        
        // Use temp directory if no output directory specified
        let outputDir = outputDirectory ?? FileManager.default.temporaryDirectory
        let baseFilename = sourceURL.deletingPathExtension().lastPathComponent
        
        await MainActor.run {
            self.isProcessing = true
            self.progress = 0.0
        }
        
        for chunkIndex in 0..<chunkCount {
            let startTime = CMTime(seconds: Double(chunkIndex) * chunkDuration, preferredTimescale: 600)
            let endTime = CMTime(seconds: min(Double(chunkIndex + 1) * chunkDuration, durationSeconds), preferredTimescale: 600)
            let timeRange = CMTimeRange(start: startTime, end: endTime)
            
            // Create output URL for this chunk
            let chunkURL = outputDir.appendingPathComponent("\(baseFilename)_chunk_\(chunkIndex).m4a")
            
            // Export the chunk
            try await exportAudioChunk(
                asset: asset,
                timeRange: timeRange,
                outputURL: chunkURL
            )
            
            chunkURLs.append(chunkURL)
            
            await MainActor.run {
                self.progress = Double(chunkIndex + 1) / Double(chunkCount)
            }
        }
        
        await MainActor.run {
            self.isProcessing = false
            self.progress = 1.0
        }
        
        return chunkURLs
    }
    
    /// Export a specific time range from an audio asset
    private func exportAudioChunk(
        asset: AVAsset,
        timeRange: CMTimeRange,
        outputURL: URL
    ) async throws {
        // Remove existing file if it exists
        try? FileManager.default.removeItem(at: outputURL)
        
        // Create export session
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw AudioProcessingError.exportSessionCreationFailed
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = timeRange
        
        // Export asynchronously
        await exportSession.export()
        
        // Check for errors
        if let error = exportSession.error {
            throw AudioProcessingError.exportFailed(error.localizedDescription)
        }
        
        guard exportSession.status == .completed else {
            throw AudioProcessingError.exportIncomplete
        }
    }
    
    /// Convert audio file to specified format
    func convertAudioFormat(
        sourceURL: URL,
        outputFormat: AudioFormat,
        sampleRate: Double? = nil,
        channels: Int? = nil,
        outputURL: URL? = nil
    ) async throws -> URL {
        let asset = AVAsset(url: sourceURL)
        let outputFile = outputURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(outputFormat.fileExtension)
        
        // Remove existing file if it exists
        try? FileManager.default.removeItem(at: outputFile)
        
        // For simple format conversions, use AVAssetExportSession
        if let preset = getExportPreset(for: outputFormat) {
            return try await exportWithPreset(
                asset: asset,
                preset: preset,
                outputFormat: outputFormat,
                outputURL: outputFile
            )
        }
        
        // For custom conversions (with specific sample rate/channels), use reader/writer
        let reader = try AVAssetReader(asset: asset)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioProcessingError.noAudioTrack
        }
        
        // Configure output settings based on format
        let outputSettings = getOutputSettings(
            for: outputFormat,
            sampleRate: sampleRate,
            channels: channels
        )
        
        let readerOutput = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: outputSettings
        )
        
        reader.add(readerOutput)
        
        // Set up the writer
        let writer = try AVAssetWriter(outputURL: outputFile, fileType: .wav)
        
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: outputSettings
        )
        
        writer.add(writerInput)
        
        // Start reading and writing
        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        
        // Process the audio
        let writerInputTransfer = AudioQueueTransfer(value: writerInput)
        let readerOutputTransfer = AudioQueueTransfer(value: readerOutput)
        let writerTransfer = AudioQueueTransfer(value: writer)
        await withCheckedContinuation { continuation in
            writerInput.requestMediaDataWhenReady(on: DispatchQueue(label: "audioProcessing")) {
                let writerInput = writerInputTransfer.value
                let readerOutput = readerOutputTransfer.value
                while writerInput.isReadyForMoreMediaData {
                    if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(sampleBuffer)
                    } else {
                        writerInput.markAsFinished()
                        writerTransfer.value.finishWriting {
                            continuation.resume()
                        }
                        break
                    }
                }
            }
        }
        
        guard writer.status == .completed else {
            throw AudioProcessingError.conversionFailed
        }
        
        return outputFile
    }
    
    /// Split audio for Voxtral processing (30-minute chunks)
    func prepareForVoxtral(audioURL: URL) async throws -> [URL] {
        // Voxtral can handle up to 30 minutes
        let maxChunkDuration: TimeInterval = 30 * 60 // 30 minutes in seconds
        
        // First convert to WAV
        let wavURL = try await convertToWAV(sourceURL: audioURL)
        
        // Then split into chunks if needed
        let asset = AVAsset(url: wavURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        
        if durationSeconds <= maxChunkDuration {
            // File is already under 30 minutes, no need to split
            return [wavURL]
        } else {
            // Split into 30-minute chunks
            return try await splitAudioFile(
                sourceURL: wavURL,
                chunkDuration: maxChunkDuration
            )
        }
    }
    
    /// Clean up temporary chunk files
    func cleanupChunks(_ chunkURLs: [URL]) {
        for url in chunkURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }
    
    // MARK: - Helper Methods
    
    private func getExportPreset(for format: AudioFormat) -> String? {
        switch format {
        case .m4a:
            return AVAssetExportPresetAppleM4A
        case .wav, .mp3, .aiff, .caf:
            return nil // Use custom reader/writer for these
        }
    }
    
    private func exportWithPreset(
        asset: AVAsset,
        preset: String,
        outputFormat: AudioFormat,
        outputURL: URL
    ) async throws -> URL {
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw AudioProcessingError.exportSessionCreationFailed
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = outputFormat.avFileType
        
        await exportSession.export()
        
        guard exportSession.status == .completed else {
            throw AudioProcessingError.exportFailed(exportSession.error?.localizedDescription ?? "Unknown error")
        }
        
        return outputURL
    }
    
    private func getOutputSettings(
        for format: AudioFormat,
        sampleRate: Double?,
        channels: Int?
    ) -> [String: Any] {
        var settings: [String: Any] = [:]
        
        // Set format
        settings[AVFormatIDKey] = format.formatID
        
        // Set sample rate (default to 44100 if not specified)
        settings[AVSampleRateKey] = sampleRate ?? 44100
        
        // Set channels (default to mono for voice)
        settings[AVNumberOfChannelsKey] = channels ?? 1
        
        // Format-specific settings
        switch format {
        case .wav, .aiff, .caf:
            // Linear PCM settings
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
            
        case .m4a:
            // AAC settings
            settings[AVEncoderAudioQualityKey] = AVAudioQuality.high.rawValue
            settings[AVEncoderBitRateKey] = 128000
            
        case .mp3:
            // MP3 settings
            settings[AVEncoderBitRateKey] = 128000
        }
        
        return settings
    }
    
    /// Convert to WAV specifically for Voxtral (convenience method)
    func convertToWAV(
        sourceURL: URL,
        sampleRate: Double = 16000,
        outputURL: URL? = nil
    ) async throws -> URL {
        return try await convertAudioFormat(
            sourceURL: sourceURL,
            outputFormat: .wav,
            sampleRate: sampleRate,
            channels: 1,
            outputURL: outputURL
        )
    }
    
    /// Detect audio format from file extension
    static func detectFormat(from url: URL) -> AudioFormat? {
        switch url.pathExtension.lowercased() {
        case "wav": return .wav
        case "m4a": return .m4a
        case "mp3": return .mp3
        case "aiff", "aif": return .aiff
        case "caf": return .caf
        default: return nil
        }
    }
    
    /// Check if file needs conversion for Voxtral
    func needsVoxtralConversion(audioURL: URL) async -> Bool {
        guard let format = Self.detectFormat(from: audioURL) else { return true }
        
        // Voxtral works best with WAV
        if format != .wav { return true }
        
        // Check sample rate and channels
        let asset = AVAsset(url: audioURL)
        if (try? await asset.loadTracks(withMediaType: .audio).first) != nil {
            // Check if we need to resample or convert to mono
            // This would require analyzing the format descriptions
            return false // For now, assume WAV files are OK
        }
        
        return true
    }
}

// MARK: - Error Types
enum AudioProcessingError: LocalizedError {
    case exportSessionCreationFailed
    case exportFailed(String)
    case exportIncomplete
    case noAudioTrack
    case conversionFailed
    
    var errorDescription: String? {
        switch self {
        case .exportSessionCreationFailed:
            return "Failed to create export session"
        case .exportFailed(let reason):
            return "Export failed: \(reason)"
        case .exportIncomplete:
            return "Export did not complete successfully"
        case .noAudioTrack:
            return "No audio track found in file"
        case .conversionFailed:
            return "Failed to convert audio format"
        }
    }
}
