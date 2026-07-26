import Foundation
import CoreML
import AVFoundation
import Accelerate

/// Service for extracting speaker embeddings using Pyannote model via CoreML
class PyannoteSpeakerEmbedding {
    
    // MARK: - Types
    
    enum EmbeddingError: LocalizedError {
        case modelNotFound
        case modelLoadFailed(String)
        case audioLoadFailed(String)
        case preprocessingFailed(String)
        case predictionFailed(String)
        case invalidEmbedding
        
        var errorDescription: String? {
            switch self {
            case .modelNotFound:
                return "Speaker embedding model not found. Please run convert_pyannote_to_coreml.py"
            case .modelLoadFailed(let error):
                return "Failed to load CoreML model: \(error)"
            case .audioLoadFailed(let error):
                return "Failed to load audio file: \(error)"
            case .preprocessingFailed(let error):
                return "Audio preprocessing failed: \(error)"
            case .predictionFailed(let error):
                return "Model prediction failed: \(error)"
            case .invalidEmbedding:
                return "Invalid embedding output from model"
            }
        }
    }
    
    // Use the common SpeakerEmbedding from SpeakerEmbeddingProtocol.swift
    
    // MARK: - Properties
    
    private var model: MLModel?
    private let logger = VoxtralLogger.shared
    private let sampleRate: Double = 16000  // Pyannote expects 16kHz
    private let windowSizeSeconds: Double = 3.0  // 3-second windows
    private var windowSizeSamples: Int { Int(windowSizeSeconds * sampleRate) }
    private(set) var isTestModel = false
    
    // MARK: - Initialization
    
    init() throws {
        try loadModel()
    }
    
    private func loadModel() throws {
        // Try to load from bundle first
        let modelName = "PyannoteSpeakerEmbedding"
        
        // Check Resources/Models directory (mlpackage)
        let mlpackageURL = Bundle.main.resourceURL?
            .appendingPathComponent("Models")
            .appendingPathComponent("\(modelName).mlpackage")
        
        // Check Resources/Models directory (compiled)
        let resourcesURL = Bundle.main.resourceURL?
            .appendingPathComponent("Models")
            .appendingPathComponent("\(modelName).mlmodelc")
        
        // Check compiled model in bundle
        let compiledURL = Bundle.main.url(
            forResource: modelName,
            withExtension: "mlmodelc"
        )
        
        // Try different locations
        let possibleURLs = [
            mlpackageURL,
            resourcesURL,
            compiledURL,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("AlmRecorder/Resources/Models/\(modelName).mlpackage")
        ].compactMap { $0 }
        
        for url in possibleURLs {
            if FileManager.default.fileExists(atPath: url.path) {
                logger.info("[PyannoteSpeakerEmbedding] Found model at: \(url.path)")
                do {
                    let config = MLModelConfiguration()
                    config.computeUnits = .cpuAndNeuralEngine
                    
                    self.model = try MLModel(contentsOf: url, configuration: config)
                    logger.info("[PyannoteSpeakerEmbedding] Model loaded successfully")
                    
                    // Check if this is a test model
                    if let metadata = model?.modelDescription.metadata,
                       let description = metadata[MLModelMetadataKey.description] as? String {
                        if description.contains("test") || description.contains("functional") {
                            self.isTestModel = true
                            logger.warning("[PyannoteSpeakerEmbedding] Using test model - embeddings will have zero confidence")
                        }
                    }
                    
                    return
                } catch {
                    logger.error("[PyannoteSpeakerEmbedding] Failed to load model from \(url.lastPathComponent): \(error)")
                }
            }
        }
        
        logger.error("[PyannoteSpeakerEmbedding] Model not found in any expected location")
        logger.info("[PyannoteSpeakerEmbedding] Expected locations:")
        for url in possibleURLs {
            logger.info("  - \(url.path)")
        }
        
        throw EmbeddingError.modelNotFound
    }
    
    // MARK: - Public Methods
    
    /// Extract speaker embedding from audio file
    /// - Parameter audioPath: Path to audio file (any format)
    /// - Returns: Speaker embedding with metadata
    func extractEmbedding(from audioPath: String) async throws -> SpeakerEmbedding {
        let url = URL(fileURLWithPath: audioPath)
        return try await extractEmbedding(from: url)
    }
    
    /// Extract speaker embedding from audio URL
    func extractEmbedding(from audioURL: URL) async throws -> SpeakerEmbedding {
        logger.info("[PyannoteSpeakerEmbedding] Extracting embedding from: \(audioURL.lastPathComponent)")
        
        // Load and preprocess audio
        let audioData = try await loadAndPreprocessAudio(from: audioURL)
        
        // Create MLMultiArray input
        let input = try MLMultiArray(
            shape: [1, 1, NSNumber(value: audioData.count)],
            dataType: .float32
        )
        
        // Fill the array
        for (index, value) in audioData.enumerated() {
            input[index] = NSNumber(value: value)
        }
        
        // Create model input
        let modelInput = try MLDictionaryFeatureProvider(dictionary: [
            "audio_input": MLFeatureValue(multiArray: input)
        ])
        
        // Run prediction
        guard let model = self.model else {
            throw EmbeddingError.modelNotFound
        }
        
        let output = try await model.prediction(from: modelInput)
        
        // Extract embedding
        guard let embeddingValue = output.featureValue(for: "speaker_embedding"),
              let embeddingArray = embeddingValue.multiArrayValue else {
            throw EmbeddingError.invalidEmbedding
        }
        
        // Convert to Float array (should be 512 dimensions)
        let embedding = (0..<embeddingArray.count).map { 
            Float(truncating: embeddingArray[$0])
        }
        
        logger.info("[PyannoteSpeakerEmbedding] Extracted \(embedding.count)-dimensional embedding")
        
        // Test models produce meaningless embeddings - return zero confidence
        // so they get ignored in clustering
        let confidence = isTestModel ? Float(0.0) : calculateConfidence(embedding: embedding)
        
        return SpeakerEmbedding(
            vector: embedding,
            audioPath: audioURL.path,
            duration: TimeInterval(audioData.count) / sampleRate,
            confidence: confidence
        )
    }
    
    /// Compare two speaker embeddings
    /// - Parameters:
    ///   - embedding1: First speaker embedding
    ///   - embedding2: Second speaker embedding
    /// - Returns: Similarity score (0-1, higher means more similar)
    func similarity(_ embedding1: [Float], _ embedding2: [Float]) -> Float {
        guard embedding1.count == embedding2.count else {
            logger.warning("[PyannoteSpeakerEmbedding] Embedding dimension mismatch")
            return 0
        }
        
        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        
        let count = vDSP_Length(embedding1.count)
        
        vDSP_dotpr(embedding1, 1, embedding2, 1, &dotProduct, count)
        vDSP_svesq(embedding1, 1, &normA, count)
        vDSP_svesq(embedding2, 1, &normB, count)
        
        guard normA > 0 && normB > 0 else { return 0 }
        
        return dotProduct / (sqrt(normA) * sqrt(normB))
    }
    
    /// Check if two embeddings belong to the same speaker
    /// - Parameters:
    ///   - embedding1: First speaker embedding
    ///   - embedding2: Second speaker embedding
    ///   - threshold: Similarity threshold (default: 0.85)
    /// - Returns: True if likely same speaker
    func isSameSpeaker(
        _ embedding1: [Float],
        _ embedding2: [Float],
        threshold: Float = 0.85
    ) -> Bool {
        return similarity(embedding1, embedding2) >= threshold
    }
    
    // MARK: - Private Methods
    
    private func loadAndPreprocessAudio(from url: URL) async throws -> [Float] {
        // Load audio file
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw EmbeddingError.audioLoadFailed(error.localizedDescription)
        }
        
        // Create format for 16kHz mono
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw EmbeddingError.preprocessingFailed("Failed to create audio format")
        }
        
        // Create converter
        guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
            throw EmbeddingError.preprocessingFailed("Failed to create audio converter")
        }
        
        // Calculate frame count for target sample rate
        let inputDuration = Double(file.length) / file.processingFormat.sampleRate
        let outputFrameCount = UInt32(inputDuration * sampleRate)
        
        // Create output buffer
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCount
        ) else {
            throw EmbeddingError.preprocessingFailed("Failed to create output buffer")
        }
        
        // Create input buffer and read file
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw EmbeddingError.preprocessingFailed("Failed to create input buffer")
        }
        
        do {
            try file.read(into: inputBuffer)
        } catch {
            throw EmbeddingError.audioLoadFailed("Failed to read audio data: \(error)")
        }
        
        // Convert audio
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }
        
        if let error = error {
            throw EmbeddingError.preprocessingFailed("Conversion failed: \(error)")
        }
        
        // Extract float array
        let floatData = Array(UnsafeBufferPointer(
            start: outputBuffer.floatChannelData![0],
            count: Int(outputBuffer.frameLength)
        ))
        
        // Handle window size
        if floatData.count > windowSizeSamples {
            // Take center window for best representation
            let startIdx = (floatData.count - windowSizeSamples) / 2
            return Array(floatData[startIdx..<(startIdx + windowSizeSamples)])
        } else if floatData.count < windowSizeSamples {
            // Pad with zeros if too short
            return floatData + Array(repeating: 0, count: windowSizeSamples - floatData.count)
        } else {
            return floatData
        }
    }
    
    private func calculateConfidence(embedding: [Float]) -> Float {
        // Calculate L2 norm of embedding
        var norm: Float = 0
        vDSP_svesq(embedding, 1, &norm, vDSP_Length(embedding.count))
        
        // Normalize to 0-1 range based on typical norms (10-30)
        let normalizedNorm = sqrt(norm)
        return min(1.0, normalizedNorm / 20.0)
    }
}
