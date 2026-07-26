import Foundation

/// Resolves filesystem locations for **development / build-from-source** runs, where the app is
/// launched outside a packaged `.app` bundle and therefore cannot use `Bundle.main` resources.
///
/// Production builds always resolve bundled resources via `Bundle.main` first; these helpers are
/// only consulted as a fallback. The repository root is found, in order:
///   1. The `ALMRECORDER_DEV_ROOT` environment variable (explicit override), or
///   2. Walking up from this source file (`#filePath`) to the directory containing `Package.swift`.
///
/// Because `#filePath` is the path of *this file at compile time*, a contributor who builds from
/// their own clone gets that clone's paths automatically — there are no per-machine hardcoded paths.
enum DevPaths {
    /// Absolute path to the repository root for the current build.
    static let repoRoot: String = {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["ALMRECORDER_DEV_ROOT"], !env.isEmpty {
            return (env as NSString).expandingTildeInPath
        }
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir.path
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        // Fallback: this file lives at <root>/AlmRecorder/Services/Support/DevPaths.swift
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Support
            .deletingLastPathComponent()   // Services
            .deletingLastPathComponent()   // AlmRecorder
            .deletingLastPathComponent()   // <root>
            .path
    }()

    /// `<root>/AlmRecorder/Resources/Libraries` — staged whisper ggml dylibs (+ vectorlite, sqlite).
    static var resourcesLibraries: String { "\(repoRoot)/AlmRecorder/Resources/Libraries" }
    /// `<root>/AlmRecorder/Resources/Binaries` — staged CLI binaries (whisper-cli, llama-*).
    static var resourcesBinaries: String { "\(repoRoot)/AlmRecorder/Resources/Binaries" }
    /// `<root>/External/whisper.cpp/build` — CMake build output of the whisper.cpp submodule.
    static var whisperBuild: String { "\(repoRoot)/External/whisper.cpp/build" }
    /// `<root>/External/llama.cpp/build/bin` — CMake build output of the llama.cpp submodule.
    static var llamaBuildBin: String { "\(repoRoot)/External/llama.cpp/build/bin" }
}
