import SwiftUI
import AppKit

/// First-run setup: check the Mac's specs, download the right models for its RAM, and (optionally)
/// connect the Voice Memos folder. Reuses the existing model managers + `UnifiedDownloadQueue`, so
/// downloads continue in the background and show in the app-wide banner after the wizard closes.
struct SetupWizardView: View {
    var onFinish: (NavigationItem) -> Void

    enum Step: Int, CaseIterable { case system, permissions, models, voiceMemos, done }

    @Environment(\.scenePhase) private var scenePhase
    @State private var step: Step = .system
    @State private var ramGB = SystemSpecs.physicalMemoryGB
    @State private var startedDownloads = false
    @ObservedObject private var downloads = UnifiedDownloadQueue.shared
    @ObservedObject private var fileAccess = FileAccessManager.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @ObservedObject private var vibeVoiceModels = VibeVoiceModelManager.shared
    @ObservedObject private var vibeVoiceRuntime = VibeVoiceRuntimeInstaller.shared
    @ObservedObject private var embeddingModels = EmbeddingModelManager.shared
    @StateObject private var gemmaModels = GemmaModelManager()
    @State private var voiceMemosConnected = false
    @State private var downloadError: String?

    private var tier: SystemTier { SystemSpecs.tier(ramGB: ramGB) }
    private var plan: SetupModelPlan { SetupRecommender.plan(ramGB: ramGB) }
    private var transcriptionModelInstalled: Bool {
        vibeVoiceRuntime.isInstalled
            && vibeVoiceModels.isModelDownloaded(plan.vibeVoiceQuantization)
    }
    private var gemmaModelInstalled: Bool {
        gemmaModels.isModelDownloaded(plan.gemmaKey)
    }
    private var embeddingModelInstalled: Bool {
        embeddingModels.isModelDownloaded(plan.embeddingId)
    }
    private var allRecommendedModelsInstalled: Bool {
        transcriptionModelInstalled
            && gemmaModelInstalled
            && embeddingModelInstalled
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView { content.padding(24) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 660, height: 580)
        .task { await permissions.refresh() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await permissions.refresh() }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill").font(.system(size: 26)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Set up AlmRecorder").font(.headline)
                Text(stepTitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Circle()
                        .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
        }
        .padding(16)
    }

    private var stepTitle: String {
        switch step {
        case .system: return "Step 1 of 5 · System check"
        case .permissions: return "Step 2 of 5 · Permissions"
        case .models: return "Step 3 of 5 · Models"
        case .voiceMemos: return "Step 4 of 5 · Voice Memos"
        case .done: return "Step 5 of 5 · Done"
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .system: systemStep
        case .permissions: permissionsStep
        case .models: modelsStep
        case .voiceMemos: voiceMemosStep
        case .done: doneStep
        }
    }

    private var footer: some View {
        HStack {
            if step != .system && step != .done {
                Button("Back") { withAnimation { step = Step(rawValue: step.rawValue - 1) ?? .system } }
            }
            Spacer()
            switch step {
            case .system:
                Button("Continue") { advance() }.buttonStyle(.borderedProminent)
            case .permissions:
                if permissions.microphone == .granted {
                    Button("Continue") { advance() }.buttonStyle(.borderedProminent)
                } else {
                    Button("Skip for now") { advance() }
                }
            case .models:
                Button(modelPrimaryActionTitle) {
                    if allRecommendedModelsInstalled || startedDownloads {
                        advance()
                    } else {
                        startDownloads()
                    }
                }
                .buttonStyle(.borderedProminent)
                if !allRecommendedModelsInstalled && !startedDownloads {
                    Button("Skip for now") { advance() }
                }
            case .voiceMemos:
                if voiceMemosConnected {
                    Button("Continue") { advance() }.buttonStyle(.borderedProminent)
                } else {
                    Button("Skip") { advance() }
                }
            case .done:
                Button("Open Library") { onFinish(.library) }
                Button("Start Recording") { onFinish(.record) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
        .padding(16)
    }

    private func advance() {
        withAnimation { step = Step(rawValue: step.rawValue + 1) ?? .done }
    }

    private var modelPrimaryActionTitle: String {
        if allRecommendedModelsInstalled { return "Continue" }
        if startedDownloads { return "Continue" }
        return "Download Models"
    }

    // MARK: - Step 1: system

    private var systemStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome").font(.title.bold())
            Text("AlmRecorder transcribes and searches your recordings entirely on-device. That needs a capable Mac — **16 GB of memory minimum, 24 GB recommended**.")
                .foregroundColor(.secondary)

            VStack(spacing: 0) {
                specRow("memorychip", "Memory", "\(ramGB) GB")
                Divider()
                specRow("cpu", "Processors", "\(SystemSpecs.activeProcessorCount) cores")
                Divider()
                specRow("internaldrive", "Free disk", "\(SystemSpecs.freeDiskGB) GB")
            }
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            tierBanner
        }
    }

    private func specRow(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack {
            Label(label, systemImage: icon)
            Spacer()
            Text(value).fontWeight(.medium).monospacedDigit()
        }
        .padding(12)
    }

    private var tierBanner: some View {
        let (icon, color, text): (String, Color, String) = {
            switch tier {
            case .recommended: return ("checkmark.seal.fill", .green, "Your Mac meets the recommended specs. You'll get the best models.")
            case .minimum: return ("checkmark.circle.fill", .blue, "Your Mac meets the minimum. You'll get a slightly lighter 12B model.")
            case .belowMinimum: return ("exclamationmark.triangle.fill", .orange, "Below the 16 GB minimum. AlmRecorder will use lighter models — transcription and AI features may be slower or lower quality.")
            }
        }()
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundColor(color)
            Text(text).font(.callout).foregroundColor(.secondary)
            Spacer()
        }
        .padding(12)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Step 2: permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Allow recording access").font(.title2.bold())
            Text("The **microphone** records you. **Screen Recording** adds the other people in calls as a separate system-audio track. You can still import and search without either permission.")
                .foregroundColor(.secondary)

            VStack(spacing: 0) {
                permissionRow("mic.fill", "Microphone", "Required when you start a recording", permissions.microphone, required: true) {
                    Task { await permissions.requestMicrophone() }
                }
                Divider()
                permissionRow("rectangle.dashed.badge.record", "System audio", "Recommended for calls and meetings", permissions.screenRecording, required: false) {
                    permissions.requestScreenRecording()
                }
                Divider()
                permissionRow(
                    "keyboard",
                    "Realtime dictation",
                    "Required for the global Fn shortcut and text insertion",
                    permissions.accessibility,
                    required: true
                ) {
                    permissions.requestAccessibility()
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if permissions.screenRecording != .granted {
                Label("macOS may ask you to reopen AlmRecorder after system-audio access is granted. Calendar prompts can be enabled later from Meetings.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func permissionRow(_ icon: String, _ title: String, _ subtitle: String,
                               _ status: PermissionsManager.Status, required: Bool,
                               grant: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.medium))
                    if required {
                        Text("Required").font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15)).clipShape(Capsule())
                    }
                }
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            switch status {
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill").font(.caption).foregroundColor(.green)
            case .denied:
                Button("Open Settings") { openPrivacySettings() }.controlSize(.small)
            case .notDetermined:
                Button("Grant", action: grant).controlSize(.small).buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Step 2: models

    private var modelsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Download your models").font(.title2.bold())
            Text("Picked for your \(ramGB) GB Mac. These power recording transcription, realtime Fn dictation, AI profiles/summaries, and semantic search. You can change them later in Settings.")
                .foregroundColor(.secondary)

            VStack(spacing: 0) {
                modelRow(
                    icon: "waveform.badge.mic",
                    title: "Transcription + realtime Fn dictation",
                    name: "Full VibeVoice ASR \(plan.vibeVoiceQuantization.displayName) · MLX/Metal",
                    size: bytesString(plan.vibeVoiceQuantization.estimatedDownloadBytes),
                    done: transcriptionModelInstalled
                )
                Divider()
                modelRow(icon: "brain", title: "AI (multimodal)", name: gemmaName,
                         size: gbString(gemmaGB),
                         done: gemmaModelInstalled)
                Divider()
                modelRow(icon: "magnifyingglass", title: "Search", name: embeddingName,
                         size: mbString(embeddingMB),
                         done: embeddingModelInstalled)
            }
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack {
                Text(downloadSizeDescription).font(.callout).foregroundColor(.secondary)
                Spacer()
                Text("\(SystemSpecs.freeDiskGB) GB free").font(.caption).foregroundColor(SystemSpecs.freeDiskGB < Int(remainingDownloadGB) + 5 ? .orange : .secondary)
            }

            if startedDownloads {
                Text("Downloading… this continues in the background — feel free to continue.")
                    .font(.caption).foregroundColor(.secondary)
                ModelDownloadProgressView()
                    .frame(maxHeight: 160)
            }

            if let downloadError {
                Label(downloadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func modelRow(icon: String, title: String, name: String, size: String, done: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.medium))
                Text(name).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            if done {
                Label("Installed", systemImage: "checkmark.circle.fill").font(.caption).foregroundColor(.green)
            } else {
                Text(size).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(12)
    }

    // MARK: - Step 3: voice memos

    private var voiceMemosStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect Voice Memos").font(.title2.bold())
            Text("Optionally let AlmRecorder import and transcribe your Apple Voice Memos automatically. It only reads the folder; nothing leaves your Mac.")
                .foregroundColor(.secondary)

            if fileAccess.hasVoiceMemosAccess || voiceMemosConnected {
                Label("Voice Memos connected — new memos will transcribe automatically.", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Button {
                    connectVoiceMemos()
                } label: {
                    Label("Connect Voice Memos Folder…", systemImage: "folder.badge.plus")
                }
                .controlSize(.large)
                Text("You'll pick the Voice Memos folder; macOS remembers the permission.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Step 4: done

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 48)).foregroundColor(.green)
            Text("You're all set").font(.title.bold())
            Text(doneModelsMessage)
                .foregroundColor(.secondary)
            Text("Start a recording now, or open your Library to import and find existing audio. Everything stays on your Mac.")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private func startDownloads() {
        let vibeVoiceQuantization = plan.vibeVoiceQuantization
        downloadError = nil
        Task {
            do {
                if !vibeVoiceRuntime.isInstalled {
                    try await vibeVoiceRuntime.install()
                }
                if !vibeVoiceModels.isModelDownloaded(vibeVoiceQuantization) {
                    try await vibeVoiceModels.downloadModel(vibeVoiceQuantization)
                }
            } catch {
                await MainActor.run {
                    downloadError = "Transcription model download failed: \(error.localizedDescription)"
                }
            }
        }
        if !gemmaModels.isModelDownloaded(plan.gemmaKey) {
            Task {
                do {
                    try await gemmaModels.downloadModel(plan.gemmaKey)
                } catch {
                    await MainActor.run {
                        downloadError = "AI model download failed: \(error.localizedDescription)"
                    }
                }
            }
        }
        if !embeddingModels.isModelDownloaded(plan.embeddingId) {
            Task { await embeddingModels.ensureDefaultModel() }
        }
        // Make the recommended models the active selections.
        let s = GlobalModelSettings.shared
        s.selectedVibeVoiceQuantization = vibeVoiceQuantization
        s.vibeVoiceSpeakerMode = TranscriptionProductionDefaults.vibeVoiceSpeakerMode
        s.transcriptionBackend = TranscriptionProductionDefaults.backend
        // Gemma is installed for text-only summaries/consensus, never for audio transcription.
        s.selectedLLMEngine = .voxtral
        s.selectedTextLLMModel = plan.gemmaKey
        s.selectedEmbeddingModel = plan.embeddingId

        startedDownloads = true
    }

    private func connectVoiceMemos() {
        FileAccessManager.shared.requestVoiceMemosAccess { url in
            guard url != nil else { return }
            VoiceMemosMonitorService.shared.settings.isEnabled = true
            VoiceMemosMonitorService.shared.startMonitoring()
            voiceMemosConnected = true
        }
    }

    // MARK: - Size helpers

    private var gemmaName: String { GemmaConfiguration.models[plan.gemmaKey]?.name ?? plan.gemmaKey }
    private var gemmaGB: Double { GemmaConfiguration.models[plan.gemmaKey]?.sizeGB ?? 0 }
    private var embeddingModel: EmbeddingModelConfig? {
        embeddingModels.availableModels.first { $0.id == plan.embeddingId }
    }
    private var embeddingName: String { embeddingModel?.name ?? "Qwen3 Embedding 0.6B" }
    private var embeddingMB: Int { embeddingModel?.sizeInMB ?? 640 }
    private var remainingDownloadGB: Double {
        (transcriptionModelInstalled ? 0 : Double(plan.vibeVoiceQuantization.estimatedDownloadBytes) / 1_000_000_000.0)
            + (gemmaModelInstalled ? 0 : gemmaGB)
            + (embeddingModelInstalled ? 0 : Double(embeddingMB) / 1000.0)
    }
    private var downloadSizeDescription: String {
        allRecommendedModelsInstalled
            ? "All recommended models are installed"
            : "Remaining download ≈ \(gbString(remainingDownloadGB))"
    }
    private var doneModelsMessage: String {
        if allRecommendedModelsInstalled {
            return "Your recording transcription, realtime dictation, AI, and search models are installed."
        }
        if startedDownloads {
            return "Model downloads have started and will continue in the background. Progress stays visible in the app."
        }
        return "You skipped model downloads. Recording still works, and the Library will guide you to Models before transcription or semantic search is needed."
    }

    private func mbString(_ mb: Int) -> String {
        mb >= 1000 ? String(format: "%.1f GB", Double(mb) / 1000.0) : "\(mb) MB"
    }
    private func bytesString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    private func gbString(_ gb: Double) -> String { String(format: "%.1f GB", gb) }
}
