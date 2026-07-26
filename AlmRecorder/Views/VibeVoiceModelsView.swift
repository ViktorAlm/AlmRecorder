import SwiftUI

struct VibeVoiceModelsView: View {
    @StateObject private var manager = VibeVoiceModelManager.shared
    @StateObject private var runtimeInstaller = VibeVoiceRuntimeInstaller.shared
    @ObservedObject private var settings = GlobalModelSettings.shared
    @State private var operationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("VibeVoice-ASR")
                        .font(.headline)
                    Text(
                        "Long-form Who/When/What transcription in 50+ languages, "
                            + "including Swedish."
                    )
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                runtimeControl
            }

            ForEach(VibeVoiceQuantization.allCases) { quantization in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(quantization.displayName)
                            .fontWeight(.medium)
                        Text(ByteCountFormatter.string(
                            fromByteCount: quantization.estimatedDownloadBytes,
                            countStyle: .file
                        ))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    Spacer()
                    if manager.isDownloading,
                       settings.selectedVibeVoiceQuantization == quantization {
                        ProgressView(value: manager.downloadProgress)
                            .frame(width: 120)
                    } else if manager.isModelDownloaded(quantization) {
                        if settings.transcriptionBackend == .vibeVoice,
                           settings.selectedVibeVoiceQuantization == quantization {
                            Label("In use", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else {
                            Button("Use this") {
                                settings.selectedVibeVoiceQuantization = quantization
                                settings.transcriptionBackend = .vibeVoice
                            }
                        }
                        Button {
                            do {
                                try manager.deleteModel(quantization)
                            } catch {
                                operationError = error.localizedDescription
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            settings.transcriptionBackend == .vibeVoice
                                && settings.selectedVibeVoiceQuantization == quantization
                        )
                    } else {
                        Button("Download") {
                            settings.selectedVibeVoiceQuantization = quantization
                            Task {
                                do {
                                    try await manager.downloadModel(quantization)
                                } catch {
                                    operationError = error.localizedDescription
                                }
                            }
                        }
                        .disabled(manager.isDownloading)
                    }
                }
                .padding()
                .cardSurface()
            }

            Picker("Speaker handling", selection: $settings.vibeVoiceSpeakerMode) {
                ForEach(VibeVoiceSpeakerMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Text("AlmRecorder fused is recommended: VibeVoice labels stay local while FluidAudio embeddings feed the Evidence Graph across recordings.")
                .font(.caption)
                .foregroundColor(.secondary)

            if !manager.status.isEmpty {
                Text(manager.status)
                    .font(.caption)
                    .foregroundColor(manager.errorMessage == nil ? .secondary : .red)
            }
        }
        .padding()
        .alert("VibeVoice setup failed", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("OK") { operationError = nil }
        } message: {
            Text(operationError ?? "")
        }
    }

    @ViewBuilder
    private var runtimeControl: some View {
        if runtimeInstaller.isInstalled {
            Label("Runtime ready", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundColor(.green)
        } else if runtimeInstaller.isInstalling {
            VStack(alignment: .trailing) {
                ProgressView()
                Text(runtimeInstaller.status)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        } else {
            Button("Install runtime") {
                Task {
                    do {
                        try await runtimeInstaller.install()
                    } catch {
                        operationError = error.localizedDescription
                    }
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
