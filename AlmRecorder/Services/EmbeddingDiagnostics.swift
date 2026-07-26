import Foundation

/// Collects diagnostic information when embedding generation fails
class EmbeddingDiagnostics {
    static let shared = EmbeddingDiagnostics()
    private let logger = VoxtralLogger.shared
    
    private init() {}
    
    /// Collect comprehensive diagnostic data for a failed embedding
    func collectDiagnostics(
        for text: String,
        modelPath: String?,
        modelId: String?,
        error: Error,
        context: EmbeddingContext = .utterance
    ) -> [String: Any] {
        var diagnostics: [String: Any] = [:]
        
        // Basic info
        diagnostics["timestamp"] = Date().ISO8601Format()
        diagnostics["error"] = String(describing: error)
        diagnostics["error_type"] = String(describing: type(of: error))
        diagnostics["context"] = context.rawValue
        diagnostics["model_id"] = modelId ?? "unknown"
        diagnostics["model_path"] = modelPath ?? "none"
        
        // Text diagnostics
        diagnostics["text_length"] = text.count
        diagnostics["text_preview"] = String(text.prefix(200))
        diagnostics["text_lines"] = text.components(separatedBy: .newlines).count
        diagnostics["text_words"] = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        
        // Model file diagnostics
        if let modelPath = modelPath {
            if FileManager.default.fileExists(atPath: modelPath) {
                diagnostics["model_exists"] = true
                
                if let attrs = try? FileManager.default.attributesOfItem(atPath: modelPath) {
                    diagnostics["model_size_mb"] = (attrs[.size] as? Int64 ?? 0) / 1024 / 1024
                    diagnostics["model_modified"] = (attrs[.modificationDate] as? Date)?.ISO8601Format() ?? ""
                }
                
                diagnostics["model_readable"] = FileManager.default.isReadableFile(atPath: modelPath)
            } else {
                diagnostics["model_exists"] = false
                logger.error("[EmbeddingDiagnostics] Model file does not exist: \(modelPath)")
            }
        }
        
        // System diagnostics
        diagnostics["system"] = collectSystemDiagnostics()
        
        // Embedding service diagnostics
        diagnostics["embedding_service"] = collectEmbeddingServiceDiagnostics()
        
        // Speaker embedding diagnostics (if applicable)
        if context == .speaker {
            diagnostics["speaker_embedding"] = collectSpeakerEmbeddingDiagnostics()
        }
        
        // Log the collected diagnostics
        logger.info("[EmbeddingDiagnostics] Collected diagnostics: \(diagnostics)")
        
        return diagnostics
    }
    
    /// Collect diagnostics for failed speaker embedding
    func collectSpeakerDiagnostics(
        for audioPath: String,
        modelType: String?,
        error: Error
    ) -> [String: Any] {
        var diagnostics: [String: Any] = [:]
        
        // Basic info
        diagnostics["timestamp"] = Date().ISO8601Format()
        diagnostics["error"] = String(describing: error)
        diagnostics["error_type"] = String(describing: type(of: error))
        diagnostics["model_type"] = modelType ?? "unknown"
        diagnostics["audio_path"] = audioPath
        
        // Audio file diagnostics
        if FileManager.default.fileExists(atPath: audioPath) {
            diagnostics["audio_exists"] = true
            
            if let attrs = try? FileManager.default.attributesOfItem(atPath: audioPath) {
                diagnostics["audio_size_bytes"] = attrs[.size] as? Int64 ?? 0
                diagnostics["audio_size_kb"] = (attrs[.size] as? Int64 ?? 0) / 1024
                diagnostics["audio_modified"] = (attrs[.modificationDate] as? Date)?.ISO8601Format() ?? ""
            }
            
            diagnostics["audio_readable"] = FileManager.default.isReadableFile(atPath: audioPath)
            
            // Get audio file extension
            let url = URL(fileURLWithPath: audioPath)
            diagnostics["audio_extension"] = url.pathExtension
            
        } else {
            diagnostics["audio_exists"] = false
            logger.error("[EmbeddingDiagnostics] Audio file does not exist: \(audioPath)")
        }
        
        // System diagnostics
        diagnostics["system"] = collectSystemDiagnostics()
        
        // FluidAudio specific diagnostics
        diagnostics["fluidaudio"] = collectFluidAudioDiagnostics()
        
        // Log the collected diagnostics
        logger.info("[EmbeddingDiagnostics] Collected speaker diagnostics: \(diagnostics)")
        
        return diagnostics
    }
    
    private func collectSystemDiagnostics() -> [String: Any] {
        var system: [String: Any] = [:]
        
        // Memory info
        let memoryInfo = ProcessInfo.processInfo
        system["physical_memory_gb"] = memoryInfo.physicalMemory / 1024 / 1024 / 1024
        system["active_processor_count"] = memoryInfo.activeProcessorCount
        
        // Disk space
        if let systemAttributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()) {
            if let freeSpace = systemAttributes[.systemFreeSize] as? Int64 {
                system["free_disk_gb"] = freeSpace / 1024 / 1024 / 1024
            }
            if let totalSpace = systemAttributes[.systemSize] as? Int64 {
                system["total_disk_gb"] = totalSpace / 1024 / 1024 / 1024
            }
        }
        
        // OS version
        system["os_version"] = ProcessInfo.processInfo.operatingSystemVersionString
        
        // Current memory usage of app
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if result == KERN_SUCCESS {
            system["app_memory_mb"] = info.resident_size / 1024 / 1024
        }
        
        return system
    }
    
    private func collectEmbeddingServiceDiagnostics() -> [String: Any] {
        var embedding: [String: Any] = [:]
        
        // Check llama-embedding binary
        let possiblePaths = [
            Bundle.main.path(forResource: "llama-embedding", ofType: nil, inDirectory: "Binaries"),
            Bundle.main.path(forResource: "llama-embedding", ofType: nil),
            "\(DevPaths.resourcesBinaries)/llama-embedding"
        ].compactMap { $0 }
        
        var foundPath: String?
        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                foundPath = path
                break
            }
        }
        
        if let binaryPath = foundPath {
            embedding["binary_path"] = binaryPath
            embedding["binary_exists"] = true
            embedding["binary_executable"] = FileManager.default.isExecutableFile(atPath: binaryPath)
            
            if let attrs = try? FileManager.default.attributesOfItem(atPath: binaryPath) {
                embedding["binary_size_kb"] = (attrs[.size] as? Int64 ?? 0) / 1024
                embedding["binary_modified"] = (attrs[.modificationDate] as? Date)?.ISO8601Format() ?? ""
            }
        } else {
            embedding["binary_exists"] = false
            embedding["searched_paths"] = possiblePaths
        }
        
        // Check embedding models directory
        let embeddingModelsPath = FileManager.default.urls(for: .applicationSupportDirectory,
                                                          in: .userDomainMask).first?
            .appendingPathComponent("AlmRecorder")
            .appendingPathComponent("EmbeddingModels")
            .path ?? ""
        
        embedding["models_directory"] = embeddingModelsPath
        embedding["models_directory_exists"] = FileManager.default.fileExists(atPath: embeddingModelsPath)
        
        // List available models
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: embeddingModelsPath) {
            embedding["available_models"] = contents.filter { $0.hasSuffix(".gguf") }
        }
        
        // Check current model from EmbeddingModelManager
        embedding["current_model"] = EmbeddingModelManager.shared.currentModel
        embedding["model_loaded"] = EmbeddingModelManager.shared.isModelLoaded
        
        return embedding
    }
    
    private func collectSpeakerEmbeddingDiagnostics() -> [String: Any] {
        var speaker: [String: Any] = [:]
        
        // Check which speaker embedding service is being used
        let settings = GlobalModelSettings.shared
        speaker["selected_model"] = settings.selectedEmbeddingModel
        speaker["auto_generate"] = settings.autoGenerateEmbeddings
        
        return speaker
    }
    
    private func collectFluidAudioDiagnostics() -> [String: Any] {
        var fluidaudio: [String: Any] = [:]
        
        // Check FluidAudio models directory
        let modelsPath = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask).first?
            .appendingPathComponent("FluidAudio")
            .appendingPathComponent("Models")
            .path ?? ""
        
        fluidaudio["models_directory"] = modelsPath
        fluidaudio["models_directory_exists"] = FileManager.default.fileExists(atPath: modelsPath)
        
        // List model files
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: modelsPath) {
            fluidaudio["model_files"] = contents
            fluidaudio["model_count"] = contents.count
        }
        
        return fluidaudio
    }
    
    /// Format diagnostics as a readable string for logging
    func formatDiagnostics(_ diagnostics: [String: Any]) -> String {
        var output = "=== EMBEDDING FAILURE DIAGNOSTICS ===\n"
        output += "Timestamp: \(diagnostics["timestamp"] ?? "unknown")\n"
        output += "Error: \(diagnostics["error"] ?? "unknown")\n"
        output += "Context: \(diagnostics["context"] ?? "unknown")\n"
        output += "\n"
        
        if let textLength = diagnostics["text_length"] as? Int {
            output += "TEXT:\n"
            output += "  Length: \(textLength) chars\n"
            output += "  Words: \(diagnostics["text_words"] ?? 0)\n"
            output += "  Lines: \(diagnostics["text_lines"] ?? 0)\n"
            output += "\n"
        }
        
        if let audioPath = diagnostics["audio_path"] as? String {
            output += "AUDIO FILE:\n"
            output += "  Path: \(audioPath)\n"
            output += "  Exists: \(diagnostics["audio_exists"] ?? false)\n"
            output += "  Size: \(diagnostics["audio_size_kb"] ?? 0)KB\n"
            output += "\n"
        }
        
        if let modelPath = diagnostics["model_path"] as? String, modelPath != "none" {
            output += "MODEL FILE:\n"
            output += "  Path: \(modelPath)\n"
            output += "  Exists: \(diagnostics["model_exists"] ?? false)\n"
            output += "  Size: \(diagnostics["model_size_mb"] ?? 0)MB\n"
            output += "\n"
        }
        
        if let system = diagnostics["system"] as? [String: Any] {
            output += "SYSTEM:\n"
            output += "  Memory: \(system["physical_memory_gb"] ?? 0)GB\n"
            output += "  Free disk: \(system["free_disk_gb"] ?? 0)GB\n"
            output += "  App memory: \(system["app_memory_mb"] ?? 0)MB\n"
            output += "  Processors: \(system["active_processor_count"] ?? 0)\n"
            output += "\n"
        }
        
        if let embedding = diagnostics["embedding_service"] as? [String: Any] {
            output += "EMBEDDING SERVICE:\n"
            output += "  Binary exists: \(embedding["binary_exists"] ?? false)\n"
            output += "  Current model: \(embedding["current_model"] ?? "none")\n"
            output += "  Model loaded: \(embedding["model_loaded"] ?? false)\n"
            if let models = embedding["available_models"] as? [String] {
                output += "  Available models: \(models.count)\n"
            }
            output += "\n"
        }
        
        output += "=== END DIAGNOSTICS ===\n"
        
        return output
    }
}

// MARK: - Supporting Types

enum EmbeddingContext: String {
    case utterance = "utterance"
    case speaker = "speaker"
    case search = "search"
    case maintenance = "maintenance"
}