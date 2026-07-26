import Foundation
import Combine

/// Manages Whisper model downloads and status
class WhisperModelManager: NSObject, ObservableObject {
    private let logger = VoxtralLogger.shared
    
    // MARK: - Published Properties
    
    @Published var isModelLoaded = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var currentModel: String = ""
    @Published var availableModels: [WhisperModelVariant] = WhisperModelVariant.recommendedModels
    @Published var downloadedModels: Set<WhisperModelVariant> = []
    @Published var currentVariant: WhisperModelVariant?
    
    // MARK: - Private Properties
    
    private let modelsDirectory: URL
    private var downloadTask: URLSessionDownloadTask?
    private var urlSession: URLSession!
    private var downloadContinuation: CheckedContinuation<Void, Error>?
    private var currentDownloadVariant: WhisperModelVariant?
    private var refreshTimer: Timer?
    
    // MARK: - Singleton
    
    static let shared = WhisperModelManager()
    
    // MARK: - Initialization
    
    override private init() {
        self.modelsDirectory = WhisperConfiguration.modelsDirectory
        super.init()
        
        // Configure URLSession (using default, not background, for CLI compatibility)
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 5
        config.timeoutIntervalForRequest = 300 // 5 minutes for initial response
        config.timeoutIntervalForResource = 7200 // 2 hours for large models
        config.allowsCellularAccess = true
        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        
        createModelsDirectoryIfNeeded()
        checkDownloadedModels()
        
        logger.info("[WhisperModelManager] Available models count: \(availableModels.count)")
        for model in availableModels {
            logger.info("[WhisperModelManager] Available: \(model.displayName) - \(model.family.rawValue)")
        }
        
        // Set up periodic refresh to detect externally downloaded models
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            self.checkDownloadedModels()
        }
        
        // Sync with GlobalModelSettings after init completes
        Task { @MainActor in
            self.syncWithGlobalSettings()
        }
    }
    
    // MARK: - Public Methods
    
    /// Sync current variant with GlobalModelSettings (called after init)
    @MainActor
    private func syncWithGlobalSettings() {
        if currentVariant == nil {
            currentVariant = GlobalModelSettings.shared.selectedWhisperVariant
            if let variant = currentVariant {
                currentModel = variant.displayName
            }
        }
    }
    
    /// Check if a specific model variant is downloaded
    func isModelDownloaded(_ variant: WhisperModelVariant) -> Bool {
        let modelPath = modelPath(for: variant)
        
        // Check if file exists
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            return false
        }
        
        // Validate file size (must be at least 1MB)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: modelPath.path),
           let fileSize = attributes[.size] as? Int64,
           fileSize > 1_000_000 {
            return true
        }
        
        // File exists but is too small, probably corrupted
        logger.warning("[WhisperModelManager] Model file corrupted or too small: \(variant.displayName)")
        try? FileManager.default.removeItem(at: modelPath)
        return false
    }
    
    // MARK: - Legacy Bridge Methods
    
    /// Bridge property for backward compatibility - returns model keys as strings
    var downloadedModelKeys: Set<String> {
        Set(downloadedModels.compactMap { variant in
            // Try to find matching legacy key first
            if let legacyKey = variant.toLegacyKey() {
                return legacyKey
            }
            // Fallback to variant identifier
            return variant.toIdentifier()
        })
    }
    
    /// Check if a model is downloaded by legacy string key
    func isModelDownloaded(_ modelKey: String) -> Bool {
        // Try to parse from legacy key
        if let variant = WhisperModelVariant.fromLegacyKey(modelKey) {
            return isModelDownloaded(variant)
        }
        
        // Try to parse as variant identifier
        if let variant = WhisperModelVariant.fromIdentifier(modelKey) {
            return isModelDownloaded(variant)
        }
        
        return false
    }
    
    /// Download a model by legacy string key
    func downloadModel(_ modelKey: String) async throws {
        // Try to parse from legacy key
        if let variant = WhisperModelVariant.fromLegacyKey(modelKey) {
            try await downloadModel(variant)
            return
        }
        
        // Try to parse as variant identifier
        if let variant = WhisperModelVariant.fromIdentifier(modelKey) {
            try await downloadModel(variant)
            return
        }
        
        throw TranscriptionError.modelNotFound
    }
    
    /// Get model path by legacy string key
    func getModelPath(for modelKey: String) -> URL? {
        // Try to parse from legacy key
        if let variant = WhisperModelVariant.fromLegacyKey(modelKey) {
            return getModelPath(for: variant)
        }
        
        // Try to parse as variant identifier
        if let variant = WhisperModelVariant.fromIdentifier(modelKey) {
            return getModelPath(for: variant)
        }
        
        return nil
    }
    
    /// Delete a model by legacy string key
    func deleteModel(_ modelKey: String) throws {
        // Try to parse from legacy key
        if let variant = WhisperModelVariant.fromLegacyKey(modelKey) {
            try deleteModel(variant)
            return
        }
        
        // Try to parse as variant identifier
        if let variant = WhisperModelVariant.fromIdentifier(modelKey) {
            try deleteModel(variant)
            return
        }
        
        throw TranscriptionError.modelNotFound
    }
    
    /// Get variant from legacy model key
    func getVariant(for modelKey: String) -> WhisperModelVariant? {
        // Try to parse from legacy key
        if let variant = WhisperModelVariant.fromLegacyKey(modelKey) {
            return variant
        }
        
        // Try to parse as variant identifier
        if let variant = WhisperModelVariant.fromIdentifier(modelKey) {
            return variant
        }
        
        return nil
    }
    
    /// Get the full path for a model file
    func getModelPath(for variant: WhisperModelVariant) -> URL? {
        guard isModelDownloaded(variant) else {
            return nil
        }
        
        return modelPath(for: variant)
    }
    
    /// Download a model (non-blocking using queue)
    func downloadModel(_ variant: WhisperModelVariant) async throws {
        // Check if already downloaded
        if isModelDownloaded(variant) {
            logger.info("[WhisperModelManager] Model already downloaded: \(variant.displayName)")
            return
        }
        
        logger.info("[WhisperModelManager] Enqueuing download for model: \(variant.displayName)")
        
        // Use unified download queue
        guard let downloadURL = variant.downloadURL else {
            logger.error("[WhisperModelManager] No download URL for model: \(variant.displayName)")
            throw TranscriptionError.invalidURL
        }
        
        let modelId = "whisper-\(variant.toIdentifier())"
        UnifiedDownloadQueue.shared.enqueueDownload(
            modelId: modelId,
            displayName: variant.displayName,
            modelType: "whisper",
            downloadURL: downloadURL,
            destinationPath: modelPath(for: variant),
            fileSize: variant.estimatedSize
        )
        
        // Always wait for TinyDiarize models and other critical models during transcription
        // These are required for the transcription pipeline to work
        let isTinyDiarize = variant.version == .tdrz
        let shouldWaitOther = await shouldWaitForDownload()
        let shouldWait = isTinyDiarize || shouldWaitOther
        
        if shouldWait {
            logger.info("[WhisperModelManager] Waiting for model download to complete: \(variant.displayName)")
            try await waitForDownloadUnified(modelId)
            logger.info("[WhisperModelManager] Model download completed: \(variant.displayName)")
        }
    }
    
    /// Download a model without blocking (returns immediately)
    func downloadModelNonBlocking(_ variant: WhisperModelVariant) {
        if isModelDownloaded(variant) {
            logger.info("[WhisperModelManager] Model already downloaded: \(variant.displayName)")
            return
        }
        
        guard let downloadURL = variant.downloadURL else {
            logger.error("[WhisperModelManager] No download URL for model: \(variant.displayName)")
            return
        }
        
        let modelId = "whisper-\(variant.toIdentifier())"
        UnifiedDownloadQueue.shared.enqueueDownload(
            modelId: modelId,
            displayName: variant.displayName,
            modelType: "whisper",
            downloadURL: downloadURL,
            destinationPath: modelPath(for: variant),
            fileSize: variant.estimatedSize
        )
    }
    
    /// Wait for a specific model to finish downloading using unified queue
    private func waitForDownloadUnified(_ modelId: String) async throws {
        let maxWaitTime: TimeInterval = 7200 // 2 hours
        let checkInterval: TimeInterval = 1.0
        let startTime = Date()
        
        // Extract variant from modelId to check if file exists
        let variantId = modelId.replacingOccurrences(of: "whisper-", with: "")
        let variant = WhisperModelVariant.fromIdentifier(variantId)
        
        while Date().timeIntervalSince(startTime) < maxWaitTime {
            // Check if model file now exists (download completed)
            if let variant = variant, isModelDownloaded(variant) {
                logger.info("[WhisperModelManager] Model download verified: \(variant.displayName)")
                checkDownloadedModels() // Refresh the downloaded models list
                return
            }
            
            // Check download queue status
            if let task = UnifiedDownloadQueue.shared.downloadTasks.first(where: { $0.modelId == modelId }) {
                if task.state == .completed {
                    // Give it a moment for file to be written
                    try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                    checkDownloadedModels() // Refresh the downloaded models list
                    return
                } else if task.state == .failed {
                    throw task.error ?? TranscriptionError.downloadFailed
                } else if task.state == .cancelled {
                    throw TranscriptionError.downloadCancelled
                }
                // If still downloading, continue waiting
            } else if !UnifiedDownloadQueue.shared.isInQueue(modelId) {
                // Not in queue anymore - check if file exists one more time
                if let variant = variant, isModelDownloaded(variant) {
                    checkDownloadedModels() // Refresh the downloaded models list
                    return
                }
                // If not in queue and file doesn't exist, it likely failed
                throw TranscriptionError.downloadFailed
            }
            
            // Wait before checking again
            try await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
        }
        
        throw TranscriptionError.downloadTimeout
    }
    
    /// Determine if we should wait for download (for backward compatibility)
    private func shouldWaitForDownload() async -> Bool {
        // In transcription context, wait for download
        // In UI context, don't wait
        return await MainActor.run {
            // Check if we're in a transcription flow
            return self.isDownloading
        }
    }
    
    /// Cancel current download
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        
        Task { @MainActor in
            isDownloading = false
            downloadProgress = 0.0
        }
    }
    
    /// Check if a model variant is currently being downloaded
    func isDownloading(_ variant: WhisperModelVariant) -> Bool {
        let modelId = "whisper-\(variant.toIdentifier())"
        return UnifiedDownloadQueue.shared.isInQueue(modelId)
    }
    
    /// Delete a downloaded model
    func deleteModel(_ variant: WhisperModelVariant) throws {
        let path = modelPath(for: variant)
        try FileManager.default.removeItem(at: path)
        
        downloadedModels.remove(variant)
        checkDownloadedModels()
        
        logger.info("[WhisperModelManager] Deleted model: \(variant.displayName)")
    }
    
    /// Get total size of downloaded models
    func getTotalModelSize() -> Int64 {
        var totalSize: Int64 = 0
        
        for variant in downloadedModels {
            let path = modelPath(for: variant)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
               let fileSize = attributes[.size] as? Int64 {
                totalSize += fileSize
            }
        }
        
        return totalSize
    }
    
    /// Get all available quantizations for a model
    func getAvailableQuantizations(for family: WhisperModelFamily, size: WhisperModelSize) -> [WhisperQuantization] {
        return availableModels
            .filter { $0.family == family && $0.size == size }
            .map { $0.quantization }
            .sorted { $0.qualityScore > $1.qualityScore }
    }
    
    // MARK: - Private Methods
    
    private func createModelsDirectoryIfNeeded() {
        // Base models directory will be created as needed
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }
    
    func checkDownloadedModels() {
        downloadedModels.removeAll()
        
        // Check all possible model variants
        for variant in availableModels {
            let path = modelPath(for: variant)
            if FileManager.default.fileExists(atPath: path.path) {
                downloadedModels.insert(variant)
            }
        }
        
        // Also check for legacy models and migrate them
        migrateLegacyModels()
        
        // Check if we have at least one model
        isModelLoaded = !downloadedModels.isEmpty
        
        // Use the user's selected model from GlobalModelSettings
        if currentVariant == nil {
            currentVariant = GlobalModelSettings.shared.selectedWhisperVariant
            if let variant = currentVariant {
                currentModel = variant.displayName
            }
        }
        
        logger.info("[WhisperModelManager] Found \(downloadedModels.count) downloaded models")
    }
    
    private func modelDirectory(for variant: WhisperModelVariant) -> URL {
        // Build path without quantization as a directory (it's part of the filename)
        var path = modelsDirectory
            .appendingPathComponent(variant.family.rawValue)
            .appendingPathComponent(variant.size.rawValue)
        
        // Only add version directory for large models or if explicitly versioned
        if variant.size == .large || (variant.version != nil && variant.version != .v1) {
            path = path.appendingPathComponent(variant.version?.rawValue ?? "v1")
        }
        
        return path
    }
    
    private func modelPath(for variant: WhisperModelVariant) -> URL {
        // Use the variant's own localPath computation
        return variant.localPath
    }
    
    private func migrateLegacyModels() {
        // Check for old model locations and migrate them
        let oldKBLabPath = WhisperConfiguration.modelPath(for: .kblab)
        let oldOpenAIPath = WhisperConfiguration.modelPath(for: .openai)
        
        // Migrate KBLab models
        if let contents = try? FileManager.default.contentsOfDirectory(at: oldKBLabPath, includingPropertiesForKeys: nil) {
            for file in contents where file.pathExtension == "bin" {
                if let variant = WhisperModelVariant.fromLegacyFilename(file.lastPathComponent, type: .kblab) {
                    let newPath = modelPath(for: variant)
                    try? FileManager.default.createDirectory(at: modelDirectory(for: variant), withIntermediateDirectories: true)
                    try? FileManager.default.moveItem(at: file, to: newPath)
                    downloadedModels.insert(variant)
                    logger.info("[WhisperModelManager] Migrated legacy model: \(file.lastPathComponent) -> \(variant.displayName)")
                }
            }
        }
        
        // Migrate OpenAI models
        if let contents = try? FileManager.default.contentsOfDirectory(at: oldOpenAIPath, includingPropertiesForKeys: nil) {
            for file in contents where file.pathExtension == "bin" {
                if let variant = WhisperModelVariant.fromLegacyFilename(file.lastPathComponent, type: .openai) {
                    let newPath = modelPath(for: variant)
                    try? FileManager.default.createDirectory(at: modelDirectory(for: variant), withIntermediateDirectories: true)
                    try? FileManager.default.moveItem(at: file, to: newPath)
                    downloadedModels.insert(variant)
                    logger.info("[WhisperModelManager] Migrated legacy model: \(file.lastPathComponent) -> \(variant.displayName)")
                }
            }
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension WhisperModelManager: URLSessionDownloadDelegate, URLSessionTaskDelegate {
    
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        logger.debug("[WhisperModelManager] Redirect from: \(task.originalRequest?.url?.absoluteString ?? "unknown")")
        logger.debug("[WhisperModelManager] Redirect to: \(request.url?.absoluteString ?? "unknown")")
        logger.debug("[WhisperModelManager] Response code: \(response.statusCode)")
        
        // Allow the redirect
        completionHandler(request)
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        
        logger.debug("[WhisperModelManager] Download progress: \(totalBytesWritten) / \(totalBytesExpectedToWrite) = \(String(format: "%.2f%%", progress * 100))")
        logger.debug("[WhisperModelManager] Bytes written this call: \(bytesWritten)")
        
        Task { @MainActor in
            self.downloadProgress = progress
            logger.debug("[WhisperModelManager] UI progress updated to: \(self.downloadProgress)")
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        logger.info("[WhisperModelManager] Download finished to location: \(location.path)")
        
        guard let variant = currentDownloadVariant else {
            logger.error("[WhisperModelManager] Error: No current variant set")
            return
        }
        
        // Check file size at download location
        if let attributes = try? FileManager.default.attributesOfItem(atPath: location.path) {
            let fileSize = attributes[.size] as? Int64 ?? 0
            logger.info("[WhisperModelManager] Downloaded file size: \(fileSize) bytes (\(fileSize / 1_000_000) MB)")
            
            // Move file to final location
            let destinationPath = self.modelPath(for: variant)
            
            do {
                // Validate size
                guard fileSize > 1_000_000 else { // 1MB minimum
                    logger.error("[WhisperModelManager] Downloaded file too small: \(fileSize) bytes")
                    downloadContinuation?.resume(throwing: TranscriptionError.downloadFailed)
                    downloadContinuation = nil
                    return
                }
                
                // Create directory if needed
                let destDir = destinationPath.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
                
                // Remove existing file if it exists
                try? FileManager.default.removeItem(at: destinationPath)
                
                // Move downloaded file
                try FileManager.default.moveItem(at: location, to: destinationPath)
                
                logger.info("[WhisperModelManager] Model downloaded successfully: \(variant.displayName) (\(fileSize / 1_000_000) MB)")
                
                Task { @MainActor in
                    self.downloadedModels.insert(variant)
                    self.checkDownloadedModels()
                    self.isDownloading = false
                    self.downloadProgress = 0.0
                }
                
                // Success - resume continuation
                downloadContinuation?.resume()
                downloadContinuation = nil
                
            } catch {
                logger.error("[WhisperModelManager] Failed to move downloaded file: \(error)")
                downloadContinuation?.resume(throwing: TranscriptionError.downloadFailed)
                downloadContinuation = nil
            }
        } else {
            logger.error("[WhisperModelManager] Could not get file attributes")
            downloadContinuation?.resume(throwing: TranscriptionError.downloadFailed)
            downloadContinuation = nil
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            logger.error("[WhisperModelManager] Download error: \(error)")
            logger.error("[WhisperModelManager] Error code: \((error as NSError).code)")
            logger.error("[WhisperModelManager] Error domain: \((error as NSError).domain)")
            
            Task { @MainActor in
                self.isDownloading = false
                self.downloadProgress = 0.0
            }
            
            // Resume continuation with error
            downloadContinuation?.resume(throwing: TranscriptionError.downloadFailed)
            downloadContinuation = nil
        } else {
            logger.info("[WhisperModelManager] Download task completed successfully")
            // Success case is handled in didFinishDownloadingTo
        }
        
        // Clean up
        currentDownloadVariant = nil
    }
}