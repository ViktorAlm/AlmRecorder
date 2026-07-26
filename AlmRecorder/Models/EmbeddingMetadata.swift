import Foundation

/// Metadata about embeddings stored in the database
struct EmbeddingMetadata {
    let dimensions: Int
    let modelId: String
    let quantization: QuantizationType
    let createdAt: Date
    
    enum QuantizationType: String {
        case binary = "binary"      // 1 bit per dimension
        case int8 = "int8"         // 8 bits per dimension
        case float16 = "float16"   // 16 bits per dimension
        case float32 = "float32"   // 32 bits per dimension
        
        var bytesPerDimension: Double {
            switch self {
            case .binary: return 0.125  // 1 bit = 0.125 bytes
            case .int8: return 1.0
            case .float16: return 2.0
            case .float32: return 4.0
            }
        }
    }
    
    /// Calculate storage size in bytes for this embedding
    func storageSize() -> Int {
        return Int(ceil(Double(dimensions) * quantization.bytesPerDimension))
    }
    
    /// Get the number of bits for binary quantization
    func binaryBits() -> Int {
        return dimensions
    }
}

/// Manages dynamic embedding dimensions
class EmbeddingDimensionManager {
    static let shared = EmbeddingDimensionManager()
    
    private let settingsRepo = GRDBSettingsRepository.shared
    private let dimensionsKey = "embedding.dimensions"
    private let modelIdKey = "embedding.modelId"
    private let quantizationKey = "embedding.quantization"
    
    private init() {}
    
    /// Current embedding dimensions (defaults to 768 for Qwen)
    var currentDimensions: Int {
        get {
            let stored = settingsRepo.getInt(forKey: dimensionsKey) ?? 0
            return stored > 0 ? stored : 768  // Default to Qwen's 768
        }
        set {
            settingsRepo.setInt(newValue, forKey: dimensionsKey)
        }
    }
    
    /// Current model ID
    var currentModelId: String {
        get {
            settingsRepo.getString(forKey: modelIdKey) ?? EmbeddingModelManager.defaultModelId
        }
        set {
            settingsRepo.setString(newValue, forKey: modelIdKey)
        }
    }
    
    /// Current quantization type
    var currentQuantization: EmbeddingMetadata.QuantizationType {
        get {
            let stored = settingsRepo.getString(forKey: quantizationKey) ?? "binary"
            return EmbeddingMetadata.QuantizationType(rawValue: stored) ?? .binary
        }
        set {
            settingsRepo.setString(newValue.rawValue, forKey: quantizationKey)
        }
    }
    
    /// Update dimensions based on selected model
    func updateDimensions(for modelId: String) {
        guard let model = EmbeddingModelManager.shared.availableModels.first(where: { $0.id == modelId }) else {
            return
        }
        
        currentDimensions = model.dimensions
        currentModelId = modelId
        
        print("[EmbeddingDimensionManager] Updated dimensions to \(model.dimensions) for model \(modelId)")
    }
    
    /// Get current metadata
    func getCurrentMetadata() -> EmbeddingMetadata {
        return EmbeddingMetadata(
            dimensions: currentDimensions,
            modelId: currentModelId,
            quantization: currentQuantization,
            createdAt: Date()
        )
    }
    
    /// Calculate required storage bytes for current settings
    func getStorageBytes() -> Int {
        return getCurrentMetadata().storageSize()
    }
    
    /// Validate embedding data size matches expected dimensions
    func validateEmbeddingSize(_ data: Data) -> Bool {
        let expected = getStorageBytes()
        return data.count == expected
    }
}