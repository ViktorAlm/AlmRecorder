import Foundation
import Combine

/// Configuration for available embedding models
struct EmbeddingModelConfig {
    let id: String
    let name: String
    let description: String
    let modelFile: String
    let downloadURL: String
    let sizeInMB: Int
    let ramRequiredMB: Int
    let dimensions: Int
    let embeddingsPerSecond: Int
    let supportsMultilingual: Bool
    let quality: ModelQuality
    
    enum ModelQuality: String, CaseIterable {
        case tiny = "Tiny"
        case small = "Small"
        case medium = "Medium"
        case large = "Large"
        
        var color: String {
            switch self {
            case .tiny: return "gray"
            case .small: return "blue"
            case .medium: return "purple"
            case .large: return "orange"
            }
        }
    }
    
    var formattedSize: String {
        "\(sizeInMB) MB"
    }
    
    var formattedRAM: String {
        if ramRequiredMB >= 1000 {
            return String(format: "%.1f GB", Double(ramRequiredMB) / 1000.0)
        }
        return "\(ramRequiredMB) MB"
    }
    
    var formattedSpeed: String {
        "\(embeddingsPerSecond) emb/sec"
    }
}

/// Manages embedding model downloads and selection
class EmbeddingModelManager: ObservableObject {
    private let logger = VoxtralLogger.shared
    static let shared = EmbeddingModelManager()
    private let settingsRepo = GRDBSettingsRepository.shared
    
    // MARK: - Constants
    /// Default model - Qwen3 0.6B Q8 for best balance of quality and performance
    static let defaultModelId = "qwen3-embed-0.6b-q8"
    
    // MARK: - Published Properties
    @Published var availableModels: [EmbeddingModelConfig] = []
    @Published var currentModel: String = ""
    @Published var isModelLoaded: Bool = false
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var downloadedModels: Set<String> = []
    @Published var estimatedTimeRemaining: String = ""
    
    // MARK: - Private Properties
    private var downloadTask: URLSessionDownloadTask?
    private let modelsDirectory: URL
    private let fileManager = FileManager.default
    
    // MARK: - Model Catalog
    private let modelCatalog: [EmbeddingModelConfig] = [
        // Qwen3-Embedding-0.6B variants (1024 dimensions)
        // Note: Only Q8_0 and F16 variants are officially available
        EmbeddingModelConfig(
            id: "qwen3-embed-0.6b-q8",
            name: "Qwen3 0.6B Q8_0",
            description: "8-bit quantized, high quality with good performance",
            modelFile: "Qwen3-Embedding-0.6B-Q8_0.gguf",
            downloadURL: "https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF/resolve/main/Qwen3-Embedding-0.6B-Q8_0.gguf",
            sizeInMB: 639,
            ramRequiredMB: 800,
            dimensions: 1024,  // Actual dimension for 0.6B model
            embeddingsPerSecond: 85,
            supportsMultilingual: true,
            quality: .medium
        ),
        
        EmbeddingModelConfig(
            id: "qwen3-embed-0.6b-f16",
            name: "Qwen3 0.6B F16",
            description: "Full 16-bit precision, highest quality",
            modelFile: "Qwen3-Embedding-0.6B-f16.gguf",
            downloadURL: "https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF/resolve/main/Qwen3-Embedding-0.6B-f16.gguf",
            sizeInMB: 1200,
            ramRequiredMB: 1400,
            dimensions: 1024,  // Actual dimension for 0.6B model
            embeddingsPerSecond: 80,
            supportsMultilingual: true,
            quality: .large
        )
    ]
    
    // MARK: - Initialization
    private init() {
        // Set up models directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first!
        self.modelsDirectory = appSupport
            .appendingPathComponent("AlmRecorder")
            .appendingPathComponent("EmbeddingModels")
        
        // Create directory if needed
        try? fileManager.createDirectory(at: modelsDirectory,
                                        withIntermediateDirectories: true)
        
        // Load model catalog
        self.availableModels = modelCatalog
        
        // Check for downloaded models
        updateDownloadedModels()
        
        // Load saved preference
        if let savedModel = settingsRepo.getString(forKey: "selectedEmbeddingModel"),
           isModelDownloaded(savedModel) {
            currentModel = savedModel
            isModelLoaded = true
        } else {
            // Try to migrate from UserDefaults
            if let legacyModel = UserDefaults.standard.string(forKey: "selectedEmbeddingModel") {
                settingsRepo.setString(legacyModel, forKey: "selectedEmbeddingModel")
                UserDefaults.standard.removeObject(forKey: "selectedEmbeddingModel")
                if isModelDownloaded(legacyModel) {
                    currentModel = legacyModel
                    isModelLoaded = true
                    return
                }
            }
            
            // Auto-select or download default model
            Task {
                await ensureDefaultModel()
            }
        }
    }
    
    // MARK: - Public Methods
    
    /// Ensure default model is downloaded and selected
    @MainActor
    func ensureDefaultModel() async {
        // Check if any model is already selected
        if !currentModel.isEmpty && isModelDownloaded(currentModel) {
            return
        }
        
        // Check if default model is downloaded
        if isModelDownloaded(Self.defaultModelId) {
            try? selectModel(Self.defaultModelId)
            return
        }
        
        // Download default model
        logger.info("[EmbeddingModelManager] Downloading default model: \(Self.defaultModelId)")
        do {
            try await downloadModel(Self.defaultModelId)
            try selectModel(Self.defaultModelId)
            logger.info("[EmbeddingModelManager] Default model ready: \(Self.defaultModelId)")
        } catch {
            logger.error("[EmbeddingModelManager] Failed to download default model: \(error)")
        }
    }
    
    /// Check if a model is downloaded
    func isModelDownloaded(_ modelId: String) -> Bool {
        guard let model = availableModels.first(where: { $0.id == modelId }) else {
            return false
        }
        let modelPath = modelsDirectory.appendingPathComponent(model.modelFile)
        
        // Check file exists
        guard fileManager.fileExists(atPath: modelPath.path) else {
            return false
        }
        
        // Validate file size (must be at least 10MB for a valid model)
        if let attributes = try? fileManager.attributesOfItem(atPath: modelPath.path),
           let size = attributes[.size] as? Int64 {
            // Models should be at least 10MB
            return size > 10_000_000
        }
        
        return false
    }
    
    /// Get path to a downloaded model
    func getModelPath(for modelId: String) -> URL? {
        guard let model = availableModels.first(where: { $0.id == modelId }),
              isModelDownloaded(modelId) else {
            return nil
        }
        return modelsDirectory.appendingPathComponent(model.modelFile)
    }
    
    /// Download a model using UnifiedDownloadQueue
    func downloadModel(_ modelId: String) async throws {
        guard let model = availableModels.first(where: { $0.id == modelId }) else {
            throw EmbeddingError.modelNotFound
        }
        
        guard !isModelDownloaded(modelId) else {
            logger.info("[EmbeddingModelManager] Model already downloaded: \(modelId)")
            return
        }
        
        let destinationURL = modelsDirectory.appendingPathComponent(model.modelFile)
        
        // Use UnifiedDownloadQueue
        UnifiedDownloadQueue.shared.enqueueDownload(
            modelId: modelId,
            displayName: model.name,
            modelType: "embedding",
            downloadURL: URL(string: model.downloadURL)!,
            destinationPath: destinationURL,
            fileSize: Int64(model.sizeInMB * 1_000_000)
        )
        
        logger.info("[EmbeddingModelManager] Enqueued download: \(model.name)")
        
        // Update UI state
        await MainActor.run {
            isDownloading = UnifiedDownloadQueue.shared.isInQueue(modelId)
            updateDownloadedModels()
        }
        
        // For compatibility with async/await pattern, wait for download
        await waitForDownload(modelId)
    }
    
    /// Wait for a model to finish downloading
    private func waitForDownload(_ modelId: String) async {
        let maxWaitTime: TimeInterval = 3600 // 1 hour
        let checkInterval: TimeInterval = 1.0
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < maxWaitTime {
            // Check if downloaded
            if isModelDownloaded(modelId) {
                await MainActor.run {
                    isDownloading = false
                    downloadProgress = 1.0
                    updateDownloadedModels()
                }
                return
            }
            
            // Check if still in queue
            if !UnifiedDownloadQueue.shared.isInQueue(modelId) {
                // Check if failed
                if let task = UnifiedDownloadQueue.shared.downloadTasks.first(where: { $0.modelId == modelId }) {
                    if task.state == .failed {
                        await MainActor.run {
                            isDownloading = false
                            downloadProgress = 0.0
                        }
                        return
                    }
                }
            }
            
            // Update progress
            if let task = UnifiedDownloadQueue.shared.downloadTasks.first(where: { $0.modelId == modelId }) {
                await MainActor.run {
                    downloadProgress = task.progress
                }
            }
            
            // Wait before checking again
            try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
        }
    }
    
    /// Delete a model
    func deleteModel(_ modelId: String) throws {
        guard let model = availableModels.first(where: { $0.id == modelId }) else {
            throw EmbeddingError.modelNotFound
        }
        
        let modelPath = modelsDirectory.appendingPathComponent(model.modelFile)
        
        if fileManager.fileExists(atPath: modelPath.path) {
            try fileManager.removeItem(at: modelPath)
            updateDownloadedModels()
            
            if currentModel == modelId {
                currentModel = ""
                isModelLoaded = false
                autoSelectModel()
            }
        }
    }
    
    /// Select a model for use
    func selectModel(_ modelId: String) throws {
        guard isModelDownloaded(modelId) else {
            throw EmbeddingError.modelNotDownloaded
        }
        
        currentModel = modelId
        isModelLoaded = true
        settingsRepo.setString(modelId, forKey: "selectedEmbeddingModel")
        
        // Update dimension manager with new model's dimensions
        if let model = availableModels.first(where: { $0.id == modelId }) {
            EmbeddingDimensionManager.shared.updateDimensions(for: modelId)
            logger.info("[EmbeddingModelManager] Selected model: \(modelId) with \(model.dimensions) dimensions")
        } else {
            logger.info("[EmbeddingModelManager] Selected model: \(modelId)")
        }
    }
    
    /// Get total disk usage of downloaded models
    func getTotalDiskUsage() -> Int64 {
        var totalSize: Int64 = 0
        
        for model in availableModels where isModelDownloaded(model.id) {
            let modelPath = modelsDirectory.appendingPathComponent(model.modelFile)
            if let attributes = try? fileManager.attributesOfItem(atPath: modelPath.path),
               let size = attributes[.size] as? Int64 {
                totalSize += size
            }
        }
        
        return totalSize
    }
    
    // MARK: - Private Methods
    
    private func updateDownloadedModels() {
        var downloaded: Set<String> = []
        for model in availableModels {
            if isModelDownloaded(model.id) {
                downloaded.insert(model.id)
            }
        }
        self.downloadedModels = downloaded
    }
    
    private func autoSelectModel() {
        // Get system RAM
        let totalRAM = ProcessInfo.processInfo.physicalMemory / (1024 * 1024) // MB
        
        // Find best model for available RAM (use 25% of total RAM as threshold)
        let availableForModel = Int(Double(totalRAM) * 0.25)
        
        // Sort by quality (descending) and find best fit
        let sortedModels = availableModels.sorted { $0.ramRequiredMB > $1.ramRequiredMB }
        
        for model in sortedModels {
            if model.ramRequiredMB <= availableForModel && isModelDownloaded(model.id) {
                try? selectModel(model.id)
                return
            }
        }
        
        // If no model fits or is downloaded, select the smallest one
        if let smallest = availableModels.min(by: { $0.ramRequiredMB < $1.ramRequiredMB }) {
            logger.info("[EmbeddingModelManager] Auto-selected smallest model: \(smallest.id)")
            // Don't auto-download, just mark as preferred
            settingsRepo.setString(smallest.id, forKey: "preferredEmbeddingModel")
        }
    }
}

// MARK: - Errors
enum EmbeddingError: LocalizedError {
    case modelNotFound
    case modelNotDownloaded
    case downloadFailed(String)
    case invalidModelFile
    case embeddingGenerationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "Embedding model not found"
        case .modelNotDownloaded:
            return "Model must be downloaded first"
        case .downloadFailed(let reason):
            return "Download failed: \(reason)"
        case .invalidModelFile:
            return "Invalid model file format"
        case .embeddingGenerationFailed(let reason):
            return "Failed to generate embedding: \(reason)"
        }
    }
}