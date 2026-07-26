import Foundation

/// Shared helpers for locating the bundled/dev llama.cpp CLI binaries and the ggml/llama dynamic
/// libraries that MUST match them.
///
/// The llama tools (`llama-mtmd-cli`, `llama-cli`, `llama-embedding`) are all built from the same
/// llama.cpp checkout and load their dylibs from a dedicated directory kept SEPARATE from Whisper's
/// ggml. Loading the wrong `libggml-base.dylib` makes the binary abort with
/// "Symbol not found: _ggml_add_id" (see EmbeddingService for the original of this hazard).
enum LlamaRuntime {
    /// Dev build output of `External/llama.cpp` — holds a consistent binary + dylib set.
    static let devBuildDir = DevPaths.llamaBuildBin
    /// Dev copy of the bundled binaries directory.
    static let devBinariesDir = DevPaths.resourcesBinaries

    /// Set `DYLD_LIBRARY_PATH` so a binary STAGED for bundling (in a `.../Binaries/` dir) loads the
    /// matching ggml/llama dylibs from its sibling `.../Libraries/llama` dir.
    ///
    /// Homebrew/system binaries — and dev CMake builds in `External/llama.cpp/build/bin` — already
    /// carry their own rpath to compatible dylibs, so we MUST NOT override them. Pointing, say, a
    /// Homebrew b9430 binary at an older bundled/External ggml would make it crash or silently run the
    /// wrong (Gemma-unaware) code. This is therefore a no-op unless the binary sits next to a
    /// `Libraries/llama` dir we control.
    static func applyLibraryPath(to process: Process, binaryPath: String) {
        let systemPrefixes = ["/opt/homebrew/", "/usr/local/", "/usr/bin/", "/bin/"]
        if systemPrefixes.contains(where: { binaryPath.hasPrefix($0) }) { return }

        let binDir = (binaryPath as NSString).deletingLastPathComponent       // .../Binaries
        let resourcesDir = (binDir as NSString).deletingLastPathComponent     // .../Resources
        let libDir = "\(resourcesDir)/Libraries/llama"
        guard FileManager.default.fileExists(atPath: "\(libDir)/libllama.dylib") else { return }

        var env = process.environment ?? ProcessInfo.processInfo.environment
        if let existing = env["DYLD_LIBRARY_PATH"], !existing.isEmpty {
            env["DYLD_LIBRARY_PATH"] = "\(libDir):\(existing)"
        } else {
            env["DYLD_LIBRARY_PATH"] = libDir
        }
        process.environment = env
    }

    /// Locate a llama.cpp CLI binary by name. Order: bundled `Resources/Binaries`, dev binaries dir,
    /// dev build dir, caller-supplied system paths, common Homebrew/system paths, then `which`.
    static func findBinary(named name: String, systemSearchPaths: [String] = []) -> String? {
        let fm = FileManager.default

        if let bundled = Bundle.main.path(forResource: name, ofType: nil, inDirectory: "Binaries") {
            return bundled
        }
        if let bundled = Bundle.main.path(forResource: name, ofType: nil) {
            return bundled
        }

        var candidates: [String] = [
            "\(devBinariesDir)/\(name)",
            "\(devBuildDir)/\(name)",
        ]
        candidates.append(contentsOf: systemSearchPaths)
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ])

        if let found = candidates.first(where: { fm.fileExists(atPath: $0) }) {
            return found
        }
        return which(name)
    }

    private static func which(_ name: String) -> String? {
        let task = Process()
        task.launchPath = "/usr/bin/which"
        task.arguments = [name]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()  // Suppress errors
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty == false) ? path : nil
        } catch {
            return nil
        }
    }
}
