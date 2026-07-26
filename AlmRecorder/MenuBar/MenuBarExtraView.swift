import SwiftUI

/// View for the menu bar extra dropdown
struct MenuBarExtraView: View {
    @StateObject private var controller = MenuBarController.shared
    @StateObject private var modelSettings = GlobalModelSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header with recording button
            recordingSection
                .padding(.vertical, 8)
            
            Divider()
            
            // Quick actions
            quickActionsSection
                .padding(.vertical, 4)
            
            if !controller.recentTranscriptions.isEmpty {
                Divider()
                recentSection
                    .padding(.vertical, 4)
            }
            
            Divider()
            
            // App controls
            appControlsSection
                .padding(.vertical, 4)
        }
        .frame(width: 280)
    }
    
    // MARK: - Recording Section
    
    private var recordingSection: some View {
        VStack(spacing: 8) {
            // Big record button
            Button(action: { controller.toggleRecording() }) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(controller.isRecording ? Color.red : Color.blue)
                            .frame(width: 40, height: 40)
                        
                        Image(systemName: controller.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(controller.isRecording ? "Recording..." : "Start Recording")
                            .font(.system(size: 14, weight: .medium))
                        
                        if controller.isRecording {
                            Text(controller.formatDuration(controller.recordingDuration))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                        } else {
                            Text("Click to start")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    if controller.isRecording {
                        // Animated recording indicator
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(controller.isRecording ? Color.red.opacity(0.1) : Color.blue.opacity(0.1))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            
            // Current model info
            HStack {
                Image(systemName: "cpu")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text(currentModelInfo())
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
            }
            .padding(.horizontal, 12)
        }
    }
    
    // MARK: - Quick Actions
    
    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Semantic Search
            MenuButton(
                title: "Semantic Search",
                icon: "magnifyingglass.circle",
                shortcut: "⇧⌘F"
            ) {
                controller.openSemanticSearch()
            }
            
            // Transcribe File
            MenuButton(
                title: "Transcribe File...",
                icon: "doc.badge.waveform",
                shortcut: "⌘O"
            ) {
                showFileImporter()
            }
            
            // Voice Memos
            MenuButton(
                title: "Process Voice Memos",
                icon: "recordingtape",
                shortcut: nil
            ) {
                processVoiceMemos()
            }
            
            // Queue Status
            if controller.queueCount > 0 || controller.isProcessing {
                HStack {
                    Image(systemName: "tray.full")
                        .font(.caption)
                        .frame(width: 20)
                    
                    Text("Queue: \(controller.queueCount) items")
                        .font(.caption)
                    
                    Spacer()
                    
                    if controller.isProcessing {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 16, height: 16)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - Recent Transcriptions
    
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            
            ForEach(controller.recentTranscriptions) { item in
                Button(action: {
                    controller.copyTranscriptToClipboard(item.transcript)
                }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.fileName)
                                .font(.caption)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            
                            Text(item.truncatedTranscript)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "doc.on.clipboard")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .background(Color.primary.opacity(0.01))
            }
        }
    }
    
    // MARK: - App Controls
    
    private var appControlsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuButton(
                title: "Open AlmRecorder",
                icon: "app.badge",
                shortcut: nil
            ) {
                controller.openMainWindow()
            }
            
            MenuButton(
                title: "Settings...",
                icon: "gearshape",
                shortcut: "⌘,"
            ) {
                openSettings()
            }
            
            Divider()
                .padding(.vertical, 4)
            
            MenuButton(
                title: "Quit",
                icon: "power",
                shortcut: "⌘Q"
            ) {
                NSApplication.shared.terminate(nil)
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func currentModelInfo() -> String {
        switch modelSettings.transcriptionBackend {
        case .whisper:
            if let variant = modelSettings.selectedWhisperVariant {
                let sizeStr = formatBytes(variant.estimatedSize)
                return "Whisper: \(variant.displayName) (\(sizeStr))"
            } else if !modelSettings.selectedWhisperModel.isEmpty {
                // Fallback to legacy model name
                return "Whisper: \(modelSettings.selectedWhisperModel)"
            }
            return "Whisper: No model"
        case .llm:
            switch modelSettings.selectedLLMEngine {
            case .voxtral: return "Voxtral: \(modelSettings.selectedVoxtralTranscriptionModel)"
            case .gemma: return "Gemma: \(modelSettings.selectedGemmaTranscriptionModel)"
            }
        case .vibeVoice:
            return "VibeVoice: \(modelSettings.selectedVibeVoiceQuantization.displayName)"
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
    
    private func showFileImporter() {
        let panel = NSOpenPanel()
        panel.title = "Select Audio File"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie]
        
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                _ = await UnifiedTranscriptionManager.shared.transcribe(
                    audioFile: url.path,
                    source: .imported,
                    language: "auto-detected"
                )
            }
        }
    }
    
    private func processVoiceMemos() {
        controller.openMainWindow()
        // Navigate to voice memos
        NotificationCenter.default.post(
            name: Notification.Name("NavigateToVoiceMemos"),
            object: nil
        )
    }
    
    private func openSettings() {
        controller.openMainWindow()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

// MARK: - Menu Button Component

struct MenuButton: View {
    let title: String
    let icon: String
    let shortcut: String?
    let action: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .font(.caption)
                    .frame(width: 20)
                
                Text(title)
                    .font(.system(size: 13))
                
                Spacer()
                
                if let shortcut = shortcut {
                    Text(shortcut)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isHovering ? Color.primary.opacity(0.05) : Color.clear)
            .onHover { hovering in
                isHovering = hovering
            }
        }
        .buttonStyle(.plain)
    }
}
