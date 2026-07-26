import Combine
import Foundation

/// Installs the pinned MLX runtime into Application Support. Distribution builds bundle `uv`; the
/// development fallback uses an existing uv installation. The resulting environment is isolated
/// from system Python and can be validated through the same helper probe used for transcription.
final class VibeVoiceRuntimeInstaller: ObservableObject {
    static let shared = VibeVoiceRuntimeInstaller()

    @Published private(set) var isInstalling = false
    @Published private(set) var status = ""

    private let fileManager = FileManager.default

    var isInstalled: Bool {
        VibeVoiceHelperRunner.resolveCommand() != nil
            && fileManager.fileExists(atPath: runtimeDirectory.appendingPathComponent("bin/python3").path)
    }

    func install() async throws {
        guard let uvURL = locateUV() else {
            throw TranscriptionError.installationFailed
        }
        await setState(installing: true, status: "Preparing isolated Python…")
        defer { Task { await self.setState(installing: false, status: "") } }

        let parent = runtimeDirectory.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            ".VibeVoiceRuntime-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: staging) }

        try await run(
            uvURL,
            arguments: ["python", "install", "3.12"]
        )
        try Task.checkCancellation()
        await setState(installing: true, status: "Creating VibeVoice runtime…")
        try await run(
            uvURL,
            arguments: [
                "venv",
                "--python", "3.12",
                "--python-preference", "only-managed",
                "--relocatable",
                "--seed",
                staging.path
            ]
        )
        try Task.checkCancellation()
        await setState(installing: true, status: "Installing pinned MLX-Audio…")
        try await run(
            uvURL,
            arguments: [
                "pip", "install",
                "--python", staging.appendingPathComponent("bin/python3").path,
                "git+https://github.com/Blaizzy/mlx-audio.git@\(VibeVoiceConfiguration.mlxAudioRevision)"
            ]
        )

        guard let sourceScript = helperSourceURL else {
            throw TranscriptionError.installationFailed
        }
        try fileManager.copyItem(
            at: sourceScript,
            to: staging.appendingPathComponent("vibevoice_helper.py")
        )

        let backup = parent.appendingPathComponent(
            ".VibeVoiceRuntime-backup-\(UUID().uuidString)",
            isDirectory: true
        )
        if fileManager.fileExists(atPath: runtimeDirectory.path) {
            try fileManager.moveItem(at: runtimeDirectory, to: backup)
        }
        do {
            try fileManager.moveItem(at: staging, to: runtimeDirectory)
            try? fileManager.removeItem(at: backup)
        } catch {
            if fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: runtimeDirectory)
            }
            throw error
        }

        await setState(installing: true, status: "Validating runtime…")
        do {
            try await VibeVoiceService.shared.validateRuntime()
        } catch {
            try? fileManager.removeItem(at: runtimeDirectory)
            throw error
        }
    }

    private var runtimeDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AlmRecorder/VibeVoiceRuntime", isDirectory: true)
    }

    private var helperSourceURL: URL? {
        let bundled = Bundle.main.url(
            forResource: "vibevoice_helper",
            withExtension: "py",
            subdirectory: "Python"
        )
        if let bundled { return bundled }
        let development = URL(
            fileURLWithPath: "\(DevPaths.repoRoot)/AlmRecorder/Resources/Python/vibevoice_helper.py"
        )
        return fileManager.fileExists(atPath: development.path) ? development : nil
    }

    private func locateUV() -> URL? {
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "uv", withExtension: nil, subdirectory: "Binaries"),
            Bundle.main.url(forResource: "uv", withExtension: nil),
            URL(fileURLWithPath: "/opt/homebrew/bin/uv"),
            URL(fileURLWithPath: "/usr/local/bin/uv")
        ]
        return candidates.compactMap { $0 }.first {
            fileManager.isExecutableFile(atPath: $0.path)
        }
    }

    private func run(_ executable: URL, arguments: [String]) async throws {
        try await Task.detached(priority: .utility) {
            let logURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("almrec-vibevoice-install-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            defer { try? FileManager.default.removeItem(at: logURL) }
            let logHandle = try FileHandle(forWritingTo: logURL)
            defer { try? logHandle.close() }

            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = logHandle
            process.standardError = logHandle
            try process.run()
            process.waitUntilExit()
            try? logHandle.synchronize()
            guard process.terminationStatus == 0 else {
                let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                throw TranscriptionError.processFailed(String(log.suffix(6_000)))
            }
        }.value
    }

    private func setState(installing: Bool, status: String) async {
        await MainActor.run {
            self.isInstalling = installing
            self.status = status
        }
    }
}
