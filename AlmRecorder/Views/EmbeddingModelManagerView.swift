import SwiftUI

struct EmbeddingModelManagerView: View {
    @StateObject private var modelManager = EmbeddingModelManager.shared
    @StateObject private var embeddingQueue = EmbeddingQueueManager.shared
    @State private var selectedModelForDownload: String?
    @State private var showingDeleteConfirmation = false
    @State private var modelToDelete: String?
    @State private var isDownloading = false
    @State private var downloadError: String?
    @State private var isPerformingMaintenance = false
    @State private var embeddingStats: (total: Int, indexed: Int, missing: Int)?
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
            
            Divider()
            
            // Content
            ScrollView {
                VStack(spacing: 20) {
                    currentModelSection
                    embeddingMaintenanceSection
                    availableModelsSection
                    storageInfoSection
                }
                .padding(20)
            }
        }
        .frame(width: 700, height: 600)
        .alert("Download Error", isPresented: .constant(downloadError != nil)) {
            Button("OK") { downloadError = nil }
        } message: {
            Text(downloadError ?? "")
        }
        .alert("Delete Model", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deleteSelectedModel()
            }
        } message: {
            if let modelId = modelToDelete,
               let model = modelManager.availableModels.first(where: { $0.id == modelId }) {
                Text("Are you sure you want to delete \(model.name)?")
            }
        }
    }
    
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Embedding Models")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Manage models for semantic search")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button("Done") {
                dismiss()
            }
        }
        .padding()
    }
    
    private var currentModelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Current Model", systemImage: "cpu")
                .font(.headline)
            
            if modelManager.currentModel.isEmpty {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text("No model selected. Download a model to enable semantic search.")
                        .foregroundColor(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.yellow.opacity(0.1))
                .cornerRadius(8)
            } else if let model = modelManager.availableModels.first(where: { $0.id == modelManager.currentModel }) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.name)
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(.medium)
                        
                        HStack(spacing: 12) {
                            Label(model.formattedSize, systemImage: "internaldrive")
                            Label(model.formattedRAM, systemImage: "memorychip")
                            Label("\(model.dimensions)D", systemImage: "cube")
                            Label(model.formattedSpeed, systemImage: "speedometer")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        
                        Text(model.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.green)
                }
                .padding()
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            }
        }
    }
    
    private var embeddingMaintenanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Embedding Maintenance", systemImage: "gearshape.2")
                .font(.headline)
            
            VStack(spacing: 12) {
                // Statistics
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Embedding Statistics")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        if let stats = embeddingStats {
                            HStack(spacing: 20) {
                                VStack(alignment: .leading) {
                                    Text("Total")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("\(stats.total)")
                                        .font(.title3)
                                        .fontWeight(.medium)
                                }
                                
                                VStack(alignment: .leading) {
                                    Text("Indexed")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("\(stats.indexed)")
                                        .font(.title3)
                                        .fontWeight(.medium)
                                        .foregroundColor(.green)
                                }
                                
                                VStack(alignment: .leading) {
                                    Text("Missing")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("\(stats.missing)")
                                        .font(.title3)
                                        .fontWeight(.medium)
                                        .foregroundColor(stats.missing > 0 ? .orange : .green)
                                }
                                
                                VStack(alignment: .leading) {
                                    Text("Coverage")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("\(stats.total > 0 ? Int(Double(stats.indexed) / Double(stats.total) * 100) : 0)%")
                                        .font(.title3)
                                        .fontWeight(.medium)
                                }
                            }
                        } else {
                            Text("Loading statistics...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    VStack(spacing: 8) {
                        Button(action: refreshStats) {
                            Label("Refresh", systemImage: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        
                        Button(action: performMaintenance) {
                            Label("Fix Missing", systemImage: "wrench.and.screwdriver")
                                .font(.caption)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isPerformingMaintenance || !modelManager.isModelLoaded || embeddingStats?.missing == 0)
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                
                // Queue Status
                if embeddingQueue.hasActiveJobs || isPerformingMaintenance {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            if embeddingQueue.isProcessing {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Processing embeddings...")
                                    .font(.caption)
                            } else if isPerformingMaintenance {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Checking for missing embeddings...")
                                    .font(.caption)
                            }
                            
                            Spacer()
                            
                            if embeddingQueue.hasActiveJobs {
                                Text("\(embeddingQueue.pendingJobs.count) pending")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        if embeddingQueue.globalProgress > 0 {
                            ProgressView(value: embeddingQueue.globalProgress)
                                .progressViewStyle(.linear)
                        }
                    }
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                }
            }
        }
        .onAppear {
            refreshStats()
        }
    }
    
    private var availableModelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Available Models", systemImage: "square.grid.2x2")
                .font(.headline)
            
            ForEach(modelManager.availableModels, id: \.id) { model in
                modelRow(model)
            }
        }
    }
    
    private func modelRow(_ model: EmbeddingModelConfig) -> some View {
        HStack {
            // Model info
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(model.name)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                    
                    // Quality badge
                    Text(model.quality.rawValue)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(qualityColor(model.quality).opacity(0.2))
                        .foregroundColor(qualityColor(model.quality))
                        .cornerRadius(4)
                }
                
                Text(model.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 16) {
                    Label(model.formattedSize, systemImage: "arrow.down.circle")
                        .font(.caption2)
                    Label("RAM: \(model.formattedRAM)", systemImage: "memorychip")
                        .font(.caption2)
                    Label("\(model.dimensions)D", systemImage: "cube")
                        .font(.caption2)
                    Label(model.formattedSpeed, systemImage: "speedometer")
                        .font(.caption2)
                }
                .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Action buttons
            if modelManager.downloadedModels.contains(model.id) {
                if modelManager.currentModel == model.id {
                    // Currently active
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.green)
                } else {
                    // Downloaded, can activate or delete
                    HStack(spacing: 8) {
                        Button(action: {
                            try? modelManager.selectModel(model.id)
                        }) {
                            Text("Use")
                                .font(.caption)
                        }
                        .buttonStyle(.borderedProminent)
                        
                        Button(action: {
                            modelToDelete = model.id
                            showingDeleteConfirmation = true
                        }) {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else if isDownloading && selectedModelForDownload == model.id {
                // Currently downloading
                VStack(alignment: .trailing, spacing: 4) {
                    ProgressView(value: modelManager.downloadProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 100)
                    
                    Text("\(Int(modelManager.downloadProgress * 100))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                // Not downloaded, can download
                Button(action: {
                    downloadModel(model.id)
                }) {
                    Label("Download", systemImage: "arrow.down.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDownloading)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private var storageInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Storage", systemImage: "internaldrive")
                .font(.headline)
            
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Total Models Size")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(formatBytes(modelManager.getTotalDiskUsage()))
                        .font(.title3)
                        .fontWeight(.medium)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Downloaded Models")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("\(modelManager.downloadedModels.count)")
                        .font(.title3)
                        .fontWeight(.medium)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }
    
    // MARK: - Helper Methods
    
    private func qualityColor(_ quality: EmbeddingModelConfig.ModelQuality) -> Color {
        switch quality {
        case .tiny: return .gray
        case .small: return .blue
        case .medium: return .purple
        case .large: return .orange
        }
    }
    
    private func downloadModel(_ modelId: String) {
        selectedModelForDownload = modelId
        isDownloading = true
        
        Task {
            do {
                try await modelManager.downloadModel(modelId)
                
                await MainActor.run {
                    isDownloading = false
                    selectedModelForDownload = nil
                    
                    // Auto-select if it's the first model
                    if modelManager.downloadedModels.count == 1 {
                        try? modelManager.selectModel(modelId)
                    }
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    selectedModelForDownload = nil
                    downloadError = error.localizedDescription
                }
            }
        }
    }
    
    private func deleteSelectedModel() {
        guard let modelId = modelToDelete else { return }
        
        do {
            try modelManager.deleteModel(modelId)
            modelToDelete = nil
        } catch {
            downloadError = error.localizedDescription
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    private func refreshStats() {
        Task {
            do {
                let utteranceRepo = GRDBUtteranceRepository()
                let total = try utteranceRepo.count()
                let indexed = try utteranceRepo.countWithEmbeddings()
                let missing = total - indexed
                
                await MainActor.run {
                    embeddingStats = (total: total, indexed: indexed, missing: missing)
                }
            } catch {
                print("Failed to load embedding statistics: \(error)")
            }
        }
    }
    
    private func performMaintenance() {
        isPerformingMaintenance = true
        
        Task {
            await embeddingQueue.triggerMaintenanceCheck()
            
            await MainActor.run {
                isPerformingMaintenance = false
                // Refresh stats after maintenance
                refreshStats()
            }
        }
    }
}
