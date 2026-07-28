import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Modern Import View
struct ModernImportView: View {
    @State private var isDragging = false
    
    var body: some View {
        VStack(spacing: 30) {
            Text("Import Audio Files")
                .font(.largeTitle)
                .fontWeight(.bold)
                .fontDesign(.rounded)
            
            // Drag & Drop Area
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 2, dash: [10])
                    )
                    .foregroundColor(isDragging ? .blue : .secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                
                VStack(spacing: 20) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 60))
                        .foregroundStyle(.secondary)
                    
                    Text("Drop audio files here")
                        .font(.title2)
                        .fontDesign(.rounded)
                    
                    Text("or")
                        .foregroundColor(.secondary)
                    
                    Button("Browse Files") {
                        openFileBrowser()
                    }
                    .glassButton(tint: .accentColor, prominent: true)
                }
            }
            .frame(height: 300)
            .padding(40)
            .onDrop(of: [.audio, .fileURL], isTargeted: $isDragging) { providers in
                handleDroppedFiles(providers: providers)
                return true
            }
        }
        .padding(40)
    }
    
    private func openFileBrowser() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Select Audio Files"
        openPanel.message = "Choose audio files to transcribe"
        openPanel.showsResizeIndicator = true
        openPanel.showsHiddenFiles = false
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowedContentTypes = [.audio, .wav, .mpeg4Audio, .aiff]
        
        if openPanel.runModal() == .OK {
            let urls = openPanel.urls
            processSelectedFiles(urls: urls)
        }
    }
    
    private func handleDroppedFiles(providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { (urlData, error) in
                    if let urlData = urlData as? Data,
                       let path = String(data: urlData, encoding: .utf8),
                       let url = URL(string: path) {
                        DispatchQueue.main.async {
                            processSelectedFiles(urls: [url])
                        }
                    }
                }
            }
        }
    }
    
    private func processSelectedFiles(urls: [URL]) {
        // Queue files for transcription
        for url in urls {
            // Check if file is an audio file
            let audioExtensions = ["wav", "mp3", "m4a", "aiff", "flac", "ogg", "opus"]
            let fileExtension = url.pathExtension.lowercased()
            
            if audioExtensions.contains(fileExtension) {
                // Add to transcription queue
                _ = TranscriptionQueueManager.shared.addJob(
                    audioFile: url.path,
                    source: .imported
                )
            }
        }
    }
}

// MARK: - Modern Library View
struct ModernLibraryView: View {
    @StateObject private var unifiedManager = UnifiedTranscriptionManager.shared
    @State private var transcriptions: [TranscriptionItem] = []
    @State private var searchText = ""
    @State private var sortOrder = "Date"
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Label("Library", systemImage: "folder.fill")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                HStack {
                    Image(systemName: "magnifyingglass")
                    TextField("Search recordings...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .frame(width: 250)
                
                Picker("Sort", selection: $sortOrder) {
                    Text("Date").tag("Date")
                    Text("Name").tag("Name")
                    Text("Duration").tag("Duration")
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            .padding()
            
            Divider()
            
            // Content
            ScrollView {
                if transcriptions.isEmpty {
                    VStack(spacing: 20) {
                        Spacer(minLength: 100)
                        Image(systemName: "folder")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("No transcriptions yet")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        Text("Record or import audio to get started")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300))], spacing: 20) {
                        ForEach(filteredTranscriptions) { item in
                            RecordingCard(item: item)
                        }
                    }
                    .padding()
                }
            }
        }
        .onAppear {
            loadTranscriptions()
        }
    }
    
    private var filteredTranscriptions: [TranscriptionItem] {
        let filtered = searchText.isEmpty ? transcriptions : transcriptions.filter { item in
            item.fileName.localizedCaseInsensitiveContains(searchText) ||
            item.transcript.localizedCaseInsensitiveContains(searchText)
        }
        
        switch sortOrder {
        case "Name":
            return filtered.sorted { $0.fileName < $1.fileName }
        case "Duration":
            return filtered.sorted { $0.duration > $1.duration }
        default: // Date
            return filtered.sorted { $0.transcribedDate > $1.transcribedDate }
        }
    }
    
    private func loadTranscriptions() {
        transcriptions = unifiedManager.loadSavedTranscriptions()
    }
}

// MARK: - Recording Card
struct RecordingCard: View {
    let item: TranscriptionItem
    @State private var isHovering = false
    @State private var showingTranscript = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: iconForSource(item.source))
                    .font(.title2)
                    .foregroundStyle(colorForSource(item.source))
                
                Spacer()
                
                Text(item.formattedDuration)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
            
            Text(item.fileName)
                .font(.headline)
                .lineLimit(1)
            
            Text(preview(of: item.transcript))
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
            
            Text("Transcribed \(item.formattedTranscribedDate)")
                .font(.caption2)
                .foregroundColor(.secondary)
            
            HStack {
                Button(action: { showingTranscript.toggle() }) {
                    Label("View", systemImage: "doc.text")
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                Button(action: { copyTranscript(item.transcript) }) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.plain)
            }
            .font(.caption)
        }
        .padding()
        .cardSurface(cornerRadius: 12)
        .shadow(color: .black.opacity(0.1), radius: isHovering ? 8 : 5)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .sheet(isPresented: $showingTranscript) {
            TranscriptDetailView(item: item)
        }
    }
    
    private func iconForSource(_ source: TranscriptionItem.TranscriptionSource) -> String {
        switch source {
        case .recording: return "mic.fill"
        case .voiceMemos: return "waveform"
        case .imported: return "doc.fill"
        }
    }
    
    private func colorForSource(_ source: TranscriptionItem.TranscriptionSource) -> Color { source.color }
    
    private func preview(of text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 100 {
            return String(cleaned.prefix(97)) + "..."
        }
        return cleaned
    }
    
    private func copyTranscript(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Transcript Detail View
struct TranscriptDetailView: View {
    let item: TranscriptionItem
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.fileName)
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    HStack {
                        Label(item.formattedDuration, systemImage: "clock")
                        Label(item.formattedFileSize, systemImage: "doc")
                        Label(item.language, systemImage: "globe")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button("Done") {
                    dismiss()
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()
            
            // Transcript
            ScrollView {
                Text(item.transcript)
                    .textSelection(.enabled)
                    .font(.system(.body, design: .default))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .frame(width: 700, height: 500)
    }
}

// MARK: - Voice Memos View
struct VoiceMemosView: View {
    var body: some View {
        ImportView() // Uses the full-featured import view for Voice Memos
    }
}

// MARK: - Batch Process View
struct BatchProcessView: View {
    @State private var selectedFiles: [URL] = []
    @State private var isProcessing = false
    @State private var progress: Double = 0
    
    var body: some View {
        VStack(spacing: 30) {
            Text("Batch Processing")
                .font(.largeTitle)
                .fontWeight(.bold)
                .fontDesign(.rounded)
            
            // File List
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(selectedFiles.count) files selected")
                        .font(.headline)
                    
                    Spacer()
                    
                    Button("Add Files") {
                        selectFilesForBatch()
                    }
                    .glassButton()
                }
                
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(selectedFiles, id: \.self) { url in
                            HStack {
                                Image(systemName: "doc.fill")
                                Text(url.lastPathComponent)
                                Spacer()
                                Button(action: { removeFile(url) }) {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(8)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
            .padding()
            .cardSurface(cornerRadius: 12)
            
            // Progress
            if isProcessing {
                VStack(spacing: 12) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                    
                    Text("Processing \(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Start Button
            Button(action: startBatchProcess) {
                Label("Start Processing", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .glassButton(tint: .accentColor, prominent: true)
            .disabled(selectedFiles.isEmpty || isProcessing)
        }
        .padding(40)
    }
    
    private func startBatchProcess() {
        isProcessing = true
        progress = 0
        
        Task {
            let totalFiles = selectedFiles.count
            
            for (index, fileURL) in selectedFiles.enumerated() {
                // Update progress
                await MainActor.run {
                    progress = Double(index) / Double(totalFiles)
                }
                
                // Add to transcription queue
                _ = TranscriptionQueueManager.shared.addJob(
                    audioFile: fileURL.path,
                    source: .imported
                )
                
                // Small delay to avoid overwhelming the queue
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            }
            
            // Complete
            await MainActor.run {
                progress = 1.0
                isProcessing = false
                selectedFiles.removeAll()
            }
        }
    }
    
    private func selectFilesForBatch() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Select Audio Files for Batch Processing"
        openPanel.message = "Choose multiple audio files to transcribe"
        openPanel.showsResizeIndicator = true
        openPanel.showsHiddenFiles = false
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowedContentTypes = [.audio, .wav, .mpeg4Audio, .aiff]
        
        if openPanel.runModal() == .OK {
            selectedFiles.append(contentsOf: openPanel.urls)
        }
    }
    
    private func removeFile(_ url: URL) {
        selectedFiles.removeAll { $0 == url }
    }
}

// MARK: - Modern Settings View
struct ModernSettingsView: View {
    @State private var selection: SettingsPane = .general

    private enum SettingsPane: String, CaseIterable, Identifiable {
        case general
        case recording
        case appearance
        case dictation
        case transcription
        case models
        case speakers
        case speakerID
        case evaluation
        case tags
        case mcp

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .recording: return "Recording"
            case .appearance: return "Appearance"
            case .dictation: return "Realtime Dictation"
            case .transcription: return "Transcription"
            case .models: return "Models"
            case .speakers: return "People & Speakers"
            case .speakerID: return "Speaker Identification"
            case .evaluation: return "Evaluation"
            case .tags: return "Tags"
            case .mcp: return "MCP Access"
            }
        }

        var shortTitle: String {
            switch self {
            case .speakers: return "Speakers"
            case .speakerID: return "Speaker ID"
            case .mcp: return "MCP"
            case .dictation: return "Dictation"
            default: return title
            }
        }

        var icon: String {
            switch self {
            case .general: return "gear"
            case .recording: return "mic"
            case .appearance: return "paintbrush"
            case .dictation: return "waveform.badge.mic"
            case .transcription: return "text.quote"
            case .models: return "cpu"
            case .speakers: return "person.2"
            case .speakerID: return "waveform.and.person.filled"
            case .evaluation: return "checkmark.seal"
            case .tags: return "tag"
            case .mcp: return "point.3.connected.trianglepath.dotted"
            }
        }

        var subtitle: String {
            switch self {
            case .general: return "App behavior, meeting automation, and library maintenance"
            case .recording: return "Audio quality and recording chunk size"
            case .appearance: return "Theme and accent color"
            case .dictation: return "Hold-to-talk local dictation and text insertion"
            case .transcription: return "The engine used for new transcription jobs"
            case .models: return "Download and select local AI models"
            case .speakers: return "Review, merge, rename, and repair global identities"
            case .speakerID: return "Choose the local diarization and global matching pipeline"
            case .evaluation: return "Build gold data and benchmark speaker accuracy"
            case .tags: return "Organize labels used across recordings"
            case .mcp: return "Control local integrations and their data access"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar

            Divider()

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: selection.icon)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(selection.title)
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text(selection.subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)

                Divider()

                selectedContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: 820,
            idealWidth: 1040,
            maxWidth: .infinity,
            minHeight: 620,
            idealHeight: 760,
            maxHeight: .infinity
        )
    }

    private var settingsSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsGroup("App", panes: [.general, .recording, .appearance])
                settingsGroup(
                    "AI & Transcription",
                    panes: [.dictation, .transcription, .models]
                )
                settingsGroup(
                    "Speaker System",
                    panes: FeatureFlags.developerTools
                        ? [.speakers, .speakerID, .evaluation]
                        : [.speakers]
                )
                settingsGroup("Library", panes: [.tags])
                settingsGroup("Integrations", panes: [.mcp])
            }
            .padding(14)
        }
        .frame(width: 200)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private func settingsGroup(_ title: String, panes: [SettingsPane]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)

            ForEach(panes) { pane in
                Button {
                    selection = pane
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: pane.icon)
                            .frame(width: 18)
                        Text(pane.shortTitle)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.body)
                    .foregroundStyle(selection == pane ? Color.accentColor : Color.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .background(
                        selection == pane ? Color.accentColor.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityValue(selection == pane ? "Selected" : "")
            }
        }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selection {
        case .general:
            GeneralSettingsView()
        case .recording:
            RecordingSettingsView()
        case .appearance:
            AppearanceSettingsView()
        case .dictation:
            RealtimeDictationSettingsView()
        case .transcription:
            TranscriptionSettingsView(onOpenModels: { selection = .models })
        case .models:
            ModelManagerView()
        case .speakers:
            SpeakerManagementView()
        case .speakerID:
            SpeakerPipelineSettingsView()
        case .evaluation:
            SpeakerEvaluationSettingsView()
        case .tags:
            TagManagementView()
        case .mcp:
            MCPSettingsView()
        }
    }
}

// MARK: - Settings Sub-views
struct GeneralSettingsView: View {
    @State private var showClearConfirmation = false
    @State private var isClearingData = false
    @State private var databaseSize: String = "Calculating..."
    @State private var showSuccessAlert = false
    @State private var showErrorAlert = false
    @State private var errorMessage: String = ""
    @AppStorage(MeetingMonitor.offerToRecordKey) private var offerToRecordMeetings = false
    @State private var showBackfillConfirmation = false
    @State private var mergingMeetings = false
    @State private var mergeMeetingsSummary: String?
    @ObservedObject private var backfill = SpeakerBackfillService.shared
    @ObservedObject private var voiceBackfill = VoiceEmbeddingBackfillService.shared
    @ObservedObject private var queue = TranscriptionQueueManager.shared
    @AppStorage("launchAtStartup") private var launchAtStartup = false
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("hasCompletedSetup") private var hasCompletedSetup = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at startup", isOn: $launchAtStartup)
                    .onChange(of: launchAtStartup) { LoginItem.setEnabled($0) }
                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                Text("The menu bar icon shows recording/queue status and quick actions.")
                    .font(.caption).foregroundColor(.secondary)

                HStack {
                    Button("Run Setup Again…") { hasCompletedSetup = false }
                    Spacer()
                }
            }
            .onAppear { launchAtStartup = LoginItem.isEnabled }

            Section("Meeting Recording") {
                Toggle("Offer to record my meetings", isOn: $offerToRecordMeetings)
                    .onChange(of: offerToRecordMeetings) { enabled in
                        if enabled { MeetingMonitor.shared.startMonitoring() }
                        else { MeetingMonitor.shared.stopMonitoring() }
                    }
                Text("When a meeting with other people is about to start, AlmRecorder asks if you want to record it. Requires Calendar access and the app running.")
                    .font(.caption).foregroundColor(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Merge Meeting Tracks").font(.headline)
                    Text("Fold each meeting's separate mic + system recordings into one, dropping the duplicate (echo) lines the mic picks up from your speakers. Fixes meetings that appear twice.")
                        .font(.caption).foregroundColor(.secondary)
                }
                if mergingMeetings {
                    ProgressView()
                } else {
                    HStack {
                        Button {
                            Task {
                                mergingMeetings = true
                                let n = await MeetingAssembler.foldAllExisting()
                                mergeMeetingsSummary = n == 0 ? "Nothing to merge." : "Merged \(n) meeting\(n == 1 ? "" : "s")."
                                mergingMeetings = false
                            }
                        } label: {
                            Label("Merge Meeting Tracks…", systemImage: "rectangle.stack.badge.minus")
                        }
                        .disabled(queue.isProcessing)
                        Spacer()
                    }
                    if let s = mergeMeetingsSummary {
                        Text(s).font(.caption).foregroundColor(.secondary)
                    }
                }
            }

            Section("Database & Data") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Clear All Data")
                            .font(.headline)
                        Text("Remove all recordings, transcriptions, and settings")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if isClearingData {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .scaleEffect(0.8)
                    } else {
                        Button(role: .destructive) {
                            showClearConfirmation = true
                        } label: {
                            Text("Clear Database...")
                        }
                        .disabled(isClearingData)
                    }
                }
                
                HStack {
                    Text("Database Size")
                    Spacer()
                    Text(databaseSize)
                        .foregroundColor(.secondary)
                }
            }

            Section("Speaker Identities") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Rebuild Speakers from Audio")
                        .font(.headline)
                    Text("Re-diarizes every recording with FluidAudio and unifies voices across files into stable, nameable speakers. Transcripts are untouched. Run when the queue is idle.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if backfill.isRunning {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(backfill.processed),
                                     total: Double(max(backfill.total, 1)))
                        Text(backfill.statusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    HStack {
                        Button {
                            showBackfillConfirmation = true
                        } label: {
                            Label("Rebuild Speakers…", systemImage: "person.2.wave.2")
                        }
                        .disabled(queue.isProcessing)
                        Spacer()
                    }
                    if let summary = backfill.lastSummary {
                        Text(summary).font(.caption).foregroundColor(.secondary)
                    } else if queue.isProcessing {
                        Text("Queue is busy — available when transcription is idle.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Rebuild Voice Fingerprints")
                        .font(.headline)
                    Text("Stores a per-line voice fingerprint for every utterance so the People page can flag and fix mis-assigned lines. Doesn't change who said what. Run when the queue is idle.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if voiceBackfill.isRunning {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(voiceBackfill.processed),
                                     total: Double(max(voiceBackfill.total, 1)))
                        Text(voiceBackfill.statusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    HStack {
                        Button {
                            Task { await voiceBackfill.run() }
                        } label: {
                            Label("Rebuild Voice Fingerprints…", systemImage: "waveform.badge.magnifyingglass")
                        }
                        .disabled(queue.isProcessing)
                        Spacer()
                    }
                    if let summary = voiceBackfill.lastSummary {
                        Text(summary).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            updateDatabaseSize()
        }
        .alert("Clear All Data?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear All Data", role: .destructive) {
                clearAllData()
            }
        } message: {
            Text("This will permanently delete all recordings, transcriptions, and settings. This action cannot be undone.")
        }
        .alert("Data Cleared Successfully", isPresented: $showSuccessAlert) {
            Button("OK") { 
                // Restart app or refresh state
                NotificationCenter.default.post(name: NSNotification.Name("RefreshAppState"), object: nil)
            }
        } message: {
            Text("All data has been cleared. The app will refresh.")
        }
        .alert("Error Clearing Data", isPresented: $showErrorAlert) {
            Button("OK") { }
        } message: {
            Text(errorMessage.isEmpty ? "Failed to clear database. Please try again or restart the app." : errorMessage)
        }
        .alert("Rebuild Speakers from Audio?", isPresented: $showBackfillConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Rebuild", role: .destructive) {
                Task { await backfill.run() }
            }
        } message: {
            Text("This clears the current speaker set (including any names and merges) and rebuilds it by re-diarizing every recording. Transcript text is not affected. This can take a while for large libraries.")
        }
    }

    private func updateDatabaseSize() {
        Task {
            let size = await calculateDatabaseSize()
            await MainActor.run {
                self.databaseSize = formatBytes(size)
            }
        }
    }
    
    private func calculateDatabaseSize() async -> Int64 {
        var totalSize: Int64 = 0
        
        // Get database file size
        let dbPath = GRDBDatabaseManager.shared.databasePath
        if let attributes = try? FileManager.default.attributesOfItem(atPath: dbPath) {
            totalSize += attributes[.size] as? Int64 ?? 0
        }
        
        // Add WAV cache size
        totalSize += WAVCacheManager.shared.getCacheSize()
        
        // Add temp files size
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("AlmRecorder")
        totalSize += getDirectorySize(tempDir)
        
        return totalSize
    }
    
    private func getDirectorySize(_ url: URL) -> Int64 {
        var size: Int64 = 0
        let fileManager = FileManager.default
        
        if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path) {
                    size += attributes[.size] as? Int64 ?? 0
                }
            }
        }
        
        return size
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }
    
    private func clearAllData() {
        isClearingData = true
        errorMessage = ""
        
        Task {
            do {
                // Clear database with comprehensive wipe
                try await GRDBDatabaseManager.shared.clearAllDataComprehensive()
                
                await MainActor.run {
                    isClearingData = false
                    showSuccessAlert = true
                    updateDatabaseSize()
                    
                    // Post notification to refresh UI
                    NotificationCenter.default.post(name: NSNotification.Name("DatabaseCleared"), object: nil)
                }
            } catch {
                await MainActor.run {
                    isClearingData = false
                    errorMessage = "Error: \(error.localizedDescription)"
                    showErrorAlert = true
                    print("Failed to clear data: \(error)")
                }
            }
        }
    }
}

struct TranscriptionSettingsView: View {
    let onOpenModels: () -> Void

    @ObservedObject private var modelSettings = GlobalModelSettings.shared
    @StateObject private var cleanupManager = ModelCleanupManager.shared
    @State private var showingCleanup = false
    @State private var diskUsage: Int64 = 0
    @State private var availableSpace: Int64 = 0
    
    var body: some View {
        Form {
            Section("Current Default") {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: backendIcon)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 30)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(currentEngine)
                            .font(.headline)
                        Text(currentModel)
                            .foregroundStyle(.secondary)
                        Text("New jobs copy this selection when they enter the queue, so queued work never changes unexpectedly.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Label("In use", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }

                if let speakerHandling {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Speaker handling")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(speakerHandling)
                            .font(.callout.weight(.medium))
                    }
                }

                HStack {
                    Button(action: onOpenModels) {
                        Label("Change transcription model…", systemImage: "cpu")
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Clean Up Model Storage…") {
                        showingCleanup = true
                    }

                    Spacer()
                }
            }

            NightlyRetranscriptionSettingsView()
            
            Section("Storage") {
                HStack {
                    Image(systemName: "internaldrive")
                        .foregroundColor(storageStatusColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Downloaded models: \(formatBytes(diskUsage))")
                            .font(.callout)
                        Text("\(formatBytes(availableSpace)) available on this Mac")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if availableSpace < 5_000_000_000 {
                        Text("Low space")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.orange.opacity(0.15), in: Capsule())
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { updateDiskUsage() }
        .sheet(isPresented: $showingCleanup) {
            ModelCleanupView()
                .onDisappear { updateDiskUsage() }
        }
    }

    private var currentEngine: String {
        switch modelSettings.transcriptionBackend {
        case .whisper: return "Whisper"
        case .llm: return modelSettings.selectedLLMEngine.rawValue
        case .vibeVoice: return "VibeVoice"
        }
    }

    private var currentModel: String {
        switch modelSettings.transcriptionBackend {
        case .whisper:
            return modelSettings.selectedWhisperVariant?.toIdentifier()
                ?? modelSettings.selectedWhisperModel
        case .llm:
            switch modelSettings.selectedLLMEngine {
            case .voxtral: return modelSettings.selectedVoxtralTranscriptionModel
            case .gemma: return modelSettings.selectedGemmaTranscriptionModel
            }
        case .vibeVoice:
            return modelSettings.selectedVibeVoiceQuantization.displayName
        }
    }

    private var speakerHandling: String? {
        guard modelSettings.transcriptionBackend == .vibeVoice else { return nil }
        return modelSettings.vibeVoiceSpeakerMode.displayName
    }

    private var backendIcon: String {
        switch modelSettings.transcriptionBackend {
        case .whisper: return "waveform.badge.mic"
        case .llm: return "brain"
        case .vibeVoice: return "person.2.wave.2"
        }
    }
    
    private var storageStatusColor: Color {
        let availableGB = Double(availableSpace) / (1024 * 1024 * 1024)
        if availableGB < 1 {
            return .red
        } else if availableGB < 5 {
            return .orange
        } else {
            return .green
        }
    }
    
    private func updateDiskUsage() {
        diskUsage = cleanupManager.getTotalDiskUsage()
        
        let fileManager = FileManager.default
        let modelsDir = VoxtralConfiguration.modelsDirectory
        
        do {
            let attributes = try fileManager.attributesOfFileSystem(forPath: modelsDir.path)
            if let freeSpace = attributes[.systemFreeSize] as? NSNumber {
                availableSpace = freeSpace.int64Value
            }
        } catch {
            print("Failed to get disk space: \(error)")
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct RecordingSettingsView: View {
    @AppStorage("chunkDuration") private var chunkDuration = 600.0
    @AppStorage("audioQuality") private var audioQuality = "high"
    
    var body: some View {
        Form {
            Section("Audio Settings") {
                Picker("Quality:", selection: $audioQuality) {
                    Text("Low (64 kbps)").tag("low")
                    Text("Medium (128 kbps)").tag("medium")
                    Text("High (256 kbps)").tag("high")
                    Text("Lossless").tag("lossless")
                }
                
                VStack(alignment: .leading) {
                    Text("Chunk Duration: \(Int(chunkDuration / 60)) minutes")
                    Slider(value: $chunkDuration, in: 300...1800, step: 300)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct AppearanceSettingsView: View {
    @AppStorage("colorScheme") private var colorScheme = "auto"
    @AppStorage("accentColor") private var accentColor = "blue"
    
    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $colorScheme) {
                    ForEach(AppAppearanceChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text("System follows your current macOS appearance automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Section("Accent Color") {
                HStack(spacing: 14) {
                    ForEach(AppAccentChoice.allCases) { choice in
                        Button {
                            accentColor = choice.rawValue
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(choice.color)
                                    .frame(width: 34, height: 34)

                                if accentColor == choice.rawValue {
                                    Image(systemName: "checkmark")
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                }
                            }
                            .padding(3)
                            .overlay(
                                Circle()
                                    .stroke(
                                        accentColor == choice.rawValue
                                            ? Color.primary.opacity(0.8)
                                            : Color.secondary.opacity(0.25),
                                        lineWidth: accentColor == choice.rawValue ? 2 : 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(choice.displayName)
                        .accessibilityValue(accentColor == choice.rawValue ? "Selected" : "")
                    }
                }

                Text("Applied to navigation, primary actions, progress, and selection throughout AlmRecorder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct MCPSettingsView: View {
    @ObservedObject private var controller = MCPServiceController.shared
    @State private var copied = false
    @State private var confirmRotation = false
    @State private var availableRecordingCount = 0
    @State private var hiddenRecordingCount = 0

    private let recordingRepository = GRDBRecordingRepository()

    private var enabled: Binding<Bool> {
        Binding(
            get: { controller.isEnabled },
            set: { controller.setEnabled($0) }
        )
    }

    private var transcriptAccess: Binding<Bool> {
        Binding(
            get: { controller.credential.allowTranscripts },
            set: { controller.setTranscriptAccess($0) }
        )
    }

    private var writeAccess: Binding<Bool> {
        Binding(
            get: { controller.credential.allowWrites },
            set: { controller.setWriteAccess($0) }
        )
    }

    private var clientConfigurationPreview: String {
        let configuration = controller.clientConfigurationJSON
        return configuration.replacingOccurrences(
            of: #"("ALMRECORDER_MCP_TOKEN"\s*:\s*")[^"]*(")"#,
            with: #"$1<secret token hidden — use Copy configuration>$2"#,
            options: .regularExpression
        )
    }

    var body: some View {
        Form {
            Section("Model Context Protocol") {
                Toggle("Enable local MCP server", isOn: enabled)
                LabeledContent("Status") {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(controller.isRunning ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                        Text(controller.statusMessage)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("The server is available only while AlmRecorder is open. It listens on a user-only Unix socket; the bundled bridge provides standard MCP over stdio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Client access") {
                Toggle(
                    "Allow content, notes, comments, summaries, and transcript search",
                    isOn: transcriptAccess
                )
                Toggle("Allow tags, notes, and comments to be changed", isOn: writeAccess)
                Text("Enabling MCP exposes metadata only. Content and write access are separate. Notes and comments require both content and write access; tag changes require write access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recording privacy") {
                LabeledContent("Available to MCP") {
                    Text("\(availableRecordingCount)")
                        .monospacedDigit()
                }
                LabeledContent("Hidden from MCP") {
                    Text("\(hiddenRecordingCount)")
                        .monospacedDigit()
                }
                Label(
                    "Individual recordings can be hidden from MCP in their detail view.",
                    systemImage: "network.slash"
                )
                Label(
                    "Tags can automatically hide every recording carrying that tag.",
                    systemImage: "tag"
                )
                Text("Recording and tag restrictions override every global permission. Hidden recordings are treated as nonexistent across search, resources, meeting notes, comments, writes, and library statistics. MCP clients cannot change privacy-blocking tags.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Client configuration") {
                ScrollView(.horizontal) {
                    Text(verbatim: clientConfigurationPreview)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 150, maxHeight: 220)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                HStack {
                    Button(copied ? "Copied" : "Copy configuration") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            controller.clientConfigurationJSON,
                            forType: .string
                        )
                        copied = true
                    }
                    Button("Rotate token…", role: .destructive) {
                        confirmRotation = true
                    }
                    Spacer()
                }
                Text("The secret token is hidden in this preview. Copying includes it, so store the copied configuration like a password. Rotating the token disconnects existing clients until their configuration is updated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear(perform: refreshPrivacyCounts)
        .onReceive(
            NotificationCenter.default.publisher(for: .mcpRecordingPrivacyDidChange)
        ) { _ in
            refreshPrivacyCounts()
        }
        .confirmationDialog(
            "Rotate MCP token?",
            isPresented: $confirmRotation,
            titleVisibility: .visible
        ) {
            Button("Rotate token", role: .destructive) {
                controller.rotateToken()
                copied = false
            }
        } message: {
            Text("Existing MCP client configurations will stop working.")
        }
    }

    private func refreshPrivacyCounts() {
        guard let counts = try? recordingRepository.mcpAvailabilityCounts() else {
            return
        }
        availableRecordingCount = counts.available
        hiddenRecordingCount = counts.hidden
    }
}
