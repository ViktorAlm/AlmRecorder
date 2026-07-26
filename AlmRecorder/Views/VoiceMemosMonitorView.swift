import SwiftUI
import AVFoundation

/// View for monitoring and managing Voice Memos import
struct VoiceMemosMonitorView: View {
    @ObservedObject private var monitor = VoiceMemosMonitorService.shared
    @State private var showSettings = false
    @State private var selectedMemo: VoiceMemoEntry?
    @State private var showProcessAllConfirmation = false
    @State private var showingSpeakerReview = false
    @State private var selectedSpeakerReview: (recordingId: Int64, audioPath: String, result: TranscriptionResult, memoName: String)?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            
            Divider()
            
            // Content
            if monitor.pendingMemos.isEmpty && monitor.processedMemos.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        // Speaker reviews pending
                        if !monitor.pendingSpeakerReviews.isEmpty {
                            speakerReviewSection
                        }
                        
                        // Currently processing
                        if !monitor.currentlyProcessing.isEmpty {
                            currentlyProcessingView()
                        }
                        
                        // Pending memos
                        if !monitor.pendingMemos.isEmpty {
                            pendingMemosSection
                        }
                        
                        // Processed memos
                        if !monitor.processedMemos.isEmpty {
                            processedMemosSection
                        }
                    }
                    .padding()
                }
            }
            
            Divider()
            
            // Footer controls
            footerControls
        }
        .frame(minWidth: 600, minHeight: 400)
        // Speakers are saved as unnamed profiles during transcription.
        // The speaker review section lets the user choose to review when ready.
        .sheet(isPresented: $showSettings) {
            VoiceMemosSettingsView()
        }
        .sheet(item: $selectedMemo) { memo in
            VoiceMemoDetailView(memo: memo)
        }
        .sheet(isPresented: $showingSpeakerReview) {
            if let review = selectedSpeakerReview {
                SpeakerReviewWizard(
                    isPresented: $showingSpeakerReview,
                    recordingId: review.recordingId,
                    audioFilePath: review.audioPath,
                    transcriptionResult: review.result,
                    onComplete: { assignmentResult in
                        // Remove from pending reviews after completion
                        if let index = monitor.pendingSpeakerReviews.firstIndex(where: { $0.recordingId == review.recordingId }) {
                            monitor.pendingSpeakerReviews.remove(at: index)
                        }
                        print("[VoiceMemosMonitor] Speaker review completed for \(review.memoName)")
                    }
                )
            }
        }
        .alert("Process All Memos?", isPresented: $showProcessAllConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Process All") {
                Task {
                    await monitor.processAllPending()
                }
            }
        } message: {
            Text("This will transcribe and generate summaries for all \(monitor.pendingMemos.count) pending Voice Memos.")
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            Image(systemName: "mic.circle.fill")
                .font(.title2)
                .foregroundColor(.blue)
            
            Text("Voice Memos Monitor")
                .font(.title2)
                .fontWeight(.semibold)
            
            Spacer()
            
            // Statistics
            let stats = monitor.getStatistics()
            HStack(spacing: 16) {
                if stats.processing > 0 {
                    StatBadge(label: "Processing", value: stats.processing, color: .blue)
                }
                StatBadge(label: "Pending", value: stats.pending, color: .orange)
                StatBadge(label: "Processed", value: stats.processed, color: .green)
                if stats.failed > 0 {
                    StatBadge(label: "Failed", value: stats.failed, color: .red)
                }
            }
            
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
            }
        }
        .padding()
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("No Voice Memos Found")
                .font(.title3)
                .fontWeight(.medium)
            
            Text("Voice Memos will appear here when detected")
                .foregroundColor(.secondary)
            
            if !monitor.isMonitoring {
                Button("Start Monitoring") {
                    monitor.startMonitoring()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Currently Processing
    
    private func currentlyProcessingView() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                
                Text("Processing \(monitor.currentlyProcessing.count) memo\(monitor.currentlyProcessing.count == 1 ? "" : "s")...")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Spacer()
            }
            
            if monitor.processingProgress > 0 && monitor.processingProgress < 1 {
                ProgressView(value: monitor.processingProgress)
                    .progressViewStyle(.linear)
            }
            
            Text("Generating transcripts and summaries...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.blue.opacity(0.1))
        .cornerRadius(8)
    }
    
    // MARK: - Pending Section
    
    private var pendingMemosSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Pending", systemImage: "clock")
                    .font(.headline)
                
                // Show total duration of pending items
                if !monitor.pendingMemos.isEmpty {
                    let totalDuration = monitor.pendingMemos
                        .compactMap { $0.duration }
                        .reduce(0, +)
                    
                    Text("Total: \(formatTotalDuration(totalDuration))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(4)
                }
                
                Spacer()
                
                if monitor.pendingMemos.count > 1 && monitor.currentlyProcessing.isEmpty {
                    Button("Process All") {
                        showProcessAllConfirmation = true
                    }
                    .buttonStyle(.borderless)
                }
            }
            
            ForEach(monitor.pendingMemos) { memo in
                VoiceMemoMonitorRow(
                    memo: memo,
                    isProcessing: monitor.currentlyProcessing.contains(memo.id)
                ) {
                    Task {
                        await monitor.processMemo(memo)
                    }
                }
            }
        }
    }
    
    // MARK: - Processed Section
    
    private var processedMemosSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Processed", systemImage: "checkmark.circle")
                    .font(.headline)
                
                Spacer()
                
                if !monitor.processedMemos.isEmpty {
                    Button("Clear History") {
                        monitor.clearHistory()
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                }
            }
            
            ForEach(monitor.processedMemos.prefix(10)) { memo in
                VoiceMemoMonitorRow(
                    memo: memo,
                    isProcessing: false
                ) {
                    if memo.status == .failed {
                        monitor.retryMemo(memo.id)
                    } else {
                        selectedMemo = memo
                    }
                }
            }
            
            if monitor.processedMemos.count > 10 {
                Text("+ \(monitor.processedMemos.count - 10) more")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading)
            }
        }
    }
    
    // MARK: - Speaker Review Section
    
    private var speakerReviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            speakerReviewHeader
            speakerReviewList
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }
    
    private var speakerReviewHeader: some View {
        HStack {
            Label("Speaker Review Available", systemImage: "person.2.circle.fill")
                .font(.headline)
                .foregroundColor(.blue)
            
            Spacer()
            
            Text("\(monitor.pendingSpeakerReviews.count) pending")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var speakerReviewList: some View {
        ForEach(Array(monitor.pendingSpeakerReviews.enumerated()), id: \.offset) { index, review in
            speakerReviewRow(review: review)
        }
    }
    
    private func speakerReviewRow(review: (recordingId: Int64, audioPath: String, result: TranscriptionResult, memoName: String)) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(review.memoName)
                    .font(.body)
                    .fontWeight(.medium)
                
                HStack(spacing: 8) {
                    if let speakerCount = review.result.detectedSpeakerCount {
                        Label("\(speakerCount) speakers", systemImage: "person.2")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    let duration = review.result.totalDuration
                    let durationString = String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60)
                    Text(durationString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Button("Review Speakers") {
                selectedSpeakerReview = review
                showingSpeakerReview = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding()
        .background(Color.purple.opacity(0.05))
        .cornerRadius(8)
    }
    
    // MARK: - Footer
    
    private var footerControls: some View {
        HStack {
            if let error = monitor.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(1)
            }
            
            Spacer()
            
            if monitor.isMonitoring {
                Label("Monitoring", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundColor(.green)
                
                Button("Stop") {
                    monitor.stopMonitoring()
                }
            } else {
                Button("Start Monitoring") {
                    monitor.startMonitoring()
                }
            }
            
            Button("Scan Now") {
                monitor.scanForNewMemos()
            }
            .disabled(!monitor.isMonitoring)
        }
        .padding()
    }
    
    private func formatTotalDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        
        if hours > 0 {
            return String(format: "%dh %02dm %02ds", hours, minutes, secs)
        } else if minutes > 0 {
            return String(format: "%dm %02ds", minutes, secs)
        } else {
            return String(format: "%ds", secs)
        }
    }
}

// MARK: - Supporting Views

struct VoiceMemoMonitorRow: View {
    let memo: VoiceMemoEntry
    let isProcessing: Bool
    let action: () -> Void
    
    @State private var isPlaying = false
    @State private var audioPlayer: AVAudioPlayer?
    @State private var playbackProgress: Double = 0
    @State private var playbackTimer: Timer?
    @State private var showingActions = false
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                // Playback button
                Button(action: togglePlayback) {
                    ZStack {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title2)
                            .foregroundColor(isPlaying ? .orange : .blue)
                        
                        if isPlaying && playbackProgress > 0 {
                            Circle()
                                .trim(from: 0, to: playbackProgress)
                                .stroke(Color.orange, lineWidth: 2)
                                .frame(width: 32, height: 32)
                                .rotationEffect(.degrees(-90))
                                .animation(.linear(duration: 0.1), value: playbackProgress)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(isPlaying ? "Pause" : "Play")
                .disabled(memo.status == .processing)
                
                // Main content
                HStack {
                // Status icon
                Image(systemName: statusIcon)
                    .foregroundColor(statusColor)
                    .frame(width: 20)
                
                // Info
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(memo.fileName)
                            .font(.system(.body))
                            .lineLimit(1)
                        
                        // Duration badge
                        if let duration = memo.duration {
                            Text(formatDuration(duration))
                                .font(.system(.caption, design: .monospaced))
                                .fontWeight(.semibold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(4)
                        }
                        
                        // Status badge
                        Text(statusText)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(statusTextColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(statusTextColor.opacity(0.15))
                            .cornerRadius(4)
                        
                        if isProcessing {
                            ProgressView()
                                .scaleEffect(0.6)
                                .padding(.leading, 4)
                        }
                    }
                    
                    HStack(spacing: 12) {
                        // Exact date and time
                        Label(formatExactDateTime(memo.createdDate), systemImage: "calendar.badge.clock")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text(formatFileSize(memo.fileSize))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        // Relative time in parentheses
                        Text("(\(formatRelativeDate(memo.createdDate)))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .italic()
                    }
                    
                    if let summary = memo.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .padding(.top, 2)
                    }
                }
                
                Spacer()
                
                // Action menu button
                Menu {
                    if memo.status == .pending {
                        Button(action: { action() }) {
                            Label("Transcribe Now", systemImage: "text.quote")
                        }
                    } else if memo.status == .failed {
                        Button(action: { action() }) {
                            Label("Retry Transcription", systemImage: "arrow.clockwise")
                        }
                    } else if memo.status == .completed {
                        Button(action: { action() }) {
                            Label("Re-transcribe", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    
                    Divider()
                    
                    Button(action: { showInFinder() }) {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    
                    if memo.status == .completed {
                        Button(action: { openInApp() }) {
                            Label("Open Recording", systemImage: "doc.text")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
            .opacity(isProcessing ? 0.7 : 1.0)
            }
            
            // Playback progress bar
            if isPlaying {
                HStack {
                    ProgressView(value: playbackProgress)
                        .progressViewStyle(.linear)
                        .frame(height: 3)
                    
                    if let player = audioPlayer {
                        Text("\(formatTime(player.currentTime)) / \(formatTime(player.duration))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
        }
    }
    
    private var statusIcon: String {
        if isProcessing {
            return "arrow.triangle.2.circlepath"
        }
        
        switch memo.status {
        case .pending:
            return "clock"
        case .processing:
            return "arrow.triangle.2.circlepath"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .skipped:
            return "arrow.uturn.forward.circle"
        }
    }
    
    private var statusColor: Color {
        if isProcessing {
            return .blue
        }
        
        switch memo.status {
        case .pending:
            return .orange
        case .processing:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        case .skipped:
            return .gray
        }
    }
    
    private var statusText: String {
        switch memo.status {
        case .pending:
            return "Not Transcribed"
        case .processing:
            return "Transcribing..."
        case .completed:
            return "Transcribed"
        case .failed:
            return "Failed"
        case .skipped:
            return "Already Imported"
        }
    }
    
    private var statusTextColor: Color {
        switch memo.status {
        case .pending:
            return .orange
        case .processing:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        case .skipped:
            return .purple
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    private func formatExactDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm:ss a"
        return formatter.string(from: date)
    }
    
    private func formatRelativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    
    // MARK: - Playback Methods
    
    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }
    
    private func startPlayback() {
        guard let url = URL(string: "file://\(memo.filePath)") else { return }
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            isPlaying = true
            
            // Start progress timer
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                if let player = audioPlayer {
                    playbackProgress = player.currentTime / player.duration
                    
                    if !player.isPlaying {
                        stopPlayback()
                    }
                }
            }
        } catch {
            print("Failed to play audio: \(error)")
        }
    }
    
    private func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        playbackProgress = 0
        playbackTimer?.invalidate()
        playbackTimer = nil
    }
    
    // MARK: - Action Methods
    
    private func showInFinder() {
        if let url = URL(string: "file://\(memo.filePath)") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
    
    private func openInApp() {
        // Open the recording in the main app with the transcription details
        // This would navigate to the recording detail view
        // For now, just show in Finder
        showInFinder()
    }
}

struct StatBadge: View {
    let label: String
    let value: Int
    let color: Color
    
    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(color)
            
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Settings View

struct VoiceMemosSettingsView: View {
    @ObservedObject private var monitor = VoiceMemosMonitorService.shared
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Voice Memos Settings")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button("Done") {
                    dismiss()
                }
            }
            .padding()
            
            Divider()
            
            // Settings
            Form {
                Section("Monitoring") {
                    Toggle("Enable Monitoring", isOn: $monitor.settings.isEnabled)
                    
                    HStack {
                        Text("Check Interval")
                        Spacer()
                        Picker("", selection: $monitor.settings.checkInterval) {
                            Text("30 seconds").tag(30.0)
                            Text("1 minute").tag(60.0)
                            Text("2 minutes").tag(120.0)
                            Text("5 minutes").tag(300.0)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 120)
                    }
                }
                
                Section("Processing") {
                    Toggle("Auto Process New Memos", isOn: $monitor.settings.autoProcessNew)
                    
                    Toggle("Auto Generate Summary", isOn: $monitor.settings.autoGenerateSummary)
                    
                    Toggle("Enable Duration Limit", isOn: $monitor.settings.enableDurationLimit)
                        .help("When disabled, processes entire audio regardless of length")
                    
                    if monitor.settings.enableDurationLimit {
                        HStack {
                            Text("Max Processing Duration")
                            Spacer()
                            Picker("", selection: $monitor.settings.maxProcessingDuration) {
                                Text("5 minutes").tag(300.0)
                                Text("10 minutes").tag(600.0)
                                Text("30 minutes").tag(1800.0)
                                Text("1 hour").tag(3600.0)
                                Text("2 hours").tag(7200.0)
                                Text("3 hours").tag(10800.0)
                                Text("5 hours").tag(18000.0)
                                Text("10 hours").tag(36000.0)
                            }
                            .pickerStyle(.menu)
                            .frame(width: 120)
                        }
                        .disabled(!monitor.settings.enableDurationLimit)
                    }
                    
                    Toggle("Delete After Import", isOn: $monitor.settings.deleteAfterImport)
                        .disabled(true) // For safety, keep disabled for now
                }
                
                Section("Status") {
                    if let lastCheck = monitor.settings.lastCheckDate {
                        HStack {
                            Text("Last Check")
                            Spacer()
                            Text(formatDate(lastCheck))
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    let stats = monitor.getStatistics()
                    HStack {
                        Text("Total Processed")
                        Spacer()
                        Text("\(stats.processed)")
                            .foregroundColor(.secondary)
                    }
                    
                    if stats.failed > 0 {
                        HStack {
                            Text("Failed")
                            Spacer()
                            Text("\(stats.failed)")
                                .foregroundColor(.red)
                        }
                    }
                    
                    if stats.processing > 0 {
                        HStack {
                            Text("Currently Processing")
                            Spacer()
                            Text("\(stats.processing)")
                                .foregroundColor(.blue)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 400, height: 400)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Detail View

struct VoiceMemoDetailView: View {
    let memo: VoiceMemoEntry
    @ObservedObject private var monitor = VoiceMemosMonitorService.shared
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text(memo.fileName)
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                if memo.status == .failed {
                    Button("Retry") {
                        monitor.retryMemo(memo.id)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
                
                Button("Done") {
                    dismiss()
                }
            }
            
            Divider()
            
            // Details
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let summary = memo.summary {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Summary")
                                .font(.headline)
                            
                            Text(summary)
                                .textSelection(.enabled)
                        }
                    }
                    
                    if let snippet = memo.transcriptSnippet {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Transcript Preview")
                                .font(.headline)
                            
                            Text(snippet + (snippet.count >= 200 ? "..." : ""))
                                .textSelection(.enabled)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Divider()
                    
                    // Metadata
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16) {
                        GridRow {
                            Text("Status:")
                                .foregroundColor(.secondary)
                            HStack {
                                Image(systemName: statusIcon(for: memo.status))
                                    .foregroundColor(statusColor(for: memo.status))
                                Text(memo.status.rawValue.capitalized)
                            }
                        }
                        
                        GridRow {
                            Text("File Size:")
                                .foregroundColor(.secondary)
                            Text(formatFileSize(memo.fileSize))
                        }
                        
                        if let duration = memo.duration {
                            GridRow {
                                Text("Duration:")
                                    .foregroundColor(.secondary)
                                Text(formatDuration(duration))
                            }
                        }
                        
                        GridRow {
                            Text("Created:")
                                .foregroundColor(.secondary)
                            Text(formatDate(memo.createdDate))
                        }
                        
                        if let processed = memo.processedDate {
                            GridRow {
                                Text("Processed:")
                                    .foregroundColor(.secondary)
                                Text(formatDate(processed))
                            }
                        }
                        
                        GridRow {
                            Text("File Path:")
                                .foregroundColor(.secondary)
                            Text(memo.filePath)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }
                    .font(.system(.body))
                }
                .padding()
            }
        }
        .padding()
        .frame(width: 500, height: 400)
    }
    
    private func statusIcon(for status: VoiceMemoEntry.ProcessingStatus) -> String {
        switch status {
        case .pending:
            return "clock"
        case .processing:
            return "arrow.triangle.2.circlepath"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .skipped:
            return "arrow.uturn.forward.circle"
        }
    }
    
    private func statusColor(for status: VoiceMemoEntry.ProcessingStatus) -> Color {
        switch status {
        case .pending:
            return .orange
        case .processing:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        case .skipped:
            return .gray
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}