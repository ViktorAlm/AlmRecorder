import Foundation
import AVFoundation
import Accelerate

/// Service for extracting audio segments from recordings
class AudioSegmentExtractor {
    
    static let shared = AudioSegmentExtractor()
    private init() {}
    
    private let logger = VoxtralLogger.shared
    private var audioFileCache: [String: AVAudioFile] = [:]
    private let cacheQueue = DispatchQueue(label: "com.almrecorder.audio.cache", attributes: .concurrent)
    
    // MARK: - Public Methods
    
    /// Extract audio data for a specific time range
    func extractSegment(
        from audioFilePath: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        padding: TimeInterval = 0.1
    ) async throws -> Data {
        
        let url = URL(fileURLWithPath: audioFilePath)
        
        // Add small padding to avoid cutting off words
        let paddedStart = max(0, startTime - padding)
        let paddedEnd = endTime + padding
        
        return try await withCheckedThrowingContinuation { continuation in
            extractSegmentSync(
                from: url,
                startTime: paddedStart,
                endTime: paddedEnd
            ) { result in
                continuation.resume(with: result)
            }
        }
    }
    
    /// Extract multiple segments efficiently
    func extractSegments(
        from audioFilePath: String,
        timeRanges: [(start: TimeInterval, end: TimeInterval)]
    ) async throws -> [Data] {
        
        let url = URL(fileURLWithPath: audioFilePath)
        var segments: [Data] = []
        
        // Load audio file once
        let audioFile = try AVAudioFile(forReading: url)
        
        for range in timeRanges {
            let data = try await extractSegmentFromFile(
                audioFile,
                startTime: range.start,
                endTime: range.end
            )
            segments.append(data)
        }
        
        return segments
    }
    
    /// Get audio file duration
    func getDuration(of audioFilePath: String) throws -> TimeInterval {
        let url = URL(fileURLWithPath: audioFilePath)
        let audioFile = try AVAudioFile(forReading: url)
        let frameCount = audioFile.length
        let sampleRate = audioFile.processingFormat.sampleRate
        return Double(frameCount) / sampleRate
    }
    
    /// Generate waveform data for visualization
    func generateWaveform(
        from audioData: Data,
        targetSamples: Int = 100
    ) -> [Float] {
        
        // Convert data to audio buffer
        guard let pcmBuffer = dataToPCMBuffer(audioData) else {
            return Array(repeating: 0, count: targetSamples)
        }
        
        guard let floatData = pcmBuffer.floatChannelData?[0] else {
            return Array(repeating: 0, count: targetSamples)
        }
        
        let frameCount = Int(pcmBuffer.frameLength)
        let samplesPerPixel = max(1, frameCount / targetSamples)
        var waveform: [Float] = []
        
        for i in 0..<targetSamples {
            let startIdx = i * samplesPerPixel
            let endIdx = min(startIdx + samplesPerPixel, frameCount)
            
            if startIdx < frameCount {
                // Calculate RMS value for this segment
                var rms: Float = 0
                vDSP_rmsqv(
                    floatData.advanced(by: startIdx),
                    1,
                    &rms,
                    vDSP_Length(endIdx - startIdx)
                )
                waveform.append(rms)
            } else {
                waveform.append(0)
            }
        }
        
        // Normalize
        if let maxValue = waveform.max(), maxValue > 0 {
            waveform = waveform.map { $0 / maxValue }
        }
        
        return waveform
    }
    
    // MARK: - Private Methods
    
    private func extractSegmentSync(
        from url: URL,
        startTime: TimeInterval,
        endTime: TimeInterval,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let frameCount = audioFile.length
            let sampleRate = audioFile.processingFormat.sampleRate
            
            // Calculate frame positions
            let startFrame = AVAudioFramePosition(startTime * sampleRate)
            let endFrame = AVAudioFramePosition(endTime * sampleRate)
            
            // Clamp to valid range
            let validStartFrame = max(0, min(startFrame, frameCount))
            let validEndFrame = max(validStartFrame, min(endFrame, frameCount))
            let framesToRead = AVAudioFrameCount(validEndFrame - validStartFrame)
            
            guard framesToRead > 0 else {
                completion(.failure(AudioExtractionError.invalidTimeRange))
                return
            }
            
            // Create buffer for audio data
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: framesToRead
            ) else {
                completion(.failure(AudioExtractionError.bufferCreationFailed))
                return
            }
            
            // Seek to start position and read
            audioFile.framePosition = validStartFrame
            try audioFile.read(into: buffer, frameCount: framesToRead)
            
            // Convert to Data
            let data = pcmBufferToData(buffer)
            completion(.success(data))
            
        } catch {
            completion(.failure(error))
        }
    }
    
    private func extractSegmentFromFile(
        _ audioFile: AVAudioFile,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) async throws -> Data {
        
        let frameCount = audioFile.length
        let sampleRate = audioFile.processingFormat.sampleRate
        
        // Calculate frame positions
        let startFrame = AVAudioFramePosition(startTime * sampleRate)
        let endFrame = AVAudioFramePosition(endTime * sampleRate)
        
        // Clamp to valid range
        let validStartFrame = max(0, min(startFrame, frameCount))
        let validEndFrame = max(validStartFrame, min(endFrame, frameCount))
        let framesToRead = AVAudioFrameCount(validEndFrame - validStartFrame)
        
        guard framesToRead > 0 else {
            throw AudioExtractionError.invalidTimeRange
        }
        
        // Create buffer for audio data
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFile.processingFormat,
            frameCapacity: framesToRead
        ) else {
            throw AudioExtractionError.bufferCreationFailed
        }
        
        // Seek to start position and read
        audioFile.framePosition = validStartFrame
        try audioFile.read(into: buffer, frameCount: framesToRead)
        
        // Convert to Data
        return pcmBufferToData(buffer)
    }
    
    private func pcmBufferToData(_ buffer: AVAudioPCMBuffer) -> Data {
        // Create a temporary file to write the audio data as WAV
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        
        do {
            // Create an audio file for writing
            let audioFile = try AVAudioFile(
                forWriting: tempURL,
                settings: buffer.format.settings,
                commonFormat: buffer.format.commonFormat,
                interleaved: buffer.format.isInterleaved
            )
            
            // Write the buffer to the file
            try audioFile.write(from: buffer)
            
            // Read the file data
            let data = try Data(contentsOf: tempURL)
            
            // Clean up temp file
            try? FileManager.default.removeItem(at: tempURL)
            
            return data
            
        } catch {
            logger.error("[AudioSegmentExtractor] Failed to convert PCM buffer to WAV data: \(error)")
            
            // Fallback: return raw PCM data (won't work with AVAudioPlayer but better than nothing)
            let audioFormat = buffer.format
            let frameLength = buffer.frameLength
            let bytesPerFrame = audioFormat.streamDescription.pointee.mBytesPerFrame
            let dataSize = Int(frameLength) * Int(bytesPerFrame)
            
            if let channelData = buffer.floatChannelData {
                return Data(bytes: channelData[0], count: dataSize)
            } else if let channelData = buffer.int16ChannelData {
                return Data(bytes: channelData[0], count: dataSize)
            } else {
                return Data()
            }
        }
    }
    
    private func dataToPCMBuffer(_ data: Data) -> AVAudioPCMBuffer? {
        // Try to parse as WAV file first
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        
        do {
            // Write data to temp file
            try data.write(to: tempURL)
            
            // Read as audio file to get proper format
            let audioFile = try AVAudioFile(forReading: tempURL)
            let format = audioFile.processingFormat
            let frameCount = AVAudioFrameCount(audioFile.length)
            
            // Create buffer with correct format
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
            ) else {
                try? FileManager.default.removeItem(at: tempURL)
                return nil
            }
            
            // Read audio into buffer
            try audioFile.read(into: buffer)
            
            // Clean up
            try? FileManager.default.removeItem(at: tempURL)
            
            return buffer
            
        } catch {
            // Clean up on error
            try? FileManager.default.removeItem(at: tempURL)
            
            // Fallback: try to interpret as raw PCM (16kHz mono float32)
            logger.warning("[AudioSegmentExtractor] Failed to parse as WAV, trying raw PCM: \(error)")
            
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            )!
            
            let frameCapacity = UInt32(data.count / 4) // 4 bytes per float32
            
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCapacity
            ) else {
                return nil
            }
            
            buffer.frameLength = frameCapacity
            
            // Copy data to buffer
            data.withUnsafeBytes { bytes in
                if let floatData = buffer.floatChannelData?[0] {
                    bytes.copyBytes(to: UnsafeMutableBufferPointer(
                        start: floatData,
                        count: Int(frameCapacity)
                    ))
                }
            }
            
            return buffer
        }
    }
    
    /// Clear audio file cache
    func clearCache() {
        cacheQueue.async(flags: .barrier) {
            self.audioFileCache.removeAll()
        }
    }
}

// MARK: - Errors

enum AudioExtractionError: LocalizedError {
    case fileNotFound
    case invalidTimeRange
    case bufferCreationFailed
    case conversionFailed
    
    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "Audio file not found"
        case .invalidTimeRange:
            return "Invalid time range specified"
        case .bufferCreationFailed:
            return "Failed to create audio buffer"
        case .conversionFailed:
            return "Failed to convert audio data"
        }
    }
}