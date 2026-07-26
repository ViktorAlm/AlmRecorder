import SwiftUI

/// The four background pipelines a recording passes through, each with its own independent
/// queue/manager. Only `.transcription` has the rich per-job detail pane (chunks/ETA/run
/// settings); the other three are lightweight jobs shown via `BackgroundQueueTabView`.
enum QueueTab: String, CaseIterable {
    case transcription, embeddings, insights, cleanup

    var title: String {
        switch self {
        case .transcription: return "Transcription"
        case .embeddings: return "Embeddings"
        case .insights: return "Insights"
        case .cleanup: return "Cleanup"
        }
    }

    var icon: String {
        switch self {
        case .transcription: return "waveform"
        case .embeddings: return "brain"
        case .insights: return "sparkles"
        case .cleanup: return "text.badge.checkmark"
        }
    }
}

struct QueueView: View {
    @ObservedObject private var queueManager = TranscriptionQueueManager.shared
    @ObservedObject private var downloadQueue = UnifiedDownloadQueue.shared
    @ObservedObject private var unifiedManager = UnifiedTranscriptionManager.shared
    @ObservedObject private var voiceMemosMonitor = VoiceMemosMonitorService.shared
    @ObservedObject private var embeddingQueue = EmbeddingQueueManager.shared
    @ObservedObject private var insightsQueue = RecordingInsightsQueueManager.shared
    @ObservedObject private var cleanupQueue = TranscriptCleanupQueueManager.shared
    @StateObject private var importer = VoiceMemosImporter()
    @ObservedObject private var fileAccess = FileAccessManager.shared
    @State private var selectedJobId: UUID?
    @State private var showingClearConfirmation = false
    @State private var voiceMemosNotice: String?
    @State private var emptyCount: Int = 0
    @State private var selectedTab: QueueTab = .transcription

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            switch selectedTab {
            case .transcription:
                transcriptionSplitView
            case .embeddings:
                embeddingsTab
            case .insights:
                insightsTab
            case .cleanup:
                cleanupTab
            }
        }
        .frame(
            minWidth: 820,
            idealWidth: 1040,
            maxWidth: .infinity,
            minHeight: 620,
            idealHeight: 760,
            maxHeight: .infinity
        )
        .onAppear { emptyCount = queueManager.emptyRecordingCount() }
        .onChange(of: queueManager.completedJobs.count) { _ in
            emptyCount = queueManager.emptyRecordingCount()
        }
    }

    private var transcriptionSplitView: some View {
        let selectedJob = queueManager.jobs.first(where: { $0.id == selectedJobId })
        return HSplitView {
            // Left: queue list. Fills the width when nothing is selected; constrained once a
            // detail pane is shown so the split is balanced (and user-resizable).
            queueListPanel
                .frame(minWidth: 360, idealWidth: 480,
                       maxWidth: selectedJob == nil ? .infinity : 600)

            // Right: job details — only when a job is selected (no empty half-pane).
            if let selectedJob {
                jobDetailPanel(selectedJob)
                    .frame(minWidth: 420, maxWidth: .infinity)
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabButton(.transcription, count: queueManager.queueSize)
            tabButton(.embeddings, count: embeddingQueue.queueSize)
            tabButton(.insights, count: insightsQueue.queueSize)
            tabButton(.cleanup, count: cleanupQueue.queueSize)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func tabButton(_ tab: QueueTab, count: Int) -> some View {
        let isSelected = selectedTab == tab
        return Button(action: { selectedTab = tab }) {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                Text(tab.title)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(isSelected ? Color.white.opacity(0.25) : Color.secondary.opacity(0.2))
                        .cornerRadius(8)
                }
            }
            .font(.subheadline)
            .fontWeight(isSelected ? .semibold : .regular)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .foregroundColor(isSelected ? Color.accentColor : .primary)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func simpleQueueHeader(title: String, icon: String, isProcessing: Bool) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            if isProcessing {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text("Processing")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.green)
                }
            }
        }
        .padding()
    }

    private var embeddingsTab: some View {
        VStack(spacing: 0) {
            simpleQueueHeader(title: "Embedding Queue", icon: "brain", isProcessing: embeddingQueue.isProcessing)
            Divider()
            BackgroundQueueTabView(
                emptyIcon: "brain",
                pending: embeddingQueue.pendingJobs,
                active: embeddingQueue.activeJobs,
                failed: embeddingQueue.failedJobs,
                completed: embeddingQueue.completedJobs,
                subtitle: { job in "\(job.completedUtterances)/\(job.totalUtterances) utterances" },
                onRetry: { job in embeddingQueue.retryJob(job.id) },
                onCancel: { job in embeddingQueue.cancelJob(job.id) },
                onClearCompleted: { embeddingQueue.clearCompletedJobs() }
            )
        }
    }

    private var insightsTab: some View {
        VStack(spacing: 0) {
            simpleQueueHeader(title: "Insights Queue", icon: "sparkles", isProcessing: insightsQueue.isProcessing)
            Divider()
            BackgroundQueueTabView(
                emptyIcon: "sparkles",
                pending: insightsQueue.pendingJobs,
                active: insightsQueue.activeJobs,
                failed: insightsQueue.failedJobs,
                completed: insightsQueue.completedJobs,
                onRetry: { job in insightsQueue.retryJob(job.id) },
                onCancel: { job in insightsQueue.cancelJob(job.id) },
                onClearCompleted: { insightsQueue.clearCompletedJobs() }
            )
        }
    }

    private var cleanupTab: some View {
        VStack(spacing: 0) {
            simpleQueueHeader(title: "Transcript Cleanup Queue", icon: "text.badge.checkmark", isProcessing: cleanupQueue.isProcessing)
            Divider()
            BackgroundQueueTabView(
                emptyIcon: "text.badge.checkmark",
                pending: cleanupQueue.pendingJobs,
                active: cleanupQueue.activeJobs,
                failed: cleanupQueue.failedJobs,
                completed: cleanupQueue.completedJobs,
                subtitle: { job in
                    var parts: [String] = [job.mode.rawValue.capitalized]
                    if let summary = job.outcomeSummary { parts.append(summary) }
                    return parts.joined(separator: " · ")
                },
                onRetry: { job in cleanupQueue.retryJob(job.id) },
                onCancel: { job in cleanupQueue.cancelJob(job.id) },
                onClearCompleted: { cleanupQueue.clearCompletedJobs() }
            )
        }
    }

    private var queueListPanel: some View {
        VStack(spacing: 0) {
            // Header
            queueHeader
            
            Divider()
            
            // Stats bar
            statsBar
            
            Divider()
            
            // Queue sections
            ScrollView {
                if queueManager.jobs.isEmpty {
                    queueEmptyState
                } else {
                    VStack(spacing: 16) {
                    // Note: All transcriptions now go through the queue
                    // No need for separate "Active Transcriptions" section
                    
                    // Currently processing
                    if let currentJob = queueManager.currentJob {
                        queueSection(
                            title: "Currently Processing",
                            icon: "gearshape.fill",
                            color: .blue,
                            jobs: [currentJob]
                        )
                    }
                    
                    // Waiting for model downloads
                    let waitingForModel = queueManager.jobs.filter { $0.status == .waitingForModel }
                    if !waitingForModel.isEmpty {
                        queueSection(
                            title: "Waiting for Model",
                            icon: "arrow.down.circle",
                            color: .orange,
                            jobs: waitingForModel
                        )
                    }
                    
                    // Pending jobs
                    if !queueManager.pendingJobs.isEmpty {
                        queueSection(
                            title: "Pending",
                            icon: "clock",
                            color: .secondary,
                            jobs: queueManager.pendingJobs
                        )
                    }
                    
                    // Failed jobs
                    if !queueManager.failedJobs.isEmpty {
                        queueSection(
                            title: "Failed",
                            icon: "xmark.circle",
                            color: .red,
                            jobs: queueManager.failedJobs
                        )
                    }
                    
                    // Completed jobs (last 10)
                    let recentCompleted = queueManager.completedJobs.suffix(10)
                    if !recentCompleted.isEmpty {
                        queueSection(
                            title: "Recently Completed",
                            icon: "checkmark.circle",
                            color: .green,
                            jobs: Array(recentCompleted),
                            collapsed: true
                        )
                    }
                    }
                    .padding()
                }
            }
            
            Divider()
            
            // Bottom toolbar
            queueToolbar
        }
    }

    private var queueEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 42))
                .foregroundStyle(.green)

            Text("Transcription queue is clear")
                .font(.title3)
                .fontWeight(.semibold)

            Text("New recordings and imported audio appear here automatically. You can keep using AlmRecorder while work runs in the background.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)

            if emptyCount > 0 {
                Button(action: requeueEmpties) {
                    Label("Re-queue \(emptyCount) empty recording\(emptyCount == 1 ? "" : "s")",
                          systemImage: "arrow.counterclockwise.circle")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 340)
        .padding(32)
    }
    
    private var queueHeader: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Transcription Queue", systemImage: "tray.full")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                // Start/Resume when there's pending work but nothing is actually running (idle,
                // paused, OR a stuck "processing" state with no live worker); Pause while running.
                if !queueManager.pendingJobs.isEmpty && queueManager.activeWorkers == 0 {
                    Button(action: { queueManager.startOrResumeProcessing() }) {
                        Label(queueManager.isPaused ? "Resume" : "Start", systemImage: "play.circle.fill")
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.bordered)
                } else if queueManager.activeWorkers > 0 {
                    Button(action: { queueManager.pauseAllProcessing() }) {
                        Label("Pause", systemImage: "pause.circle.fill")
                            .foregroundColor(.orange)
                    }
                    .buttonStyle(.bordered)
                }
                
                if queueManager.isPaused {
                    HStack(spacing: 4) {
                        Image(systemName: "pause.circle.fill")
                            .foregroundColor(.orange)
                        Text("Queue Paused")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.orange)
                    }
                } else if queueManager.isProcessing {
                    HStack(spacing: 8) {
                        // Processing indicator
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                            Text("Processing (\(queueManager.activeWorkers) worker\(queueManager.activeWorkers == 1 ? "" : "s"))")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.green)
                        }
                        
                        // Jobs count
                        if queueManager.pendingJobs.count > 0 {
                            Text("(\(queueManager.completedJobs.count) of \(queueManager.jobs.count) done)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            
            // Enhanced global progress
            if queueManager.isProcessing || queueManager.globalProgress > 0 {
                VStack(spacing: 4) {
                    // Progress bar
                    ProgressView(value: queueManager.globalProgress)
                        .tint(.blue)
                    
                    // Progress details
                    HStack {
                        // Current job info
                        if let currentJob = queueManager.currentJob {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.text")
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                                Text(currentJob.fileName)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundColor(.primary)
                                Text("• \(Int(currentJob.detailedProgress * 100))%")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.blue)
                                    .monospacedDigit()
                            }
                        }
                        
                        Spacer()
                        
                        // Queue stats
                        HStack(spacing: 8) {
                            Text("\(queueManager.pendingJobs.count) pending")
                                .font(.caption)
                                .foregroundColor(.orange)
                            
                            if queueManager.failedJobs.count > 0 {
                                Text("\(queueManager.failedJobs.count) failed")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }
            }
        }
        .padding()
    }
    
    private var statsBar: some View {
        HStack(spacing: 20) {
            StatItem(
                label: "Queue Size",
                value: "\(queueManager.queueSize)",
                color: .blue
            )
            
            StatItem(
                label: "Completed",
                value: "\(queueManager.completedJobs.count)",
                color: .green
            )
            
            StatItem(
                label: "Failed",
                value: "\(queueManager.failedJobs.count)",
                color: .red
            )
            
            Divider()
                .frame(height: 20)
            
            StatItem(
                label: "Workers",
                value: "\(queueManager.activeWorkers)/\(queueManager.maxConcurrentJobs)",
                color: queueManager.activeWorkers > 0 ? .green : .gray
            )
            
            Spacer()
            
            Text("Completion: \(Int(queueManager.completionRate * 100))%")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private func queueSection(
        title: String,
        icon: String,
        color: Color,
        jobs: [TranscriptionJob],
        collapsed: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header
            HStack {
                Label(title, systemImage: icon)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(color)
                
                Spacer()
                
                Text("\(jobs.count)")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.2))
                    .cornerRadius(4)
            }
            
            // Job list
            if !collapsed {
                ForEach(jobs) { job in
                    JobRow(
                        job: job,
                        isSelected: job.id == selectedJobId,
                        onSelect: { selectedJobId = job.id }
                    )
                }
            }
        }
    }
    
    private var queueToolbar: some View {
        HStack {
            Button(action: addVoiceMemosToQueue) {
                Label("Add Voice Memos", systemImage: "mic.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .help("Grant access to your Voice Memos library and queue all recordings for transcription")

            if let notice = voiceMemosNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .transition(.opacity)
            }

            Button(action: { queueManager.cancelAllPendingJobs() }) {
                Label("Cancel All", systemImage: "xmark.circle")
            }
            .disabled(queueManager.pendingJobs.isEmpty)
            
            Button(action: { showingClearConfirmation = true }) {
                Label("Clear Completed", systemImage: "trash")
            }
            .disabled(queueManager.completedJobs.isEmpty)

            Button(action: requeueEmpties) {
                Label(emptyCount > 0 ? "Re-queue Empties (\(emptyCount))" : "Re-queue Empties",
                      systemImage: "arrow.counterclockwise.circle")
            }
            .disabled(emptyCount == 0)
            .help("Re-transcribe recordings that came out empty/failed (e.g. long files)")

            Spacer()
            
            // Model downloads indicator
            if downloadQueue.activeDownloads > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.orange)
                    Text("\(downloadQueue.activeDownloads) downloads")
                        .font(.caption)
                }
            }
        }
        .padding()
        .confirmationDialog(
            "Clear completed jobs?",
            isPresented: $showingClearConfirmation
        ) {
            Button("Clear All Completed", role: .destructive) {
                queueManager.clearCompletedJobs()
            }
        }
    }
    
    private func jobDetailPanel(_ job: TranscriptionJob) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Job header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(job.fileName)
                            .font(.title3)
                            .fontWeight(.semibold)
                        
                        Spacer()
                        
                        JobStatusBadge(status: job.status)
                    }
                    
                    HStack {
                        Label(job.source.rawValue, systemImage: sourceIcon(for: job.source))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        if job.isPromptTest {
                            Text("PROMPT TEST")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.2))
                                .foregroundColor(.purple)
                                .cornerRadius(4)
                        }
                    }
                }
                
                Divider()
                
                // Progress section
                if job.status == .processing || job.status == .waitingForModel {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("Progress", systemImage: job.progressPhase.icon)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Spacer()
                                
                                // Phase badge
                                Text(job.progressPhase.displayName)
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(phaseColor(for: job.progressPhase).opacity(0.2))
                                    .foregroundColor(phaseColor(for: job.progressPhase))
                                    .cornerRadius(4)
                            }
                            
                            // Progress percentage and ETA
                            HStack {
                                // Percentage
                                Text("\(Int(job.detailedProgress * 100))%")
                                    .font(.system(.title2, design: .rounded))
                                    .fontWeight(.bold)
                                    .foregroundColor(.primary)
                                    .monospacedDigit()
                                
                                Spacer()
                                
                                // ETA
                                if let eta = job.calculatedETA, eta > 0 {
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("Time Remaining")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        HStack(spacing: 4) {
                                            Image(systemName: "clock.fill")
                                                .font(.caption)
                                                .foregroundColor(.orange)
                                            Text(formatDetailedETA(eta))
                                                .font(.system(.body, design: .rounded))
                                                .fontWeight(.semibold)
                                                .foregroundColor(.orange)
                                                .monospacedDigit()
                                        }
                                    }
                                }
                            }
                            
                            // Main progress bar with gradient
                            ProgressView(value: job.detailedProgress)
                                .tint(phaseColor(for: job.progressPhase))
                                .padding(.vertical, 4)
                            
                            // Detailed progress message
                            Text(job.detailedProgressMessage)
                                .font(.caption)
                                .foregroundColor(.primary)
                            
                            // Chunk progress if applicable
                            if job.progressPhase == .transcribingChunks && job.totalChunks > 0 {
                                HStack(spacing: 12) {
                                    // Chunk counter
                                    HStack(spacing: 4) {
                                        Image(systemName: "square.stack.3d.up.fill")
                                            .font(.caption2)
                                            .foregroundColor(.blue)
                                        // Show current chunk being processed (completedChunks + 1) unless we're done
                                        let currentChunk = job.currentChunkProgress >= 1.0 ? job.completedChunks : min(job.completedChunks + 1, job.totalChunks)
                                        Text("Chunk \(currentChunk) of \(job.totalChunks)")
                                            .font(.caption2)
                                            .monospacedDigit()
                                    }
                                    
                                    // Processing speed
                                    if !job.chunkProcessingTimes.isEmpty {
                                        let avgTime = job.chunkProcessingTimes.reduce(0, +) / Double(job.chunkProcessingTimes.count)
                                        HStack(spacing: 4) {
                                            Image(systemName: "speedometer")
                                                .font(.caption2)
                                                .foregroundColor(.green)
                                            Text("\(String(format: "%.1f", avgTime))s/chunk")
                                                .font(.caption2)
                                                .monospacedDigit()
                                        }
                                    }
                                    
                                    Spacer()
                                }
                                .padding(.top, 4)
                            }
                            
                            // Legacy progress message if it exists
                            if !job.progressMessage.isEmpty && job.progressMessage != job.detailedProgressMessage {
                                Text(job.progressMessage)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .italic()
                            }
                        }
                    }
                }
                
                // Job info
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Job Information", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        InfoRow(label: "ID", value: job.id.uuidString.prefix(8) + "...")
                        InfoRow(label: "Priority", value: String(job.priority.rawValue))
                        InfoRow(label: "Created", value: formatDate(job.createdAt))
                        
                        if let startedAt = job.startedAt {
                            InfoRow(label: "Started", value: formatDate(startedAt))
                        }
                        
                        if let completedAt = job.completedAt {
                            InfoRow(label: "Completed", value: formatDate(completedAt))
                        }
                        
                        if let duration = job.duration {
                            InfoRow(label: "Audio Duration", value: formatDuration(duration))
                        }
                        
                        if let fileSize = job.fileSize {
                            InfoRow(label: "File Size", value: formatBytes(fileSize))
                        }
                        
                        if let model = job.requiredModel {
                            InfoRow(label: "Model", value: model)
                        }
                    }
                }
                
                // Run Settings
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Run Settings", systemImage: "slider.horizontal.3")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            // Compact display badge
                            Text(job.runSettings.compactDisplay)
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.indigo.opacity(0.2))
                                .foregroundColor(.indigo)
                                .cornerRadius(4)
                        }
                        
                        Divider()
                        
                        // Detailed settings
                        VStack(alignment: .leading, spacing: 6) {
                            InfoRow(label: "Temperature", value: String(format: "%.2f", job.runSettings.temperature))
                            InfoRow(label: "Top-K", value: "\(job.runSettings.topK)")
                            if let topP = job.runSettings.topP {
                                InfoRow(label: "Top-P", value: String(format: "%.2f", topP))
                            }
                            InfoRow(label: "Max Tokens", value: "\(job.runSettings.maxTokens)")
                            InfoRow(label: "Context Keep", value: "\(job.runSettings.contextKeep)")
                            if let seed = job.runSettings.seed {
                                InfoRow(label: "Seed", value: "\(seed)")
                            }
                            
                            // Show prompt preview
                            if !job.runSettings.prompt.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Prompt:")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(String(job.runSettings.prompt.prefix(100)))
                                        .font(.caption)
                                        .foregroundColor(.primary)
                                        .padding(6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color(NSColor.controlBackgroundColor))
                                        .cornerRadius(4)
                                }
                            }
                        }
                    }
                }
                
                // Prompt test config if applicable
                if let promptConfig = job.promptConfig {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Prompt Test Configuration", systemImage: "flask")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            InfoRow(label: "Test", value: promptConfig.name)
                            InfoRow(label: "Group", value: promptConfig.group.rawValue)
                            
                            Text("Prompt:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text(promptConfig.prompt.isEmpty ? "[Empty]" : promptConfig.prompt)
                                .font(.system(.caption, design: .monospaced))
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(4)
                        }
                    }
                }
                
                // Error section
                if let error = job.error {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Error", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundColor(.red)
                            
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                                .textSelection(.enabled)
                        }
                    }
                }
                
                // Transcript section
                if let transcript = job.transcript {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Transcript", systemImage: "doc.text")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            ScrollView {
                                Text(transcript)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background(Color(NSColor.controlBackgroundColor))
                                    .cornerRadius(4)
                            }
                            .frame(maxHeight: 200)
                        }
                    }
                }
                
                // Actions
                HStack {
                    if job.status == .failed && job.canRetry {
                        Button(action: { queueManager.retryJob(job.id) }) {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                    }
                    
                    if job.status == .pending || job.status == .processing {
                        Button(action: { queueManager.cancelJob(job.id) }) {
                            Label("Cancel", systemImage: "xmark.circle")
                        }
                        .foregroundColor(.red)
                    }
                    
                    Spacer()
                }
            }
            .padding()
        }
    }
    
    private var activeTranscriptionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header
            HStack {
                Label("Active Transcriptions", systemImage: "waveform.circle.fill")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.orange)
                
                Spacer()
                
                Text("\(voiceMemosMonitor.currentlyProcessing.count + (unifiedManager.isTranscribing ? 1 : 0))")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2))
                    .cornerRadius(4)
            }
            
            VStack(spacing: 4) {
                // Show Voice Memos Monitor active transcriptions
                if !voiceMemosMonitor.currentlyProcessing.isEmpty {
                    ForEach(Array(voiceMemosMonitor.pendingMemos.filter { voiceMemosMonitor.currentlyProcessing.contains($0.id) }), id: \.id) { memo in
                        HStack {
                            Image(systemName: "mic.fill")
                                .foregroundColor(.orange)
                                .frame(width: 20)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(memo.fileName)
                                    .font(.caption)
                                    .lineLimit(1)
                                
                                Text("Voice Memos Monitor")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 20, height: 20)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.orange.opacity(0.05))
                        .cornerRadius(6)
                    }
                }
                
                // Show direct UnifiedTranscriptionManager activity
                if unifiedManager.isTranscribing {
                    HStack {
                        Image(systemName: "text.quote")
                            .foregroundColor(.orange)
                            .frame(width: 20)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(unifiedManager.transcriptionStatus)
                                .font(.caption)
                                .lineLimit(1)
                            
                            HStack {
                                Text("Direct Transcription")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                
                                if unifiedManager.transcriptionProgress > 0 {
                                    Text("\(Int(unifiedManager.transcriptionProgress * 100))%")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                        
                        Spacer()
                        
                        if unifiedManager.transcriptionProgress > 0 {
                            ProgressView(value: unifiedManager.transcriptionProgress)
                                .progressViewStyle(.circular)
                                .scaleEffect(0.7)
                                .frame(width: 20, height: 20)
                        } else {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 20, height: 20)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.05))
                    .cornerRadius(6)
                }
            }
        }
        .padding()
    }
    
    private var emptyDetailView: some View {
        VStack {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 60))
                .foregroundColor(.secondary.opacity(0.3))
            Text("Select a job to view details")
                .font(.title3)
                .foregroundColor(.secondary)
            Spacer()
        }
    }
    
    // MARK: - Voice Memos -> Queue

    /// Grant access to the Voice Memos library (prompting via a folder picker if needed) and
    /// queue every recording for transcription. Dedup is handled by addJob.
    private func requeueEmpties() {
        let n = queueManager.requeueEmptyRecordings()
        withAnimation {
            voiceMemosNotice = n > 0 ? "Re-queued \(n) empty recording\(n == 1 ? "" : "s")"
                                     : "No empty recordings to re-queue"
        }
        emptyCount = queueManager.emptyRecordingCount()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { voiceMemosNotice = nil }
        }
    }

    private func addVoiceMemosToQueue() {
        let enqueue: () -> Void = {
            importer.loadVoiceMemos()
            let memos = importer.voiceMemos
            for memo in memos {
                _ = queueManager.addJob(
                    audioFile: memo.url.path,
                    fileName: memo.url.lastPathComponent,
                    source: .voiceMemos
                )
            }
            withAnimation {
                voiceMemosNotice = memos.isEmpty
                    ? (importer.errorMessage ?? "No voice memos found")
                    : "Queued \(memos.count) voice memo\(memos.count == 1 ? "" : "s")"
            }
        }

        if fileAccess.hasVoiceMemosAccess {
            enqueue()
        } else {
            fileAccess.requestVoiceMemosAccess { url in
                DispatchQueue.main.async {
                    if url != nil {
                        enqueue()
                    } else {
                        withAnimation { voiceMemosNotice = "Voice Memos access not granted" }
                    }
                }
            }
        }
    }

    // MARK: - Helper Functions

    private func phaseColor(for phase: TranscriptionJob.ProgressPhase) -> Color {
        switch phase {
        case .waiting:
            return .gray
        case .preparingAudio:
            return .blue
        case .splittingChunks:
            return .orange
        case .transcribingChunks:
            return .green
        case .combiningResults:
            return .purple
        case .finalizing:
            return .indigo
        }
    }
    
    private func sourceIcon(for source: TranscriptionItem.TranscriptionSource) -> String {
        switch source {
        case .recording:
            return "mic.fill"
        case .voiceMemos:
            return "waveform"
        case .imported:
            return "square.and.arrow.down"
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .short
        return formatter.string(from: date)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    private func formatDetailedETA(_ eta: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter.string(from: eta) ?? "Unknown"
    }
}

// MARK: - Supporting Views

struct JobRow: View {
    let job: TranscriptionJob
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.fileName)
                            .font(.system(.body, weight: .medium))
                            .lineLimit(1)
                        
                        HStack(spacing: 8) {
                            Text(job.source.rawValue)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            if let model = job.requiredModel {
                                Text(model)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                
                Spacer()
                
                if job.status == .processing {
                    VStack(alignment: .trailing, spacing: 4) {
                        // Percentage and spinner
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("\(Int(job.detailedProgress * 100))%")
                                .font(.system(.caption, design: .rounded))
                                .fontWeight(.semibold)
                                .monospacedDigit()
                                .foregroundColor(.blue)
                        }
                        
                        // ETA if available
                        if let eta = job.calculatedETA, eta > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "clock")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                                Text(formatETA(eta))
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .foregroundColor(.orange)
                                    .monospacedDigit()
                            }
                        }
                        
                        // Chunk progress
                        if job.progressPhase == .transcribingChunks && job.totalChunks > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "square.stack.3d.up")
                                    .font(.caption2)
                                    .foregroundColor(.purple)
                                // Show current chunk being processed consistently
                                let currentChunk = job.currentChunkProgress >= 1.0 ? job.completedChunks : min(job.completedChunks + 1, job.totalChunks)
                                Text("\(currentChunk)/\(job.totalChunks)")
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .foregroundColor(.purple)
                                    .monospacedDigit()
                            }
                        }
                    }
                } else {
                    JobStatusIndicator(status: job.status)
                }
            }
            
            // Add progress bar for processing jobs
            if job.status == .processing {
                ProgressView(value: job.detailedProgress)
                    .tint(progressColor(for: job.progressPhase))
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
    
    private func formatETA(_ eta: TimeInterval) -> String {
        if eta < 60 {
            return "\(Int(eta))s"
        } else if eta < 3600 {
            let minutes = Int(eta) / 60
            let seconds = Int(eta) % 60
            if seconds > 0 {
                return "\(minutes)m \(seconds)s"
            } else {
                return "\(minutes)m"
            }
        } else {
            let hours = Int(eta) / 3600
            let minutes = (Int(eta) % 3600) / 60
            return "\(hours)h \(minutes)m"
        }
    }
    
    private func progressColor(for phase: TranscriptionJob.ProgressPhase) -> Color {
        switch phase {
        case .waiting:
            return .gray
        case .preparingAudio:
            return .blue
        case .splittingChunks:
            return .orange
        case .transcribingChunks:
            return .green
        case .combiningResults:
            return .purple
        case .finalizing:
            return .indigo
        }
    }
}

struct JobStatusIndicator: View {
    let status: TranscriptionJob.JobStatus
    
    var body: some View {
        Image(systemName: statusIcon)
            .foregroundColor(statusColor)
            .font(.caption)
    }
    
    private var statusIcon: String {
        switch status {
        case .pending:
            return "clock"
        case .processing:
            return "gearshape.fill"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .cancelled:
            return "xmark.circle"
        case .waitingForModel:
            return "arrow.down.circle"
        case .retrying:
            return "arrow.clockwise.circle"
        case .paused:
            return "pause.circle.fill"
        case .interrupted:
            return "exclamationmark.triangle.fill"
        }
    }
    
    private var statusColor: Color {
        switch status {
        case .pending:
            return .secondary
        case .processing:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .orange
        case .waitingForModel:
            return .orange
        case .retrying:
            return .yellow
        case .paused:
            return .orange
        case .interrupted:
            return .yellow
        }
    }
}

struct JobStatusBadge: View {
    let status: TranscriptionJob.JobStatus
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: statusIcon)
            Text(status.rawValue)
        }
        .font(.caption)
        .fontWeight(.medium)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor.opacity(0.2))
        .foregroundColor(statusColor)
        .cornerRadius(6)
    }
    
    private var statusIcon: String {
        switch status {
        case .pending:
            return "clock"
        case .processing:
            return "gearshape.fill"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .cancelled:
            return "xmark.circle"
        case .waitingForModel:
            return "arrow.down.circle"
        case .retrying:
            return "arrow.clockwise.circle"
        case .paused:
            return "pause.circle.fill"
        case .interrupted:
            return "exclamationmark.triangle.fill"
        }
    }
    
    private var statusColor: Color {
        switch status {
        case .pending:
            return .secondary
        case .processing:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .orange
        case .waitingForModel:
            return .orange
        case .retrying:
            return .yellow
        case .paused:
            return .orange
        case .interrupted:
            return .yellow
        }
    }
}

struct StatItem: View {
    let label: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(color)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label + ":")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
            Spacer()
        }
    }
}
