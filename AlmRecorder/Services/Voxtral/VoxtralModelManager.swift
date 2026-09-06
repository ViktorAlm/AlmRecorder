import Foundation
import Combine

/// Manages Voxtral model downloads and status
class VoxtralModelManager: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var isModelLoaded = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var currentModel: String = ""
    
    // MARK: - Private Properties
    
    private let modelsDirectory: URL
    private let logger = VoxtralLogger.shared
    private var downloadTask: URLSessionDownloadTask?
    
    // MARK: - Initialization
    
    init() {
        self.modelsDirectory = VoxtralConfiguration.modelsDirectory
        createModelsDirectoryIfNeeded()
        checkModelStatus()
    }
    
    // MARK: - Public Methods
    
    /// Check if a specific model is downloaded
    func isModelDownloaded(_ modelKey: String) -> Bool {
        guard let config = VoxtralConfiguration.models[modelKey] else {
            return false
        }
        
        let modelPath = modelsDirectory.appendingPathComponent(config.modelFile)
        let mmprojPath = modelsDirectory.appendingPathComponent(config.mmprojFile)
        
        // Check both files exist
        guard FileManager.default.fileExists(atPath: modelPath.path),
              FileManager.default.fileExists(atPath: mmprojPath.path) else {
            return false
        }
        
        // Reject partial files; catalog sizes are estimates, so use the shared conservative floor.
        if let modelAttrs = try? FileManager.default.attributesOfItem(atPath: modelPath.path),
           let modelSize = modelAttrs[.size] as? Int64,
           let mmprojAttrs = try? FileManager.default.attributesOfItem(atPath: mmprojPath.path),
           let mmprojSize = mmprojAttrs[.size] as? Int64 {
            return UnifiedDownloadQueue.isAcceptableFileSize(
                modelSize,
                declaredSize: Int64(config.sizeGB * 1_000_000_000)
            ) && UnifiedDownloadQueue.isAcceptableFileSize(
                mmprojSize,
                declaredSize: Int64(config.mmprojSizeGB * 1_000_000_000)
            )
        }
        
        return false
    }
    
    /// Get the path for a model file (only if it exists)
    func getModelPath(for modelKey: String) -> URL? {
        guard let config = VoxtralConfiguration.models[modelKey] else {
            return nil
        }
        let modelPath = modelsDirectory.appendingPathComponent(config.modelFile)
        // Only return the path if the file actually exists
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            logger.warning("Model file not found at path: \(modelPath.path)")
            return nil
        }
        return modelPath
    }
    
    /// Get the path for a mmproj file (only if it exists)
    func getMmprojPath(for modelKey: String) -> URL? {
        guard let config = VoxtralConfiguration.models[modelKey] else {
            return nil
        }
        let mmprojPath = modelsDirectory.appendingPathComponent(config.mmprojFile)
        // Only return the path if the file actually exists
        guard FileManager.default.fileExists(atPath: mmprojPath.path) else {
            logger.warning("Mmproj file not found at path: \(mmprojPath.path)")
            return nil
        }
        return mmprojPath
    }
    
    /// Download a model
    func downloadModel(_ modelKey: String) async throws {
        guard let config = VoxtralConfiguration.models[modelKey] else {
            logger.error("Model configuration not found for: \(modelKey)")
            throw TranscriptionError.modelNotFound
        }
        
        logger.info("Starting download for model: \(config.name)")
        
        // Check if already downloaded with valid size
        if isModelDownloaded(modelKey) {
            logger.info("Model already downloaded: \(config.name)")
            await MainActor.run {
                isModelLoaded = true
                currentModel = modelKey
            }
            return
        }
        
        let modelPath = modelsDirectory.appendingPathComponent(config.modelFile)
        let mmprojPath = modelsDirectory.appendingPathComponent(config.mmprojFile)
        
        // Prepare additional files for download
        let additionalFiles = [
            UnifiedDownloadQueue.AdditionalDownload(
                url: URL(string: config.mmprojURL)!,
                path: mmprojPath,
                fileSize: Int64(config.mmprojSizeGB * 1_000_000_000)
            )
        ]
        
        // Use UnifiedDownloadQueue
        UnifiedDownloadQueue.shared.enqueueDownload(
            modelId: "voxtral-\(modelKey)",
            displayName: config.name,
            modelType: "voxtral",
            downloadURL: URL(string: config.modelURL)!,
            destinationPath: modelPath,
            fileSize: Int64(config.sizeGB * 1_000_000_000),
            additionalFiles: additionalFiles
        )
        
        logger.info("Enqueued download: \(config.name)")
        
        // Update UI state
        await MainActor.run {
            isDownloading = UnifiedDownloadQueue.shared.isInQueue("voxtral-\(modelKey)")
        }
        
        // Wait for download to complete
        guard await waitForDownload("voxtral-\(modelKey)") else {
            throw TranscriptionError.downloadFailed
        }
        // The projector is queued only after the primary GGUF completes. Do not report the model
        // ready while that required second file is still downloading.
        guard await waitForDownload("voxtral-\(modelKey)-additional") else {
            throw TranscriptionError.downloadFailed
        }
        
        // Check if download succeeded
        if isModelDownloaded(modelKey) {
            await MainActor.run {
                isModelLoaded = true
                currentModel = modelKey
                downloadProgress = 1.0
            }
            logger.info("Successfully downloaded model: \(config.name)")
        } else {
            throw TranscriptionError.downloadFailed
        }
    }
    
    /// Delete a downloaded model
    func deleteModel(_ modelKey: String) throws {
        guard let config = VoxtralConfiguration.models[modelKey] else {
            throw TranscriptionError.modelNotFound
        }
        
        let modelPath = modelsDirectory.appendingPathComponent(config.modelFile)
        let mmprojPath = modelsDirectory.appendingPathComponent(config.mmprojFile)
        
        if FileManager.default.fileExists(atPath: modelPath.path) {
            try FileManager.default.removeItem(at: modelPath)
        }
        
        if FileManager.default.fileExists(atPath: mmprojPath.path) {
            try FileManager.default.removeItem(at: mmprojPath)
        }
        
        if currentModel == modelKey {
            currentModel = ""
            isModelLoaded = false
        }
        
        logger.info("Deleted model: \(config.name)")
    }
    
    /// Get the size of a downloaded model in bytes
    func getModelSize(_ modelKey: String) -> Int64 {
        guard let config = VoxtralConfiguration.models[modelKey] else {
            return 0
        }
        
        let modelPath = modelsDirectory.appendingPathComponent(config.modelFile)
        let mmprojPath = modelsDirectory.appendingPathComponent(config.mmprojFile)
        
        var totalSize: Int64 = 0
        
        if let attributes = try? FileManager.default.attributesOfItem(atPath: modelPath.path),
           let size = attributes[.size] as? Int64 {
            totalSize += size
        }
        
        if let attributes = try? FileManager.default.attributesOfItem(atPath: mmprojPath.path),
           let size = attributes[.size] as? Int64 {
            totalSize += size
        }
        
        return totalSize
    }
    
    // MARK: - Private Methods
    
    private func createModelsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: modelsDirectory,
                                                   withIntermediateDirectories: true,
                                                   attributes: nil)
        } catch {
            logger.error("Failed to create models directory: \(error.localizedDescription)")
        }
    }
    
    private func checkModelStatus() {
        // Check for default model
        let defaultModel = VoxtralConfiguration.defaultModel
        if isModelDownloaded(defaultModel) {
            currentModel = defaultModel
            isModelLoaded = true
            logger.info("Default model is loaded: \(defaultModel)")
        } else {
            // Check if any model is downloaded
            for (key, _) in VoxtralConfiguration.models {
                if isModelDownloaded(key) {
                    currentModel = key
                    isModelLoaded = true
                    logger.info("Found downloaded model: \(key)")
                    break
                }
            }
        }
    }
    
    /// Wait for a model to finish downloading
    private func waitForDownload(_ modelId: String) async -> Bool {
        let maxWaitTime: TimeInterval = 8 * 60 * 60
        let checkInterval: TimeInterval = 1.0
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < maxWaitTime {
            // Check if still in queue
            if !UnifiedDownloadQueue.shared.isInQueue(modelId) {
                // Either completed or failed
                if let task = UnifiedDownloadQueue.shared.downloadTasks.first(where: { $0.modelId == modelId }) {
                    if task.state == .completed {
                        await MainActor.run {
                            isDownloading = false
                            downloadProgress = 1.0
                        }
                        return true
                    } else if task.state == .failed {
                        await MainActor.run {
                            isDownloading = false
                            downloadProgress = 0.0
                        }
                        return false
                    }
                } else if Date().timeIntervalSince(startTime) >= 5 {
                    logger.error("Download task was never created: \(modelId)")
                    return false
                }
            }
            
            // Update progress
            if let task = UnifiedDownloadQueue.shared.downloadTasks.first(where: { $0.modelId == modelId }) {
                await MainActor.run {
                    downloadProgress = task.progress
                }
            }
            
            // Wait before checking again
            do {
                try await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
            } catch {
                return false
            }
        }
        logger.error("Download timed out: \(modelId)")
        return false
    }
}
