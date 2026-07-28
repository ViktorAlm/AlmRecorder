import AppKit
import SwiftUI

struct RealtimeDictationSettingsView: View {
    @AppStorage("feature.realtimeDictation") private var enabled = true
    @AppStorage(DictationHotkeySettings.presetKey)
    private var hotkeyPresetRaw = DictationHotkeyPreset.function.rawValue
    @ObservedObject private var controller = RealtimeDictationController.shared
    @ObservedObject private var models = VibeASRBitNetModelManager.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @State private var showHotkeyRecorder = false
    @State private var presetBeforeRecording = DictationHotkeyPreset.function.rawValue

    var body: some View {
        Form {
            Section("Realtime Dictation") {
                Toggle("Enable experimental realtime dictation", isOn: $enabled)
                    .onChange(of: enabled) { _, value in
                        controller.setEnabled(value)
                        if value {
                            permissions.requestAccessibility()
                            Task { await permissions.requestMicrophone() }
                        }
                    }

                Text("Hold \(DictationHotkeySettings.currentBinding().displayName) while speaking. Live text appears in a floating bar; release to insert it into the app you were using.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shortcut") {
                Picker("Activation shortcut", selection: $hotkeyPresetRaw) {
                    ForEach(DictationHotkeyPreset.allCases) { preset in
                        Text(preset.title).tag(preset.rawValue)
                    }
                }
                .onChange(of: hotkeyPresetRaw) { oldValue, newValue in
                    guard let preset = DictationHotkeyPreset(rawValue: newValue) else {
                        return
                    }
                    DictationHotkeySettings.select(preset)
                    if preset == .custom,
                       DictationHotkeySettings.customBinding() == nil {
                        presetBeforeRecording = oldValue
                        beginHotkeyRecording()
                    } else if !showHotkeyRecorder {
                        controller.reloadHotkey()
                    }
                }

                HStack {
                    Text("Current")
                    Spacer()
                    Text(DictationHotkeySettings.currentBinding().displayName)
                        .foregroundStyle(.secondary)
                }

                Button("Record custom shortcut…") {
                    presetBeforeRecording = hotkeyPresetRaw
                    beginHotkeyRecording()
                }

                Text("Fn is the recommended Willow-style hold shortcut. Custom shortcuts require at least one modifier plus a key; choose a combination unused by other apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Local Runtime") {
                statusRow(
                    title: "VibeASR.cpp runtime",
                    ready: controller.runtimeAvailable,
                    detail: controller.runtimeAvailable
                        ? "Installed"
                        : "Run Scripts/package_vibeasr_bitnet.sh"
                )
                statusRow(
                    title: "VibeVoice ASR BitNet model",
                    ready: models.isModelDownloaded,
                    detail: models.isModelDownloaded ? "Installed · 1.58 GiB" : "Not downloaded"
                )

                if models.isDownloading {
                    ProgressView(value: models.downloadProgress)
                    Text(models.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !models.isModelDownloaded {
                    Button("Download VibeVoice ASR BitNet") {
                        Task {
                            try? await models.downloadModel()
                            controller.warm()
                        }
                    }
                } else {
                    Button("Warm model now") {
                        controller.warm()
                    }
                    .disabled(!controller.runtimeAvailable)
                }

                if let error = models.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Permissions") {
                statusRow(
                    title: "Microphone",
                    ready: permissions.microphone == .granted,
                    detail: permissionText(permissions.microphone)
                )
                statusRow(
                    title: "Accessibility",
                    ready: permissions.accessibility == .granted,
                    detail: permissionText(permissions.accessibility)
                )
                HStack {
                    Button("Request Microphone") {
                        Task { await permissions.requestMicrophone() }
                    }
                    Button("Request Accessibility") {
                        permissions.requestAccessibility()
                    }
                }
            }

            Section("Status") {
                Text(stateText)
                Text("Text insertion requires the direct-distribution, unsandboxed app build. macOS App Sandbox does not permit Accessibility automation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { await permissions.refresh() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            Task {
                await permissions.refresh()
                controller.reloadHotkey()
            }
        }
        .sheet(isPresented: $showHotkeyRecorder) {
            DictationHotkeyRecorderSheet(
                onCapture: { binding in
                    DictationHotkeySettings.saveCustom(binding)
                    hotkeyPresetRaw = DictationHotkeyPreset.custom.rawValue
                    showHotkeyRecorder = false
                },
                onCancel: {
                    if DictationHotkeySettings.customBinding() == nil {
                        hotkeyPresetRaw = presetBeforeRecording
                    }
                    showHotkeyRecorder = false
                }
            )
        }
        .onChange(of: showHotkeyRecorder) { _, isShowing in
            if !isShowing {
                controller.resumeHotkeyAfterCapture()
            }
        }
    }

    private func statusRow(title: String, ready: Bool, detail: String) -> some View {
        HStack {
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ready ? .green : .orange)
            Text(title)
            Spacer()
            Text(detail).foregroundStyle(.secondary)
        }
    }

    private func permissionText(_ status: PermissionsManager.Status) -> String {
        switch status {
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .notDetermined: return "Required"
        }
    }

    private var stateText: String {
        guard enabled else {
            return "Disabled"
        }
        guard permissions.accessibility == .granted else {
            return "Accessibility access is required before the global shortcut can be detected."
        }
        guard permissions.microphone == .granted else {
            return "Microphone access is required before dictation can start."
        }
        guard controller.runtimeAvailable else {
            return "Install the VibeASR.cpp runtime before starting dictation."
        }
        guard models.isModelDownloaded else {
            return "Download the VibeVoice ASR BitNet model before starting dictation."
        }

        switch controller.state {
        case .disabled: return "Disabled"
        case .idle: return "Ready"
        case .warming: return "Loading the model…"
        case .listening: return "Listening…"
        case .finalizing: return "Finishing transcription…"
        case .failed(let message): return message
        }
    }

    private func beginHotkeyRecording() {
        controller.suspendHotkeyForCapture()
        showHotkeyRecorder = true
    }
}
