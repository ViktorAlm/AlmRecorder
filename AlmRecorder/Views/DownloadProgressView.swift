import SwiftUI

/// View showing download progress for all models
struct DownloadProgressView: View {
    @ObservedObject var downloadQueue = UnifiedDownloadQueue.shared
    @State private var showingQueue = true // Auto-show by default
    
    var body: some View {
        VStack(spacing: 0) {
            // Show if any downloads are pending or active
            if !downloadQueue.downloadTasks.filter({ $0.state == .downloading || $0.state == .pending }).isEmpty {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.blue)
                    
                    Text("\(downloadQueue.activeDownloads) active download\(downloadQueue.activeDownloads == 1 ? "" : "s")")
                        .font(.caption)
                    
                    Spacer()
                    
                    Button(action: { showingQueue.toggle() }) {
                        Text(showingQueue ? "Hide" : "Show")
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.gray.opacity(0.1))
                
                if showingQueue {
                    Divider()
                    downloadList
                }
            }
        }
    }
    
    private var downloadList: some View {
        VStack(spacing: 8) {
            ForEach(downloadQueue.downloadTasks.filter { task in
                task.state == .downloading || task.state == .pending
            }) { task in
                WhisperDownloadTaskRow(task: task)
            }
        }
        .padding(12)
    }
}

struct WhisperDownloadTaskRow: View {
    let task: UnifiedDownloadQueue.DownloadTask
    @ObservedObject var downloadQueue = UnifiedDownloadQueue.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(task.displayName)
                    .font(.system(size: 12, weight: .medium))
                
                Spacer()
                
                statusIndicator
            }
            
            if task.state == .downloading {
                ProgressView(value: task.progress)
                    .progressViewStyle(LinearProgressViewStyle())
                
                HStack {
                    Text(progressText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    if let eta = task.estimatedTimeRemaining {
                        Text(formatTime(eta))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(6)
    }
    
    private var statusIndicator: some View {
        Group {
            switch task.state {
            case .pending:
                Label("Queued", systemImage: "clock")
                    .font(.caption2)
                    .foregroundColor(.orange)
            case .downloading:
                Button(action: {
                    downloadQueue.cancelDownload(task.id)
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                }
            case .failed:
                Button(action: {
                    downloadQueue.retryDownload(task.id)
                }) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
            default:
                EmptyView()
            }
        }
    }
    
    private var progressText: String {
        if task.totalBytes > 0 {
            let downloaded = formatBytes(task.bytesWritten)
            let total = formatBytes(task.totalBytes)
            let percent = Int(task.progress * 100)
            return "\(downloaded) / \(total) (\(percent)%)"
        } else {
            return "Downloading..."
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "\(Int(seconds))s"
        } else if seconds < 3600 {
            return "\(Int(seconds / 60))m"
        } else {
            let hours = Int(seconds / 3600)
            let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
            return "\(hours)h \(minutes)m"
        }
    }
}
