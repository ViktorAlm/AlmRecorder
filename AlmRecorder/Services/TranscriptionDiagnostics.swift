import Foundation

/// Collects diagnostic information when transcription fails
class TranscriptionDiagnostics {
    static let shared = TranscriptionDiagnostics()
    private let logger = VoxtralLogger.shared
    
    private init() {}
    
    /// Collect comprehensive diagnostic data for a failed transcription
    func collectDiagnostics(
        for audioPath: String,
        modelPath: String?,
        backend: TranscriptionBackend?,
        error: Error
    ) -> [String: Any] {
        var diagnostics: [String: Any] = [:]
        
        // Basic info
        diagnostics["timestamp"] = Date().ISO8601Format()
        diagnostics["error"] = String(describing: error)
        diagnostics["error_type"] = String(describing: type(of: error))
        diagnostics["backend"] = backend?.rawValue ?? "unknown"
        diagnostics["audio_path"] = audioPath
        diagnostics["model_path"] = modelPath ?? "none"
        
        // Audio file diagnostics
        if FileManager.default.fileExists(atPath: audioPath) {
            diagnostics["audio_exists"] = true
            
            if let attrs = try? FileManager.default.attributesOfItem(atPath: audioPath) {
                diagnostics["audio_size_bytes"] = attrs[.size] as? Int64 ?? 0
                diagnostics["audio_size_kb"] = (attrs[.size] as? Int64 ?? 0) / 1024
                diagnostics["audio_modified"] = (attrs[.modificationDate] as? Date)?.ISO8601Format() ?? ""
                diagnostics["audio_created"] = (attrs[.creationDate] as? Date)?.ISO8601Format() ?? ""
            }
            
            // Check if file is readable
            diagnostics["audio_readable"] = FileManager.default.isReadableFile(atPath: audioPath)
            
            // Get audio file extension
            let url = URL(fileURLWithPath: audioPath)
            diagnostics["audio_extension"] = url.pathExtension
            
        } else {
            diagnostics["audio_exists"] = false
            logger.error("[Diagnostics] Audio file does not exist: \(audioPath)")
        }
        
        // Model file diagnostics
        if let modelPath = modelPath {
            if FileManager.default.fileExists(atPath: modelPath) {
                diagnostics["model_exists"] = true
                
                if let attrs = try? FileManager.default.attributesOfItem(atPath: modelPath) {
                    diagnostics["model_size_mb"] = (attrs[.size] as? Int64 ?? 0) / 1024 / 1024
                }
                
                diagnostics["model_readable"] = FileManager.default.isReadableFile(atPath: modelPath)
            } else {
                diagnostics["model_exists"] = false
                logger.error("[Diagnostics] Model file does not exist: \(modelPath)")
            }
        }
        
        // System diagnostics
        diagnostics["system"] = collectSystemDiagnostics()
        
        // Backend-specific diagnostics
        if let backend = backend {
            switch backend {
            case .whisper:
                diagnostics["whisper"] = collectWhisperDiagnostics()
            case .llm:
                diagnostics["llm"] = collectVoxtralDiagnostics()
            case .vibeVoice:
                let quantization = GlobalModelSettings.shared.selectedVibeVoiceQuantization
                diagnostics["vibevoice"] = [
                    "runtime_installed": VibeVoiceService.shared.isRuntimeInstalled,
                    "quantization": quantization.rawValue,
                    "model_revision": VibeVoiceConfiguration.modelRevision(for: quantization),
                    "model_installed": VibeVoiceModelManager.shared.isModelDownloaded(quantization)
                ]
            }
        }
        
        // Log the collected diagnostics
        logger.info("[Diagnostics] Collected diagnostics: \(diagnostics)")
        
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
        
        return system
    }
    
    private func collectWhisperDiagnostics() -> [String: Any] {
        var whisper: [String: Any] = [:]
        
        // Check whisper-cli binary
        let whisperPath = WhisperConfiguration.whisperCLIPath
        whisper["cli_path"] = whisperPath
        whisper["cli_exists"] = FileManager.default.fileExists(atPath: whisperPath)
        whisper["cli_executable"] = FileManager.default.isExecutableFile(atPath: whisperPath)
        
        if let attrs = try? FileManager.default.attributesOfItem(atPath: whisperPath) {
            whisper["cli_size_kb"] = (attrs[.size] as? Int64 ?? 0) / 1024
            whisper["cli_modified"] = (attrs[.modificationDate] as? Date)?.ISO8601Format() ?? ""
        }
        
        // Check for dynamic libraries
        let libraryPaths: [String]
        if let bundleResourcePath = Bundle.main.resourcePath {
            libraryPaths = ["\(bundleResourcePath)/Libraries"]
        } else {
            libraryPaths = [
                DevPaths.resourcesLibraries,
                "\(DevPaths.whisperBuild)/src"
            ]
        }
        
        var libStatus: [String: Bool] = [:]
        for path in libraryPaths {
            libStatus[path] = FileManager.default.fileExists(atPath: path)
        }
        whisper["library_paths"] = libStatus
        
        // Check models directory
        let modelsPath = WhisperConfiguration.modelsDirectory.path
        whisper["models_directory"] = modelsPath
        whisper["models_directory_exists"] = FileManager.default.fileExists(atPath: modelsPath)
        
        // List available models
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: modelsPath) {
            whisper["available_models"] = contents.filter { $0.hasSuffix(".bin") }
        }
        
        return whisper
    }
    
    private func collectVoxtralDiagnostics() -> [String: Any] {
        var voxtral: [String: Any] = [:]
        
        // Check llama-cli binary if available
        if let llamaPath = Bundle.main.path(forResource: "llama-cli", ofType: nil) {
            voxtral["cli_path"] = llamaPath
            voxtral["cli_exists"] = FileManager.default.fileExists(atPath: llamaPath)
            voxtral["cli_executable"] = FileManager.default.isExecutableFile(atPath: llamaPath)
        }
        
        // Check models directory
        let modelsPath = VoxtralConfiguration.modelsDirectory.path
        voxtral["models_directory"] = modelsPath
        voxtral["models_directory_exists"] = FileManager.default.fileExists(atPath: modelsPath)
        
        return voxtral
    }
    
    /// Format diagnostics as a readable string for logging
    func formatDiagnostics(_ diagnostics: [String: Any]) -> String {
        var output = "=== TRANSCRIPTION FAILURE DIAGNOSTICS ===\n"
        output += "Timestamp: \(diagnostics["timestamp"] ?? "unknown")\n"
        output += "Error: \(diagnostics["error"] ?? "unknown")\n"
        output += "Backend: \(diagnostics["backend"] ?? "unknown")\n"
        output += "\n"
        
        output += "AUDIO FILE:\n"
        output += "  Path: \(diagnostics["audio_path"] ?? "unknown")\n"
        output += "  Exists: \(diagnostics["audio_exists"] ?? false)\n"
        output += "  Size: \(diagnostics["audio_size_kb"] ?? 0)KB\n"
        output += "  Readable: \(diagnostics["audio_readable"] ?? false)\n"
        output += "\n"
        
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
            output += "  Processors: \(system["active_processor_count"] ?? 0)\n"
            output += "\n"
        }
        
        output += "=== END DIAGNOSTICS ===\n"
        
        return output
    }
}
