import Foundation

// MARK: - Unified Model Protocol

/// Protocol that all model types must conform to for unified management
protocol UnifiedModelVariant: Identifiable, Equatable, Hashable {
    /// Unique identifier for the model
    var id: String { get }
    
    /// Display name shown in UI
    var displayName: String { get }
    
    /// Short description of the model
    var description: String { get }
    
    /// Model type (whisper, voxtral, embedding)
    var modelType: ModelType { get }
    
    /// Model family/provider (e.g., OpenAI, KBLab, Qwen)
    var family: String { get }
    
    /// Model size in bytes
    var sizeInBytes: Int64 { get }
    
    /// Download URL
    var downloadURL: URL? { get }
    
    /// Local file path where model should be stored
    var localPath: URL { get }
    
    /// Additional files needed (e.g., mmproj for Voxtral)
    var additionalFiles: [AdditionalFile] { get }
    
    /// Check if model is downloaded
    func isDownloaded() -> Bool
}

// MARK: - Supporting Types

enum ModelType: String, CaseIterable {
    case whisper = "Whisper"      // Speech-to-text
    case voxtral = "Voxtral"      // Multi-modal transcription
    case embedding = "Embedding"   // Semantic embeddings
    case summary = "Summary"       // Text summarization
    
    var icon: String {
        switch self {
        case .whisper: return "waveform.badge.mic"
        case .voxtral: return "cpu"
        case .embedding: return "sparkles"
        case .summary: return "doc.text"
        }
    }
    
    var description: String {
        switch self {
        case .whisper: return "Speech-to-text transcription"
        case .voxtral: return "Multi-modal transcription"
        case .embedding: return "Semantic search embeddings"
        case .summary: return "Text summarization"
        }
    }
}

struct AdditionalFile {
    let filename: String
    let downloadURL: URL
    let localPath: URL
    let sizeInBytes: Int64
}

// MARK: - Model Quality/Performance Profiles

enum ModelQuality: Int, CaseIterable, Comparable {
    case tiny = 0
    case small = 1
    case medium = 2
    case large = 3
    case xlarge = 4
    
    static func < (lhs: ModelQuality, rhs: ModelQuality) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
    
    var description: String {
        switch self {
        case .tiny: return "Tiny - Fastest"
        case .small: return "Small - Fast"
        case .medium: return "Medium - Balanced"
        case .large: return "Large - High Quality"
        case .xlarge: return "XLarge - Best Quality"
        }
    }
}

// MARK: - Download Priority

enum DownloadPriority: Int, Comparable {
    case low = 0
    case normal = 1
    case high = 2
    case critical = 3  // For models needed immediately for transcription
    
    static func < (lhs: DownloadPriority, rhs: DownloadPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Model Status

enum ModelStatus {
    case notDownloaded
    case queued
    case downloading(progress: Double)
    case downloaded
    case failed(error: String)
    case updating
}

// MARK: - Unified Model Wrapper

/// Wrapper to make existing models conform to UnifiedModelVariant
struct UnifiedModel: UnifiedModelVariant {
    let id: String
    let displayName: String
    let description: String
    let modelType: ModelType
    let family: String
    let sizeInBytes: Int64
    let downloadURL: URL?
    let localPath: URL
    let additionalFiles: [AdditionalFile]
    
    private let downloadChecker: () -> Bool
    
    init(
        id: String,
        displayName: String,
        description: String,
        modelType: ModelType,
        family: String,
        sizeInBytes: Int64,
        downloadURL: URL?,
        localPath: URL,
        additionalFiles: [AdditionalFile] = [],
        isDownloaded: @escaping () -> Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.modelType = modelType
        self.family = family
        self.sizeInBytes = sizeInBytes
        self.downloadURL = downloadURL
        self.localPath = localPath
        self.additionalFiles = additionalFiles
        self.downloadChecker = isDownloaded
    }
    
    func isDownloaded() -> Bool {
        downloadChecker()
    }
    
    // Equatable
    static func == (lhs: UnifiedModel, rhs: UnifiedModel) -> Bool {
        lhs.id == rhs.id
    }
    
    // Hashable
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Extensions for Existing Models

extension WhisperModelVariant {
    // Create a UnifiedModel wrapper for WhisperModelVariant
    func toUnifiedModel() -> any UnifiedModelVariant {
        UnifiedModel(
            id: toIdentifier(),
            displayName: displayName,
            description: "\(family.rawValue) \(size.rawValue) model with \(quantization.description)",
            modelType: .whisper,
            family: family.rawValue,
            sizeInBytes: estimatedSize,
            downloadURL: downloadURL,
            localPath: localPath,
            additionalFiles: [],
            isDownloaded: {
                WhisperModelManager.shared.isModelDownloaded(self)
            }
        )
    }
}

// MARK: - Model Collection

/// Collection of all available models
class UnifiedModelCatalog {
    static let shared = UnifiedModelCatalog()
    
    private init() {}
    
    /// Get all available models
    func getAllModels() -> [any UnifiedModelVariant] {
        var models: [any UnifiedModelVariant] = []
        
        // Add Whisper models
        models.append(contentsOf: WhisperModelVariant.recommendedModels.map { $0.toUnifiedModel() })
        
        // Add Voxtral models
        models.append(contentsOf: getVoxtralModels())
        
        // Add Embedding models
        models.append(contentsOf: getEmbeddingModels())
        
        return models
    }
    
    /// Get models by type
    func getModels(for type: ModelType) -> [any UnifiedModelVariant] {
        getAllModels().filter { $0.modelType == type }
    }
    
    // MARK: - Voxtral Models
    
    private func getVoxtralModels() -> [any UnifiedModelVariant] {
        VoxtralConfiguration.models.compactMap { key, config in
            let mmProjFile = AdditionalFile(
                filename: config.mmprojFile,
                downloadURL: URL(string: config.mmprojURL)!,
                localPath: VoxtralConfiguration.modelsDirectory.appendingPathComponent(config.mmprojFile),
                sizeInBytes: Int64(config.mmprojSizeGB * 1_000_000_000)
            )
            
            return UnifiedModel(
                id: "voxtral-\(key)",
                displayName: config.name,
                description: "Voxtral \(config.name)",
                modelType: .voxtral,
                family: "Voxtral",
                sizeInBytes: Int64(config.sizeGB * 1_000_000_000),
                downloadURL: URL(string: config.modelURL),
                localPath: VoxtralConfiguration.modelsDirectory.appendingPathComponent(config.modelFile),
                additionalFiles: [mmProjFile],
                isDownloaded: {
                    VoxtralModelManager().isModelDownloaded(key)
                }
            )
        }
    }
    
    // MARK: - Embedding Models
    
    private func getEmbeddingModels() -> [any UnifiedModelVariant] {
        EmbeddingModelManager.shared.availableModels.map { config in
            UnifiedModel(
                id: "embedding-\(config.id)",
                displayName: config.name,
                description: config.description,
                modelType: .embedding,
                family: "Qwen",
                sizeInBytes: Int64(config.sizeInMB * 1_000_000),
                downloadURL: URL(string: config.downloadURL),
                localPath: URL(fileURLWithPath: NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first!)
                    .appendingPathComponent("AlmRecorder/EmbeddingModels")
                    .appendingPathComponent(config.modelFile),
                additionalFiles: [],
                isDownloaded: {
                    EmbeddingModelManager.shared.isModelDownloaded(config.id)
                }
            )
        }
    }
}
