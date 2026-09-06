import Foundation

/// Collects microphone samples until VAD reports a natural pause at or after the preferred
/// duration. Continuous speech is never split merely because the target duration elapsed.
struct RealtimePauseChunker {
    private let preferredSampleCount: Int
    private let prerollSampleCount: Int
    private let minimumSampleCount: Int
    private var rollingSamples: [Float] = []
    private var containsSpeech = false

    init(
        sampleRate: Int = RealtimeDictationConfiguration.sampleRate,
        preferredDuration: TimeInterval =
            RealtimeDictationConfiguration.preferredChunkDuration,
        prerollDuration: TimeInterval =
            RealtimeDictationConfiguration.speechPrerollDuration,
        minimumDuration: TimeInterval =
            RealtimeDictationConfiguration.minimumChunkDuration
    ) {
        preferredSampleCount = Int(preferredDuration * Double(sampleRate))
        prerollSampleCount = Int(prerollDuration * Double(sampleRate))
        minimumSampleCount = Int(minimumDuration * Double(sampleRate))
        rollingSamples.reserveCapacity(preferredSampleCount)
    }

    mutating func append(
        _ samples: [Float],
        activity: RealtimeVoiceActivityDetector.Update
    ) -> [Float]? {
        guard !samples.isEmpty else { return nil }
        rollingSamples.append(contentsOf: samples)
        if activity.started {
            containsSpeech = true
        }
        guard containsSpeech else {
            retainPreroll()
            return nil
        }
        // A pause is only a normal boundary once the chunk has enough context. Pauses before the
        // preferred duration remain in the same chunk; uninterrupted speech can continue for as
        // long as necessary.
        guard activity.ended, rollingSamples.count >= preferredSampleCount else {
            return nil
        }
        return takeChunk()
    }

    mutating func finish() -> [Float]? {
        takeChunk()
    }

    private mutating func takeChunk() -> [Float]? {
        defer {
            rollingSamples.removeAll(keepingCapacity: true)
            containsSpeech = false
        }
        guard containsSpeech, rollingSamples.count >= minimumSampleCount else {
            return nil
        }
        return rollingSamples
    }

    private mutating func retainPreroll() {
        if rollingSamples.count > prerollSampleCount {
            rollingSamples.removeFirst(rollingSamples.count - prerollSampleCount)
        }
    }
}

/// Converts a continuous sample stream into pause-delimited chunks and keeps only one ASR request
/// in flight, preventing a slow machine from fanning out concurrent model work.
actor RealtimeTranscriptionPipeline {
    typealias TextHandler = @Sendable (String) async -> Void
    typealias ErrorHandler = @Sendable (Error) async -> Void

    private let server: VibeVoiceMLXRealtimeServer
    private let onText: TextHandler
    private let onError: ErrorHandler
    nonisolated private let sampleContinuation: AsyncStream<[Float]>.Continuation
    private let sampleStream: AsyncStream<[Float]>

    private var pendingWindows: [[Float]] = []
    private var assembler = RealtimeTranscriptAssembler()
    private var voiceActivityDetector = RealtimeVoiceActivityDetector()
    private var pauseChunker = RealtimePauseChunker()
    private var worker: Task<Void, Never>?
    private var terminalError: Error?
    private var sampleConsumer: Task<Void, Never>?
    private var ingestionFinished = false

    init(
        server: VibeVoiceMLXRealtimeServer,
        onText: @escaping TextHandler,
        onError: @escaping ErrorHandler
    ) {
        var continuation: AsyncStream<[Float]>.Continuation!
        let stream = AsyncStream<[Float]> { continuation = $0 }
        sampleStream = stream
        sampleContinuation = continuation
        self.server = server
        self.onText = onText
        self.onError = onError
    }

    func start() {
        guard sampleConsumer == nil else { return }
        let stream = sampleStream
        sampleConsumer = Task {
            for await samples in stream {
                append(samples)
            }
        }
    }

    /// AsyncStream continuations are thread-safe, so the audio conversion queue can submit without
    /// spawning a task per microphone buffer. `finish()` closes and drains this stream first.
    nonisolated func ingest(_ samples: [Float]) {
        sampleContinuation.yield(samples)
    }

    private func append(_ samples: [Float]) {
        guard terminalError == nil, !samples.isEmpty else { return }
        let activity = voiceActivityDetector.process(samples)
        if let chunk = pauseChunker.append(samples, activity: activity) {
            pendingWindows.append(chunk)
        }
        startWorkerIfNeeded()
    }

    func finish() async throws -> String {
        if !ingestionFinished {
            ingestionFinished = true
            sampleContinuation.finish()
            let consumer = sampleConsumer
            await consumer?.value
            sampleConsumer = nil
        }
        if let chunk = pauseChunker.finish() {
            pendingWindows.append(chunk)
        }
        startWorkerIfNeeded()
        let activeWorker = worker
        await activeWorker?.value

        if let terminalError { throw terminalError }
        let result = assembler.committed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw RealtimeDictationError.noText }
        return result
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !pendingWindows.isEmpty else { return }
        worker = Task { await drain() }
    }

    private func drain() async {
        while !pendingWindows.isEmpty, terminalError == nil {
            let samples = pendingWindows.removeFirst()
            do {
                try await process(samples)
            } catch {
                terminalError = error
                await onError(error)
            }
        }
        worker = nil
        // A window can arrive while an awaiting process call is returning and before worker clears.
        if !pendingWindows.isEmpty, terminalError == nil {
            startWorkerIfNeeded()
        }
    }

    private func process(_ samples: [Float]) async throws {
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "almrec-dictation-\(UUID().uuidString).wav"
        )
        try RealtimeWAVWriter.write(
            samples: samples,
            sampleRate: RealtimeDictationConfiguration.sampleRate,
            to: temporaryURL
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let committedBeforeWindow = assembler.committed
        let text = try await server.transcribe(audioURL: temporaryURL) { [weak self] piece in
            await self?.receive(piece: piece, committedBeforeWindow: committedBeforeWindow)
        }
        let assembled = assembler.commit(text)
        await onText(assembled)
    }

    private func receive(piece: String, committedBeforeWindow: String) async {
        assembler.updateProvisional(assembler.provisional + piece)
        let partial = [committedBeforeWindow, assembler.provisional]
            .filter { !$0.isEmpty }
            .joined(separator: committedBeforeWindow.isEmpty ? "" : " ")
        await onText(partial)
    }
}
