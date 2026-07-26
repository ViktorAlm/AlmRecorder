import Foundation
import Combine

/// Manages Gemma model downloads and on-disk status. Mirrors VoxtralModelManager but against the
/// Gemma catalog/directory. Each model is a (GGUF + BF16 mmproj) pair downloaded via UnifiedDownloadQueue.
class GemmaModelManager: ObservableObject {

    // MARK: - Published Properties

    @Published var isModelLoaded = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var currentModel: String = ""

    // MARK: - Private Properties

    private let modelsDirectory: URL
    private let logger = VoxtralLogger.shared

    // MARK: - Initialization

    init() {
        self.modelsDirectory = GemmaConfiguration.modelsDirectory
        createModelsDirectoryIfNeeded()
        checkModelStatus()
    }

    // MARK: - Public Methods

    /// Check if a specific model is downloaded (both the GGUF and its mmproj, with sane sizes).
    func isModelDownloaded(_ modelKey: String) -> Bool {
        guard let config = GemmaConfiguration.models[modelKey] else { return false }

        let modelPath = modelsDirectory.appendingPathComponent(config.modelFile)
        let mmprojPath = modelsDirectory.appendingPathComponent(config.mmprojFile)

        guard FileManager.default.fileExists(atPath: modelPath.path),
              FileManager.default.fileExists(atPath: mmprojPath.path) else {
            return false
        }

        if let modelAttrs = try? FileManager.default.attributesOfItem(atPath: modelPath.path),
           let modelSize = modelAttrs[.size] as? Int64,
           let mmprojAttrs = try? FileManager.default.attributesOfItem(atPath: mmprojPath.path),
           let mmprojSize = mmprojAttrs[.size] as? Int64 {
            return modelSize > 100_000_000 && mmprojSize > 10_000_000
        }
        return false
    }

    /// Path to a model file (only if it exists on disk).
    func getModelPath(for modelKey: String) -> URL? {
        guard let config = GemmaConfiguration.models[modelKey] else { return nil }
        let modelPath = modelsDirectory.appendingPathComponent(config.modelFile)
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            logger.warning("[Gemma] Model file not found at path: \(modelPath.path)")
            return nil
        }
        return modelPath
    }

    /// Path to a mmproj file (only if it exists on disk).
    func getMmprojPath(for modelKey: String) -> URL? {
        guard let config = GemmaConfiguration.models[modelKey] else { return nil }
        let mmprojPath = modelsDirectory.appendingPathComponent(config.mmprojFile)
        guard FileManager.default.fileExists(atPath: mmprojPath.path) else {
            logger.warning("[Gemma] Mmproj file not found at path: \(mmprojPath.path)")
            return nil
        }
        return mmprojPath
    }

    /// Download a model (GGUF + BF16 mmproj) via the shared download queue.
    func downloadModel(_ modelKey: String) async throws {
        guard let config = GemmaConfiguration.models[modelKey] else {
            logger.error("[Gemma] Model configuration not found for: \(modelKey)")
            throw TranscriptionError.modelNotFound
        }

        logger.info("[Gemma] Starting download for model: \(config.name)")

        if isModelDownloaded(modelKey) {
            logger.info("[Gemma] Model already downloaded: \(config.name)")
            await MainActor.run {
                isModelLoaded = true
                currentModel = modelKey
            }
            return
        }

        let modelPath = modelsDirectory.appendingPathComponent(config.modelFile)
        let mmprojPath = modelsDirectory.appendingPathComponent(config.mmprojFile)
        let additionalFiles = [(url: URL(string: config.mmprojURL)!, path: mmprojPath)]

        UnifiedDownloadQueue.shared.enqueueDownload(
            modelId: "gemma-\(modelKey)",
            displayName: config.name,
            modelType: "gemma",
            downloadURL: URL(string: config.modelURL)!,
            destinationPath: modelPath,
            fileSize: Int64(config.sizeGB * 1_000_000_000),
            additionalFiles: additionalFiles
        )

        logger.info("[Gemma] Enqueued download: \(config.name)")

        await MainActor.run {
            isDownloading = UnifiedDownloadQueue.shared.isInQueue("gemma-\(modelKey)")
        }

        await waitForDownload("gemma-\(modelKey)")

        if isModelDownloaded(modelKey) {
            await MainActor.run {
                isModelLoaded = true
                currentModel = modelKey
                downloadProgress = 1.0
            }
            logger.info("[Gemma] Successfully downloaded model: \(config.name)")
        } else {
            throw TranscriptionError.downloadFailed
        }
    }

    /// Delete a downloaded model. The shared mmproj is only removed when no sibling quant needs it.
    func deleteModel(_ modelKey: String) throws {
        guard let config = GemmaConfiguration.models[modelKey] else {
            throw TranscriptionError.modelNotFound
        }

        let modelPath = modelsDirectory.appendingPathComponent(config.modelFile)
        if FileManager.default.fileExists(atPath: modelPath.path) {
            try FileManager.default.removeItem(at: modelPath)
        }

        // Only delete the mmproj if no other downloaded model in the same family still references it.
        let mmprojStillNeeded = GemmaConfiguration.models.contains { key, other in
            key != modelKey && other.mmprojFile == config.mmprojFile && isModelDownloaded(key)
        }
        if !mmprojStillNeeded {
            let mmprojPath = modelsDirectory.appendingPathComponent(config.mmprojFile)
            if FileManager.default.fileExists(atPath: mmprojPath.path) {
                try FileManager.default.removeItem(at: mmprojPath)
            }
        }

        if currentModel == modelKey {
            currentModel = ""
            isModelLoaded = false
        }

        logger.info("[Gemma] Deleted model: \(config.name)")
    }

    /// Total on-disk size (GGUF + mmproj) in bytes.
    func getModelSize(_ modelKey: String) -> Int64 {
        guard let config = GemmaConfiguration.models[modelKey] else { return 0 }

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
            logger.error("[Gemma] Failed to create models directory: \(error.localizedDescription)")
        }
    }

    private func checkModelStatus() {
        let defaultModel = GemmaConfiguration.defaultModel
        if isModelDownloaded(defaultModel) {
            currentModel = defaultModel
            isModelLoaded = true
            logger.info("[Gemma] Default model is loaded: \(defaultModel)")
        } else {
            for (key, _) in GemmaConfiguration.models {
                if isModelDownloaded(key) {
                    currentModel = key
                    isModelLoaded = true
                    logger.info("[Gemma] Found downloaded model: \(key)")
                    break
                }
            }
        }
    }

    /// Wait for a model to finish downloading.
    private func waitForDownload(_ modelId: String) async {
        let maxWaitTime: TimeInterval = 3600 // 1 hour
        let checkInterval: TimeInterval = 1.0
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < maxWaitTime {
            if !UnifiedDownloadQueue.shared.isInQueue(modelId) {
                if let task = UnifiedDownloadQueue.shared.downloadTasks.first(where: { $0.modelId == modelId }) {
                    if task.state == .completed {
                        await MainActor.run {
                            isDownloading = false
                            downloadProgress = 1.0
                        }
                        return
                    } else if task.state == .failed {
                        await MainActor.run {
                            isDownloading = false
                            downloadProgress = 0.0
                        }
                        return
                    }
                }
            }

            if let task = UnifiedDownloadQueue.shared.downloadTasks.first(where: { $0.modelId == modelId }) {
                await MainActor.run {
                    downloadProgress = task.progress
                }
            }

            try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
        }
    }
}
