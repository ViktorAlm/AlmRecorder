import SwiftUI

struct NightlyRetranscriptionSettingsView: View {
    @ObservedObject private var nightly = NightlyRetranscriptionController.shared
    @State private var showRestartConfirmation = false

    var body: some View {
        Section("Nightly Re-transcription") {
            Toggle(
                "Retranscribe the library overnight",
                isOn: Binding(
                    get: { nightly.configuration.enabled },
                    set: { nightly.setEnabled($0) }
                )
            )

            Text(
                "Processes one recording at a time, keeps the old transcript until the new one "
                    + "is ready, and resumes on the next night. The current recording may finish "
                    + "after the window closes; no new recording starts."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text("Start")
                    DatePicker(
                        "",
                        selection: timeBinding(start: true),
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    Text("Stop starting")
                    DatePicker(
                        "",
                        selection: timeBinding(start: false),
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                }
                GridRow {
                    Text("Eligible calls")
                    Text(nightly.eligibleRecordingCount.formatted())
                        .monospacedDigit()
                    Text("Audio")
                    Text(formatDuration(nightly.eligibleAudioSeconds))
                        .monospacedDigit()
                }
                GridRow {
                    Text("Compute remaining")
                    Text(formatDuration(nightly.estimatedRemainingSeconds))
                        .monospacedDigit()
                    Text("Projected nights")
                    Text("~\(nightly.estimatedNightsRemaining)")
                        .monospacedDigit()
                }
            }
            .font(.callout)

            Toggle(
                "Protect confirmed speaker-gold recordings (\(nightly.excludedGoldCount))",
                isOn: Binding(
                    get: { nightly.configuration.excludeSpeakerGold },
                    set: { nightly.setExcludeSpeakerGold($0) }
                )
            )
            .disabled(nightly.manifest?.activeJobID != nil)

            Toggle(
                "Keep this Mac awake while a nightly recording is processing",
                isOn: Binding(
                    get: { nightly.configuration.preventIdleSleepWhileProcessing },
                    set: { nightly.setPreventIdleSleep($0) }
                )
            )

            if let manifest = nightly.manifest {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(nightly.statusText)
                            .font(.callout.weight(.semibold))
                        Spacer()
                        Text(
                            "\(manifest.terminalCount.formatted())/"
                                + manifest.items.count.formatted()
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    ProgressView(value: nightly.progress)
                    HStack(spacing: 14) {
                        Label(
                            "\(manifest.completedCount.formatted()) completed",
                            systemImage: "checkmark.circle"
                        )
                        if manifest.failedCount > 0 {
                            Label(
                                "\(manifest.failedCount.formatted()) failed",
                                systemImage: "exclamationmark.triangle"
                            )
                            .foregroundStyle(.orange)
                        }
                        if let activeTitle = nightly.activeTitle {
                            Label(activeTitle, systemImage: "waveform")
                                .lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Text("Locked plan: \(nightly.settingsSummary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            HStack {
                Button("Refresh estimate") {
                    nightly.refreshLibrarySummary()
                }
                Button("Restart plan with current settings…") {
                    showRestartConfirmation = true
                }
                .disabled(nightly.manifest?.activeJobID != nil)
                Spacer()
                if nightly.missingAudioCount > 0 {
                    Label(
                        "\(nightly.missingAudioCount) missing audio",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Label(
                "AlmRecorder must be running when the window begins. It prevents idle sleep while "
                    + "processing, but cannot wake a sleeping Mac or work with the lid closed.",
                systemImage: "moon.zzz"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { nightly.refreshLibrarySummary() }
        .alert("Restart the nightly plan?", isPresented: $showRestartConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Restart", role: .destructive) {
                nightly.restartPlanWithCurrentSettings()
            }
        } message: {
            Text(
                "This creates a fresh plan with the currently selected transcription and speaker "
                    + "settings. Calls completed by the previous plan become eligible again."
            )
        }
    }

    private func timeBinding(start: Bool) -> Binding<Date> {
        Binding(
            get: {
                let minute = start
                    ? nightly.configuration.window.startMinute
                    : nightly.configuration.window.endMinute
                return Calendar.current.date(
                    bySettingHour: minute / 60,
                    minute: minute % 60,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                if start {
                    nightly.setWindow(startMinute: minute)
                } else {
                    nightly.setWindow(endMinute: minute)
                }
            }
        )
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400
            ? [.day, .hour]
            : seconds >= 3_600
                ? [.hour, .minute]
                : [.minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(0, seconds)) ?? "0 min"
    }
}
