import Foundation
import AVFoundation
import ScreenCaptureKit
import Combine
import OSLog

/// Dual-channel meeting recorder.
///
/// Captures two independent tracks so a call can be transcribed by *source* instead of guessing with
/// diarization on a muddy mono mix:
///   • **Mic track** — `AVAudioEngine` input with Voice-Processing I/O enabled (noise suppression +
///     auto-gain, and echo-cancellation of the engine's own output). This is "you".
///   • **System track** — `ScreenCaptureKit` system audio, captured *digitally* (so the remote
///     participants are pristine and there is no echo to remove). This is "them".
///
/// Both are best-effort: if Screen Recording permission is missing we still record the mic, and vice
/// versa. On stop, the two file URLs are handed to the transcription queue, tagged by source.
final class MeetingRecorder: NSObject, ObservableObject {
    /// Shared so a meeting keeps recording even if the user navigates away from the Record tab.
    static let shared = MeetingRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var micActive = false
    @Published private(set) var systemActive = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var micLevel: Float = 0     // 0…1, live mic RMS for the meter/waveform
    @Published private(set) var systemLevel: Float = 0  // 0…1, live system-audio RMS

    private(set) var micFileURL: URL?
    private(set) var systemFileURL: URL?

    private let logger = Logger(subsystem: "com.almrecorder", category: "MeetingRecorder")

    // Mic
    // Keep no input audio unit alive while idle. In particular, voice-processing input nodes can
    // continue to make macOS report microphone use after the engine has merely been stopped.
    private var engine: AVAudioEngine?
    private var micTapInstalled = false
    private var micFile: AVAudioFile?

    // System audio
    private var stream: SCStream?
    private var systemFile: AVAudioFile?
    private let systemQueue = DispatchQueue(label: "com.almrecorder.meeting.system")

    private var timer: Timer?
    private var startedAt: Date?

    // MARK: - Lifecycle

    func start() async {
        let shouldStart = await MainActor.run {
            guard !isRecording, !isStarting else { return false }
            isStarting = true
            statusMessage = "Starting…"
            return true
        }
        guard shouldStart else { return }

        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stamp = Int(Date().timeIntervalSince1970)
        micFileURL = base.appendingPathComponent("meeting_\(stamp)_mic.caf")
        systemFileURL = base.appendingPathComponent("meeting_\(stamp)_system.caf")

        let startedMic = startMic()
        let startedSystem = await startSystemAudio()

        guard startedMic || startedSystem else {
            stopMic()
            await stopSystemAudio()
            await MainActor.run {
                isStarting = false
                micActive = false
                systemActive = false
                statusMessage = "No audio sources available."
            }
            return
        }

        await MainActor.run {
            micActive = startedMic
            systemActive = startedSystem
            startedAt = Date()
            duration = 0
            isStarting = false
            isRecording = true
            statusMessage = sourceSummary()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, let s = self.startedAt else { return }
                self.duration = Date().timeIntervalSince(s)
            }
        }
    }

    /// Stop both captures and return the recorded track URLs (nil if that source produced nothing).
    @discardableResult
    func stop() async -> (mic: URL?, system: URL?) {
        guard isRecording || engine != nil || stream != nil else { return (nil, nil) }

        let hadMic = engine != nil
        let hadSystem = stream != nil

        await MainActor.run {
            timer?.invalidate()
            timer = nil
            isRecording = false
            micLevel = 0
            systemLevel = 0
        }

        // Mic
        stopMic()

        // System
        await stopSystemAudio()

        let mic = (hadMic && fileHasAudio(micFileURL)) ? micFileURL : nil
        let sys = (hadSystem && fileHasAudio(systemFileURL)) ? systemFileURL : nil
        await MainActor.run {
            micActive = false
            systemActive = false
            statusMessage = ""
        }
        return (mic, sys)
    }

    // MARK: - Mic channel

    @discardableResult
    private func startMic() -> Bool {
        // The engine owns the microphone input audio unit, so its lifetime is deliberately scoped
        // to this recording attempt rather than the lifetime of the app-wide recorder singleton.
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        micTapInstalled = false

        // Enable Voice-Processing I/O for acoustic echo cancellation — without it the mic also records
        // the speaker output (the remote party leaks into our track, duplicating the system capture).
        // Historically VPIO ducked ALL other system audio (the call went quiet in the speakers), which
        // is why it was removed. macOS 14 added `voiceProcessingOtherAudioDuckingConfiguration`, so we
        // now get AEC while keeping the meeting at full volume by setting ducking to minimum. Only
        // enable it where we can control the ducking (macOS 14+); older systems keep the raw mic.
        if #available(macOS 14.0, *) {
            do {
                try input.setVoiceProcessingEnabled(true)
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                        enableAdvancedDucking: false, duckingLevel: .min)
                logger.info("Voice-processing (AEC) enabled with minimal ducking")
            } catch {
                logger.warning("Voice-processing unavailable, recording raw mic: \(error.localizedDescription)")
            }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let url = micFileURL else {
            stopMic()
            return false
        }

        do {
            micFile = try AVAudioFile(forWriting: url, settings: format.settings)
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                // Runs on the audio render thread; AVAudioFile.write here is the standard pattern.
                try? self?.micFile?.write(from: buffer)
                self?.publishMicLevel(buffer)
            }
            micTapInstalled = true
            try engine.start()
            logger.info("Mic capture started @ \(format.sampleRate, format: .fixed(precision: 0))Hz")
            return true
        } catch {
            logger.error("Mic capture failed: \(error.localizedDescription)")
            stopMic()
            return false
        }
    }

    /// Stop and release every object that owns a microphone input audio unit. Releasing the engine
    /// (not just calling `stop`) is what makes idle microphone use unambiguous to macOS.
    private func stopMic() {
        guard let engine else {
            micFile = nil
            return
        }

        let input = engine.inputNode
        if micTapInstalled {
            input.removeTap(onBus: 0)
            micTapInstalled = false
        }
        engine.stop()
        if #available(macOS 14.0, *) {
            try? input.setVoiceProcessingEnabled(false)
        }
        engine.reset()
        micFile = nil // closing the AVAudioFile flushes it
        self.engine = nil
    }

    // MARK: - System-audio channel (ScreenCaptureKit)

    @discardableResult
    private func startSystemAudio() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                logger.warning("No display available for system audio capture")
                return false
            }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true // don't record our own playback
            config.sampleRate = 48_000
            config.channelCount = 2
            // SCStream needs a display source even when we only want audio; keep video tiny + slow.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
            try await stream.startCapture()
            self.stream = stream
            await MainActor.run {
                PermissionsManager.shared.noteScreenRecordingAccessGranted()
            }
            logger.info("System-audio capture started")
            return true
        } catch {
            logger.error("System-audio capture failed: \(error.localizedDescription)")
            await stopSystemAudio()
            await MainActor.run {
                statusMessage = "System audio off — enable Screen Recording in System Settings ▸ Privacy."
            }
            return false
        }
    }

    private func stopSystemAudio() async {
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        systemQueue.sync { systemFile = nil }
    }

    // MARK: - Helpers

    private func setSystemActive(_ v: Bool) { DispatchQueue.main.async { self.systemActive = v } }

    private func publishMicLevel(_ buffer: AVAudioPCMBuffer) {
        let level = Self.rmsLevel(buffer)
        DispatchQueue.main.async { self.micLevel = level }
    }

    /// RMS → 0…1 level, averaged across channels. Handles interleaved + multi-channel buffers
    /// (mic from the engine, system audio from ScreenCaptureKit). Scaled so normal levels read
    /// mid-meter; runs on the audio thread, callers publish on main.
    static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let channels = max(Int(buffer.format.channelCount), 1)
        let interleaved = buffer.format.isInterleaved
        var sumSq: Float = 0
        var count = 0

        if let data = buffer.floatChannelData {
            if interleaved {
                let total = frames * channels, p = data[0]
                for i in 0..<total { sumSq += p[i] * p[i] }; count = total
            } else {
                for c in 0..<channels { let p = data[c]; for i in 0..<frames { sumSq += p[i] * p[i] } }
                count = frames * channels
            }
        } else if let data = buffer.int16ChannelData {
            let n: Float = 1.0 / 32768.0
            if interleaved {
                let total = frames * channels, p = data[0]
                for i in 0..<total { let s = Float(p[i]) * n; sumSq += s * s }; count = total
            } else {
                for c in 0..<channels { let p = data[c]; for i in 0..<frames { let s = Float(p[i]) * n; sumSq += s * s } }
                count = frames * channels
            }
        } else if let data = buffer.int32ChannelData {
            let n: Float = 1.0 / Float(Int32.max)
            if interleaved {
                let total = frames * channels, p = data[0]
                for i in 0..<total { let s = Float(p[i]) * n; sumSq += s * s }; count = total
            } else {
                for c in 0..<channels { let p = data[c]; for i in 0..<frames { let s = Float(p[i]) * n; sumSq += s * s } }
                count = frames * channels
            }
        } else {
            return 0
        }
        guard count > 0 else { return 0 }
        return min(1, sqrt(sumSq / Float(count)) * 12)
    }

    private func sourceSummary() -> String {
        switch (micActive, systemActive) {
        case (true, true): return "Recording mic + system audio"
        case (true, false): return "Recording mic only (no system audio)"
        case (false, true): return "Recording system audio only (no mic)"
        case (false, false): return "No audio sources"
        }
    }

    private func fileHasAudio(_ url: URL?) -> Bool {
        guard let url, let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return false }
        return size > 1024 // more than just a header
    }

    /// Convert a ScreenCaptureKit audio `CMSampleBuffer` into an `AVAudioPCMBuffer`.
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else {
            return nil
        }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }
}

// MARK: - Stop-from-anywhere

extension MeetingRecorder {
    /// Canonical "stop from anywhere" path — menu commands, the menu bar extra, notification
    /// actions, and the Record page all funnel through here so stopping always behaves the same:
    /// both tracks go to the transcription queue (MeetingAssembler folds them into one recording)
    /// and any meeting-monitor association is cleared.
    @MainActor
    @discardableResult
    func stopAndEnqueue() async -> (mic: URL?, system: URL?) {
        let urls = await stop()
        let queue = TranscriptionQueueManager.shared
        if let mic = urls.mic {
            _ = queue.addJob(audioFile: mic.path, fileName: mic.lastPathComponent,
                             source: .recording, priority: .high)
        }
        if let sys = urls.system {
            _ = queue.addJob(audioFile: sys.path, fileName: sys.lastPathComponent,
                             source: .recording, priority: .high)
        }
        MeetingMonitor.shared.clearActiveRecording()
        return urls
    }
}

// MARK: - SCStream callbacks

extension MeetingRecorder: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferIsValid(sampleBuffer) else { return }
        // Already on `systemQueue` (the sample-handler queue) — convert + write synchronously.
        guard let pcm = MeetingRecorder.pcmBuffer(from: sampleBuffer) else { return }
        if systemFile == nil, let url = systemFileURL {
            systemFile = try? AVAudioFile(forWriting: url, settings: pcm.format.settings)
        }
        try? systemFile?.write(from: pcm)
        let lvl = MeetingRecorder.rmsLevel(pcm)
        DispatchQueue.main.async { self.systemLevel = lvl }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("System-audio stream stopped: \(error.localizedDescription)")
        setSystemActive(false)
    }
}
