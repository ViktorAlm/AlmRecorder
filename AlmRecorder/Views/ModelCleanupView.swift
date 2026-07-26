import SwiftUI

struct ModelCleanupView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cleanupManager = ModelCleanupManager.shared
    @State private var downloadedModels: [ModelCleanupManager.ModelInfo] = []
    @State private var totalDiskUsage: Int64 = 0
    @State private var showingDeleteConfirmation = false
    @State private var modelToDelete: ModelCleanupManager.ModelInfo?
    @State private var showingDeleteAllConfirmation = false
    @State private var isDeleting = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var orphanedFiles: [URL] = []
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection
            
            Divider()
            
            // Storage info
            storageInfoSection
                .padding()
            
            Divider()
            
            // Models list
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(downloadedModels, id: \.key) { model in
                        ModelRow(
                            model: model,
                            onDelete: {
                                modelToDelete = model
                                showingDeleteConfirmation = true
                            },
                            onVerify: {
                                verifyModel(model)
                            }
                        )
                    }
                    
                    if downloadedModels.isEmpty {
                        emptyStateView
                    }
                    
                    // Orphaned files section
                    if !orphanedFiles.isEmpty {
                        orphanedFilesSection
                    }
                }
                .padding()
            }
            
            Divider()
            
            // Action buttons
            actionButtonsSection
                .padding()
        }
        .frame(width: 650, height: 500)
        .onAppear {
            loadModels()
        }
        .alert("Delete Model", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let model = modelToDelete {
                    deleteModel(model)
                }
            }
        } message: {
            Text("Are you sure you want to delete \(modelToDelete?.name ?? "")? This will free up \(modelToDelete?.formattedSize ?? "").")
        }
        .alert("Delete All Models", isPresented: $showingDeleteAllConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete All", role: .destructive) {
                deleteAllModels()
            }
        } message: {
            Text("Are you sure you want to delete all downloaded models? This will free up \(formatBytes(totalDiskUsage)).")
        }
        .alert("Model Cleanup", isPresented: $showingAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
        }
    }
    
    private var headerSection: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "trash.circle.fill")
                    .font(.largeTitle)
                    .foregroundColor(.orange)
                
                VStack(alignment: .leading) {
                    Text("Model Cleanup")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("Manage downloaded AI models")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                HStack(spacing: 12) {
                    Button(action: loadModels) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    
                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
    }
    
    private var storageInfoSection: some View {
        HStack(spacing: 20) {
            StorageInfoCard(
                title: "Total Usage",
                value: formatBytes(totalDiskUsage),
                icon: "internaldrive",
                color: .blue
            )
            
            StorageInfoCard(
                title: "Models",
                value: "\(downloadedModels.count)",
                icon: "square.stack.3d.up.fill",
                color: .green
            )
            
            StorageInfoCard(
                title: "Cache",
                value: getCacheSize(),
                icon: "memorychip",
                color: .orange
            )
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 60))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text("No Models Downloaded")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text("Downloaded models will appear here")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
    
    private var orphanedFilesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Orphaned Files", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundColor(.orange)
            
            Text("\(orphanedFiles.count) files not matching any model configuration")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Button("Clean Orphaned Files") {
                cleanOrphanedFiles()
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }
    
    private var actionButtonsSection: some View {
        HStack(spacing: 12) {
            Button(action: cleanTemporaryFiles) {
                Label("Clean Temp Files", systemImage: "wind")
            }
            .disabled(isDeleting)
            
            Spacer()
            
            if !downloadedModels.isEmpty {
                Button(action: { showingDeleteAllConfirmation = true }) {
                    Label("Delete All Models", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isDeleting)
            }
        }
    }
    
    // MARK: - Actions
    
    private func loadModels() {
        downloadedModels = cleanupManager.getDownloadedModels()
        totalDiskUsage = cleanupManager.getTotalDiskUsage()
        orphanedFiles = cleanupManager.getOrphanedFiles()
    }
    
    private func deleteModel(_ model: ModelCleanupManager.ModelInfo) {
        isDeleting = true
        
        do {
            try cleanupManager.deleteModel(model.key)
            alertMessage = "Successfully deleted \(model.name)"
            showingAlert = true
            loadModels()
        } catch {
            alertMessage = "Failed to delete model: \(error.localizedDescription)"
            showingAlert = true
        }
        
        isDeleting = false
    }
    
    private func deleteAllModels() {
        isDeleting = true
        
        do {
            try cleanupManager.deleteAllModels()
            alertMessage = "Successfully deleted all models"
            showingAlert = true
            loadModels()
        } catch {
            alertMessage = "Failed to delete models: \(error.localizedDescription)"
            showingAlert = true
        }
        
        isDeleting = false
    }
    
    private func cleanTemporaryFiles() {
        let result = cleanupManager.cleanTemporaryFiles()
        
        if result.hasErrors {
            alertMessage = result.summary + "\n\nErrors:\n" + result.errors.joined(separator: "\n")
        } else {
            alertMessage = "Successfully cleaned temporary files\n" + result.summary
        }
        
        showingAlert = true
        loadModels()
    }
    
    private func cleanOrphanedFiles() {
        do {
            try cleanupManager.cleanOrphanedFiles()
            alertMessage = "Orphaned files cleaned"
            showingAlert = true
            loadModels()
        } catch {
            alertMessage = "Failed to clean orphaned files: \(error.localizedDescription)"
            showingAlert = true
        }
    }
    
    private func verifyModel(_ model: ModelCleanupManager.ModelInfo) {
        let verification = cleanupManager.verifyModel(model.key)
        
        if verification.isValid {
            alertMessage = "\(model.name) is valid and complete"
        } else {
            alertMessage = "\(model.name) verification failed: \(verification.error ?? "Unknown error")"
        }
        showingAlert = true
    }
    
    private func getCacheSize() -> String {
        // Get WAV cache size
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AlmRecorder/WAVCache")
        
        let size = getDirectorySize(cacheDir)
        return formatBytes(size)
    }
    
    private func getDirectorySize(_ url: URL) -> Int64 {
        var size: Int64 = 0
        
        if let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        ) {
            for case let fileURL as URL in enumerator {
                if let resourceValues = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
                   let fileSize = resourceValues.totalFileAllocatedSize {
                    size += Int64(fileSize)
                }
            }
        }
        
        return size
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Supporting Views

struct ModelRow: View {
    let model: ModelCleanupManager.ModelInfo
    let onDelete: () -> Void
    let onVerify: () -> Void
    
    var body: some View {
        HStack {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.title2)
                .foregroundColor(.blue)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name)
                    .font(.headline)
                
                HStack {
                    Text(model.formattedSize)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("•")
                        .foregroundColor(.secondary)
                    
                    Text(model.modelFile)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            
            Spacer()
            
            HStack(spacing: 8) {
                Button(action: onVerify) {
                    Image(systemName: "checkmark.shield")
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)
                .help("Verify model integrity")
                
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .help("Delete this model")
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

struct StorageInfoCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}