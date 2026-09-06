import AppKit
import AVFoundation
import Combine
import ApplicationServices

@MainActor
final class RealtimeDictationController: ObservableObject {
    static let shared = RealtimeDictationController()

    enum State: Equatable {
        case disabled
        case idle
        case warming
        case listening
        case finalizing
        case failed(String)
    }

    @Published private(set) var state: State = .disabled
    @Published private(set) var liveText = ""

    private let server = VibeVoiceMLXRealtimeServer()
    private let insertion = DictationInsertionService()
    private let overlay = DictationOverlayController()
    private var hotkey: GlobalDictationHotkey?
    private var capture: RealtimeAudioCapture?
    private var pipeline: RealtimeTranscriptionPipeline?
    private var insertionTarget = DictationInsertionTarget(element: nil)
    private var keyHeld = false
    private var startTask: Task<Void, Never>?
    private var safetyStopTask: Task<Void, Never>?
    private var warmReleaseTask: Task<Void, Never>?
    private var gpuHeld = false
    private var releasingModel = false

    var runtimeAvailable: Bool {
        VibeVoiceHelperRunner.resolveCommand() != nil
    }

    func synchronizeEnabledState() {
        setEnabled(FeatureFlags.realtimeDictation)
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "feature.realtimeDictation")
        if enabled {
            installHotkey()
            state = .idle
        } else {
            shutdown()
        }
    }

    func reloadHotkey() {
        hotkey?.stop()
        hotkey = nil
        if FeatureFlags.realtimeDictation {
            installHotkey()
        }
    }

    func suspendHotkeyForCapture() {
        hotkey?.stop()
        hotkey = nil
    }

    func resumeHotkeyAfterCapture() {
        if FeatureFlags.realtimeDictation {
            installHotkey()
        }
    }

    func shutdown() {
        keyHeld = false
        cancelWarmRelease()
        startTask?.cancel()
        startTask = nil
        safetyStopTask?.cancel()
        safetyStopTask = nil
        capture?.stop()
        capture = nil
        pipeline = nil
        hotkey?.stop()
        hotkey = nil
        overlay.hide()
        state = .disabled
        Task { [weak self] in
            await self?.releaseModelAndGPU()
        }
    }

    private func installHotkey() {
        guard hotkey == nil else { return }
        let hotkey = GlobalDictationHotkey(
            binding: DictationHotkeySettings.currentBinding(),
            onPress: { [weak self] in self?.press() },
            onRelease: { [weak self] in self?.release() }
        )
        self.hotkey = hotkey
        hotkey.start()
    }

    private func press() {
        guard FeatureFlags.realtimeDictation, !keyHeld,
              !releasingModel,
              state == .idle || state == .warming else {
            return
        }
        cancelWarmRelease()
        keyHeld = true
        insertionTarget = insertion.captureTarget()
        let shortcut = DictationHotkeySettings.currentBinding().displayName
        overlay.show(
            status: "Starting dictation…",
            text: "Keep \(shortcut) held and speak"
        )
        startTask = Task { [weak self] in
            await self?.beginIfStillHeld()
        }
    }

    private func release() {
        keyHeld = false
        if state == .warming {
            startTask?.cancel()
            startTask = nil
            overlay.hide()
            return
        }
        guard state == .listening else { return }
        Task { [weak self] in await self?.finish() }
    }

    private func beginIfStillHeld() async {
        guard keyHeld else {
            overlay.hide()
            state = .idle
            return
        }
        guard AXIsProcessTrusted() else {
            promptForAccessibility()
            fail(RealtimeDictationError.accessibilityPermissionRequired)
            return
        }

        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphone == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            fail(RealtimeDictationError.microphonePermissionRequired)
            return
        }
        guard VibeVoiceModelManager.shared.isModelDownloaded(
            RealtimeDictationConfiguration.modelQuantization
        ) else {
            fail(RealtimeDictationError.modelNotDownloaded)
            return
        }
        guard runtimeAvailable else {
            fail(RealtimeDictationError.serverNotInstalled)
            return
        }
        guard keyHeld else {
            overlay.hide()
            state = .idle
            return
        }

        state = .warming
        overlay.show(
            status: "Preparing VibeVoice ASR 4-bit",
            text: "Reserving Metal for realtime dictation…"
        )
        do {
            guard await acquireGPU() else {
                throw CancellationError()
            }
            guard keyHeld else {
                await releaseModelAndGPU()
                overlay.hide()
                state = .idle
                return
            }

            liveText = ""
            let pipeline = RealtimeTranscriptionPipeline(
                server: server,
                onText: { [weak self] text in
                    await self?.receive(text: text)
                },
                onError: { [weak self] error in
                    await self?.receive(error: error)
                }
            )
            let capture = RealtimeAudioCapture()
            await pipeline.start()
            try capture.start { samples in
                pipeline.ingest(samples)
            }
            self.pipeline = pipeline
            self.capture = capture
            state = .listening
            overlay.update(
                status: "Listening · loading 4-bit model",
                text: "Speak now · release to insert"
            )
            safetyStopTask?.cancel()
            safetyStopTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(120))
                guard let self, self.state == .listening else { return }
                self.keyHeld = false
                await self.finish()
            }

            // Capture starts before the 5.7 GB model load, so the user can speak immediately.
            // Any first pause-delimited chunk waits on this same readiness task.
            try await server.start { [weak self] status in
                await self?.receive(modelStatus: status)
            }
            if state == .listening {
                overlay.update(status: "Listening · release to insert", text: liveText)
            }
        } catch {
            guard keyHeld else {
                await releaseModelAndGPU()
                overlay.hide()
                state = .idle
                return
            }
            fail(error)
        }
    }

    private func finish() async {
        guard state == .listening, let pipeline else { return }
        safetyStopTask?.cancel()
        safetyStopTask = nil
        state = .finalizing
        capture?.stop()
        capture = nil
        overlay.update(status: "Finishing…", text: liveText)
        var finalState: State = .idle
        do {
            let text = try await pipeline.finish()
            try insertion.insert(text, into: insertionTarget)
            liveText = text
            overlay.update(status: "Inserted", text: text)
        } catch RealtimeDictationError.noText {
            overlay.update(status: "No speech detected", text: "")
        } catch {
            finalState = .failed(error.localizedDescription)
            overlay.show(
                status: "Dictation unavailable",
                text: error.localizedDescription
            )
        }
        self.pipeline = nil
        if finalState == .idle {
            state = .idle
            scheduleWarmRelease()
        } else {
            await releaseModelAndGPU()
            state = finalState
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(
                for: finalState == .idle ? .milliseconds(650) : .seconds(2)
            )
            guard let self, self.state == finalState else { return }
            self.overlay.hide()
            if case .failed = finalState {
                self.state = FeatureFlags.realtimeDictation ? .idle : .disabled
            }
        }
    }

    private func receive(text: String) {
        liveText = text
        overlay.update(status: "Listening · release to insert", text: text)
    }

    private func receive(error: Error) {
        fail(error)
    }

    private func receive(modelStatus: String) {
        guard state == .listening || state == .warming else { return }
        overlay.update(status: modelStatus, text: liveText)
    }

    private func fail(_ error: Error) {
        let message = error.localizedDescription
        keyHeld = false
        cancelWarmRelease()
        startTask?.cancel()
        startTask = nil
        capture?.stop()
        capture = nil
        pipeline = nil
        safetyStopTask?.cancel()
        safetyStopTask = nil
        state = .failed(message)
        overlay.show(status: "Dictation unavailable", text: message)
        Task { @MainActor [weak self] in
            await self?.releaseModelAndGPU()
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.overlay.hide()
            self.state = FeatureFlags.realtimeDictation ? .idle : .disabled
        }
    }

    private func acquireGPU() async -> Bool {
        if gpuHeld { return true }
        guard await GPUResourceManager.shared.acquire(.dictation) else {
            return false
        }
        gpuHeld = true
        return true
    }

    private func releaseModelAndGPU() async {
        cancelWarmRelease()
        guard !releasingModel else { return }
        releasingModel = true
        await server.stop()
        if gpuHeld {
            gpuHeld = false
            GPUResourceManager.shared.release(.dictation)
        }
        releasingModel = false
    }

    private func scheduleWarmRelease() {
        cancelWarmRelease()
        warmReleaseTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    for: .seconds(RealtimeDictationConfiguration.warmRetentionDuration)
                )
            } catch {
                return
            }
            guard let self, self.state == .idle, !self.keyHeld else { return }
            await self.releaseModelAndGPU()
        }
    }

    private func cancelWarmRelease() {
        warmReleaseTask?.cancel()
        warmReleaseTask = nil
    }

    private func promptForAccessibility() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
