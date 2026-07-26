import Foundation
import AVFoundation

/// Splits audio files based on speaker segments
class SpeakerAudioSplitter {
    
    private let logger = VoxtralLogger.shared
    
    /// Split audio file into segments based on speaker boundaries
    /// - Parameters:
    ///   - sourceURL: URL of the source audio file
    ///   - segments: Array of speaker segments with timing information
    ///   - outputDirectory: Optional directory for output files
    /// - Returns: Dictionary mapping segment indices to audio file URLs
    func splitAudioBySpeakers(
        sourceURL: URL,
        segments: [SpeakerDiarizer.SpeakerSegment],
        outputDirectory: URL? = nil,
        padding: TimeInterval = 0.1,
        minDuration: TimeInterval = 1.0
    ) async throws -> [Int: URL] {
        
        logger.info("[SpeakerAudioSplitter] Splitting audio into \(segments.count) speaker segments")
        
        let asset = AVAsset(url: sourceURL)
        let outputDir = outputDirectory ?? FileManager.default.temporaryDirectory
        let baseFilename = sourceURL.deletingPathExtension().lastPathComponent
        
        // Get audio duration for boundary validation
        let duration = try await asset.load(.duration)
        let audioDuration = CMTimeGetSeconds(duration)
        
        var segmentFiles: [Int: URL] = [:]
        
        for (index, segment) in segments.enumerated() {
            let outputURL = outputDir.appendingPathComponent(
                "\(baseFilename)_\(segment.speakerId.replacingOccurrences(of: " ", with: "_"))_\(index).m4a"
            )
            
            // Calculate padded boundaries
            var paddedStart = max(0, segment.startTime - padding)
            var paddedEnd = min(audioDuration, segment.endTime + padding)
            
            // Ensure minimum duration for better transcription
            let currentDuration = paddedEnd - paddedStart
            if currentDuration < minDuration {
                let additionalPadding = (minDuration - currentDuration) / 2.0
                paddedStart = max(0, paddedStart - additionalPadding)
                paddedEnd = min(audioDuration, paddedEnd + additionalPadding)
                
                logger.info("[SpeakerAudioSplitter] Extended segment \(index) from \(String(format: "%.2f", currentDuration))s to \(String(format: "%.2f", paddedEnd - paddedStart))s")
            }
            
            logger.debug("[SpeakerAudioSplitter] Creating segment \(index): \(segment.speakerId) [\(String(format: "%.1f", paddedStart))-\(String(format: "%.1f", paddedEnd))s] (original: [\(String(format: "%.1f", segment.startTime))-\(String(format: "%.1f", segment.endTime))s])")
            
            try await extractSegment(
                from: asset,
                startTime: paddedStart,
                endTime: paddedEnd,
                outputURL: outputURL
            )
            
            segmentFiles[index] = outputURL
        }
        
        logger.info("[SpeakerAudioSplitter] Created \(segmentFiles.count) audio segments")
        return segmentFiles
    }
    
    /// Extract a time segment from an audio asset
    private func extractSegment(
        from asset: AVAsset,
        startTime: TimeInterval,
        endTime: TimeInterval,
        outputURL: URL
    ) async throws {
        
        // Remove existing file if present
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
        
        // Export the segment
        await exportSession.export()
        
        if let error = exportSession.error {
            logger.error("[SpeakerAudioSplitter] Export failed: \(error.localizedDescription)")
            throw AudioProcessingError.exportFailed(error.localizedDescription)
        }
        
        guard exportSession.status == .completed else {
            throw AudioProcessingError.exportIncomplete
        }
    }
    
    /// Merge overlapping or adjacent segments from the same speaker
    func mergeAdjacentSpeakerSegments(
        _ segments: [SpeakerDiarizer.SpeakerSegment],
        maxGap: TimeInterval = 0.5
    ) -> [SpeakerDiarizer.SpeakerSegment] {
        
        guard !segments.isEmpty else { return [] }
        
        var merged: [SpeakerDiarizer.SpeakerSegment] = []
        var currentSegment = segments[0]
        
        for i in 1..<segments.count {
            let nextSegment = segments[i]
            
            // Check if same speaker and close enough
            if currentSegment.speakerId == nextSegment.speakerId &&
               nextSegment.startTime - currentSegment.endTime <= maxGap {
                
                // Merge segments
                let mergedText = [currentSegment.text, nextSegment.text]
                    .compactMap { $0 }
                    .joined(separator: " ")
                
                currentSegment = SpeakerDiarizer.SpeakerSegment(
                    speakerId: currentSegment.speakerId,
                    startTime: currentSegment.startTime,
                    endTime: nextSegment.endTime,
                    text: mergedText.isEmpty ? nil : mergedText
                )
            } else {
                // Save current and start new
                merged.append(currentSegment)
                currentSegment = nextSegment
            }
        }
        
        // Add last segment
        merged.append(currentSegment)
        
        logger.debug("[SpeakerAudioSplitter] Merged \(segments.count) segments into \(merged.count)")
        
        return merged
    }
    
    /// Create a combined audio file from multiple segments
    func combineSegments(
        segmentURLs: [URL],
        outputURL: URL
    ) async throws {
        
        logger.info("[SpeakerAudioSplitter] Combining \(segmentURLs.count) segments")
        
        // Create composition
        let composition = AVMutableComposition()
        
        guard let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw AudioProcessingError.compositionCreationFailed
        }
        
        var currentTime = CMTime.zero
        
        // Add each segment to the composition
        for segmentURL in segmentURLs {
            let asset = AVAsset(url: segmentURL)
            
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                logger.warning("[SpeakerAudioSplitter] No audio track in segment: \(segmentURL.lastPathComponent)")
                continue
            }
            
            let duration = try await asset.load(.duration)
            let timeRange = CMTimeRange(start: .zero, duration: duration)
            
            try audioTrack.insertTimeRange(
                timeRange,
                of: sourceTrack,
                at: currentTime
            )
            
            currentTime = CMTimeAdd(currentTime, duration)
        }
        
        // Export composition
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw AudioProcessingError.exportSessionCreationFailed
        }
        
        // Remove existing file
        try? FileManager.default.removeItem(at: outputURL)
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        
        await exportSession.export()
        
        if let error = exportSession.error {
            throw AudioProcessingError.exportFailed(error.localizedDescription)
        }
        
        guard exportSession.status == .completed else {
            throw AudioProcessingError.exportIncomplete
        }
        
        logger.info("[SpeakerAudioSplitter] Combined audio saved to: \(outputURL.lastPathComponent)")
    }
}

// MARK: - Audio Processing Errors

extension AudioProcessingError {
    static let compositionCreationFailed = AudioProcessingError.exportFailed("Failed to create audio composition")
}