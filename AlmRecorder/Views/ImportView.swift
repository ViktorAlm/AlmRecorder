import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @StateObject private var importer = VoiceMemosImporter()
    @StateObject private var batchManager = BatchTranscriptionManager()
    @StateObject private var queueManager = TranscriptionQueueManager.shared
    @StateObject private var fileAccess = FileAccessManager.shared
    @ObservedObject private var globalSettings = GlobalTranscriptionSettings.shared
    @State private var showingExportOptions = false
    @State private var dragOver = false
    @State private var showingSpeakerReview = false
    @State private var selectedSpeakerReview: (recordingId: Int64, audioPath: String, result: TranscriptionResult, fileName: String)?
    
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            
            Divider()
            
            if importer.voiceMemos.isEmpty {
                emptyState
            } else {
                fileList
            }
            
            if batchManager.isProcessing {
                progressOverlay
            }
        }
        .onAppear {
            importer.loadVoiceMemos()
        }
        .onDrop(of: [.audio], isTargeted: $dragOver) { providers in
            handleDrop(providers: providers)
            return true
        }
        // Speakers are saved as unnamed profiles during transcription.
        // The user can review them from Speaker Management or via the pending review list.
        .sheet(isPresented: $showingSpeakerReview) {
            if let review = selectedSpeakerReview {
                SpeakerReviewWizard(
                    isPresented: $showingSpeakerReview,
                    recordingId: review.recordingId,
                    audioFilePath: review.audioPath,
                    transcriptionResult: review.result,
                    onComplete: { assignmentResult in
                        // Remove from pending reviews after completion
                        if let index = batchManager.pendingSpeakerReviews.firstIndex(where: { $0.recordingId == review.recordingId }) {
                            batchManager.pendingSpeakerReviews.remove(at: index)
                        }
                        if let index = queueManager.pendingSpeakerReviews.firstIndex(where: { $0.recordingId == review.recordingId }) {
                            queueManager.pendingSpeakerReviews.remove(at: index)
                        }
                        selectedSpeakerReview = nil
                    }
                )
            }
        }
    }
    
    private var toolbar: some View {
        HStack {
            Button(action: { 
                fileAccess.requestVoiceMemosAccess { url in
                    if url != nil {
                        importer.loadVoiceMemos()
                    }
                }
            }) {
                Label("Voice Memos Folder", systemImage: "folder.badge.mic")
            }
            
            Button(action: {
                fileAccess.requestFileAccess { urls in
                    if let urls = urls {
                        importer.importFromFiles(urls)
                    }
                }
            }) {
                Label("Import Files", systemImage: "doc.badge.plus")
            }
            
            Spacer()
            
            if !importer.voiceMemos.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(importer.getSelectedMemos().count) of \(importer.voiceMemos.count) selected")
                        .foregroundColor(.secondary)
                    
                    // Show total duration of selected items
                    if importer.getSelectedMemos().count > 0 {
                        let totalDuration = importer.getSelectedMemos()
                            .compactMap { $0.duration }
                            .reduce(0, +)
                        Text("Total: \(formatTotalDuration(totalDuration))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Button("Select All") {
                    importer.selectAll()
                }
                .disabled(importer.voiceMemos.allSatisfy { $0.isSelected })
                
                Button("Deselect All") {
                    importer.deselectAll()
                }
                .disabled(importer.voiceMemos.allSatisfy { !$0.isSelected })
                
                Spacer()
                
                // Settings indicator
                TranscriptionRunSettingsCompactView()
                
                Button(action: startBatchTranscription) {
                    Label("Transcribe Selected", systemImage: "text.quote")
                }
                .disabled(importer.getSelectedMemos().isEmpty || batchManager.isProcessing)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding()
    }
    
    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 60))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text("No Voice Memos Found")
                .font(.title2)
                .foregroundColor(.secondary)
            
            Text("Select your Voice Memos folder or import audio files")
                .foregroundColor(.secondary)
            
            HStack(spacing: 20) {
                Button(action: {
                    fileAccess.requestVoiceMemosAccess { url in
                        if url != nil {
                            importer.loadVoiceMemos()
                        }
                    }
                }) {
                    VStack {
                        Image(systemName: "folder.badge.mic")
                            .font(.largeTitle)
                        Text("Select Voice Memos Folder")
                    }
                    .frame(width: 200, height: 100)
                }
                .buttonStyle(.bordered)
                
                Button(action: {
                    fileAccess.requestFileAccess { urls in
                        if let urls = urls {
                            importer.importFromFiles(urls)
                        }
                    }
                }) {
                    VStack {
                        Image(systemName: "doc.badge.plus")
                            .font(.largeTitle)
                        Text("Import Audio Files")
                    }
                    .frame(width: 200, height: 100)
                }
                .buttonStyle(.bordered)
            }
            
            Spacer()
            
            if let error = importer.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.yellow)
                    Text(error)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.yellow.opacity(0.1))
                .cornerRadius(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(style: StrokeStyle(lineWidth: 2, dash: [5]))
                .foregroundColor(dragOver ? .blue : .clear)
                .animation(.easeInOut, value: dragOver)
        )
    }
    
    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(importer.voiceMemos) { memo in
                    VoiceMemoRow(
                        memo: memo,
                        isSelected: memo.isSelected,
                        onToggle: { importer.toggleSelection(for: memo) }
                    )
                }
            }
            .padding()
        }
    }
    
    private var progressOverlay: some View {
        VStack(spacing: 20) {
            Text("Transcribing Files")
                .font(.title2)
                .fontWeight(.semibold)
            
            if !batchManager.currentFile.isEmpty {
                VStack(spacing: 8) {
                    Text(batchManager.currentFile)
                        .foregroundColor(.primary)
                        .fontWeight(.medium)
                    
                    // Show detailed status
                    if !batchManager.currentStatus.isEmpty {
                        TranscriptionStatusView(
                            status: batchManager.currentStatus,
                            progress: batchManager.currentFileProgress,
                            isTranscribing: true
                        )
                    }
                }
            }
            
            ProgressView(value: batchManager.progress)
                .frame(width: 300)
            
            Text("\(batchManager.completedItems.count) completed, \(batchManager.failedFiles.count) failed")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Button("Cancel") {
                batchManager.cancel()
            }
            
            if !batchManager.failedFiles.isEmpty {
                VStack(alignment: .leading) {
                    Text("Failed files:")
                        .font(.caption)
                        .fontWeight(.semibold)
                    ForEach(batchManager.failedFiles, id: \.file) { failed in
                        Text("• \(failed.file): \(failed.error)")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding()
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)
            }
        }
        .padding(40)
        .cornerRadius(12)
        .shadow(radius: 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.3))
    }
    
    private func startBatchTranscription() {
        let selected = importer.getSelectedMemos()
        guard !selected.isEmpty else { return }
        
        // Get run settings if custom settings are enabled
        let runSettings = globalSettings.useCustomSettings ? globalSettings.createRunSettings() : nil
        
        Task {
            // Use the new queue-based batch transcription
            await batchManager.transcribeBatchUsingQueue(selected, importer: importer, runSettings: runSettings)
            
            // Speakers are saved as unnamed profiles during transcription.
            // User can review them from Speaker Management at any time.
            await MainActor.run {
                if !batchManager.completedItems.isEmpty {
                    showingExportOptions = true
                }
            }
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.audio.identifier, options: nil) { item, error in
                if let url = item as? URL {
                    DispatchQueue.main.async {
                        importer.importFromFiles([url])
                    }
                }
            }
        }
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

// MARK: - Voice Memo Details Popover

struct VoiceMemoDetailsPopover: View {
    let memo: VoiceMemoFile
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recording Details")
                .font(.headline)
                .padding(.bottom, 4)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                DetailRow(label: "File Name", value: memo.name)
                DetailRow(label: "Duration", value: memo.formattedDuration)
                DetailRow(label: "File Size", value: memo.formattedFileSize)
                DetailRow(label: "Created", value: memo.formattedExactDateTime)
                DetailRow(label: "Modified", value: formatDate(memo.modifiedDate))
                DetailRow(label: "Format", value: memo.url.pathExtension.uppercased())
                
                if let duration = memo.duration {
                    DetailRow(label: "Exact Duration", value: String(format: "%.2f seconds", duration))
                }
            }
            
            Divider()
            
            HStack {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([memo.url])
                }
                .buttonStyle(.link)
                
                Spacer()
                
                Button("Close") {
                    // Popover will close automatically
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(width: 400)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm:ss a"
        return formatter.string(from: date)
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label + ":")
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .trailing)
            
            Text(value)
                .textSelection(.enabled)
            
            Spacer()
        }
    }
}

struct VoiceMemoRow: View {
    let memo: VoiceMemoFile
    let isSelected: Bool
    let onToggle: () -> Void
    @State private var showingDetails = false
    
    var body: some View {
        HStack {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundColor(isSelected ? .blue : .secondary)
            }
            .buttonStyle(.plain)
            
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(memo.formattedName)
                        .fontWeight(.medium)
                    
                    // Duration badge with prominent display
                    Text(memo.formattedDuration)
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(4)
                }
                
                HStack(spacing: 12) {
                    // Exact date and time
                    Label(memo.formattedExactDateTime, systemImage: "calendar.badge.clock")
                        .font(.caption)
                    
                    // File size
                    Label(memo.formattedFileSize, systemImage: "doc")
                        .font(.caption)
                    
                    // Relative date
                    Text("(\(memo.relativeDate))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .italic()
                }
                .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Additional info button
            Button(action: { showingDetails.toggle() }) {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show recording details")
            
            if memo.isTranscribing {
                // Try to get status from transcription service
                InlineTranscriptionStatus(
                    status: "Processing...",
                    progress: memo.transcriptionProgress
                )
            } else if memo.transcriptionProgress > 0 {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isSelected ? Color.blue.opacity(0.1) : Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .popover(isPresented: $showingDetails, arrowEdge: .trailing) {
            VoiceMemoDetailsPopover(memo: memo)
        }
    }
}