import SwiftUI

struct HistoryView: View {
    @StateObject private var batchManager = BatchTranscriptionManager()
    @State private var transcriptionHistory: [TranscriptionItem] = []
    @State private var searchText = ""
    @State private var selectedItem: TranscriptionItem?
    @State private var selectedUtterances: [Utterance]? = nil
    @State private var showingExportOptions = false
    @State private var displayMode: TranscriptSegmentView.DisplayMode = .chatBubble
    
    var filteredItems: [TranscriptionItem] {
        if searchText.isEmpty {
            return transcriptionHistory
        }
        return transcriptionHistory.filter { item in
            item.fileName.localizedCaseInsensitiveContains(searchText) ||
            item.transcript.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        HSplitView {
            sidebar

            // Detail pane only when something is selected; otherwise the list fills the width.
            if let selected = selectedItem {
                detailView(for: selected)
                    .frame(minWidth: 440, maxWidth: .infinity)
            }
        }
        .onAppear {
            loadHistory()
        }
    }
    
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                
                TextField("Search transcriptions...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
            .padding()
            
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filteredItems) { item in
                        HistoryRow(
                            item: item,
                            isSelected: selectedItem?.id == item.id,
                            onSelect: { selectedItem = item }
                        )
                    }
                }
                .padding(.horizontal)
            }
            
            Divider()
            
            toolbar
        }
        .frame(minWidth: 320, idealWidth: 440, maxWidth: selectedItem == nil ? .infinity : 520)
    }
    
    private var toolbar: some View {
        HStack {
            Text("\(transcriptionHistory.count) items")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Menu {
                Button("Export as Text") {
                    exportHistory(format: .txt)
                }
                Button("Export as CSV") {
                    exportHistory(format: .csv)
                }
                Button("Export as JSON") {
                    exportHistory(format: .json)
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(transcriptionHistory.isEmpty)
            
            Button(action: clearHistory) {
                Label("Clear", systemImage: "trash")
            }
            .disabled(transcriptionHistory.isEmpty)
        }
        .padding()
    }
    
    private func detailView(for item: TranscriptionItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.fileName)
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        // Status badge
                        statusBadge(for: item)
                    }
                    
                    HStack {
                        Label(item.formattedDuration, systemImage: "clock")
                        Label(item.formattedFileSize, systemImage: "doc")
                        Label(item.language, systemImage: "globe")
                        Label(item.source.rawValue, systemImage: "folder")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    
                    Text("Transcribed: \(item.formattedTranscribedDate)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: { copyTranscript(item.transcript) }) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(item.transcript.isEmpty)
                
                Button(action: { saveTranscript(item) }) {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .disabled(item.transcript.isEmpty)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            // Show error message if present
            if item.hasError, let error = item.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.1))
            }
            
            Divider()
            
            ScrollView {
                if item.transcript.isEmpty && item.hasError {
                    VStack {
                        Image(systemName: "exclamationmark.octagon")
                            .font(.system(size: 40))
                            .foregroundColor(.red.opacity(0.5))
                        Text("Transcription failed")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        if let error = item.error {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    Text(item.transcript)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
    }
    
    private func statusBadge(for item: TranscriptionItem) -> some View {
        HStack(spacing: 4) {
            Image(systemName: statusIcon(for: item.status))
                .font(.caption)
            Text(item.status.rawValue)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundColor(statusColor(for: item.status))
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(statusColor(for: item.status).opacity(0.1))
        .cornerRadius(4)
    }
    
    private func statusIcon(for status: TranscriptionItem.TranscriptionStatus) -> String {
        switch status {
        case .pending:
            return "clock"
        case .processing:
            return "arrow.triangle.2.circlepath"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .partialSuccess:
            return "exclamationmark.triangle.fill"
        }
    }
    
    private func statusColor(for status: TranscriptionItem.TranscriptionStatus) -> Color {
        switch status {
        case .pending:
            return .gray
        case .processing:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        case .partialSuccess:
            return .orange
        }
    }
    
    private var emptyDetailView: some View {
        VStack {
            Spacer()
            
            Image(systemName: "doc.text")
                .font(.system(size: 60))
                .foregroundColor(.secondary.opacity(0.3))
            
            Text("Select a transcription to view")
                .font(.title3)
                .foregroundColor(.secondary)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func loadHistory() {
        transcriptionHistory = batchManager.loadSavedTranscriptions()
            .sorted { $0.transcribedDate > $1.transcribedDate }
    }
    
    private func clearHistory() {
        UserDefaults.standard.removeObject(forKey: "SavedTranscriptions")
        transcriptionHistory = []
        selectedItem = nil
        selectedUtterances = nil
    }
    
    private func loadUtterances(for item: TranscriptionItem) {
        // Try to load utterances from database based on audio file path
        Task {
            do {
                // Query database for recording with matching audio path
                let recording = try GRDBRecordingRepository().getByFilePath(item.filePath)
                if let recordingId = recording?.id {
                    // Fetch utterances for this recording
                    let utterances = try GRDBUtteranceRepository().getByRecordingId(recordingId)
                    await MainActor.run {
                        self.selectedUtterances = utterances
                    }
                } else {
                    // No utterances found, will use plain text view
                    await MainActor.run {
                        self.selectedUtterances = nil
                    }
                }
            } catch {
                // Failed to load utterances, fallback to plain text
                await MainActor.run {
                    self.selectedUtterances = nil
                }
            }
        }
    }
    
    private var displayModeLabel: String {
        switch displayMode {
        case .chatBubble: return "Chat Bubbles"
        case .timeline: return "Timeline"
        case .row: return "List"
        case .card: return "Cards"
        }
    }
    
    private var displayModeIcon: String {
        switch displayMode {
        case .chatBubble: return "bubble.left.and.bubble.right"
        case .timeline: return "clock.arrow.circlepath"
        case .row: return "list.bullet"
        case .card: return "rectangle.grid.1x2"
        }
    }
    
    private func exportHistory(format: BatchTranscriptionManager.ExportFormat) {
        guard let url = batchManager.exportTranscriptions(items: transcriptionHistory, format: format) else {
            return
        }
        
        let savePanel = NSSavePanel()
        savePanel.directoryURL = url.deletingLastPathComponent()
        savePanel.nameFieldStringValue = url.lastPathComponent
        
        if savePanel.runModal() == .OK, let saveURL = savePanel.url {
            try? FileManager.default.moveItem(at: url, to: saveURL)
        }
    }
    
    private func copyTranscript(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    
    private func saveTranscript(_ item: TranscriptionItem) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "\(item.fileName)_transcript.txt"
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            try? item.transcript.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

struct HistoryRow: View {
    let item: TranscriptionItem
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: iconForSource(item.source))
                        .foregroundColor(.blue)
                    
                    // Status indicator overlay
                    if item.status != .completed {
                        Circle()
                            .fill(statusIndicatorColor)
                            .frame(width: 8, height: 8)
                            .offset(x: 4, y: 4)
                    }
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(item.fileName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        
                        if item.hasError {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundColor(.red)
                        }
                    }
                    
                    Text(preview(of: item.transcript))
                        .font(.caption)
                        .foregroundColor(item.hasError ? .red : .secondary)
                        .lineLimit(2)
                    
                    Text(item.formattedTranscribedDate)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
    
    private var statusIndicatorColor: Color {
        switch item.status {
        case .pending:
            return .gray
        case .processing:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        case .partialSuccess:
            return .orange
        }
    }
    
    private func iconForSource(_ source: TranscriptionItem.TranscriptionSource) -> String {
        switch source {
        case .recording:
            return "mic.fill"
        case .voiceMemos:
            return "waveform"
        case .imported:
            return "doc.fill"
        }
    }
    
    private func preview(of text: String) -> String {
        if text.isEmpty {
            return "No transcript available"
        }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 100 {
            return String(cleaned.prefix(97)) + "..."
        }
        return cleaned
    }
}