import SwiftUI

/// Reusable view for transcription settings that can be embedded in various views
struct TranscriptionRunSettingsView: View {
    @ObservedObject private var settings = GlobalTranscriptionSettings.shared
    @ObservedObject private var modelSettings = GlobalModelSettings.shared
    @StateObject private var whisperManager = WhisperModelManager.shared
    @StateObject private var voxtralService = VoxtralCppService()
    @StateObject private var gemmaService = GemmaCppService()
    @StateObject private var embeddingManager = EmbeddingModelManager.shared
    @State private var showAdvanced = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Model Selection Section
            modelSelectionSection
            
            Divider()
            
            // Enable custom settings toggle
            Toggle("Use Custom Settings", isOn: $settings.useCustomSettings)
                .font(.caption)
            
            if settings.useCustomSettings {
                // Preset selector
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preset")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Picker("Preset", selection: $settings.selectedPreset) {
                        ForEach(GlobalTranscriptionSettings.SettingsPreset.allCases, id: \.self) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: settings.selectedPreset) { newValue in
                        if newValue != .custom {
                            settings.applyPreset(newValue)
                        }
                    }
                    
                    Text(settings.selectedPreset.description)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Divider()
                
                // Basic settings
                VStack(alignment: .leading, spacing: 8) {
                    // Temperature
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label("Temperature", systemImage: "thermometer")
                                .font(.caption)
                            Spacer()
                            Text(String(format: "%.2f", settings.temperature))
                                .font(.caption)
                                .monospacedDigit()
                        }
                        Slider(value: $settings.temperature, in: 0...1, step: 0.05)
                            .onChange(of: settings.temperature) { _ in
                                settings.selectedPreset = .custom
                            }
                    }
                    
                    // Top-K
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label("Top-K", systemImage: "number.square")
                                .font(.caption)
                            Spacer()
                            Text("\(settings.topK)")
                                .font(.caption)
                                .monospacedDigit()
                        }
                        Slider(
                            value: Binding(
                                get: { Double(settings.topK) },
                                set: { settings.topK = Int($0) }
                            ),
                            in: 1...100,
                            step: 1
                        )
                        .onChange(of: settings.topK) { _ in
                            settings.selectedPreset = .custom
                        }
                    }
                }
                
                // Advanced settings toggle
                Button(action: { showAdvanced.toggle() }) {
                    HStack {
                        Label(showAdvanced ? "Hide Advanced" : "Show Advanced", 
                              systemImage: showAdvanced ? "chevron.up" : "chevron.down")
                            .font(.caption)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                
                if showAdvanced {
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 8) {
                        // Top-P
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(isOn: $settings.useTopP) {
                                HStack {
                                    Label("Top-P", systemImage: "percent")
                                        .font(.caption)
                                    Spacer()
                                    if settings.useTopP {
                                        Text(String(format: "%.2f", settings.topP ?? 0.9))
                                            .font(.caption)
                                            .monospacedDigit()
                                    }
                                }
                            }
                            
                            if settings.useTopP {
                                Slider(
                                    value: Binding(
                                        get: { settings.topP ?? 0.9 },
                                        set: { settings.topP = $0 }
                                    ),
                                    in: 0...1,
                                    step: 0.05
                                )
                            }
                        }
                        
                        // Seed
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(isOn: $settings.useSeed) {
                                HStack {
                                    Label("Seed", systemImage: "dice")
                                        .font(.caption)
                                    Spacer()
                                    if settings.useSeed {
                                        TextField("", value: Binding(
                                            get: { settings.seed ?? 42 },
                                            set: { settings.seed = $0 }
                                        ), format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                        .font(.caption)
                                    }
                                }
                            }
                        }
                        
                        // Max Tokens
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label("Max Tokens", systemImage: "text.badge.plus")
                                    .font(.caption)
                                Spacer()
                                TextField("", value: $settings.maxTokens, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 80)
                                    .font(.caption)
                            }
                        }
                        
                        // Context Keep
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label("Context Keep", systemImage: "memorychip")
                                    .font(.caption)
                                Spacer()
                                TextField("", value: $settings.contextKeep, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 80)
                                    .font(.caption)
                            }
                        }
                        
                        // GPU Layers
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label("GPU Layers", systemImage: "gpu")
                                    .font(.caption)
                                Spacer()
                                Picker("", selection: $settings.gpuLayers) {
                                    Text("All").tag(-1)
                                    Text("None").tag(0)
                                    Text("Half").tag(16)
                                    Text("Custom").tag(settings.gpuLayers)
                                }
                                .pickerStyle(.menu)
                                .frame(width: 100)
                            }
                            
                            if settings.gpuLayers != -1 && settings.gpuLayers != 0 && settings.gpuLayers != 16 {
                                TextField("Layers", value: $settings.gpuLayers, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)
                            }
                        }
                    }
                }
                
                // Reset button
                HStack {
                    Spacer()
                    Button("Reset to Defaults") {
                        settings.resetToDefaults()
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
            }
        }
        .padding()
    }
    
    // MARK: - Model Selection Section
    
    private var modelSelectionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 1. Transcription Model Selection
            VStack(alignment: .leading, spacing: 8) {
                Label("Transcription Model", systemImage: "waveform.badge.mic")
                    .font(.caption)
                    .fontWeight(.medium)
                
                HStack(spacing: 12) {
                    // Backend selector
                    Picker("", selection: $modelSettings.transcriptionBackend) {
                        Text("Whisper").tag(TranscriptionBackend.whisper)
                        Text("LLM").tag(TranscriptionBackend.llm)
                        Text("VibeVoice").tag(TranscriptionBackend.vibeVoice)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    
                    // Model picker
                    if modelSettings.transcriptionBackend == .whisper {
                        Picker("", selection: Binding(
                            get: { modelSettings.selectedWhisperVariant },
                            set: { if let variant = $0 { modelSettings.selectWhisperVariant(variant) } }
                        )) {
                            if whisperManager.downloadedModels.isEmpty {
                                Text("No models").tag(nil as WhisperModelVariant?)
                            } else {
                                ForEach(Array(whisperManager.downloadedModels.sorted()), id: \.self) { variant in
                                    HStack {
                                        Text(variant.displayName)
                                        Text("(\(formatBytes(variant.estimatedSize)))")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }.tag(variant as WhisperModelVariant?)
                                }
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(whisperManager.downloadedModels.isEmpty)
                    } else if modelSettings.transcriptionBackend == .llm {
                        // LLM engine selector
                        Picker("", selection: $modelSettings.selectedLLMEngine) {
                            Text("Voxtral").tag(LLMEngine.voxtral)
                            Text("Gemma").tag(LLMEngine.gemma)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 90)

                        if modelSettings.selectedLLMEngine == .gemma {
                            Picker("", selection: $modelSettings.selectedGemmaTranscriptionModel) {
                                ForEach(Array(gemmaService.availableModels.keys.sorted()), id: \.self) { key in
                                    if let model = gemmaService.availableModels[key] {
                                        Text(model.name).tag(key)
                                    }
                                }
                            }
                            .pickerStyle(.menu)
                        } else {
                            Picker("", selection: $modelSettings.selectedVoxtralTranscriptionModel) {
                                ForEach(Array(voxtralService.availableModels.keys.sorted()), id: \.self) { key in
                                    if let model = voxtralService.availableModels[key] {
                                        Text(model.name).tag(key)
                                    }
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    } else {
                        Picker("", selection: $modelSettings.selectedVibeVoiceQuantization) {
                            ForEach(VibeVoiceQuantization.allCases) { quantization in
                                Text(quantization.displayName).tag(quantization)
                            }
                        }
                        .pickerStyle(.menu)

                        Picker("", selection: $modelSettings.vibeVoiceSpeakerMode) {
                            ForEach(VibeVoiceSpeakerMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                if modelSettings.transcriptionBackend == .vibeVoice {
                    Text("Fused mode keeps VibeVoice text and timestamps, then applies AlmRecorder’s overlap-aware voice embeddings for global matching.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    TextField("Optional names, terms, and meeting context",
                              text: $modelSettings.vibeVoiceContext)
                        .textFieldStyle(.roundedBorder)
                }
            }
            
            // 2. Summary Model Selection (Voxtral only)
            VStack(alignment: .leading, spacing: 8) {
                Label("Summary Model", systemImage: "doc.text")
                    .font(.caption)
                    .fontWeight(.medium)
                
                HStack {
                    Text("Gemma")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 150, alignment: .leading)

                    Picker("", selection: $modelSettings.selectedTextLLMModel) {
                        ForEach(Array(gemmaService.availableModels.keys.sorted()), id: \.self) { key in
                            if let model = gemmaService.availableModels[key] {
                                Text(model.name).tag(key)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            
            // 3. Embedding Model Selection (Qwen only)
            VStack(alignment: .leading, spacing: 8) {
                Label("Embedding Model", systemImage: "brain")
                    .font(.caption)
                    .fontWeight(.medium)
                
                HStack {
                    Text("Qwen Embeddings")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 150, alignment: .leading)
                    
                    Picker("", selection: $modelSettings.selectedEmbeddingModel) {
                        if embeddingManager.downloadedModels.isEmpty {
                            Text("No models").tag("")
                        } else {
                            ForEach(Array(embeddingManager.downloadedModels.sorted()), id: \.self) { modelKey in
                                Text(modelKey).tag(modelKey)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(embeddingManager.downloadedModels.isEmpty)
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }
}

/// Compact version for embedding in smaller spaces
struct TranscriptionRunSettingsCompactView: View {
    @ObservedObject private var settings = GlobalTranscriptionSettings.shared
    
    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $settings.useCustomSettings)
                .toggleStyle(.switch)
                .scaleEffect(0.8)
            
            if settings.useCustomSettings {
                Picker("", selection: $settings.selectedPreset) {
                    ForEach(GlobalTranscriptionSettings.SettingsPreset.allCases, id: \.self) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)
                
                Text("T:\(String(format: "%.1f", settings.temperature)) K:\(settings.topK)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            } else {
                Text("Default Settings")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}
