import SwiftUI

struct WhisperModelSelectionView: View {
    @StateObject private var modelManager = WhisperModelManager.shared
    @StateObject private var whisperService = WhisperService.shared
    @State private var selectedVariant: WhisperModelVariant?
    @State private var selectedFamily: WhisperModelFamily = .openai
    @State private var selectedSize: WhisperModelSize = .large
    @State private var selectedVersion: WhisperModelVersion? = .v3
    @State private var selectedQuantization: WhisperQuantization = .q5_0
    @State private var showingDownloadConfirmation = false
    @State private var variantToDownload: WhisperModelVariant?
    
    var body: some View {
        VStack(spacing: 20) {
            headerSection
            
            Divider()
            
            modelSelectionSection
            
            Divider()
            
            quantizationSelectionSection
            
            Spacer()
            
            actionSection
        }
        .padding()
        .frame(width: 750, height: 650)
        .onAppear {
            selectedVariant = modelManager.currentVariant
            if let variant = selectedVariant {
                selectedFamily = variant.family
                selectedSize = variant.size
                selectedVersion = variant.version
                selectedQuantization = variant.quantization
            }
        }
        .alert("Download Model", isPresented: $showingDownloadConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Download") {
                if let variant = variantToDownload {
                    downloadModel(variant)
                }
            }
        } message: {
            if let variant = variantToDownload {
                Text("Download \(variant.displayName)? This will require approximately \(formatBytes(variant.estimatedSize)) of disk space.")
            }
        }
    }
    
    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.badge.mic")
                .font(.largeTitle)
                .foregroundColor(.purple)
            
            Text("Whisper Model Selection")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Choose your transcription model and quality settings")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var modelSelectionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Model Configuration")
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
                .onChange(of: selectedFamily) { _, newFamily in
                    // Reset version if switching families
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
                            ForEach(availableVersions, id: \.self) { version in
                                Text(version?.displayName ?? "v1").tag(version as WhisperModelVersion?)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .frame(width: 150)
                    }
                }
            }
            
            // Model Description
            if let description = currentModelDescription {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(.blue)
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(10)
    }
    
    private var quantizationSelectionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Quality Settings")
                .font(.headline)
            
            VStack(spacing: 12) {
                ForEach(availableQuantizations, id: \.self) { quantization in
                    quantizationRow(quantization)
                }
            }
            
            // Performance Profile Presets
            VStack(alignment: .leading, spacing: 8) {
                Text("Quick Presets")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 8) {
                    presetButton("Accuracy First", icon: "star.fill") {
                        selectedSize = .large
                        selectedVersion = .v3
                        selectedQuantization = .q8_0
                    }
                    
                    presetButton("Balanced", icon: "dial.medium.fill") {
                        selectedSize = .medium
                        selectedVersion = .v3
                        selectedQuantization = .q5_0
                    }
                    
                    presetButton("Speed First", icon: "hare.fill") {
                        selectedSize = .small
                        selectedVersion = nil
                        selectedQuantization = .q5_1
                    }
                    
                    presetButton("Minimal Storage", icon: "archivebox.fill") {
                        selectedSize = .tiny
                        selectedVersion = nil
                        selectedQuantization = .q5_1
                    }
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(10)
    }
    
    private func quantizationRow(_ quantization: WhisperQuantization) -> some View {
        let variant = WhisperModelVariant(
            family: selectedFamily,
            size: selectedSize,
            version: selectedVersion,
            quantization: quantization
        )
        let isSelected = selectedQuantization == quantization
        let isDownloaded = modelManager.isModelDownloaded(variant)
        
        return HStack {
            quantizationInfo(quantization: quantization, variant: variant, isSelected: isSelected)
            
            Spacer()
            
            qualityIndicator(quantization: quantization)
            
            actionButton(variant: variant, isSelected: isSelected, isDownloaded: isDownloaded)
        }
        .padding()
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.2), lineWidth: 1)
        )
        .cornerRadius(8)
        .onTapGesture {
            selectedQuantization = quantization
            if isDownloaded {
                selectVariant(variant)
            }
        }
    }
    
    @ViewBuilder
    private func quantizationInfo(quantization: WhisperQuantization, variant: WhisperModelVariant, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(quantization.displayName)
                    .font(.body)
                    .fontWeight(isSelected ? .semibold : .regular)
                
                if quantization == .q5_0 {
                    Text("RECOMMENDED")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .cornerRadius(4)
                }
            }
            
            HStack(spacing: 12) {
                Label(quantization.description, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Label(formatBytes(variant.estimatedSize), systemImage: "internaldrive")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    @ViewBuilder
    private func qualityIndicator(quantization: WhisperQuantization) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { index in
                Rectangle()
                    .fill(index < Int(quantization.qualityScore * 5) ? Color.purple : Color.gray.opacity(0.3))
                    .frame(width: 4, height: 12)
            }
        }
        .padding(.horizontal, 8)
    }
    
    @ViewBuilder
    private func actionButton(variant: WhisperModelVariant, isSelected: Bool, isDownloaded: Bool) -> some View {
        if isDownloaded {
            if isSelected && selectedVariant == variant {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Button("Select") {
                    selectVariant(variant)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } else {
            Button("Download") {
                variantToDownload = variant
                showingDownloadConfirmation = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
    
    @ViewBuilder
    private func presetButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(title)
                    .font(.caption2)
            }
            .frame(width: 80, height: 60)
        }
        .buttonStyle(.bordered)
    }
    
    private var actionSection: some View {
        VStack(spacing: 12) {
            if modelManager.isDownloading {
                VStack(spacing: 8) {
                    HStack {
                        Text("Downloading \(modelManager.currentModel)")
                            .font(.caption)
                        Spacer()
                        Text("\(Int(modelManager.downloadProgress * 100))%")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    
                    ProgressView(value: modelManager.downloadProgress)
                        .progressViewStyle(.linear)
                    
                    Button("Cancel Download") {
                        modelManager.cancelDownload()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            }
            
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Storage Used")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formatBytes(modelManager.getTotalModelSize()))
                        .fontWeight(.medium)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(modelManager.downloadedModels.count) models")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("downloaded")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)
        }
    }
    
    // MARK: - Helper Properties
    
    private var availableSizes: [WhisperModelSize] {
        if selectedFamily == .kblab {
            return [.large, .medium, .small]
        }
        return WhisperModelSize.allCases
    }
    
    private var availableVersions: [WhisperModelVersion?] {
        var versions: [WhisperModelVersion?] = [nil]
        if selectedFamily == .openai {
            versions.append(contentsOf: WhisperModelVersion.allCases)
        }
        return versions
    }
    
    private var availableQuantizations: [WhisperQuantization] {
        return modelManager.getAvailableQuantizations(for: selectedFamily, size: selectedSize)
            .sorted { $0.qualityScore > $1.qualityScore }
    }
    
    private var currentModelDescription: String? {
        switch selectedFamily {
        case .openai:
            return "OpenAI's Whisper models offer excellent multilingual transcription with support for 99+ languages"
        case .kblab:
            return "KBLab models are optimized specifically for Swedish transcription with superior accuracy for Nordic languages"
        case .distilWhisper:
            return "Distil-Whisper offers faster inference with minimal quality loss, perfect for real-time transcription"
        }
    }
    
    // MARK: - Helper Methods
    
    private func selectVariant(_ variant: WhisperModelVariant) {
        selectedVariant = variant
        modelManager.currentVariant = variant
        modelManager.currentModel = variant.displayName
        selectedQuantization = variant.quantization
    }
    
    private func downloadModel(_ variant: WhisperModelVariant) {
        Task {
            do {
                try await modelManager.downloadModel(variant)
                selectVariant(variant)
            } catch {
                print("Failed to download model: \(error)")
            }
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }
}
