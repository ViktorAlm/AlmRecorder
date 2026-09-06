import Foundation

final class VibeASRLineReader: @unchecked Sendable {
    private let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func readLine() throws -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newline]
                buffer.removeSubrange(...newline)
                return String(decoding: lineData, as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            }
            // `read(upToCount:)` may wait for the requested byte count while a pipe remains
            // open. Protocol messages such as `---READY---\n` are much shorter than 4 KiB, so
            // that creates a deadlock: the server waits for input while we wait for more output.
            // `availableData` returns as soon as the pipe has any bytes available.
            let chunk = handle.availableData
            if chunk.isEmpty {
                guard !buffer.isEmpty else { return nil }
                defer { buffer.removeAll(keepingCapacity: false) }
                return String(decoding: buffer, as: UTF8.self)
            }
            buffer.append(chunk)
        }
    }
}

/// Owns one warm VibeASR.cpp process. Calls are serialized and every token is forwarded immediately.
actor VibeASRStreamServer {
    private var process: Process?
    private var input: FileHandle?
    private var reader: VibeASRLineReader?
    private var errorLogURL: URL?
    private var isTranscribing = false
    private var isReady = false
    private var readinessTask: Task<Void, Error>?
    private var startupTimeoutTask: Task<Void, Never>?
    private var startupTimedOut = false

    private static let startupTimeoutNanoseconds: UInt64 = 20_000_000_000

    var isRunning: Bool {
        process?.isRunning == true
    }

    func start() async throws {
        if isRunning, isReady { return }
        if let readinessTask {
            return try await readinessTask.value
        }
        if process != nil {
            stop()
        }
        guard VibeASRBitNetModelManager.shared.isModelDownloaded else {
            throw RealtimeDictationError.modelNotDownloaded
        }
        guard let executable = RealtimeDictationConfiguration.resolveServerExecutable() else {
            throw RealtimeDictationError.serverNotInstalled
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "almrec-vibeasr-\(UUID().uuidString).log"
        )
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)

        process.executableURL = executable
        process.arguments = [
            "--vae-model", RealtimeDictationConfiguration.vaeModelURL.path,
            "--lm-model", RealtimeDictationConfiguration.languageModelURL.path,
            "-t", String(max(2, min(6, ProcessInfo.processInfo.activeProcessorCount / 2))),
            "-c", "4096",
            "-b", "1024",
            "--max-tokens", "512",
            "--greedy",
            "--prompt-format", "text",
            "--sample-rate", String(RealtimeDictationConfiguration.sampleRate)
        ]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw RealtimeDictationError.serverFailed(error.localizedDescription)
        }

        let reader = VibeASRLineReader(handle: outputPipe.fileHandleForReading)
        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.reader = reader
        self.errorLogURL = logURL

        let readinessTask = Task.detached(priority: .userInitiated) {
            while let line = try reader.readLine() {
                if line == "---READY---" { return }
                if line.hasPrefix("[ERROR]") {
                    throw RealtimeDictationError.serverFailed(line)
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
        } catch {
            self.readinessTask = nil
            startupTimeoutTask?.cancel()
            startupTimeoutTask = nil
            let didTimeOut = startupTimedOut
            let detail = recentErrorLog()
            stop()
            if didTimeOut {
                throw RealtimeDictationError.serverFailed(
                    "startup handshake timed out after 20 seconds"
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
        guard !isTranscribing else { throw RealtimeDictationError.serverBusy }
        guard isRunning, isReady, let input, let reader else {
            throw RealtimeDictationError.serverClosed
        }
        isTranscribing = true
        defer { isTranscribing = false }

        do {
            try input.write(contentsOf: Data("\(audioURL.path)\n".utf8))
        } catch {
            throw RealtimeDictationError.serverFailed(error.localizedDescription)
        }

        return try await Task.detached(priority: .userInitiated) {
            var text = ""
            while let line = try reader.readLine() {
                if line == "---END---" {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if line.hasPrefix("[ERROR]") {
                    throw RealtimeDictationError.serverFailed(line)
                }
                // The server puts each tokenizer piece on its own protocol line. Pieces already
                // contain their own leading spaces, so adding separators here would corrupt text.
                let piece = line.isEmpty ? "\n" : line
                text += piece
                await onToken(piece)
            }
            throw RealtimeDictationError.serverClosed
        }.value
    }

    func stop() {
        startupTimeoutTask?.cancel()
        startupTimeoutTask = nil
        startupTimedOut = false
        readinessTask?.cancel()
        readinessTask = nil
        isReady = false
        if let input {
            try? input.write(contentsOf: Data("EXIT\n".utf8))
            try? input.close()
        }
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        input = nil
        reader = nil
        if let errorLogURL {
            try? FileManager.default.removeItem(at: errorLogURL)
        }
        errorLogURL = nil
    }

    private func terminateForStartupTimeout() {
        guard readinessTask != nil, !isReady else { return }
        startupTimedOut = true
        try? input?.close()
        if let process, process.isRunning {
            process.terminate()
        }
    }

    func recentErrorLog() -> String {
        guard let errorLogURL,
              let text = try? String(contentsOf: errorLogURL, encoding: .utf8) else {
            return ""
        }
        return String(text.suffix(4_000))
    }
}
