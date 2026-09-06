import SwiftUI
import AVFoundation

/// The Record tab — full recording page (old design language) driven by the dual-channel
/// `MeetingRecorder`: rich status card with live VU meter, big animated record button, waveform,
/// the Transcription Settings menu, and a right-hand panel that explains the flow / shows status.
/// On stop, both tracks (mic = "Me", system = "Them") are queued for independent transcription.
struct MeetingRecorderView: View {
    @ObservedObject private var recorder = MeetingRecorder.shared
    @ObservedObject private var globalSettings = GlobalTranscriptionSettings.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @State private var showSettings = false
    @State private var resultNote: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            recordingPanel
                .frame(minWidth: 360, idealWidth: 440, maxWidth: 500)
                .padding(28)

            Divider()

            infoPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: 820,
            idealWidth: 1040,
            maxWidth: .infinity,
            minHeight: 620,
            idealHeight: 760,
            maxHeight: .infinity
        )
    }

    // MARK: - Left: recording controls

    private var recordingPanel: some View {
        VStack(spacing: 24) {
            statusCard
            sourceRow
            recordButton

            if recorder.isRecording {
                dualWaveforms
            } else {
                settingsSection
            }

            Spacer()

            if let resultNote {
                Label(resultNote, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundColor(.green)
            }
        }
    }

    private var statusCard: some View {
        VStack(spacing: 14) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)

                Text(statusTitle)
                    .font(.headline).fontDesign(.rounded)

                Spacer()

                if recorder.isRecording {
                    Text(timeString(recorder.duration))
                        .font(.system(.title3, design: .monospaced)).fontWeight(.medium)
                }
            }

            if recorder.isRecording {
                VUMeterView(level: recorder.micLevel).frame(height: 6)
            } else if let statusDetail {
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .cardSurface(cornerRadius: 16)
        .shadow(color: .black.opacity(0.1), radius: 10)
    }

    private var sourceRow: some View {
        HStack(spacing: 12) {
            sourceCard(title: "Microphone", icon: "mic.fill", state: micState)
            sourceCard(title: "System audio", icon: "speaker.wave.2.fill", state: systemState)
        }
    }

    /// Two live waveforms while recording — one for the mic (You) and one for system audio (Them) —
    /// each reflecting the real RMS level so you can see both tracks are capturing.
    private var dualWaveforms: some View {
        VStack(spacing: 12) {
            waveformRow(title: "Microphone · You", icon: "mic.fill",
                        level: recorder.micLevel, color: .blue, active: recorder.micActive)
            waveformRow(title: "System audio · Them", icon: "speaker.wave.2.fill",
                        level: recorder.systemLevel, color: .purple, active: recorder.systemActive)
        }
        .transition(.opacity)
    }

    private func waveformRow(title: String, icon: String, level: Float, color: Color, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption).foregroundColor(active ? color : .secondary)
                Text(title).font(.caption).fontWeight(.medium)
                    .foregroundColor(active ? .primary : .secondary)
                Spacer()
                if !active {
                    Text("not capturing").font(.caption2).foregroundColor(.secondary)
                }
            }
            LiveWaveformView(level: active ? level : 0, color: color)
                .frame(height: 40)
                .padding(.horizontal, 8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var recordButton: some View {
        VStack(spacing: 10) {
            if #available(macOS 26, *) {
                Button(action: toggle) {
                    Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 44))
                        .frame(width: 120, height: 120)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .clipShape(Circle())
                .tint(recorder.isRecording ? .red : .accentColor)
                .controlSize(.large)
                .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")
            } else {
                Button(action: toggle) {
                    ZStack {
                        Circle()
                            .fill(recorder.isRecording ? Color.red : Color.accentColor)
                            .frame(width: 120, height: 120)
                            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                        Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 44)).foregroundColor(.white)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")
            }

            Text(recorder.isRecording ? "Stop recording" : "Start recording")
                .font(.headline)
                .foregroundStyle(recorder.isRecording ? .red : .primary)
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { withAnimation { showSettings.toggle() } }) {
                HStack {
                    Label(showSettings ? "Hide Settings" : "Transcription Settings",
                          systemImage: showSettings ? "chevron.up.circle" : "gearshape")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    if globalSettings.useCustomSettings {
                        Text(globalSettings.selectedPreset.rawValue)
                            .font(.caption2)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Color.blue.opacity(0.2)).cornerRadius(4)
                    }
                }
            }
            .buttonStyle(.plain)

            if showSettings {
                TranscriptionRunSettingsView()
                    .padding()
                    .cardSurface(cornerRadius: 12)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Right: info / status

    @ViewBuilder private var infoPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "person.2.wave.2.fill").foregroundStyle(.purple)
                Text("Record Meeting").font(.title2).bold().fontDesign(.rounded)
                Spacer()
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if recorder.isRecording {
                        recordingInfo
                    } else {
                        idleInfo
                    }
                }
                .padding(24)
                .frame(maxWidth: 560, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var recordingInfo: some View {
        VStack(alignment: .leading, spacing: 16) {
            infoRow(icon: "waveform", color: .red, title: "Recording in progress",
                    detail: recorder.statusMessage.isEmpty ? "Capturing audio…" : recorder.statusMessage)
            infoRow(icon: "mic.fill", color: recorder.micActive ? .green : .secondary,
                    title: "Microphone (You)", detail: recorder.micActive ? "Live" : "Not capturing")
            infoRow(icon: "speaker.wave.2.fill", color: recorder.systemActive ? .green : .secondary,
                    title: "System audio (Them)", detail: recorder.systemActive ? "Live — captured digitally" : "Not capturing")
            Text("Press stop when the meeting ends — each track is transcribed separately and lands in your Library.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var idleInfo: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your mic and the computer's audio are captured as two separate tracks and transcribed independently — a clean \u{201C}Me\u{201D} vs \u{201C}Them\u{201D} split, instead of guessing from one muddy mix.")
                .font(.callout).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            infoRow(icon: "mic.fill", color: .blue, title: "Microphone → \u{201C}Me\u{201D}",
                    detail: "Your voice. Use headphones to keep the call out of this track.")
            infoRow(icon: "speaker.wave.2.fill", color: .purple, title: "System audio → \u{201C}Them\u{201D}",
                    detail: "Remote participants, captured digitally (no echo).")
            infoRow(icon: "tray.full.fill", color: .mint, title: "Then transcribed",
                    detail: "Both tracks queue automatically and appear in your Library.")

            if permissions.screenRecording == .denied {
                Divider().padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 8) {
                    Label("System audio needs Screen Recording permission.", systemImage: "lock.shield")
                        .font(.caption).foregroundColor(.orange)
                    Button(action: openScreenRecordingSettings) {
                        Label("Open Screen Recording settings…", systemImage: "lock.open")
                    }
                    .buttonStyle(.bordered)
                    Text("Grant it, then relaunch once. (Mic-only recording still works without it.)")
                        .font(.caption2).foregroundColor(.secondary)
                }
            } else if permissions.screenRecording == .notDetermined {
                Divider().padding(.vertical, 4)
                Label("System audio access is checked only when recording starts.",
                      systemImage: "hand.raised")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func infoRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(color).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Source badges

    private enum SourceState {
        case ready, checkedOnStart, recording, needsPermission, off
        var text: String {
            switch self {
            case .ready: return "Ready"
            case .checkedOnStart: return "Checked on start"
            case .recording: return "Recording"
            case .needsPermission: return "Needs permission"
            case .off: return "Off"
            }
        }
        var color: Color {
            switch self {
            case .ready, .checkedOnStart: return .secondary
            case .recording: return .green
            case .needsPermission: return .orange
            case .off: return .secondary
            }
        }
    }

    private var micState: SourceState {
        if recorder.isRecording { return recorder.micActive ? .recording : .off }
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .ready : .needsPermission
    }

    private var systemState: SourceState {
        if recorder.isRecording { return recorder.systemActive ? .recording : .off }
        switch permissions.screenRecording {
        case .granted: return .ready
        case .denied: return .needsPermission
        case .notDetermined: return .checkedOnStart
        }
    }

    private var hasMicrophoneAccess: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private var statusTitle: String {
        if recorder.isRecording { return "Recording" }
        if !hasMicrophoneAccess { return "Microphone access needed" }
        if permissions.screenRecording == .denied { return "Ready · microphone only" }
        return "Ready to record"
    }

    private var statusDetail: String? {
        if !hasMicrophoneAccess {
            return "Start recording to grant microphone access."
        }
        if permissions.screenRecording == .denied {
            return "Enable system audio to capture remote participants as a separate track."
        }
        if permissions.screenRecording == .notDetermined {
            return "System audio access will be checked when recording starts."
        }
        return "Microphone and system audio are available."
    }

    private var statusColor: Color {
        if recorder.isRecording { return .red }
        if !hasMicrophoneAccess || permissions.screenRecording == .denied { return .orange }
        return .green
    }

    private func sourceCard(title: String, icon: String, state: SourceState) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(state == .recording ? Color.green.opacity(0.15) : Color.secondary.opacity(0.1))
                    .frame(width: 38, height: 38)
                Image(systemName: icon).foregroundColor(state == .recording ? .green : .secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).fontWeight(.medium)
                Text(state.text).font(.caption2).foregroundColor(state.color)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Actions

    private func toggle() {
        if recorder.isRecording {
            Task {
                let urls = await recorder.stopAndEnqueue()
                await MainActor.run {
                    let n = (urls.mic != nil ? 1 : 0) + (urls.system != nil ? 1 : 0)
                    resultNote = n > 0 ? "Queued \(n) track\(n == 1 ? "" : "s") — see Queue / Library"
                                       : "Nothing was recorded"
                }
            }
        } else {
            resultNote = nil
            Task { await recorder.start() }
        }
    }

    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
