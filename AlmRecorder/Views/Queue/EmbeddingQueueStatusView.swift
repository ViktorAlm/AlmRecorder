import SwiftUI

/// View showing the status of the embedding queue
struct EmbeddingQueueStatusView: View {
    @ObservedObject private var queueManager = EmbeddingQueueManager.shared
    @State private var isExpanded = false
    @State private var showQueueDetails = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with toggle
            HStack {
                Image(systemName: "brain")
                    .foregroundColor(.purple)
                
                Text("Embeddings")
                    .font(.headline)
                
                Spacer()
                
                if queueManager.hasActiveJobs {
                    ProgressIndicator()
                }
                
                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    // Current status
                    if let currentJob = queueManager.currentJob {
                        CurrentJobView(job: currentJob)
                    }
                    
                    // Statistics
                    HStack(spacing: 16) {
                        EmbeddingStatItem(
                            label: "Pending",
                            value: "\(queueManager.pendingJobs.count)",
                            color: .orange
                        )
                        
                        EmbeddingStatItem(
                            label: "Processing",
                            value: "\(queueManager.activeJobs.count)",
                            color: .blue
                        )
                        
                        EmbeddingStatItem(
                            label: "Completed",
                            value: "\(queueManager.completedJobs.count)",
                            color: .green
                        )
                        
                        if !queueManager.failedJobs.isEmpty {
                            EmbeddingStatItem(
                                label: "Failed",
                                value: "\(queueManager.failedJobs.count)",
                                color: .red
                            )
                        }
                    }
                    .padding(.vertical, 4)
                    
                    // Queue control buttons
                    HStack {
                        if queueManager.isProcessing {
                            Button(action: { queueManager.stopProcessing() }) {
                                Label("Pause", systemImage: "pause.fill")
                                    .foregroundColor(.orange)
                            }
                            .buttonStyle(PlainButtonStyle())
                        } else if queueManager.hasActiveJobs {
                            Button(action: { queueManager.startProcessing() }) {
                                Label("Resume", systemImage: "play.fill")
                                    .foregroundColor(.green)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        
                        Spacer()
                        
                        Button(action: { showQueueDetails = true }) {
                            Label("Details", systemImage: "list.bullet")
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .sheet(isPresented: $showQueueDetails) {
            EmbeddingQueueDetailsView()
        }
    }
}

// MARK: - Subviews

struct CurrentJobView: View {
    let job: EmbeddingJob
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(job.recordingTitle)
                .font(.subheadline)
                .lineLimit(1)
            
            HStack {
                ProgressView(value: job.progress)
                    .progressViewStyle(LinearProgressViewStyle())
                
                Text("\(job.progressPercentage)%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Text("\(job.completedUtterances) / \(job.totalUtterances) utterances")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if let timeRemaining = job.formattedTimeRemaining {
                    Spacer()
                    Text(timeRemaining)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(4)
    }
}

struct EmbeddingStatItem: View {
    let label: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded))
                .fontWeight(.semibold)
                .foregroundColor(color)
            
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct ProgressIndicator: View {
    var body: some View {
        // Static dot — "active" is conveyed by the adjacent label/spinner, not a pulsing circle.
        Image(systemName: "circle.fill")
            .font(.system(size: 8))
            .foregroundColor(.green)
    }
}

// MARK: - Details View

struct EmbeddingQueueDetailsView: View {
    @ObservedObject private var queueManager = EmbeddingQueueManager.shared
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Embedding Queue")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button("Done") {
                    dismiss()
                }
            }
            .padding()
            
            Divider()
            
            // Job list
            List {
                if !queueManager.activeJobs.isEmpty {
                    Section("Active") {
                        ForEach(queueManager.activeJobs) { job in
                            EmbeddingJobRow(job: job)
                        }
                    }
                }
                
                if !queueManager.pendingJobs.isEmpty {
                    Section("Pending") {
                        ForEach(queueManager.pendingJobs) { job in
                            EmbeddingJobRow(job: job)
                        }
                    }
                }
                
                if !queueManager.failedJobs.isEmpty {
                    Section("Failed") {
                        ForEach(queueManager.failedJobs) { job in
                            EmbeddingJobRow(job: job)
                        }
                    }
                }
                
                if !queueManager.completedJobs.isEmpty {
                    Section("Completed") {
                        ForEach(queueManager.completedJobs) { job in
                            EmbeddingJobRow(job: job)
                        }
                    }
                }
            }
            
            // Footer controls
            HStack {
                Button("Clear Completed") {
                    queueManager.clearCompletedJobs()
                }
                .disabled(queueManager.completedJobs.isEmpty)
                
                Spacer()
                
                if queueManager.isProcessing {
                    Button("Stop Processing") {
                        queueManager.stopProcessing()
                    }
                } else if queueManager.hasActiveJobs {
                    Button("Start Processing") {
                        queueManager.startProcessing()
                    }
                }
            }
            .padding()
        }
        .frame(width: 600, height: 500)
    }
}

struct EmbeddingJobRow: View {
    let job: EmbeddingJob
    @ObservedObject private var queueManager = EmbeddingQueueManager.shared
    
    var body: some View {
        HStack {
            Image(systemName: job.status.icon)
                .foregroundColor(Color(job.status.color))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(job.recordingTitle)
                    .font(.system(.body))
                
                HStack {
                    Text("\(job.totalUtterances) utterances")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if job.status == .processing {
                        Text("• \(job.progressPercentage)%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if job.status == .failed, let error = job.error {
                        Text("• \(error)")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
            
            Spacer()
            
            if job.status == .failed {
                Button("Retry") {
                    queueManager.retryJob(job.id)
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(.blue)
            } else if job.status == .pending || job.status == .processing {
                Button("Cancel") {
                    queueManager.cancelJob(job.id)
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(.red)
            }
        }
        .padding(.vertical, 4)
    }
}