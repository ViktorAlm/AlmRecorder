import AVFoundation
import Foundation

/// Captures the default microphone and emits mono Float32 samples at VibeASR's native 24 kHz.
final class RealtimeAudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let conversionQueue = DispatchQueue(
        label: "com.almrecorder.dictation.audio-conversion",
        qos: .userInteractive
    )
    private let stateLock = NSLock()
    private var running = false

    var isRunning: Bool {
        stateLock.withLock { running }
    }

    func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let sourceFormat = input.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0,
              let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(RealtimeDictationConfiguration.sampleRate),
                channels: 1,
                interleaved: false
              ),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw RealtimeDictationError.audioConversionFailed(
                "The selected microphone format is unavailable."
            )
        }

        input.installTap(onBus: 0, bufferSize: 2_048, format: sourceFormat) {
            [weak self] buffer, _ in
            guard let self,
                  let copy = Self.copy(buffer: buffer) else {
                return
            }
            self.conversionQueue.async {
                guard self.isRunning else { return }
                do {
                    let samples = try Self.convert(
                        copy,
                        converter: converter,
                        targetFormat: targetFormat
                    )
                    if !samples.isEmpty {
                        onSamples(samples)
                    }
                } catch {
                    // A later buffer normally recovers from a transient converter failure.
                    NSLog("[RealtimeDictation] Audio conversion failed: %@", error.localizedDescription)
                }
            }
        }

        do {
            engine.prepare()
            try engine.start()
            stateLock.withLock { running = true }
        } catch {
            input.removeTap(onBus: 0)
            throw RealtimeDictationError.audioConversionFailed(error.localizedDescription)
        }
    }

    func stop() {
        guard isRunning else { return }
        stateLock.withLock { running = false }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        conversionQueue.sync {}
    }

    private static func copy(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            guard let sourceData = source[index].mData,
                  let destinationData = destination[index].mData else {
                continue
            }
            memcpy(
                destinationData,
                sourceData,
                min(Int(source[index].mDataByteSize), Int(destination[index].mDataByteSize))
            )
        }
        return copy
    }

    private static func convert(
        _ input: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) throws -> [Float] {
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio) + 32)
        guard let output = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else {
            throw RealtimeDictationError.audioConversionFailed("Could not allocate an audio buffer.")
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, status in
            if suppliedInput {
                status.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return input
        }
        if status == .error {
            throw RealtimeDictationError.audioConversionFailed(
                conversionError?.localizedDescription ?? "Unknown converter error."
            )
        }
        guard output.frameLength > 0, let channel = output.floatChannelData?[0] else {
            return []
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
