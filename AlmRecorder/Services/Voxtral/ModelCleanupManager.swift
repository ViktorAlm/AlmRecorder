import Foundation

/// Manages cleanup and removal of downloaded models
class ModelCleanupManager: ObservableObject {
    
    static let shared = ModelCleanupManager()
    
    private let logger = VoxtralLogger.shared
    private let fileManager = FileManager.default
    
    /// Get information about downloaded models
    func getDownloadedModels() -> [ModelInfo] {
        var models: [ModelInfo] = []
        let modelsDir = VoxtralConfiguration.modelsDirectory
        
        // Check each configured model
        for (key, config) in VoxtralConfiguration.models {
            let modelPath = modelsDir.appendingPathComponent(config.modelFile)
            let mmprojPath = modelsDir.appendingPathComponent(config.mmprojFile)
            
            if fileManager.fileExists(atPath: modelPath.path) {
                let modelSize = getFileSize(at: modelPath)
                let mmprojSize = getFileSize(at: mmprojPath)
                let totalSize = modelSize + mmprojSize
                
                models.append(ModelInfo(
                    key: key,
                    name: config.name,
                    modelFile: config.modelFile,
                    mmprojFile: config.mmprojFile,
                    totalSize: totalSize,
                    isDownloaded: true,
                    modelPath: modelPath,
                    mmprojPath: mmprojPath
                ))
            }
        }
        
        return models
    }
    
    /// Get total disk space used by models
    func getTotalDiskUsage() -> Int64 {
        getDownloadedModels().reduce(0) { $0 + $1.totalSize }
    }
    
    /// Delete a specific model
    func deleteModel(_ modelKey: String) throws {
        guard let config = VoxtralConfiguration.models[modelKey] else {
            throw CleanupError.modelNotFound
        }
        
        let modelsDir = VoxtralConfiguration.modelsDirectory
        let modelPath = modelsDir.appendingPathComponent(config.modelFile)
        let mmprojPath = modelsDir.appendingPathComponent(config.mmprojFile)
        
        // Delete model file
        if fileManager.fileExists(atPath: modelPath.path) {
            try fileManager.removeItem(at: modelPath)
            logger.info("Deleted model file: \(config.modelFile)")
        }
        
        // Delete mmproj file
        if fileManager.fileExists(atPath: mmprojPath.path) {
            try fileManager.removeItem(at: mmprojPath)
            logger.info("Deleted mmproj file: \(config.mmprojFile)")
        }
        
        logger.info("Successfully deleted model: \(config.name)")
    }
    
    /// Delete all downloaded models
    func deleteAllModels() throws {
        let models = getDownloadedModels()
        
        for model in models {
            try deleteModel(model.key)
        }
        
        logger.info("Deleted all \(models.count) models")
    }
    
    /// Clean temporary files and caches
    func cleanTemporaryFiles() -> CleanupResult {
        var deletedFiles = 0
        var freedSpace: Int64 = 0
        var errors: [String] = []
        
        // Clean WAV cache
        let wavCacheManager = WAVCacheManager.shared
        let cacheSize = wavCacheManager.getCacheSize()
        wavCacheManager.clearCache()
        freedSpace += cacheSize
        logger.info("[Cleanup] Cleared WAV cache: \(formatBytes(cacheSize))")
        
        // Clean temp directory
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("AlmRecorder")
        if fileManager.fileExists(atPath: tempDir.path) {
            let tempSize = getDirectorySize(tempDir)
            do {
                try fileManager.removeItem(at: tempDir)
                freedSpace += tempSize
                deletedFiles += 1
                logger.info("[Cleanup] Cleaned temp directory: \(formatBytes(tempSize))")
            } catch {
                errors.append("Failed to clean temp directory: \(error.localizedDescription)")
                logger.error("[Cleanup] Failed to clean temp directory: \(error)")
            }
        }
        
        // Clean system temp directory for WAV files
        let systemTempDir = fileManager.temporaryDirectory
        do {
            let contents = try fileManager.contentsOfDirectory(
                at: systemTempDir,
                includingPropertiesForKeys: [.fileSizeKey],
                options: .skipsHiddenFiles
            )
            
            for file in contents {
                // Clean up voxtral-related temp files
                let filename = file.lastPathComponent.lowercased()
                if filename.contains("voxtral") || 
                   filename.contains("almrecorder") ||
                   (filename.hasSuffix(".wav") && filename.contains("_chunk_")) ||
                   (filename.hasSuffix(".m4a") && filename.contains("_chunk_")) {
                    
                    if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        do {
                            try fileManager.removeItem(at: file)
                            freedSpace += Int64(size)
                            deletedFiles += 1
                            logger.debug("[Cleanup] Deleted temp file: \(file.lastPathComponent)")
                        } catch {
                            errors.append("Failed to delete \(file.lastPathComponent)")
                        }
                    }
                }
            }
        } catch {
            errors.append("Failed to scan temp directory: \(error.localizedDescription)")
            logger.error("[Cleanup] Failed to scan temp directory: \(error)")
        }
        
        // Clean any partial downloads
        let partialResult = cleanPartialDownloads()
        deletedFiles += partialResult.filesDeleted
        freedSpace += partialResult.spaceFreed
        errors.append(contentsOf: partialResult.errors)
        
        logger.info("[Cleanup] Complete: Deleted \(deletedFiles) files, freed \(formatBytes(freedSpace))")
        
        return CleanupResult(
            filesDeleted: deletedFiles,
            spaceFreed: freedSpace,
            errors: errors
        )
    }
    
    /// Clean partial or corrupted downloads
    func cleanPartialDownloads() -> CleanupResult {
        let modelsDir = VoxtralConfiguration.modelsDirectory
        var deletedFiles = 0
        var freedSpace: Int64 = 0
        var errors: [String] = []
        
        do {
            let contents = try fileManager.contentsOfDirectory(
                at: modelsDir,
                includingPropertiesForKeys: [.fileSizeKey],
                options: .skipsHiddenFiles
            )
            
            for file in contents {
                // Remove partial download files
                if file.pathExtension == "partial" || 
                   file.pathExtension == "tmp" ||
                   file.pathExtension == "download" ||
                   file.lastPathComponent.hasPrefix(".") ||
                   file.lastPathComponent.hasPrefix("tmp_") {
                    
                    if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        do {
                            try fileManager.removeItem(at: file)
                            freedSpace += Int64(size)
                            deletedFiles += 1
                            logger.info("[Cleanup] Removed partial file: \(file.lastPathComponent) (\(formatBytes(Int64(size))))")
                        } catch {
                            errors.append("Failed to remove \(file.lastPathComponent): \(error.localizedDescription)")
                        }
                    }
                }
            }
        } catch {
            errors.append("Failed to scan models directory: \(error.localizedDescription)")
            logger.error("[Cleanup] Failed to clean partial downloads: \(error)")
        }
        
        return CleanupResult(
            filesDeleted: deletedFiles,
            spaceFreed: freedSpace,
            errors: errors
        )
    }
    
    /// Verify model integrity
    func verifyModel(_ modelKey: String) -> ModelVerification {
        guard let config = VoxtralConfiguration.models[modelKey] else {
            return ModelVerification(isValid: false, error: "Model configuration not found")
        }
        
        let modelsDir = VoxtralConfiguration.modelsDirectory
        let modelPath = modelsDir.appendingPathComponent(config.modelFile)
        let mmprojPath = modelsDir.appendingPathComponent(config.mmprojFile)
        
        // Check if files exist
        guard fileManager.fileExists(atPath: modelPath.path) else {
            return ModelVerification(isValid: false, error: "Model file not found")
        }
        
        guard fileManager.fileExists(atPath: mmprojPath.path) else {
            return ModelVerification(isValid: false, error: "Projection file not found")
        }
        
        // Check file sizes (basic verification)
        let modelSize = getFileSize(at: modelPath)
        let expectedSize = Int64(config.sizeGB * 1_073_741_824)
        let tolerance = Int64(100_000_000) // 100MB tolerance
        
        if abs(modelSize - expectedSize) > tolerance {
            return ModelVerification(
                isValid: false,
                error: "Model size mismatch. Expected: \(formatBytes(expectedSize)), Found: \(formatBytes(modelSize))"
            )
        }
        
        return ModelVerification(isValid: true, error: nil)
    }
    
    /// Get orphaned files (files not matching any model configuration)
    func getOrphanedFiles() -> [URL] {
        var orphaned: [URL] = []
        let modelsDir = VoxtralConfiguration.modelsDirectory
        
        do {
            let contents = try fileManager.contentsOfDirectory(
                at: modelsDir,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )
            
            let knownFiles = VoxtralConfiguration.models.values.flatMap { config in
                [config.modelFile, config.mmprojFile]
            }
            
            for file in contents {
                let filename = file.lastPathComponent
                if !knownFiles.contains(filename) && 
                   file.pathExtension == "gguf" {
                    orphaned.append(file)
                }
            }
        } catch {
            logger.error("Failed to get orphaned files: \(error)")
        }
        
        return orphaned
    }
    
    /// Clean orphaned files
    func cleanOrphanedFiles() throws {
        let orphaned = getOrphanedFiles()
        
        for file in orphaned {
            try fileManager.removeItem(at: file)
            logger.info("Removed orphaned file: \(file.lastPathComponent)")
        }
        
        if !orphaned.isEmpty {
            logger.info("Cleaned \(orphaned.count) orphaned files")
        }
    }
    
    // MARK: - Helper Methods
    
    private func getFileSize(at url: URL) -> Int64 {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            return attributes[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    private func getDirectorySize(_ url: URL) -> Int64 {
        var size: Int64 = 0
        
        if let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        ) {
            for case let fileURL as URL in enumerator {
                if let resourceValues = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
                   let fileSize = resourceValues.totalFileAllocatedSize {
                    size += Int64(fileSize)
                }
            }
        }
        
        return size
    }
    
    // MARK: - Data Models
    
    struct CleanupResult {
        let filesDeleted: Int
        let spaceFreed: Int64
        let errors: [String]
        
        var formattedSpaceFreed: String {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromByteCount: spaceFreed)
        }
        
        var hasErrors: Bool {
            !errors.isEmpty
        }
        
        var summary: String {
            var message = "Deleted \(filesDeleted) files, freed \(formattedSpaceFreed)"
            if hasErrors {
                message += " (\(errors.count) errors)"
            }
            return message
        }
    }
    
    struct ModelInfo {
        let key: String
        let name: String
        let modelFile: String
        let mmprojFile: String
        let totalSize: Int64
        let isDownloaded: Bool
        let modelPath: URL
        let mmprojPath: URL
        
        var formattedSize: String {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromByteCount: totalSize)
        }
    }
    
    struct ModelVerification {
        let isValid: Bool
        let error: String?
    }
    
    enum CleanupError: LocalizedError {
        case modelNotFound
        case cleanupFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .modelNotFound:
                return "Model not found"
            case .cleanupFailed(let reason):
                return "Cleanup failed: \(reason)"
            }
        }
    }
}