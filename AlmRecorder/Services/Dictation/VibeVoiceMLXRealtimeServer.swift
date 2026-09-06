import Foundation

struct VibeVoiceRealtimeRequest: Codable, Equatable {
    let type: String
    let id: String
    let audio: String
    let context: String?
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case type, id, audio, context
        case maxTokens = "max_tokens"
    }
}

struct VibeVoiceRealtimeResponse: Codable, Equatable {
    let type: String
    let id: String?
    let message: String?
    let text: String?
    let processingSeconds: Double?
    let peakMemoryGB: Double?

    enum CodingKeys: String, CodingKey {
        case type, id, message, text
        case processingSeconds = "processing_seconds"
        case peakMemoryGB = "peak_memory_gb"
    }
}

private final class VibeVoiceRealtimeMemoryAbortState: @unchecked Sendable {
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

/// Owns one full VibeVoice-ASR 4-bit MLX process for a dictation session. The Python helper loads
/// the model once, keeps its Metal weights resident, and serially serves each pause-delimited WAV.
actor VibeVoiceMLXRealtimeServer {
    typealias StatusHandler = @Sendable (String) async -> Void

    private var process: Process?
    private var input: FileHandle?
    private var reader: VibeASRLineReader?
    private var errorLogURL: URL?
    private var isTranscribing = false
    private var isReady = false
    private var readinessTask: Task<Void, Error>?
    private var startupTimeoutTask: Task<Void, Never>?
    private var startupTimedOut = false
    private var memoryMonitor: DispatchSourceTimer?
    private var memoryAbort = VibeVoiceRealtimeMemoryAbortState()

    private let resourceProfile = TranscriptionResourceProfile.vibeVoice(
        RealtimeDictationConfiguration.modelQuantization
    )
    private static let startupTimeoutNanoseconds: UInt64 = 120_000_000_000

    var isRunning: Bool {
        process?.isRunning == true
    }

    func start(onStatus: StatusHandler? = nil) async throws {
        if isRunning, isReady { return }
        if let readinessTask {
            return try await readinessTask.value
        }
        if process != nil {
            await stop()
        }
        guard VibeVoiceModelManager.shared.isModelDownloaded(
            RealtimeDictationConfiguration.modelQuantization
        ) else {
            throw RealtimeDictationError.modelNotDownloaded
        }
        guard let command = VibeVoiceHelperRunner.resolveCommand() else {
            throw RealtimeDictationError.serverNotInstalled
        }
        if let deferral = SystemMemoryGate.shared.transcriptionDeferral(
            profile: resourceProfile
        ) {
            throw RealtimeDictationError.serverFailed(deferral.reason)
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "almrec-vibevoice-realtime-\(UUID().uuidString).log"
        )
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)

        process.executableURL = command.executableURL
        process.arguments = command.prefixArguments + [
            "serve",
            "--model", VibeVoiceConfiguration.modelDirectory(
                for: RealtimeDictationConfiguration.modelQuantization
            ).path,
            "--max-tokens", "768",
            "--memory-limit-bytes", String(resourceProfile.estimatedPeakBytes)
        ]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = logHandle
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        process.environment = environment

        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw RealtimeDictationError.serverFailed(error.localizedDescription)
        }

        let reader = VibeASRLineReader(handle: outputPipe.fileHandleForReading)
        memoryAbort = VibeVoiceRealtimeMemoryAbortState()
        self.process = process
        input = inputPipe.fileHandleForWriting
        self.reader = reader
        errorLogURL = logURL
        startMemoryMonitor(process: process, abortState: memoryAbort)

        let readinessTask = Task.detached(priority: .userInitiated) {
            let decoder = JSONDecoder()
            while let line = try reader.readLine() {
                guard let data = line.data(using: .utf8),
                      let response = try? decoder.decode(
                        VibeVoiceRealtimeResponse.self,
                        from: data
                      ) else {
                    continue
                }
                switch response.type {
                case "status":
                    if let message = response.message {
                        await onStatus?(message)
                    }
                case "ready":
                    return
                case "error":
                    throw RealtimeDictationError.serverFailed(
                        response.message ?? "The MLX helper failed while loading."
                    )
                default:
                    continue
                }
            }
            throw RealtimeDictationError.serverClosed
        }
        self.readinessTask = readinessTask
        startupTimedOut = false
        startupTimeoutTask = Task.detached { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.startupTimeoutNanoseconds)
            } catch {
                return
            }
            await self?.terminateForStartupTimeout()
        }

        do {
            try await readinessTask.value
            isReady = true
            self.readinessTask = nil
            startupTimeoutTask?.cancel()
            startupTimeoutTask = nil
            await onStatus?("VibeVoice ASR 4-bit ready")
        } catch {
            self.readinessTask = nil
            startupTimeoutTask?.cancel()
            startupTimeoutTask = nil
            let didTimeOut = startupTimedOut
            let memoryReason = memoryAbort.reason
            let detail = recentErrorLog()
            await stop()
            if let memoryReason {
                throw RealtimeDictationError.serverFailed(
                    "stopped to protect system memory: \(memoryReason)"
                )
            }
            if didTimeOut {
                throw RealtimeDictationError.serverFailed(
                    "loading the 4-bit MLX model timed out after 120 seconds"
                )
            }
            if !detail.isEmpty {
                throw RealtimeDictationError.serverFailed(detail)
            }
            throw error
        }
    }

    func transcribe(
        audioURL: URL,
        onToken: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        if !isRunning || !isReady {
            try await start()
        }
        guard !isTranscribing else { throw RealtimeDictationError.serverBusy }
        guard isRunning, isReady, let input, let reader else {
            throw RealtimeDictationError.serverClosed
        }
        if let reason = memoryAbort.reason {
            throw RealtimeDictationError.serverFailed(
                "stopped to protect system memory: \(reason)"
            )
        }

        isTranscribing = true
        defer { isTranscribing = false }

        let request = VibeVoiceRealtimeRequest(
            type: "transcribe",
            id: UUID().uuidString,
            audio: audioURL.path,
            context: GlobalModelSettings.shared.vibeVoiceContext.nilIfBlankForRealtime,
            maxTokens: 768
        )
        var encoded = try JSONEncoder().encode(request)
        encoded.append(0x0A)
        do {
            try input.write(contentsOf: encoded)
        } catch {
            throw RealtimeDictationError.serverFailed(error.localizedDescription)
        }

        let abortState = memoryAbort
        return try await Task.detached(priority: .userInitiated) {
            let decoder = JSONDecoder()
            while let line = try reader.readLine() {
                guard let data = line.data(using: .utf8),
                      let response = try? decoder.decode(
                        VibeVoiceRealtimeResponse.self,
                        from: data
                      ) else {
                    continue
                }
                if let responseID = response.id, responseID != request.id {
                    continue
                }
                switch response.type {
                case "token":
                    if let piece = response.text {
                        await onToken(piece)
                    }
                case "result":
                    let text = response.text?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !text.isEmpty else {
                        throw RealtimeDictationError.noText
                    }
                    // The full model emits structured JSON internally. Forward only the extracted
                    // spoken content to the dictation HUD and insertion pipeline.
                    await onToken(text)
                    return text
                case "error":
                    throw RealtimeDictationError.serverFailed(
                        response.message ?? "The 4-bit MLX model failed."
                    )
                default:
                    continue
                }
            }
            if let reason = abortState.reason {
                throw RealtimeDictationError.serverFailed(
                    "stopped to protect system memory: \(reason)"
                )
            }
            throw RealtimeDictationError.serverClosed
        }.value
    }

    func stop() async {
        startupTimeoutTask?.cancel()
        startupTimeoutTask = nil
        startupTimedOut = false
        readinessTask?.cancel()
        readinessTask = nil
        isReady = false
        isTranscribing = false
        stopMemoryMonitor()

        let oldProcess = process
        if let input {
            let exitMessage = Data("{\"type\":\"exit\"}\n".utf8)
            try? input.write(contentsOf: exitMessage)
            try? input.close()
        }
        if let oldProcess, oldProcess.isRunning {
            oldProcess.terminate()
            await Task.detached(priority: .utility) {
                oldProcess.waitUntilExit()
            }.value
        }

        process = nil
        input = nil
        reader = nil
        if let errorLogURL {
            try? FileManager.default.removeItem(at: errorLogURL)
        }
        errorLogURL = nil
    }

    func recentErrorLog() -> String {
        guard let errorLogURL,
              let text = try? String(contentsOf: errorLogURL, encoding: .utf8) else {
            return ""
        }
        return String(text.suffix(4_000))
    }

    private func terminateForStartupTimeout() {
        guard readinessTask != nil, !isReady else { return }
        startupTimedOut = true
        try? input?.close()
        if let process, process.isRunning {
            process.terminate()
        }
    }

    private func startMemoryMonitor(
        process: Process,
        abortState: VibeVoiceRealtimeMemoryAbortState
    ) {
        stopMemoryMonitor()
        let profile = resourceProfile
        let monitor = DispatchSource.makeTimerSource(
            queue: DispatchQueue(
                label: "com.almrecorder.vibevoice-realtime.memory-monitor",
                qos: .userInitiated
            )
        )
        monitor.schedule(deadline: .now() + 1, repeating: 1)
        monitor.setEventHandler { [weak process] in
            guard let process, process.isRunning,
                  let reason = SystemMemoryGate.shared.transcriptionEmergencyReason(
                    profile: profile
                  ),
                  abortState.setIfEmpty(reason) else {
                return
            }
            process.terminate()
        }
        monitor.activate()
        memoryMonitor = monitor
    }

    private func stopMemoryMonitor() {
        memoryMonitor?.setEventHandler {}
        memoryMonitor?.cancel()
        memoryMonitor = nil
    }
}

private extension String {
    var nilIfBlankForRealtime: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
