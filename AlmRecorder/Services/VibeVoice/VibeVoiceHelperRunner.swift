import Foundation

struct VibeVoiceHelperCommand: Equatable {
    let executableURL: URL
    let prefixArguments: [String]
}

private final class VibeVoiceMemoryAbortState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedReason: String?

    func setIfEmpty(_ reason: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard storedReason == nil else { return false }
        storedReason = reason
        return true
    }

    var reason: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedReason
    }
}

/// Executes the separately packaged MLX runtime. The stable file-based JSON contract isolates
/// Python/MLX logs from machine-readable output and lets cancellation terminate the child process.
final class VibeVoiceHelperRunner: @unchecked Sendable {
    private let processLock = NSLock()
    private var activeProcess: Process?
    private let logger = VoxtralLogger.shared

    func probe() async throws {
        _ = try await run(arguments: ["probe"])
    }

    func run(
        arguments: [String],
        resourceProfile: TranscriptionResourceProfile? = nil
    ) async throws -> Data {
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try self.runBlocking(
                    arguments: arguments,
                    resourceProfile: resourceProfile
                )
            }.value
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        processLock.lock()
        let process = activeProcess
        processLock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    static func resolveCommand(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> VibeVoiceHelperCommand? {
        let fileManager = FileManager.default
        if let override = environment["ALMREC_VIBEVOICE_HELPER"],
           fileManager.isExecutableFile(atPath: override) {
            return VibeVoiceHelperCommand(
                executableURL: URL(fileURLWithPath: override),
                prefixArguments: []
            )
        }

        let binaryCandidates: [URL?] = [
            Bundle.main.url(forResource: "vibevoice-helper", withExtension: nil,
                            subdirectory: "Binaries"),
            Bundle.main.url(forResource: "vibevoice-helper", withExtension: nil)
        ]
        if let binary = binaryCandidates.compactMap({ $0 }).first(
            where: { fileManager.isExecutableFile(atPath: $0.path) }
        ) {
            return VibeVoiceHelperCommand(executableURL: binary, prefixArguments: [])
        }

        let bundledScript = Bundle.main.url(
            forResource: "vibevoice_helper",
            withExtension: "py",
            subdirectory: "Python"
        )
        let bundledPython = Bundle.main.resourceURL?
            .appendingPathComponent("VibeVoiceRuntime/bin/python3")
        if let script = bundledScript,
           let python = bundledPython,
           fileManager.isExecutableFile(atPath: python.path) {
            return VibeVoiceHelperCommand(
                executableURL: python,
                prefixArguments: [script.path]
            )
        }

        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("AlmRecorder/VibeVoiceRuntime")
        let installedPython = appSupport.appendingPathComponent("bin/python3")
        let installedScript = appSupport.appendingPathComponent("vibevoice_helper.py")
        if fileManager.isExecutableFile(atPath: installedPython.path),
           fileManager.fileExists(atPath: installedScript.path) {
            return VibeVoiceHelperCommand(
                executableURL: installedPython,
                prefixArguments: [installedScript.path]
            )
        }

        let developmentScript = URL(
            fileURLWithPath: "\(DevPaths.repoRoot)/AlmRecorder/Resources/Python/vibevoice_helper.py"
        )
        if let developmentPython = environment["ALMREC_VIBEVOICE_PYTHON"],
           fileManager.fileExists(atPath: developmentScript.path),
           fileManager.isExecutableFile(atPath: developmentPython) {
            return VibeVoiceHelperCommand(
                executableURL: URL(fileURLWithPath: developmentPython),
                prefixArguments: [developmentScript.path]
            )
        }
        return nil
    }

    private func runBlocking(
        arguments: [String],
        resourceProfile: TranscriptionResourceProfile?
    ) throws -> Data {
        guard let command = Self.resolveCommand() else {
            throw TranscriptionError.transcriptionFailed(
                "VibeVoice runtime is not installed. Install it from Settings → Models."
            )
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("almrec-vibevoice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let outputURL = temporary.appendingPathComponent("result.json")
        let logURL = temporary.appendingPathComponent("helper.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)

        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.prefixArguments + arguments + ["--output", outputURL.path]
        process.standardOutput = logHandle
        process.standardError = logHandle
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        process.environment = environment

        processLock.lock()
        activeProcess = process
        processLock.unlock()
        defer {
            processLock.lock()
            if activeProcess === process { activeProcess = nil }
            processLock.unlock()
            ChildProcessReaper.shared.untrack(process)
            try? logHandle.close()
        }

        try process.run()
        ChildProcessReaper.shared.track(process, label: "vibevoice")

        let memoryAbort = VibeVoiceMemoryAbortState()
        let memoryMonitor: DispatchSourceTimer?
        if let resourceProfile {
            let monitor = DispatchSource.makeTimerSource(
                queue: DispatchQueue(
                    label: "com.almrecorder.vibevoice.memory-monitor",
                    qos: .userInitiated
                )
            )
            monitor.schedule(deadline: .now() + 2, repeating: 2)
            monitor.setEventHandler { [weak self, weak process] in
                guard let self, let process, process.isRunning,
                      let reason = SystemMemoryGate.shared.transcriptionEmergencyReason(
                        profile: resourceProfile
                      ),
                      memoryAbort.setIfEmpty(reason) else {
                    return
                }
                self.logger.error(
                    "[VibeVoice] Emergency memory stop: \(reason) — terminating pid \(process.processIdentifier)"
                )
                process.terminate()
                let pid = process.processIdentifier
                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + 2
                ) {
                    if process.isRunning {
                        kill(pid, SIGKILL)
                    }
                }
            }
            monitor.activate()
            memoryMonitor = monitor
        } else {
            memoryMonitor = nil
        }
        defer {
            memoryMonitor?.setEventHandler {}
            memoryMonitor?.cancel()
        }

        process.waitUntilExit()
        try? logHandle.synchronize()
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        if let reason = memoryAbort.reason {
            throw TranscriptionError.resourcesUnavailable(
                "VibeVoice was stopped before the Mac ran out of memory: \(reason)"
            )
        }
        guard process.terminationStatus == 0 else {
            if Task.isCancelled {
                throw CancellationError()
            }
            let detail = String(log.suffix(4_000))
            if BackgroundGPUAdmission.isMetalOOM(detail) {
                SystemMemoryGate.shared.reportMetalOOM(source: "VibeVoice MLX")
                throw TranscriptionError.gpuOutOfMemory(detail)
            }
            throw TranscriptionError.processFailed(
                detail.isEmpty ? "VibeVoice helper exited \(process.terminationStatus)" : detail
            )
        }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw TranscriptionError.invalidResponse
        }
        return try Data(contentsOf: outputURL)
    }
}
