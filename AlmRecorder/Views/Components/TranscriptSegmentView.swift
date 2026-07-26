import SwiftUI
import AVFoundation

struct TranscriptSegmentView: View {
    let utterance: Utterance
    let displayMode: DisplayMode
    let audioPath: String?
    let currentSpeaker: String? // For chat bubble alignment
    /// Resolves the GLOBAL speaker identity (uuid → name / stable placeholder). The local
    /// `utterance.speaker` label is only used when there is no `speakerUuid`. Callers build this
    /// from the speakers table; the empty default still upgrades a clustered line to its stable
    /// global label rather than the per-recording "Speaker N".
    var speakerResolver: SpeakerNameResolver = SpeakerNameResolver()
    
    @State private var isPlaying = false
    @StateObject private var player = AudioPlayerViewModel()
    @State private var isLoadingAudio = false
    @State private var waveform: [Float] = []
    @Environment(\.colorScheme) var colorScheme
    
    enum DisplayMode {
        case chatBubble    // WhatsApp/iMessage style
        case card          // Current search result style
        case row           // Compact list row
        case timeline      // With timestamp on left
    }
    
    var body: some View {
        Group {
            switch displayMode {
            case .chatBubble:
                chatBubbleView
            case .card:
                cardView
            case .row:
                rowView
            case .timeline:
                timelineView
            }
        }
        // Universal line actions (right-click): edit with provenance, or mark as trash —
        // which hides the line, teaches the exemplar memory, and sweeps for lookalikes.
        .utteranceActions(utteranceId: utterance.id, text: utterance.text)
    }
    
    // MARK: - Chat Bubble View
    
    private var chatBubbleView: some View {
        let isCurrentSpeaker = utterance.speaker == currentSpeaker
        
        return HStack(alignment: .bottom, spacing: 8) {
            if !isCurrentSpeaker {
                speakerAvatar(size: 32)
            }
            
            VStack(alignment: isCurrentSpeaker ? .trailing : .leading, spacing: 4) {
                if !isCurrentSpeaker && utterance.speaker != nil {
                    Text(speakerDisplayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                }
                
                HStack(spacing: 8) {
                    if isCurrentSpeaker { Spacer(minLength: 60) }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text(utterance.text)
                            .font(.body)
                            .foregroundColor(isCurrentSpeaker ? .white : .primary)
                            .textSelection(.enabled)
                        
                        if audioPath != nil {
                            playbackControls(compact: true, lightMode: isCurrentSpeaker)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground(isCurrentSpeaker: isCurrentSpeaker))
                    .clipShape(BubbleShape(isCurrentSpeaker: isCurrentSpeaker))
                    
                    if !isCurrentSpeaker { Spacer(minLength: 60) }
                }
                
                HStack(spacing: 4) {
                    if utterance.hasEmbedding {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                    }
                    
                    Text(formatTimestamp(utterance.startTime))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 4)
            }
            
            if isCurrentSpeaker {
                speakerAvatar(size: 32)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
    
    // MARK: - Card View
    
    private var cardView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                speakerAvatar(size: 40)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(speakerDisplayName)
                        .font(.headline)
                    
                    HStack(spacing: 8) {
                        Label(formatTimestamp(utterance.startTime), systemImage: "clock")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        if utterance.hasEmbedding {
                            Label("Indexed", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                }
                
                Spacer()
                
                if let confidence = utterance.confidence, confidence > 0 {
                    confidenceBadge(confidence)
                }
            }
            
            // Content
            Text(utterance.text)
                .font(.body)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
            
            // Playback controls
            if audioPath != nil {
                playbackControls(compact: false, lightMode: false)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
    
    // MARK: - Row View
    
    private var rowView: some View {
        HStack(alignment: .top, spacing: 12) {
            speakerAvatar(size: 36)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(speakerDisplayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Text("• \(formatTimestamp(utterance.startTime))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    if audioPath != nil {
                        playButton(size: 24)
                    }
                }
                
                Text(utterance.text)
                    .font(.body)
                    .lineLimit(2)
                    .foregroundColor(.primary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }
    
    // MARK: - Timeline View
    
    private var timelineView: some View {
        HStack(alignment: .top, spacing: 16) {
            // Time column
            VStack(alignment: .trailing, spacing: 4) {
                Text(formatTime(utterance.startTime))
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                
                if utterance.duration > 0 {
                    Text(formatDuration(utterance.duration))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
            .frame(width: 60)
            
            // Timeline indicator
            VStack(spacing: 0) {
                Circle()
                    .fill(speakerColor)
                    .frame(width: 10, height: 10)
                
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 2)
            }
            
            // Content
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    speakerAvatar(size: 28)
                    
                    Text(speakerDisplayName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    Spacer()
                    
                    if audioPath != nil {
                        playButton(size: 20)
                    }
                }
                
                Text(utterance.text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                
                if utterance.hasEmbedding {
                    Label("Indexed", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            .padding(.bottom, 16)
        }
    }
    
    // MARK: - Shared Components
    
    private func speakerAvatar(size: CGFloat) -> some View {
        Circle()
            .fill(speakerColor)
            .frame(width: size, height: size)
            .overlay(
                Text(speakerInitials)
                    .font(.system(size: size * 0.4))
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
            )
    }
    
    private var speakerColor: Color {
        Color.speakerColor(uuid: utterance.speakerUuid, label: utterance.speaker)
    }
    
    private var speakerInitials: String {
        let name = speakerResolver.displayName(for: utterance) ?? "?"
        let parts = name.split(separator: " ")

        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        } else if let first = parts.first {
            return String(first.prefix(2)).uppercased()
        } else {
            return "?"
        }
    }

    private var speakerDisplayName: String {
        speakerResolver.displayName(for: utterance) ?? "Unknown Speaker"
    }
    
    private func playButton(size: CGFloat) -> some View {
        Button(action: togglePlayback) {
            Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: size))
                .foregroundStyle(isPlaying ? .orange : .blue)
        }
        .buttonStyle(.plain)
        .disabled(isLoadingAudio)
    }
    
    private func playbackControls(compact: Bool, lightMode: Bool) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            playButton(size: compact ? 20 : 24)
            
            if !compact && !waveform.isEmpty {
                WaveformView(
                    waveform: waveform,
                    progress: player.progress,
                    isPlaying: isPlaying
                )
                .frame(height: 30)
                .frame(maxWidth: 200)
            }
            
            Text(formatDuration(player.duration > 0 ? player.currentTime : utterance.duration))
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(lightMode ? .white.opacity(0.9) : .secondary)
        }
    }
    
    private func confidenceBadge(_ confidence: Float) -> some View {
        let percentage = Int(confidence * 100)
        let color = confidence > 0.8 ? Color.green : confidence > 0.6 ? Color.orange : Color.red
        
        return HStack(spacing: 4) {
            Image(systemName: "chart.bar.fill")
                .font(.caption2)
            Text("\(percentage)%")
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(color.opacity(0.15))
        .cornerRadius(4)
    }
    
    private func bubbleBackground(isCurrentSpeaker: Bool) -> some View {
        Group {
            if isCurrentSpeaker {
                Color.blue
            } else {
                Color(NSColor.controlBackgroundColor)
            }
        }
    }
    
    // MARK: - Audio Playback
    
    private func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            loadAndPlay()
        }
    }
    
    private func loadAndPlay() {
        guard let audioPath = audioPath, !isLoadingAudio else { return }
        isLoadingAudio = true
        
        Task {
            do {
                let audioData = try await AudioSegmentExtractor.shared.extractSegment(
                    from: audioPath,
                    startTime: utterance.startTime,
                    endTime: utterance.endTime,
                    padding: 0.1
                )
                
                // Generate waveform if needed
                if displayMode == .card || (displayMode == .chatBubble && !waveform.isEmpty) {
                    let waveformData = AudioSegmentExtractor.shared.generateWaveform(
                        from: audioData,
                        targetSamples: 60
                    )
                    await MainActor.run {
                        self.waveform = waveformData
                    }
                }
                
                await player.loadAudioData(audioData)
                
                await MainActor.run {
                    isLoadingAudio = false
                    player.play()
                    isPlaying = true
                    setupPlaybackCompletion()
                }
                
            } catch {
                print("Failed to load audio segment: \(error)")
                await MainActor.run {
                    isLoadingAudio = false
                }
            }
        }
    }
    
    private func setupPlaybackCompletion() {
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            Task { @MainActor in
                if player.progress >= 0.99 || !player.isPlaying {
                    isPlaying = false
                    timer.invalidate()
                }
            }
        }
    }
    
    // MARK: - Formatting
    
    private func formatTimestamp(_ time: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = time >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: time) ?? "0:00"
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        let seconds = Int(time) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "%.1fs", duration)
        } else if duration < 60 {
            return "\(Int(duration))s"
        } else {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

// MARK: - Bubble Shape

struct BubbleShape: Shape {
    let isCurrentSpeaker: Bool
    
    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 16
        let tailSize: CGFloat = 8
        
        var path = Path()
        
        if isCurrentSpeaker {
            // Right-aligned bubble with tail on right
            path.move(to: CGPoint(x: radius, y: 0))
            path.addLine(to: CGPoint(x: rect.width - radius - tailSize, y: 0))
            path.addArc(center: CGPoint(x: rect.width - radius - tailSize, y: radius),
                       radius: radius,
                       startAngle: .degrees(-90),
                       endAngle: .degrees(0),
                       clockwise: false)
            
            // Tail
            path.addLine(to: CGPoint(x: rect.width - tailSize, y: rect.height - radius))
            path.addQuadCurve(to: CGPoint(x: rect.width, y: rect.height),
                             control: CGPoint(x: rect.width - tailSize, y: rect.height))
            path.addQuadCurve(to: CGPoint(x: rect.width - tailSize - radius, y: rect.height),
                             control: CGPoint(x: rect.width - tailSize, y: rect.height))
            
            path.addLine(to: CGPoint(x: radius, y: rect.height))
            path.addArc(center: CGPoint(x: radius, y: rect.height - radius),
                       radius: radius,
                       startAngle: .degrees(90),
                       endAngle: .degrees(180),
                       clockwise: false)
            path.addLine(to: CGPoint(x: 0, y: radius))
            path.addArc(center: CGPoint(x: radius, y: radius),
                       radius: radius,
                       startAngle: .degrees(180),
                       endAngle: .degrees(270),
                       clockwise: false)
        } else {
            // Left-aligned bubble with tail on left
            path.move(to: CGPoint(x: radius + tailSize, y: 0))
            path.addLine(to: CGPoint(x: rect.width - radius, y: 0))
            path.addArc(center: CGPoint(x: rect.width - radius, y: radius),
                       radius: radius,
                       startAngle: .degrees(-90),
                       endAngle: .degrees(0),
                       clockwise: false)
            path.addLine(to: CGPoint(x: rect.width, y: rect.height - radius))
            path.addArc(center: CGPoint(x: rect.width - radius, y: rect.height - radius),
                       radius: radius,
                       startAngle: .degrees(0),
                       endAngle: .degrees(90),
                       clockwise: false)
            
            path.addLine(to: CGPoint(x: radius + tailSize, y: rect.height))
            
            // Tail
            path.addQuadCurve(to: CGPoint(x: tailSize, y: rect.height),
                             control: CGPoint(x: tailSize + radius, y: rect.height))
            path.addQuadCurve(to: CGPoint(x: 0, y: rect.height),
                             control: CGPoint(x: tailSize, y: rect.height))
            path.addQuadCurve(to: CGPoint(x: tailSize, y: rect.height - radius),
                             control: CGPoint(x: tailSize, y: rect.height))
            
            path.addLine(to: CGPoint(x: tailSize, y: radius))
            path.addArc(center: CGPoint(x: radius + tailSize, y: radius),
                       radius: radius,
                       startAngle: .degrees(180),
                       endAngle: .degrees(270),
                       clockwise: false)
        }
        
        return path
    }
}