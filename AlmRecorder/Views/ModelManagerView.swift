import SwiftUI

struct ModelManagerView: View {
    @StateObject private var voxtralService = VoxtralCppService()
    @StateObject private var cleanupManager = ModelCleanupManager.shared
    @State private var selectedModel = VoxtralConfiguration.defaultModel
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var isInstalling = false
    @State private var showingCleanup = false
    @State private var diskUsage: (used: Int64, available: Int64) = (0, 0)
    @State private var selectedTab = "transcription"
    private let focusGemmaText: Bool

    /// `focusGemmaText: true` opens straight to LLM → Gemma (where the text model that powers AI summaries
    /// and profiles lives) instead of the default Whisper tab — so the profile's "Get Gemma…" button lands
    /// in the right place instead of dumping the user on the Whisper models.
    init(focusGemmaText: Bool = false) {
        self.focusGemmaText = focusGemmaText
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            // Transcription Models Tab (Whisper & Voxtral)
            TranscriptionModelsView(openToLLMGemma: focusGemmaText)
                .tabItem {
                    Label("Transcription", systemImage: "waveform.badge.mic")
                }
                .tag("transcription")
            
            // Summary Models Tab (Voxtral only)
            SummaryModelsView()
                .tabItem {
                    Label("Summary", systemImage: "doc.text")
                }
                .tag("summary")
            
            // Embedding Models Tab (Qwen)
            EmbeddingModelManagerView()
                .tabItem {
                    Label("Embeddings", systemImage: "brain")
                }
                .tag("embeddings")
        }
        .frame(width: 700, height: 650)
        .onAppear {
            updateDiskUsage()
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
        .sheet(isPresented: $showingCleanup) {
            ModelCleanupView()
                .onDisappear {
                    updateDiskUsage()
            }
        }
    }
    
    // Keep the old Voxtral content as a separate section we'll move
    private var voxtralModelSection: some View {
        VStack(spacing: 20) {
                headerSection
                
                Divider()
                
                if voxtralService.isModelLoaded {
                    modelLoadedView
                } else if voxtralService.isDownloading {
                    downloadingView
                } else {
                    modelSelectionView
                }
                
                Spacer()
                
                // Storage section
                storageSection
                
                Divider()
                
                statusSection
            }
            .padding()
            .frame(width: 600, height: 500)
    }
    
    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "cpu")
                .font(.largeTitle)
                .foregroundColor(.blue)
            
            Text("Voxtral Model Manager")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Native transcription without Python!")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var modelLoadedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)
            
            Text("Model Ready")
                .font(.title3)
                .fontWeight(.semibold)
            
            Text("Current model: \(voxtralService.currentModel)")
                .foregroundColor(.secondary)
            
            HStack(spacing: 20) {
                Button("Change Model") {
                    voxtralService.isModelLoaded = false
                }
                
                Button("Test Transcription") {
                    testTranscription()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
    
    private var downloadingView: some View {
        VStack(spacing: 16) {
            ProgressView(value: voxtralService.downloadProgress)
                .progressViewStyle(.linear)
                .frame(width: 300)
            
            Text("Downloading Voxtral model...")
                .font(.headline)
            
            Text("\(Int(voxtralService.downloadProgress * 100))%")
                .font(.title2)
                .monospacedDigit()
            
            Text("This may take a few minutes")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var modelSelectionView: some View {
        VStack(spacing: 20) {
            Text("Select Voxtral Model")
                .font(.headline)
            
            VStack(spacing: 12) {
                ForEach(Array(voxtralService.availableModels.keys.sorted()), id: \.self) { key in
                    if let model = voxtralService.availableModels[key] {
                        ModelOptionRow(
                            modelKey: key,
                            model: model,
                            isSelected: selectedModel == key,
                            onSelect: { selectedModel = key }
                        )
                    }
                }
            }
            
            Button(action: downloadSelectedModel) {
                Label("Download Model", systemImage: "arrow.down.circle.fill")
                    .frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
    
    private var statusSection: some View {
        VStack(spacing: 8) {
            if voxtralService.isLlamaInstalled {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("llama.cpp installed")
                        .font(.caption)
                }
            } else {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text("llama.cpp not found")
                        .font(.caption)
                    
                    Button("Install") {
                        installLlamaCpp()
                    }
                    .font(.caption)
                }
            }
            
            Text("Models stored in ~/Library/Application Support/AlmRecorder")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
    
    private func downloadSelectedModel() {
        Task {
            do {
                try await voxtralService.downloadModel(quantization: selectedModel)
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showingError = true
                }
            }
        }
    }
    
    private func installLlamaCpp() {
        isInstalling = true
        Task {
            do {
                try await voxtralService.installLlamaCpp()
                await MainActor.run {
                    isInstalling = false
                }
            } catch {
                await MainActor.run {
                    isInstalling = false
                    errorMessage = "Failed to install llama.cpp. Please install manually:\nbrew install llama.cpp"
                    showingError = true
                }
            }
        }
    }
    
    private var storageSection: some View {
        HStack(spacing: 20) {
            // Disk usage info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "internaldrive")
                        .foregroundColor(diskSpaceColor)
                    Text("Storage")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                
                Text("\(formatBytes(diskUsage.available)) available")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Text("\(formatBytes(cleanupManager.getTotalDiskUsage())) used by models")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Cleanup buttons
            HStack(spacing: 12) {
                Button(action: quickCleanup) {
                    Label("Quick Clean", systemImage: "wind")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .help("Clean temporary files and cache")
                
                Button(action: { showingCleanup = true }) {
                    Label("Manage Storage", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .help("Open full storage management")
            }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
    
    private var diskSpaceColor: Color {
        let availableGB = Double(diskUsage.available) / (1024 * 1024 * 1024)
        if availableGB < 1 {
            return .red
        } else if availableGB < 5 {
            return .orange
        } else {
            return .green
        }
    }
    
    private func updateDiskUsage() {
        let fileManager = FileManager.default
        let modelsDir = VoxtralConfiguration.modelsDirectory
        
        do {
            let attributes = try fileManager.attributesOfFileSystem(forPath: modelsDir.path)
            if let freeSpace = attributes[.systemFreeSize] as? NSNumber {
                diskUsage.available = freeSpace.int64Value
            }
        } catch {
            print("Failed to get disk space: \(error)")
        }
        
        diskUsage.used = cleanupManager.getTotalDiskUsage()
    }
    
    private func quickCleanup() {
        let result = cleanupManager.cleanTemporaryFiles()
        
        if result.hasErrors {
            errorMessage = "Cleanup completed with errors:\n" + result.summary
        } else {
            errorMessage = "Cleanup successful!\n" + result.summary
        }
        showingError = true
        updateDiskUsage()
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    private func testTranscription() {
        // Create a test audio file or use a sample
        Task {
            do {
                // For testing, we could record a short audio or use a bundled sample
                let testAudio = Bundle.main.path(forResource: "sample", ofType: "m4a") ?? ""
                let transcript = try await voxtralService.transcribe(audioFile: testAudio)
                
                await MainActor.run {
                    errorMessage = "Test successful!\n\nTranscript: \(transcript)"
                    showingError = true
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Test failed: \(error.localizedDescription)"
                    showingError = true
                }
            }
        }
    }
}

struct ModelOptionRow: View {
    let modelKey: String
    let model: VoxtralModelConfig
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .blue : .secondary)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name)
                        .fontWeight(.medium)
                    
                    HStack {
                        Text("\(String(format: "%.1f", model.sizeGB)) GB")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("•")
                            .foregroundColor(.secondary)
                        
                        Text(qualityDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
    
    private var qualityDescription: String {
        switch modelKey {
        case "Q4_K_M":
            return "Best balance (Recommended)"
        case "Q5_K_M":
            return "Higher quality"
        default:
            return "Standard quality"
        }
    }
}

// MARK: - Transcription Models View

struct TranscriptionModelsView: View {
    @StateObject private var whisperManager = WhisperModelManager.shared
    @StateObject private var voxtralService = VoxtralCppService()
    @StateObject private var gemmaService = GemmaCppService()
    @StateObject private var vibeVoiceManager = VibeVoiceModelManager.shared
    @StateObject private var modelSettings = GlobalModelSettings.shared
    // Observe the download queue so model rows reflect live download state (was read
    // non-reactively via UnifiedDownloadQueue.shared, so progress/queued state was stale).
    @ObservedObject private var downloadQueue = UnifiedDownloadQueue.shared
    @State private var selectedBackend: TranscriptionBackend
    @State private var showingDownload = false

    // Hierarchical selection state for Whisper models
    @State private var selectedFamily: WhisperModelFamily = .openai
    @State private var selectedSize: WhisperModelSize = .large
    @State private var selectedVersion: WhisperModelVersion? = .v3

    /// When true, open on the LLM backend and select the Gemma engine (see `ModelManagerView.focusGemmaText`).
    private let openToLLMGemma: Bool

    init(openToLLMGemma: Bool = false) {
        self.openToLLMGemma = openToLLMGemma
        _selectedBackend = State(
            initialValue: openToLLMGemma
                ? .llm
                : GlobalModelSettings.shared.transcriptionBackend
        )
    }

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "waveform.badge.mic")
                    .font(.largeTitle)
                    .foregroundColor(.purple)
                
                Text("Transcription Models")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Choose models for speech-to-text transcription")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
            // Backend selector
            Picker("Backend", selection: $selectedBackend) {
                Label("Whisper", systemImage: "waveform.badge.mic").tag(TranscriptionBackend.whisper)
                Label("LLM", systemImage: "cpu").tag(TranscriptionBackend.llm)
                Label("VibeVoice", systemImage: "person.2.wave.2").tag(TranscriptionBackend.vibeVoice)
            }
            .pickerStyle(.segmented)
            .frame(width: 440)
            
            // Model content scrolls — the Whisper section (family + size/version + quantization cards) is
            // routinely taller than the sheet, and was overflowing/clipping the selection bar below.
            ScrollView {
                VStack(spacing: 20) {
                    if selectedBackend == .whisper {
                        whisperModelSection

                        // Show download progress for Whisper models
                        DownloadProgressView()
                    } else if selectedBackend == .llm {
                        // LLM engine sub-picker (Voxtral or Gemma)
                        Picker("Engine", selection: $modelSettings.selectedLLMEngine) {
                            Text("Voxtral").tag(LLMEngine.voxtral)
                            Text("Gemma").tag(LLMEngine.gemma)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 240)

                        if modelSettings.selectedLLMEngine == .gemma {
                            gemmaModelsList
                        } else {
                            voxtralModelsList
                        }
                    } else {
                        VibeVoiceModelsView()
                    }
                }
                .frame(maxWidth: .infinity)
            }

            // Current selection (pinned below the scroll area, always visible)
            HStack {
                Text("Current Selection:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text(currentTranscriptionModel())
                    .font(.caption)
                    .fontWeight(.medium)
                
                Spacer()
            }
            .padding()
            .background(.quaternary)
            .cornerRadius(8)
        }
        .padding()
        .onAppear {
            // Opened via "Get Gemma…": land on the Gemma engine sub-tab (selectedBackend is already .llm).
            if openToLLMGemma { modelSettings.selectedLLMEngine = .gemma }
        }
    }

    private var whisperModelSection: some View {
        VStack(spacing: 20) {
            // Model Selection
            modelSelectionControls
            
            Divider()
            
            // Quantization Options for Selected Model
            quantizationOptionsSection
        }
        .padding()
    }
    
    private var modelSelectionControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Select Model")
                .font(.headline)
            
            // Family Selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Model Family")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Picker("Family", selection: $selectedFamily) {
                    ForEach(WhisperModelFamily.allCases, id: \.self) { family in
                        Text(family.rawValue).tag(family)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .onChange(of: selectedFamily) { newFamily in
                    // Reset version if switching to KBLab
                    if newFamily == .kblab {
                        selectedVersion = nil
                    } else if selectedVersion == nil {
                        selectedVersion = .v3
                    }
                }
            }
            
            HStack(spacing: 20) {
                // Size Selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("Model Size")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Picker("Size", selection: $selectedSize) {
                        ForEach(availableSizes, id: \.self) { size in
                            HStack {
                                Text(size.displayName)
                                Text("(\(size.parameters))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }.tag(size)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(width: 200)
                }
                
                // Version Selection (if applicable)
                if selectedFamily == .openai {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Version")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Picker("Version", selection: $selectedVersion) {
                            Text("v1").tag(nil as WhisperModelVersion?)
                            ForEach(WhisperModelVersion.allCases, id: \.self) { version in
                                Text(version.displayName).tag(version as WhisperModelVersion?)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .frame(width: 150)
                    }
                }
            }
        }
    }
    
    private var quantizationOptionsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Quantization Options")
                    .font(.headline)
                
                Spacer()
                
                Text("\(selectedFamily == .kblab ? "KB" : "") \(selectedSize.displayName) \(selectedVersion?.displayName ?? "")")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            // Show quantization options for the selected model
            VStack(spacing: 12) {
                ForEach(availableQuantizations, id: \.self) { quantization in
                    quantizationRow(quantization: quantization)
                }
            }
            
            if availableQuantizations.isEmpty {
                Text("No quantization options available for this model")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
        }
    }
    
    private func quantizationRow(quantization: WhisperQuantization) -> some View {
        let variant = WhisperModelVariant(
            family: selectedFamily,
            size: selectedSize,
            version: selectedVersion,
            quantization: quantization
        )
        
        return HStack {
            // Quantization info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(quantization.displayName)
                        .fontWeight(.medium)
                    
                    // Quality indicator
                    qualityBadge(for: quantization)
                    
                    if quantization == .q5_0 {
                        Text("RECOMMENDED")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .cornerRadius(4)
                    }

                    Spacer()

                    // Explicit on-disk status — "Select"/"Download" alone didn't make this obvious.
                    if whisperManager.isModelDownloaded(variant) {
                        Label("Downloaded", systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }
                
                HStack(spacing: 12) {
                    Label(ByteCountFormatter.string(fromByteCount: variant.estimatedSize, countStyle: .binary), systemImage: "internaldrive")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(quantization.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Action button
            modelActionButton(for: variant)
        }
        .padding()
        .background(modelSettings.selectedWhisperVariant == variant ? Color.blue.opacity(0.1) : Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    // Helper computed properties
    private var availableSizes: [WhisperModelSize] {
        if selectedFamily == .kblab {
            return [.large, .medium, .small]
        }
        return WhisperModelSize.allCases
    }
    
    private var availableQuantizations: [WhisperQuantization] {
        // Get quantizations that are actually available on HuggingFace for this model
        var quantizations: [WhisperQuantization] = []
        
        // Always check F16 (original quality)
        let f16Variant = WhisperModelVariant(
            family: selectedFamily,
            size: selectedSize,
            version: selectedVersion,
            quantization: .f16
        )
        if f16Variant.isAvailable {
            quantizations.append(.f16)
        }
        
        // Check Q8_0 (high quality quantization)
        let q8Variant = WhisperModelVariant(
            family: selectedFamily,
            size: selectedSize,
            version: selectedVersion,
            quantization: .q8_0
        )
        if q8Variant.isAvailable {
            quantizations.append(.q8_0)
        }
        
        // Check Q5_0 (for medium/large) or Q5_1 (for tiny/base/small)
        if selectedSize == .medium || selectedSize == .large {
            let q5_0Variant = WhisperModelVariant(
                family: selectedFamily,
                size: selectedSize,
                version: selectedVersion,
                quantization: .q5_0
            )
            if q5_0Variant.isAvailable {
                quantizations.append(.q5_0)
            }
        } else {
            let q5_1Variant = WhisperModelVariant(
                family: selectedFamily,
                size: selectedSize,
                version: selectedVersion,
                quantization: .q5_1
            )
            if q5_1Variant.isAvailable {
                quantizations.append(.q5_1)
            }
        }
        
        return quantizations
    }
    
    @ViewBuilder
    private func qualityBadge(for quantization: WhisperQuantization) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { index in
                Rectangle()
                    .fill(index < Int(quantization.qualityScore * 5) ? Color.purple : Color.gray.opacity(0.3))
                    .frame(width: 3, height: 10)
            }
        }
    }
    
    @ViewBuilder
    private func modelActionButton(for variant: WhisperModelVariant) -> some View {
        let modelId = "whisper-\(variant.toIdentifier())"
        let downloadTask = downloadQueue.downloadTasks.first { $0.modelId == modelId }
        let isCurrentlyDownloading = downloadTask?.state == .downloading
        
        if isCurrentlyDownloading, let task = downloadTask {
            // Downloading state
            VStack(spacing: 4) {
                ProgressView(value: task.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 100)
                Text("\(Int(task.progress * 100))%")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Button("Cancel") {
                    UnifiedDownloadQueue.shared.cancelDownload(task.id)
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundColor(.red)
            }
        } else if whisperManager.isModelDownloaded(variant) {
            // Downloaded state
            let isSelected = modelSettings.selectedWhisperVariant == variant
            
            HStack(spacing: 8) {
                if isSelected {
                    Label("In use", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundColor(.blue)
                        .help("This is the model transcription currently uses")
                } else {
                    Button("Use this") {
                        print("[ModelManagerView] Selecting variant: \(variant.displayName)")
                        modelSettings.selectWhisperVariant(variant)
                        modelSettings.transcriptionBackend = .whisper
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Switch transcription to this downloaded model")
                }
                
                // Add delete button
                Button(action: {
                    do {
                        try whisperManager.deleteModel(variant)
                        print("[ModelManagerView] Deleted model: \(variant.displayName)")
                    } catch {
                        print("[ModelManagerView] Failed to delete model: \(error)")
                    }
                }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .disabled(isSelected) // Can't delete the selected model
                .help(isSelected ? "Cannot delete the selected model" : "Delete this model")
            }
        } else {
            // Not downloaded - check if in queue
            let modelId = "whisper-\(variant.toIdentifier())"
            let isInQueue = downloadQueue.isInQueue(modelId)
            
            if isInQueue {
                // Show it's queued/downloading
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Queued")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Button("Download") {
                    print("[ModelManagerView] Enqueuing download for: \(variant.displayName)")
                    whisperManager.downloadModelNonBlocking(variant)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
    
    private var gemmaModelsList: some View {
        VStack(spacing: 12) {
            ForEach(Array(gemmaService.availableModels.keys.sorted()), id: \.self) { key in
                if let model = gemmaService.availableModels[key] {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.name)
                                .fontWeight(.medium)

                            Text("\(String(format: "%.1f", model.sizeGB)) GB + BF16 projector")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        gemmaModelActions(key: key)
                    }
                    .padding()
                    .cardSurface()
                }
            }
        }
        .padding()
    }

    @ViewBuilder
    private func gemmaModelActions(key: String) -> some View {
        if gemmaService.isModelDownloaded(key) {
            if modelSettings.selectedLLMEngine == .gemma && modelSettings.selectedGemmaTranscriptionModel == key {
                Button("Selected") {}
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(true)
            } else {
                Button("Select") {
                    modelSettings.selectedGemmaTranscriptionModel = key
                    modelSettings.selectedLLMEngine = .gemma
                    modelSettings.transcriptionBackend = .llm
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } else if downloadQueue.isInQueue("gemma-\(key)") {
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.7)
                Text("Downloading")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } else {
            Button("Download") {
                Task { try? await gemmaService.downloadModel(quantization: key) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var voxtralModelsList: some View {
        VStack(spacing: 12) {
            ForEach(Array(voxtralService.availableModels.keys.sorted()), id: \.self) { key in
                if let model = voxtralService.availableModels[key] {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.name)
                                .fontWeight(.medium)
                            
                            Text("\(String(format: "%.1f", model.sizeGB)) GB")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        if voxtralService.isModelLoaded && modelSettings.selectedVoxtralTranscriptionModel == key {
                            Button("Selected") {
                                // Already selected
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(true)
                        } else {
                            Button("Select") {
                                modelSettings.selectedVoxtralTranscriptionModel = key
                                modelSettings.selectedLLMEngine = .voxtral
                                modelSettings.transcriptionBackend = .llm
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding()
                    .cardSurface()
                }
            }
        }
        .padding()
    }
    
    private func currentTranscriptionModel() -> String {
        switch modelSettings.transcriptionBackend {
        case .whisper:
            if let variant = modelSettings.selectedWhisperVariant {
                return "Whisper: \(variant.displayName)"
            } else if !modelSettings.selectedWhisperModel.isEmpty {
                return "Whisper: \(modelSettings.selectedWhisperModel)"
            } else {
                return "Whisper: No model selected"
            }
        case .llm:
            switch modelSettings.selectedLLMEngine {
            case .voxtral:
                return "Voxtral: \(modelSettings.selectedVoxtralTranscriptionModel)"
            case .gemma:
                return "Gemma: \(modelSettings.selectedGemmaTranscriptionModel)"
            }
        case .vibeVoice:
            return "VibeVoice: \(modelSettings.selectedVibeVoiceQuantization.displayName)"
        }
    }
}

// MARK: - Summary Models View

struct SummaryModelsView: View {
    @StateObject private var gemmaService = GemmaCppService()
    @StateObject private var modelSettings = GlobalModelSettings.shared
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.largeTitle)
                    .foregroundColor(.green)
                
                Text("Summary Models")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Gemma models for summaries, topics, and tags")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
            // Model list
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(Array(gemmaService.availableModels.keys.sorted()), id: \.self) { key in
                        if let model = gemmaService.availableModels[key] {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.name)
                                        .fontWeight(.medium)
                                    
                                    HStack {
                                        Text("\(String(format: "%.1f", model.sizeGB)) GB")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        
                                        Text("•")
                                            .foregroundColor(.secondary)
                                        
                                        Text(qualityDescription(for: key))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                
                                Spacer()
                                
                                if modelSettings.selectedTextLLMModel == key {
                                    Button("Selected") {
                                        // Already selected
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(true)
                                } else {
                                    Button("Select") {
                                        modelSettings.selectedTextLLMModel = key
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                            .padding()
                            .cardSurface()
                        }
                    }
                }
                .padding()
            }
            
            Spacer()
            
            // Current selection and auto-summary toggle
            VStack(spacing: 12) {
                HStack {
                    Text("Current Selection:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("Gemma: \(modelSettings.selectedTextLLMModel)")
                        .font(.caption)
                        .fontWeight(.medium)
                    
                    Spacer()
                }
                
                Toggle("Auto-generate summaries after transcription", isOn: $modelSettings.autoGenerateSummaries)
                    .font(.caption)

                Toggle("Clean up transcripts after transcription (verify suspicious lines against audio)", isOn: $modelSettings.autoCleanTranscripts)
                    .font(.caption)
            }
            .padding()
            .background(.quaternary)
            .cornerRadius(8)
        }
        .padding()
    }
    
    private func qualityDescription(for key: String) -> String {
        if key.contains("Q4") { return "Fastest" }
        if key.contains("Q5") { return "Balanced" }
        if key.contains("Q8") { return "Higher quality" }
        return "Standard"
    }
}
