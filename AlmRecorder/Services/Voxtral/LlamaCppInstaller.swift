import Foundation

/// Handles installation and management of llama.cpp binary
class LlamaCppInstaller {
    
    static let shared = LlamaCppInstaller()
    
    private let logger = VoxtralLogger.shared
    private let fileManager = FileManager.default
    
    /// Get the path where llama-mtmd-cli should be installed
    var installedBinaryPath: URL {
        // For bundled app
        if let bundledPath = Bundle.main.url(forResource: "llama-mtmd-cli", withExtension: nil, subdirectory: "Binaries") {
            return bundledPath
        }
        
        // For development/user installation
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AlmRecorder/Binaries/llama-mtmd-cli")
    }
    
    /// Check if llama.cpp is installed and working
    func isInstalled() -> Bool {
        // Check bundled binary first
        if let bundledPath = Bundle.main.url(forResource: "llama-mtmd-cli", withExtension: nil, subdirectory: "Binaries") {
            return fileManager.fileExists(atPath: bundledPath.path)
        }
        
        // Check user installation
        return fileManager.fileExists(atPath: installedBinaryPath.path)
    }
    
    /// Install llama.cpp from source
    func installFromSource(progressHandler: @escaping (String, Double) -> Void) async throws {
        logger.info("Starting llama.cpp installation from source")
        
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("llama_build_\(UUID().uuidString)")
        
        do {
            // Create temp directory
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer {
                try? fileManager.removeItem(at: tempDir)
            }
            
            progressHandler("Cloning llama.cpp repository...", 0.1)
            
            // Clone repository
            let cloneProcess = Process()
            cloneProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            cloneProcess.arguments = ["clone", "--depth", "1", "https://github.com/ggerganov/llama.cpp.git", tempDir.path]
            try cloneProcess.run()
            cloneProcess.waitUntilExit()
            
            guard cloneProcess.terminationStatus == 0 else {
                throw InstallationError.cloneFailed
            }
            
            progressHandler("Building llama.cpp with Metal support...", 0.4)
            
            // Build with Metal support
            let buildProcess = Process()
            buildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/make")
            buildProcess.currentDirectoryURL = tempDir
            buildProcess.arguments = ["LLAMA_METAL=1", "LLAMA_ACCELERATE=1", "-j\(ProcessInfo.processInfo.processorCount)"]
            
            try buildProcess.run()
            buildProcess.waitUntilExit()
            
            guard buildProcess.terminationStatus == 0 else {
                throw InstallationError.buildFailed
            }
            
            progressHandler("Installing binary...", 0.8)
            
            // Create installation directory
            let installDir = installedBinaryPath.deletingLastPathComponent()
            try fileManager.createDirectory(at: installDir, withIntermediateDirectories: true)
            
            // Copy binary
            let sourceBinary = tempDir.appendingPathComponent("llama-cli")
            try fileManager.copyItem(at: sourceBinary, to: installedBinaryPath)
            
            // Make executable
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedBinaryPath.path)
            
            progressHandler("Installation complete!", 1.0)
            logger.info("llama.cpp installed successfully at: \(installedBinaryPath.path)")
            
        } catch {
            logger.error("Installation failed: \(error)")
            throw error
        }
    }
    
    /// Download pre-compiled binary (faster alternative)
    func downloadPrecompiled(progressHandler: @escaping (String, Double) -> Void) async throws {
        logger.info("Downloading pre-compiled llama.cpp binary")
        
        // URLs for pre-compiled binaries (you would host these)
        let binaryURLs = [
            "arm64": "https://your-cdn.com/llama-mtmd-cli-macos-arm64",
            "x86_64": "https://your-cdn.com/llama-mtmd-cli-macos-x86_64"
        ]
        
        let arch = getArchitecture()
        guard let downloadURL = binaryURLs[arch].flatMap({ URL(string: $0) }) else {
            throw InstallationError.unsupportedArchitecture
        }
        
        progressHandler("Downloading llama.cpp for \(arch)...", 0.1)
        
        // Create installation directory
        let installDir = installedBinaryPath.deletingLastPathComponent()
        try fileManager.createDirectory(at: installDir, withIntermediateDirectories: true)
        
        // Download binary
        let (localURL, _) = try await URLSession.shared.download(from: downloadURL)
        
        progressHandler("Installing binary...", 0.8)
        
        // Move to installation location
        if fileManager.fileExists(atPath: installedBinaryPath.path) {
            try fileManager.removeItem(at: installedBinaryPath)
        }
        try fileManager.moveItem(at: localURL, to: installedBinaryPath)
        
        // Make executable
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedBinaryPath.path)
        
        progressHandler("Installation complete!", 1.0)
        logger.info("Pre-compiled binary installed at: \(installedBinaryPath.path)")
    }
    
    /// Get system architecture
    private func getArchitecture() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) { ptr in
            String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
        }
        return machine // "arm64" on Apple Silicon, "x86_64" on Intel
    }
    
    enum InstallationError: LocalizedError {
        case cloneFailed
        case buildFailed
        case unsupportedArchitecture
        case downloadFailed
        
        var errorDescription: String? {
            switch self {
            case .cloneFailed:
                return "Failed to clone llama.cpp repository"
            case .buildFailed:
                return "Failed to build llama.cpp"
            case .unsupportedArchitecture:
                return "Unsupported system architecture"
            case .downloadFailed:
                return "Failed to download binary"
            }
        }
    }
}