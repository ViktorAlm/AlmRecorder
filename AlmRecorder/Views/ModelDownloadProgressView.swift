import SwiftUI

/// View showing model download progress
struct ModelDownloadProgressView: View {
    @ObservedObject private var downloadQueue = UnifiedDownloadQueue.shared
    
    var body: some View {
        VStack(spacing: 0) {
            let activeDownloads = downloadQueue.downloadTasks.filter { 
                $0.state == .downloading || $0.state == .pending 
            }
            if !activeDownloads.isEmpty {
                VStack(spacing: 12) {
                    // Header
                    HStack {
                        Label("Model Downloads", systemImage: "arrow.down.circle.fill")
                            .font(.headline)
                        
                        Spacer()
                        
                        Text("\(activeDownloads.count) active")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.top, 12)
                    
                    Divider()
                    
                    // Active and pending downloads
                    ForEach(activeDownloads) { task in
                        DownloadTaskRow(task: task)
                    }
                }
                .padding(.bottom, 12)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .shadow(radius: 2)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: downloadQueue.isDownloading)
    }
}

struct DownloadTaskRow: View {
    let task: UnifiedDownloadQueue.DownloadTask
    @ObservedObject private var downloadQueue = UnifiedDownloadQueue.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.displayName)
                        .font(.system(.body, weight: .medium))
                    
                    HStack(spacing: 8) {
                        Label(statusText, systemImage: statusIcon)
                            .font(.caption)
                            .foregroundColor(statusColor)
                        
                        Text(task.modelType.capitalized)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
                
                Spacer()
                
                if task.state == .downloading {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(task.progress * 100))%")
                            .font(.caption)
                            .monospacedDigit()
                        
                        // Show ETA if available
                        if let eta = task.estimatedTimeRemaining {
                            Text("ETA: " + formatTime(eta))
                                .font(.caption2)
                                .foregroundColor(.blue)
                        }
                    }
                }
            }
            
            if task.state == .downloading {
                HStack(spacing: 8) {
                    ProgressView(value: task.progress)
                        .progressViewStyle(.linear)
                    
                    // Show bytes downloaded if available
                    if task.totalBytes > 0 {
                        Text("\(formatBytes(task.bytesWritten)) / \(formatBytes(task.totalBytes))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            
            if let error = task.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
    
    private var statusText: String {
        switch task.state {
        case .pending:
            return "Queued"
        case .downloading:
            return "Downloading"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }
    
    private var statusIcon: String {
        switch task.state {
        case .pending:
            return "clock"
        case .downloading:
            return "arrow.down.circle"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .cancelled:
            return "xmark.circle"
        }
    }
    
    private var statusColor: Color {
        switch task.state {
        case .pending:
            return .secondary
        case .downloading:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .orange
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let speedString = formatter.string(fromByteCount: Int64(bytesPerSecond))
        return "\(speedString)/s"
    }
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "\(Int(seconds))s"
        } else if seconds < 3600 {
            let minutes = Int(seconds / 60)
            let secs = Int(seconds.truncatingRemainder(dividingBy: 60))
            return "\(minutes)m \(secs)s"
        } else {
            let hours = Int(seconds / 3600)
            let mins = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
            return "\(hours)h \(mins)m"
        }
    }
}


// MARK: - Inline Progress Banner
struct ModelDownloadBanner: View {
    @ObservedObject private var downloadQueue = UnifiedDownloadQueue.shared
    
    var body: some View {
        if let current = downloadQueue.downloadTasks.first(where: { $0.state == .downloading }) {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.7)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Downloading Model")
                            .font(.caption)
                            .fontWeight(.medium)
                        
                        Text(current.displayName)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    // Download stats
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(current.progress * 100))%")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundColor(.blue)
                        
                        if let eta = current.estimatedTimeRemaining {
                            Text("ETA: " + formatTime(eta))
                                .font(.caption2)
                                .foregroundColor(.blue)
                        }
                    }
                    
                    Button(action: {
                        downloadQueue.cancelDownload(current.id)
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                
                // Progress bar
                if current.progress > 0 {
                    ProgressView(value: current.progress)
                        .progressViewStyle(.linear)
                        .scaleEffect(y: 0.5)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassPanel(in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
    
    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let speedString = formatter.string(fromByteCount: Int64(bytesPerSecond))
        return "\(speedString)/s"
    }
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "\(Int(seconds))s"
        } else if seconds < 3600 {
            let minutes = Int(seconds / 60)
            let secs = Int(seconds.truncatingRemainder(dividingBy: 60))
            return "\(minutes)m \(secs)s"
        } else {
            let hours = Int(seconds / 3600)
            let mins = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
            return "\(hours)h \(mins)m"
        }
    }
}