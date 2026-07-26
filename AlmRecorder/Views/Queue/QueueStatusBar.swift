import SwiftUI

/// Global status bar showing queue processing status
struct QueueStatusBar: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var queueManager = TranscriptionQueueManager.shared
    @ObservedObject var embeddingQueue = EmbeddingQueueManager.shared
    @ObservedObject var insightsQueue = RecordingInsightsQueueManager.shared
    @ObservedObject var notificationManager = NotificationManager.shared
    
    @State private var isHovered = false
    @State private var showingQueuePopover = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Queue status
            if queueManager.isProcessing || !queueManager.pendingJobs.isEmpty {
                queueStatusSection
            }
            
            // Embedding queue status
            if embeddingQueue.isProcessing || embeddingQueue.hasActiveJobs {
                Divider()
                    .frame(height: 20)
                
                embeddingQueueSection
            }

            // Insights queue status
            if insightsQueue.isProcessing || insightsQueue.hasActiveJobs {
                Divider()
                    .frame(height: 20)

                insightsQueueSection
            }

            Spacer()
            
            // Notifications
            notificationBadge
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .glassPanel(in: Rectangle())
    }
    
    private var queueStatusSection: some View {
        HStack(spacing: 8) {
            // Processing indicator
            if queueManager.isProcessing {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            
            // Status text
            VStack(alignment: .leading, spacing: 2) {
                if let currentJob = queueManager.currentJob {
                    Text(currentJob.fileName)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    HStack(spacing: 4) {
                        Text(currentJob.progressMessage.isEmpty ? "Processing..." : currentJob.progressMessage)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        if currentJob.detailedProgress > 0 {
                            Text("(\(Int(currentJob.detailedProgress * 100))%)")
                                .font(.caption2)
                                .foregroundColor(.blue)
                                .monospacedDigit()
                        }
                    }
                } else if queueManager.pendingJobs.count > 0 {
                    Text("\(queueManager.pendingJobs.count) job\(queueManager.pendingJobs.count == 1 ? "" : "s") pending")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Progress bars
            if queueManager.isProcessing {
                VStack(spacing: 2) {
                    // Current job progress
                    ProgressView(value: queueManager.currentJob?.detailedProgress ?? 0)
                        .frame(width: 100)
                    
                    // Overall queue progress if multiple jobs
                    if queueManager.queueSize > 1 {
                        ProgressView(value: queueManager.globalProgress)
                            .frame(width: 100)
                            .scaleEffect(0.8)
                            .opacity(0.7)
                    }
                }
            }
            
            // Queue count badge
            if queueManager.queueSize > 0 {
                Text("\(queueManager.queueSize)")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(queueManager.isProcessing ? Color.blue : Color.gray.opacity(0.3))
                    .foregroundColor(queueManager.isProcessing ? .white : .primary)
                    .cornerRadius(8)
            }
            
            // Action buttons
            HStack(spacing: 4) {
                Button(action: { showingQueuePopover.toggle() }) {
                    Image(systemName: "list.bullet")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingQueuePopover) {
                    QueueQuickView()
                        .frame(width: 350, height: 400)
                }
                .help("View queue")
                
                if queueManager.isProcessing {
                    Button(action: pauseProcessing) {
                        Image(systemName: "pause.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Pause processing")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isHovered ? Color.blue.opacity(0.1) : Color.clear)
        .cornerRadius(6)
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            appState.toggleQueuePanel()
        }
    }
    
    private var notificationBadge: some View {
        Button(action: { appState.toggleNotificationPanel() }) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell")
                    .font(.system(size: 14))
                
                if notificationManager.hasUnreadNotifications {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Notifications")
    }
    
    private func pauseProcessing() {
        // Could implement pause functionality
        queueManager.cancelAllPendingJobs()
    }
    
    private var embeddingQueueSection: some View {
        HStack(spacing: 8) {
            // Embedding indicator
            if embeddingQueue.isProcessing {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "brain")
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
            }
            
            // Embedding status
            VStack(alignment: .leading, spacing: 2) {
                if embeddingQueue.isProcessing {
                    Text("Generating embeddings...")
                        .font(.caption)
                    
                    HStack(spacing: 4) {
                        Text("\(embeddingQueue.totalProcessedUtterances)/\(embeddingQueue.totalProcessedUtterances + embeddingQueue.totalPendingUtterances) utterances")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        if embeddingQueue.globalProgress > 0 {
                            Text("(\(Int(embeddingQueue.globalProgress * 100))%)")
                                .font(.caption2)
                                .foregroundColor(.orange)
                                .monospacedDigit()
                        }
                    }
                } else if embeddingQueue.queueSize > 0 {
                    Text("\(embeddingQueue.queueSize) embedding job\(embeddingQueue.queueSize == 1 ? "" : "s") queued")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Progress bar for embeddings
            if embeddingQueue.isProcessing {
                ProgressView(value: embeddingQueue.globalProgress)
                    .frame(width: 80)
                    .tint(.orange)
            }
        }
    }

    private var insightsQueueSection: some View {
        HStack(spacing: 8) {
            if insightsQueue.isProcessing {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundColor(.purple)
            }

            VStack(alignment: .leading, spacing: 2) {
                if insightsQueue.isProcessing, let job = insightsQueue.currentJob {
                    Text("Insights: \(job.recordingTitle)")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if insightsQueue.queueSize > 0 {
                        Text("\(insightsQueue.queueSize) recording\(insightsQueue.queueSize == 1 ? "" : "s") left")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else if insightsQueue.queueSize > 0 {
                    Text("\(insightsQueue.queueSize) insight job\(insightsQueue.queueSize == 1 ? "" : "s") queued")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

/// Quick view of queue shown in popover
struct QueueQuickView: View {
    @ObservedObject var queueManager = TranscriptionQueueManager.shared
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("Transcription Queue", systemImage: "tray.full")
                    .font(.headline)
                
                Spacer()
                
                if queueManager.queueSize > 0 {
                    Text("\(queueManager.queueSize) total")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            
            Divider()
            
            // Jobs list
            ScrollView {
                VStack(spacing: 8) {
                    // Current job
                    if let currentJob = queueManager.currentJob {
                        QueueJobRow(job: currentJob, isCurrent: true)
                    }
                    
                    // Pending jobs
                    ForEach(queueManager.pendingJobs.prefix(10)) { job in
                        QueueJobRow(job: job, isCurrent: false)
                    }
                    
                    if queueManager.pendingJobs.count > 10 {
                        Text("+ \(queueManager.pendingJobs.count - 10) more")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding()
                    }
                    
                    if queueManager.jobs.isEmpty {
                        Text("No jobs in queue")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 40)
                    }
                }
                .padding()
            }
            
            Divider()
            
            // Actions
            HStack {
                Button("Clear Completed") {
                    queueManager.clearCompletedJobs()
                }
                .disabled(queueManager.completedJobs.isEmpty)
                
                Spacer()
                
                Button("View All") {
                    AppState.shared.showQueuePanel = true
                }
            }
            .padding()
        }
    }
}

/// Row showing a job in the queue
struct QueueJobRow: View {
    let job: TranscriptionJob
    let isCurrent: Bool
    
    var body: some View {
        HStack {
            // Status icon
            statusIcon
            
            // Job info
            VStack(alignment: .leading, spacing: 2) {
                Text(job.fileName)
                    .font(.caption)
                    .fontWeight(isCurrent ? .medium : .regular)
                    .lineLimit(1)
                
                HStack(spacing: 4) {
                    if let size = job.formattedFileSize {
                        Text(size)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    if isCurrent && job.detailedProgress > 0 {
                        Text("• \(Int(job.detailedProgress * 100))%")
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }
                }
            }
            
            Spacer()
            
            // Priority badge
            if job.priority != .normal {
                priorityBadge
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isCurrent ? Color.blue.opacity(0.1) : Color.clear)
        .cornerRadius(4)
    }
    
    private var statusIcon: some View {
        Group {
            switch job.status {
            case .processing:
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            case .pending:
                Image(systemName: "clock")
                    .font(.caption)
                    .foregroundColor(.secondary)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
            case .cancelled:
                Image(systemName: "xmark.circle")
                    .font(.caption)
                    .foregroundColor(.gray)
            case .retrying:
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundColor(.orange)
            case .waitingForModel:
                Image(systemName: "arrow.down.circle")
                    .font(.caption)
                    .foregroundColor(.blue)
            case .paused:
                Image(systemName: "pause.circle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            case .interrupted:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.yellow)
            }
        }
        .frame(width: 16, height: 16)
    }
    
    private var priorityBadge: some View {
        Group {
            switch job.priority {
            case .immediate:
                Image(systemName: "bolt.circle.fill")
                    .font(.caption2)
                    .foregroundColor(.orange)
            case .high:
                Image(systemName: "arrow.up.circle.fill")
                    .font(.caption2)
                    .foregroundColor(.red)
            case .low:
                Image(systemName: "arrow.down.circle")
                    .font(.caption2)
                    .foregroundColor(.gray)
            case .normal:
                EmptyView()
            }
        }
    }
}