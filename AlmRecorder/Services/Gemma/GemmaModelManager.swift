import Foundation
import Combine

/// Manages Gemma GGUF downloads and the projector required by audio-grounded consensus.
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

    /// Check if a specific text model GGUF is downloaded with a sane size.
    func isModelDownloaded(_ modelKey: String) -> Bool {
        guard let config = GemmaConfiguration.models[modelKey] else { return false }

        let modelPath = modelsDirectory.appendingPathComponent(config.modelFile)
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            return false
        }

        if let modelAttrs = try? FileManager.default.attributesOfItem(atPath: modelPath.path),
           let modelSize = modelAttrs[.size] as? Int64 {
            return UnifiedDownloadQueue.isAcceptableFileSize(
                modelSize,
                declaredSize: Int64(config.sizeGB * 1_000_000_000)
            )
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

    func getMmprojPath(for modelKey: String) -> URL? {
        guard let config = GemmaConfiguration.models[modelKey] else { return nil }
        let path = modelsDirectory.appendingPathComponent(config.mmprojFile)
        guard FileManager.default.fileExists(atPath: path.path),
              let values = try? path.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else {
            return nil
        }
        return UnifiedDownloadQueue.isAcceptableFileSize(
            Int64(size),
            declaredSize: Int64(config.mmprojSizeGB * 1_000_000_000)
        ) ? path : nil
    }

    func isAudioModelDownloaded(_ modelKey: String) -> Bool {
        isModelDownloaded(modelKey) && getMmprojPath(for: modelKey) != nil
    }

    /// Download a GGUF via the shared queue. Audio-consensus models include their projector.
    func downloadModel(_ modelKey: String) async throws {
        guard let config = GemmaConfiguration.models[modelKey] else {
            logger.error("[Gemma] Model configuration not found for: \(modelKey)")
            throw TranscriptionError.modelNotFound
        }

        logger.info("[Gemma] Starting download for model: \(config.name)")

        let needsAudioProjector = GemmaConfiguration.isAudioConsensusModel(modelKey)
        if isModelDownloaded(modelKey),
           !needsAudioProjector || isAudioModelDownloaded(modelKey) {
            logger.info("[Gemma] Model already downloaded: \(config.name)")
            await MainActor.run {
                isModelLoaded = true
                currentModel = modelKey
            }
            return
        }

        let modelPath = modelsDirectory.appendingPathComponent(config.modelFile)
        let projectorPath = modelsDirectory.appendingPathComponent(config.mmprojFile)

        // The main GGUF may predate audio consensus. Queue just the missing projector rather than
        // making the shared downloader short-circuit on the already-present model file.
        if isModelDownloaded(modelKey),
           needsAudioProjector,
           getMmprojPath(for: modelKey) == nil,
           let projectorURL = URL(string: config.mmprojURL) {
            let projectorID = "gemma-\(modelKey)-additional"
            UnifiedDownloadQueue.shared.enqueueDownload(
                modelId: projectorID,
                displayName: "\(config.name) audio projector",
                modelType: "gemma",
                downloadURL: projectorURL,
                destinationPath: projectorPath,
                fileSize: Int64(config.mmprojSizeGB * 1_000_000_000)
            )
            guard await waitForDownload(projectorID) else {
                throw TranscriptionError.downloadFailed
            }
            guard isAudioModelDownloaded(modelKey) else {
                throw TranscriptionError.downloadFailed
            }
            await MainActor.run {
                isModelLoaded = true
                currentModel = modelKey
                downloadProgress = 1
            }
            return
        }

        let projectorFiles: [UnifiedDownloadQueue.AdditionalDownload]
        if needsAudioProjector,
           let projectorURL = URL(string: config.mmprojURL) {
            projectorFiles = [
                UnifiedDownloadQueue.AdditionalDownload(
                    url: projectorURL,
                    path: projectorPath,
                    fileSize: Int64(config.mmprojSizeGB * 1_000_000_000)
                )
            ]
        } else {
            projectorFiles = []
        }
        UnifiedDownloadQueue.shared.enqueueDownload(
            modelId: "gemma-\(modelKey)",
            displayName: config.name,
            modelType: "gemma",
            downloadURL: URL(string: config.modelURL)!,
            destinationPath: modelPath,
            fileSize: Int64(config.sizeGB * 1_000_000_000),
            additionalFiles: projectorFiles
        )

        logger.info("[Gemma] Enqueued download: \(config.name)")

        await MainActor.run {
            isDownloading = UnifiedDownloadQueue.shared.isInQueue("gemma-\(modelKey)")
        }

        guard await waitForDownload("gemma-\(modelKey)") else {
            throw TranscriptionError.downloadFailed
        }

        if needsAudioProjector {
            guard await waitForDownload("gemma-\(modelKey)-additional") else {
                throw TranscriptionError.downloadFailed
            }
        }
        if isModelDownloaded(modelKey),
           !needsAudioProjector
                || isAudioModelDownloaded(modelKey) {
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

    /// Delete a downloaded text model. Existing legacy projector files are left untouched and are
    /// never loaded; removing unrelated historical files is outside this model operation.
    func deleteModel(_ modelKey: String) throws {
        guard let config = GemmaConfiguration.models[modelKey] else {
            throw TranscriptionError.modelNotFound
        }

        let modelPath = modelsDirectory.appendingPathComponent(config.modelFile)
        if FileManager.default.fileExists(atPath: modelPath.path) {
            try FileManager.default.removeItem(at: modelPath)
        }

        if currentModel == modelKey {
            currentModel = ""
            isModelLoaded = false
        }

        logger.info("[Gemma] Deleted model: \(config.name)")
    }

    /// Text model GGUF size in bytes.
    func getModelSize(_ modelKey: String) -> Int64 {
        guard let config = GemmaConfiguration.models[modelKey] else { return 0 }

        let modelPath = modelsDirectory.appendingPathComponent(config.modelFile)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: modelPath.path),
           let size = attributes[.size] as? Int64 {
            return size
        }
        return 0
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
    private func waitForDownload(_ modelId: String) async -> Bool {
        let maxWaitTime: TimeInterval = 8 * 60 * 60
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
                        return true
                    } else if task.state == .failed {
                        await MainActor.run {
                            isDownloading = false
                            downloadProgress = 0.0
                        }
                        return false
                    }
                } else if Date().timeIntervalSince(startTime) >= 5 {
                    logger.error("[Gemma] Download task was never created: \(modelId)")
                    return false
                }
            }

            if let task = UnifiedDownloadQueue.shared.downloadTasks.first(where: { $0.modelId == modelId }) {
                await MainActor.run {
                    downloadProgress = task.progress
                }
            }

            do {
                try await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
            } catch {
                return false
            }
        }
        logger.error("[Gemma] Download timed out: \(modelId)")
        return false
    }
}
