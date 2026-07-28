import Foundation

/// Converts a continuous sample stream into overlapping windows and keeps only one ASR request
/// in flight. With the model warm, this bounds latency without allowing a slow machine to fan out.
actor RealtimeTranscriptionPipeline {
    typealias TextHandler = @Sendable (String) async -> Void
    typealias ErrorHandler = @Sendable (Error) async -> Void

    private let server: VibeASRStreamServer
    private let onText: TextHandler
    private let onError: ErrorHandler
    private let windowSampleCount: Int
    private let overlapSampleCount: Int
    private let hopSampleCount: Int
    private let minimumFinalSampleCount: Int
    nonisolated private let sampleContinuation: AsyncStream<[Float]>.Continuation
    private let sampleStream: AsyncStream<[Float]>

    private var rollingSamples: [Float] = []
    private var pendingWindows: [[Float]] = []
    private var assembler = RealtimeTranscriptAssembler()
    private var voiceActivityDetector = RealtimeVoiceActivityDetector()
    private var worker: Task<Void, Never>?
    private var currentSegmentHasSpeech = false
    private var currentSegmentHasScheduledWindow = false
    private var terminalError: Error?
    private var sampleConsumer: Task<Void, Never>?
    private var ingestionFinished = false

    init(
        server: VibeASRStreamServer,
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
        windowSampleCount = Int(
            RealtimeDictationConfiguration.windowDuration
                * Double(RealtimeDictationConfiguration.sampleRate)
        )
        overlapSampleCount = Int(
            RealtimeDictationConfiguration.overlapDuration
                * Double(RealtimeDictationConfiguration.sampleRate)
        )
        hopSampleCount = windowSampleCount - overlapSampleCount
        minimumFinalSampleCount = Int(
            RealtimeDictationConfiguration.minimumFinalWindowDuration
                * Double(RealtimeDictationConfiguration.sampleRate)
        )
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
        rollingSamples.append(contentsOf: samples)
        if activity.started {
            currentSegmentHasSpeech = true
        }
        if !currentSegmentHasSpeech {
            // Keep enough audio to preserve the beginning of a word once speech triggers.
            if rollingSamples.count > overlapSampleCount {
                rollingSamples.removeFirst(rollingSamples.count - overlapSampleCount)
            }
            return
        }
        while rollingSamples.count >= windowSampleCount {
            pendingWindows.append(Array(rollingSamples.prefix(windowSampleCount)))
            rollingSamples.removeFirst(hopSampleCount)
            currentSegmentHasScheduledWindow = true
        }
        if activity.ended {
            enqueueCurrentSegmentTail()
            rollingSamples.removeAll(keepingCapacity: true)
            currentSegmentHasSpeech = false
            currentSegmentHasScheduledWindow = false
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
        if currentSegmentHasSpeech {
            enqueueCurrentSegmentTail()
        }
        rollingSamples.removeAll(keepingCapacity: false)
        startWorkerIfNeeded()
        let activeWorker = worker
        await activeWorker?.value

        if let terminalError { throw terminalError }
        let result = assembler.committed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw RealtimeDictationError.noText }
        return result
    }

    private func enqueueCurrentSegmentTail() {
        let unsubmittedCount = currentSegmentHasScheduledWindow
            ? max(0, rollingSamples.count - overlapSampleCount)
            : rollingSamples.count
        if unsubmittedCount >= minimumFinalSampleCount {
            pendingWindows.append(rollingSamples)
        }
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
