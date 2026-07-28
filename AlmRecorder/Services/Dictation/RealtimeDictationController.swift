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

    private let server = VibeASRStreamServer()
    private let insertion = DictationInsertionService()
    private let overlay = DictationOverlayController()
    private var hotkey: GlobalDictationHotkey?
    private var capture: RealtimeAudioCapture?
    private var pipeline: RealtimeTranscriptionPipeline?
    private var insertionTarget = DictationInsertionTarget(element: nil)
    private var keyHeld = false
    private var startTask: Task<Void, Never>?
    private var safetyStopTask: Task<Void, Never>?

    var runtimeAvailable: Bool {
        RealtimeDictationConfiguration.resolveServerExecutable() != nil
    }

    func synchronizeEnabledState() {
        setEnabled(FeatureFlags.realtimeDictation)
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "feature.realtimeDictation")
        if enabled {
            installHotkey()
            state = .idle
            if VibeASRBitNetModelManager.shared.isModelDownloaded, runtimeAvailable {
                warm()
            }
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

    func warm() {
        guard FeatureFlags.realtimeDictation,
              VibeASRBitNetModelManager.shared.isModelDownloaded,
              runtimeAvailable else {
            return
        }
        state = .warming
        Task {
            do {
                try await server.start()
                if state == .warming { state = .idle }
            } catch {
                // Background warming is an optimization, not a user-initiated dictation.
                // Leave the controller usable and surface an error only after an actual press.
                if state == .warming { state = .idle }
            }
        }
    }

    func shutdown() {
        keyHeld = false
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
        Task { await server.stop() }
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
              state == .idle || state == .warming else {
            return
        }
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
        guard VibeASRBitNetModelManager.shared.isModelDownloaded else {
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
        overlay.show(status: "Preparing VibeVoice ASR")
        do {
            try await server.start()
            guard keyHeld else {
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
            overlay.update(status: "Listening · release to insert", text: "")
            safetyStopTask?.cancel()
            safetyStopTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(120))
                guard let self, self.state == .listening else { return }
                self.keyHeld = false
                await self.finish()
            }
        } catch {
            guard keyHeld else {
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
        do {
            let text = try await pipeline.finish()
            try insertion.insert(text, into: insertionTarget)
            liveText = text
            overlay.update(status: "Inserted", text: text)
            state = .idle
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(650))
                if self?.state == .idle { self?.overlay.hide() }
            }
        } catch RealtimeDictationError.noText {
            overlay.update(status: "No speech detected", text: "")
            state = .idle
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(650))
                self?.overlay.hide()
            }
        } catch {
            fail(error)
        }
        self.pipeline = nil
    }

    private func receive(text: String) {
        liveText = text
        overlay.update(status: "Listening · release to insert", text: text)
    }

    private func receive(error: Error) {
        fail(error)
    }

    private func fail(_ error: Error) {
        let message = error.localizedDescription
        keyHeld = false
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
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.overlay.hide()
            self.state = FeatureFlags.realtimeDictation ? .idle : .disabled
        }
    }

    private func promptForAccessibility() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
