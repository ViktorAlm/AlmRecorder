import Foundation
import AVFoundation
import Accelerate

/// Configuration for VAD-based audio splitting
struct VADConfiguration {
    /// Minimum silence duration to consider as a split point (seconds)
    let minSilenceDuration: TimeInterval

    /// Maximum silence duration to wait before forcing a split (seconds)
    let maxSilenceDuration: TimeInterval

    /// Silence threshold (0.0 to 1.0, lower = more sensitive)
    let silenceThreshold: Float

    /// Minimum chunk duration (seconds)
    let minChunkDuration: TimeInterval

    /// Maximum chunk duration (seconds) - split at next silence after this
    let maxChunkDuration: TimeInterval

    /// Target chunk duration (seconds) - prefer splits around this duration
    let targetChunkDuration: TimeInterval

    /// Energy window size for silence detection (seconds)
    let energyWindowSize: TimeInterval

    /// Explicit initializer so callers can override individual durations (e.g. Gemma needs <30s
    /// chunks). A struct whose `let` members all have inline defaults gets a no-argument memberwise
    /// initializer only, which is why this is spelled out.
    init(
        minSilenceDuration: TimeInterval = 0.5,
        maxSilenceDuration: TimeInterval = 2.0,
        silenceThreshold: Float = 0.02,
        minChunkDuration: TimeInterval = 30.0,
        maxChunkDuration: TimeInterval = 90.0,   // 1.5 minutes
        targetChunkDuration: TimeInterval = 60.0, // 1 minute
        energyWindowSize: TimeInterval = 0.1
    ) {
        self.minSilenceDuration = minSilenceDuration
        self.maxSilenceDuration = maxSilenceDuration
        self.silenceThreshold = silenceThreshold
        self.minChunkDuration = minChunkDuration
        self.maxChunkDuration = maxChunkDuration
        self.targetChunkDuration = targetChunkDuration
        self.energyWindowSize = energyWindowSize
    }
}

/// VAD-based audio splitter using AVFoundation
class VADAudioSplitter: ObservableObject {
    @Published var isProcessing = false
    @Published var progress: Double = 0.0
    
    private let logger = VoxtralLogger.shared
    private let config: VADConfiguration
    
    init(config: VADConfiguration = VADConfiguration()) {
        self.config = config
    }
    
    /// Split audio file based on voice activity detection
    func splitAudioWithVAD(
        sourceURL: URL,
        outputDirectory: URL? = nil
    ) async throws -> [URL] {
        logger.info("Starting VAD-based audio splitting for: \(sourceURL.lastPathComponent)")
        
        let asset = AVAsset(url: sourceURL)
        
        // Get audio duration
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        logger.info("Audio duration: \(String(format: "%.1f", durationSeconds)) seconds")
        
        // If audio is shorter than min chunk duration, return as is
        if durationSeconds <= config.minChunkDuration {
            logger.info("Audio is shorter than minimum chunk duration, returning as single chunk")
            return [sourceURL]
        }
        
        // Find silence points in the audio
        let silencePoints = try await findSilencePoints(in: asset)
        logger.info("Found \(silencePoints.count) silence points")
        
        // Determine optimal split points
        let splitPoints = determineSplitPoints(
            silencePoints: silencePoints,
            totalDuration: durationSeconds
        )
        logger.info("Determined \(splitPoints.count) split points")
        
        // Create chunks based on split points
        let chunks = try await createChunks(
            from: asset,
            splitPoints: splitPoints,
            outputDirectory: outputDirectory,
            sourceURL: sourceURL
        )
        
        logger.info("Created \(chunks.count) chunks")
        return chunks
    }
    
    /// Find silence points in audio using energy analysis
    private func findSilencePoints(in asset: AVAsset) async throws -> [TimeInterval] {
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioProcessingError.noAudioTrack
        }
        
        // Create reader
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1
        ]
        
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        reader.add(output)
        reader.startReading()
        
        var silencePoints: [TimeInterval] = []
        var currentTime: TimeInterval = 0
        let windowSamples = Int(16000 * config.energyWindowSize)
        var inSilence = false
        var silenceStartTime: TimeInterval = 0
        
        // Process audio samples
        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break
            }
            
            // Get sample data
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }
            
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                       totalLengthOut: &length, dataPointerOut: &dataPointer)
            
            guard let data = dataPointer else { continue }
            
            // Calculate RMS energy
            let samples = length / 2 // 16-bit samples
            let int16Pointer = UnsafeRawPointer(data).bindMemory(to: Int16.self, capacity: samples)
            
            // Process in windows
            for windowStart in stride(from: 0, to: samples, by: windowSamples) {
                let windowEnd = min(windowStart + windowSamples, samples)
                let windowSize = windowEnd - windowStart
                
                // Calculate RMS for this window
                var sumSquares: Float = 0
                for i in windowStart..<windowEnd {
                    let sample = Float(int16Pointer[i]) / Float(Int16.max)
                    sumSquares += sample * sample
                }
                let rms = sqrt(sumSquares / Float(windowSize))
                
                // Check if this is silence
                let isSilent = rms < config.silenceThreshold
                
                if isSilent && !inSilence {
                    // Entering silence
                    inSilence = true
                    silenceStartTime = currentTime
                } else if !isSilent && inSilence {
                    // Exiting silence
                    let silenceDuration = currentTime - silenceStartTime
                    if silenceDuration >= config.minSilenceDuration {
                        // Found a valid silence point (use the middle of the silence)
                        let silenceMidpoint = silenceStartTime + (silenceDuration / 2)
                        silencePoints.append(silenceMidpoint)
                        logger.debug("Found silence at \(String(format: "%.1f", silenceMidpoint))s, duration: \(String(format: "%.1f", silenceDuration))s")
                    }
                    inSilence = false
                }
                
                currentTime += Double(windowSize) / 16000.0
            }
        }
        
        reader.cancelReading()
        return silencePoints
    }
    
    /// Determine optimal split points from silence points
    private func determineSplitPoints(
        silencePoints: [TimeInterval],
        totalDuration: TimeInterval
    ) -> [TimeInterval] {
        var splitPoints: [TimeInterval] = []
        var lastSplitTime: TimeInterval = 0
        
        for silencePoint in silencePoints {
            let chunkDuration = silencePoint - lastSplitTime
            
            // Check if we should split here
            if chunkDuration >= config.targetChunkDuration {
                // Prefer splitting around target duration
                splitPoints.append(silencePoint)
                lastSplitTime = silencePoint
                logger.debug("Adding split point at \(String(format: "%.1f", silencePoint))s (chunk duration: \(String(format: "%.1f", chunkDuration))s)")
            } else if chunkDuration >= config.maxChunkDuration {
                // Force split if we exceed max duration
                splitPoints.append(silencePoint)
                lastSplitTime = silencePoint
                logger.debug("Forcing split at \(String(format: "%.1f", silencePoint))s (exceeded max duration)")
            }
        }
        
        // Check if the last chunk is too long
        let remainingDuration = totalDuration - lastSplitTime
        if remainingDuration > config.maxChunkDuration {
            // Find the best silence point in the remaining audio
            let candidateSilences = silencePoints.filter { $0 > lastSplitTime }
            if let bestSilence = candidateSilences.first(where: { 
                $0 - lastSplitTime >= config.minChunkDuration 
            }) {
                splitPoints.append(bestSilence)
                logger.debug("Adding final split at \(String(format: "%.1f", bestSilence))s")
            }
        }
        
        return splitPoints
    }
    
    /// Create audio chunks based on split points
    private func createChunks(
        from asset: AVAsset,
        splitPoints: [TimeInterval],
        outputDirectory: URL?,
        sourceURL: URL? = nil
    ) async throws -> [URL] {
        let outputDir = outputDirectory ?? FileManager.default.temporaryDirectory
        let baseFilename = sourceURL?.deletingPathExtension().lastPathComponent ?? "audio"
        
        var chunks: [URL] = []
        var startTime: TimeInterval = 0
        let duration = try await asset.load(.duration)
        let totalDuration = CMTimeGetSeconds(duration)
        
        // Create chunks for each segment
        for (index, splitPoint) in splitPoints.enumerated() {
            let chunkURL = outputDir.appendingPathComponent("\(baseFilename)_vad_chunk_\(index).m4a")
            let endTime = splitPoint
            
            logger.info("Creating chunk \(index + 1): \(String(format: "%.1f", startTime))s - \(String(format: "%.1f", endTime))s")
            
            try await exportChunk(
                asset: asset,
                startTime: startTime,
                endTime: endTime,
                outputURL: chunkURL
            )
            
            chunks.append(chunkURL)
            startTime = splitPoint
            
            // Update progress
            await MainActor.run {
                self.progress = Double(index + 1) / Double(splitPoints.count + 1)
            }
        }
        
        // Create final chunk if needed
        if startTime < totalDuration - 0.1 { // At least 0.1s remaining (tight threshold for determinism)
            let finalIndex = chunks.count
            let chunkURL = outputDir.appendingPathComponent("\(baseFilename)_vad_chunk_\(finalIndex).m4a")
            
            logger.info("Creating final chunk \(finalIndex + 1): \(String(format: "%.1f", startTime))s - \(String(format: "%.1f", totalDuration))s")
            
            try await exportChunk(
                asset: asset,
                startTime: startTime,
                endTime: totalDuration,
                outputURL: chunkURL
            )
            
            chunks.append(chunkURL)
        }
        
        await MainActor.run {
            self.progress = 1.0
        }
        
        // Log chunk summary
        logger.info("Created \(chunks.count) chunks:")
        for (index, chunk) in chunks.enumerated() {
            let size = getFileSize(chunk)
            logger.info("  Chunk \(index + 1): \(formatBytes(size))")
        }
        
        return chunks
    }
    
    /// Export a chunk of audio
    private func exportChunk(
        asset: AVAsset,
        startTime: TimeInterval,
        endTime: TimeInterval,
        outputURL: URL
    ) async throws {
        // Remove existing file if it exists
        try? FileManager.default.removeItem(at: outputURL)
        
        // Create time range
        let start = CMTime(seconds: startTime, preferredTimescale: 600)
        let end = CMTime(seconds: endTime, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: start, end: end)
        
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
        
        // Export
        await exportSession.export()
        
        if let error = exportSession.error {
            throw AudioProcessingError.exportFailed(error.localizedDescription)
        }
        
        guard exportSession.status == .completed else {
            throw AudioProcessingError.exportIncomplete
        }
    }
    
    /// Get file size in bytes
    private func getFileSize(_ url: URL) -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }
    
    /// Format bytes to human readable string
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// AudioProcessingError is already defined in AudioPreprocessor.swift