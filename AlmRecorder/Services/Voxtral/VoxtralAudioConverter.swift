import Foundation
import AVFoundation

/// Handles audio conversion for Voxtral transcription
class VoxtralAudioConverter {
    
    private let logger = VoxtralLogger.shared
    private let audioPreprocessor = AudioPreprocessor()
    
    /// Convert audio file to WAV format suitable for Voxtral
    /// - Parameters:
    ///   - sourceFile: Path to the source audio file
    ///   - deleteOriginal: Whether to delete the original file after conversion
    /// - Returns: Path to the converted WAV file
    func convertToWAV(audioFile: String, deleteOriginal: Bool = false) async throws -> String {
        logger.debug("Starting audio conversion for: \(audioFile)")
        
        // Check if file exists
        guard FileManager.default.fileExists(atPath: audioFile) else {
            logger.error("Audio file does not exist: \(audioFile)")
            throw TranscriptionError.invalidURL
        }
        
        // Check if already WAV with correct settings
        if isValidWAVFile(audioFile) {
            logger.debug("File is already in correct WAV format")
            return audioFile
        }
        
        // Check cache first
        if let cachedWAV = WAVCacheManager.shared.getCachedWAV(for: audioFile) {
            logger.info("Using cached WAV file: \(cachedWAV)")
            
            // Delete original if requested
            if deleteOriginal {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: audioFile))
                logger.debug("Deleted original file")
            }
            
            return cachedWAV
        }
        
        // Convert to WAV
        let sourceURL = URL(fileURLWithPath: audioFile)
        let tempDir = FileManager.default.temporaryDirectory
        let outputFileName = "\(UUID().uuidString)_voxtral.wav"
        let outputURL = tempDir.appendingPathComponent(outputFileName)
        
        do {
            logger.info("Converting audio to WAV (16kHz, mono)")
            
            let convertedURL = try await audioPreprocessor.convertAudioFormat(
                sourceURL: sourceURL,
                outputFormat: .wav,
                sampleRate: VoxtralConfiguration.audioSampleRate,
                channels: VoxtralConfiguration.audioChannels,
                outputURL: outputURL
            )
            
            logger.info("Successfully converted audio to: \(convertedURL.path)")
            
            // Cache the converted file for reuse
            WAVCacheManager.shared.cacheWAV(sourceFile: audioFile, wavFile: convertedURL.path)
            
            // Delete original if requested
            if deleteOriginal && sourceURL.path != convertedURL.path {
                try? FileManager.default.removeItem(at: sourceURL)
                logger.debug("Deleted original file")
            }
            
            return convertedURL.path
            
        } catch {
            logger.error("Audio conversion failed: \(error.localizedDescription)")
            throw TranscriptionError.processFailed("Audio conversion failed: \(error.localizedDescription)")
        }
    }
    
    /// Check if a file is a valid WAV file with correct settings
    private func isValidWAVFile(_ filePath: String) -> Bool {
        // Check file extension
        guard filePath.lowercased().hasSuffix(".wav") else {
            return false
        }
        
        // Check audio properties
        let url = URL(fileURLWithPath: filePath)
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            return false
        }
        
        let format = audioFile.processingFormat
        
        // Check if it's 16kHz mono
        let isCorrectSampleRate = abs(format.sampleRate - VoxtralConfiguration.audioSampleRate) < 100
        let isCorrectChannels = format.channelCount == UInt32(VoxtralConfiguration.audioChannels)
        
        return isCorrectSampleRate && isCorrectChannels
    }
    
    /// Clean up temporary WAV files
    func cleanupTemporaryFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: tempDir,
                                                                   includingPropertiesForKeys: nil)
            
            for file in files {
                if file.lastPathComponent.contains("_voxtral.wav") {
                    try? FileManager.default.removeItem(at: file)
                    logger.debug("Cleaned up temporary file: \(file.lastPathComponent)")
                }
            }
        } catch {
            logger.warning("Failed to cleanup temporary files: \(error.localizedDescription)")
        }
    }
    
    /// Get audio duration in seconds
    func getAudioDuration(filePath: String) -> TimeInterval? {
        let url = URL(fileURLWithPath: filePath)
        let asset = AVURLAsset(url: url)
        return getAssetDurationSync(asset)
    }
    
    /// Validate audio file for transcription
    func validateAudioFile(_ filePath: String) throws {
        // Check file exists
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw TranscriptionError.invalidURL
        }
        
        // Check file size (warn if too large)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: filePath),
           let fileSize = attributes[.size] as? Int64 {
            
            let maxSize: Int64 = 500 * 1024 * 1024  // 500MB
            if fileSize > maxSize {
                logger.warning("Audio file is very large (\(fileSize / 1024 / 1024)MB), transcription may be slow")
            }
        }
        
        // Check duration
        if let duration = getAudioDuration(filePath: filePath) {
            if duration > 3600 {  // 1 hour
                logger.warning("Audio file is very long (\(Int(duration / 60)) minutes), consider splitting into chunks")
            }
        }
    }
}
