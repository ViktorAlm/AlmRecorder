import SwiftUI
import AVFoundation
import Combine
import os.log

private let audioLog = Logger(subsystem: "com.almrecorder", category: "AudioSegmentPlayer")

struct AudioSegmentPlayer: View {
    let segment: AudioSegment
    let audioFilePath: String
    @StateObject private var player = AudioPlayerViewModel()
    @State private var waveform: [Float] = []
    @State private var isLoadingAudio = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Text preview
            Text(segment.text)
                .font(.system(.body, design: .rounded))
                .foregroundColor(.primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            // Waveform and controls
            HStack(spacing: 12) {
                // Play/Pause button
                Button(action: togglePlayback) {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(player.isPlaying ? .orange : .blue)
                }
                .buttonStyle(.plain)
                .disabled(isLoadingAudio)
                
                // Waveform visualization
                WaveformView(
                    waveform: waveform,
                    progress: player.progress,
                    isPlaying: player.isPlaying
                )
                .frame(height: 40)
                
                // Duration label
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatTime(player.currentTime))
                        .font(.system(.caption, design: .monospaced))
                    Text(formatTime(player.duration))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .frame(width: 45)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
        .onAppear {
            loadAudioSegment()
        }
        .onDisappear {
            player.stop()
        }
    }
    
    private func togglePlayback() {
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }
    
    private func loadAudioSegment() {
        guard !isLoadingAudio else { return }
        isLoadingAudio = true
        
        Task {
            do {
                // Log segment details for debugging
                audioLog.debug("Loading segment: \(segment.startTime)s - \(segment.endTime)s from: \(audioFilePath)")
                
                // Verify audio file exists
                guard FileManager.default.fileExists(atPath: audioFilePath) else {
                    audioLog.error("Audio file not found at path: \(audioFilePath)")
                    await MainActor.run {
                        isLoadingAudio = false
                    }
                    return
                }
                
                // Extract audio segment
                let audioData = try await AudioSegmentExtractor.shared.extractSegment(
                    from: audioFilePath,
                    startTime: segment.startTime,
                    endTime: segment.endTime
                )
                
                audioLog.debug("Extracted audio segment, size: \(audioData.count) bytes")
                
                // Validate extracted data
                guard !audioData.isEmpty else {
                    audioLog.error("Extracted audio data is empty")
                    await MainActor.run {
                        isLoadingAudio = false
                    }
                    return
                }
                
                // Generate waveform
                let waveformData = AudioSegmentExtractor.shared.generateWaveform(
                    from: audioData,
                    targetSamples: 80
                )
                
                audioLog.debug("Generated waveform with \(waveformData.count) samples")
                
                await MainActor.run {
                    self.waveform = waveformData
                    isLoadingAudio = false
                }
                
                // Load audio into player
                await player.loadAudioData(audioData)
                
            } catch let error as NSError {
                audioLog.error("Failed to load audio segment: \(error.localizedDescription) (domain: \(error.domain), code: \(error.code))")
                
                await MainActor.run {
                    isLoadingAudio = false
                    // Show error state in UI
                    self.waveform = Array(repeating: 0, count: 80)
                }
            }
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Waveform View

struct WaveformView: View {
    let waveform: [Float]
    let progress: Double
    let isPlaying: Bool
    
    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<waveform.count, id: \.self) { index in
                    WaveformBar(
                        amplitude: waveform[index],
                        isPlayed: Double(index) / Double(waveform.count) < progress,
                        isPlaying: isPlaying
                    )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

struct WaveformBar: View {
    let amplitude: Float
    let isPlayed: Bool
    let isPlaying: Bool
    
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(barColor)
            .frame(height: CGFloat(amplitude) * 40)
            .animation(.easeInOut(duration: 0.1), value: isPlayed)
    }
    
    private var barColor: Color {
        if isPlayed {
            return isPlaying ? .orange : .blue
        } else {
            return .gray.opacity(0.3)
        }
    }
}

// MARK: - Audio Player View Model

@MainActor
class AudioPlayerViewModel: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var progress: Double = 0
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    
    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?
    
    override init() {
        super.init()
        setupAudioSession()
    }
    
    private func setupAudioSession() {
        // Note: AVAudioSession is not available on macOS
        // Audio playback on macOS is handled directly by AVAudioPlayer
        // No additional session setup is required
    }
    
    func loadAudioData(_ data: Data) async {
        do {
            // Validate data is not empty
            guard !data.isEmpty else {
                audioLog.error("Audio data is empty")
                return
            }
            
            // Check if data appears to be WAV format (starts with "RIFF")
            let wavHeader = data.prefix(4)
            let isWAV = wavHeader == Data([0x52, 0x49, 0x46, 0x46]) // "RIFF"
            
            if !isWAV {
                audioLog.warning("Audio data may not be in WAV format")
            }
            
            // Create temporary file for audio data
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("wav")
            
            try data.write(to: tempURL)
            
            // Verify file was written successfully
            let fileSize = try FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64 ?? 0
            audioLog.debug("Wrote audio file: \(tempURL.lastPathComponent), size: \(fileSize) bytes")
            
            // Try to create audio player
            audioPlayer = try AVAudioPlayer(contentsOf: tempURL)
            audioPlayer?.delegate = self
            
            // Verify player was created successfully
            guard let player = audioPlayer else {
                audioLog.error("Failed to create AVAudioPlayer")
                try? FileManager.default.removeItem(at: tempURL)
                return
            }
            
            // Prepare to play and get duration
            let prepared = player.prepareToPlay()
            audioLog.debug("Audio prepared: \(prepared), duration: \(player.duration)s")
            
            await MainActor.run {
                duration = player.duration
                
                // If duration is 0 or invalid, there might be an issue
                if duration <= 0 {
                    audioLog.warning("Invalid audio duration: \(self.duration)")
                }
            }
            
            // Clean up temp file after a delay
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                try? FileManager.default.removeItem(at: tempURL)
            }
            
        } catch let error as NSError {
            audioLog.error("Failed to load audio: \(error.localizedDescription) (code: \(error.code), domain: \(error.domain))")
        }
    }
    
    func play() {
        audioPlayer?.play()
        isPlaying = true
        startProgressTimer()
    }
    
    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopProgressTimer()
    }
    
    func stop() {
        audioPlayer?.stop()
        audioPlayer?.currentTime = 0
        isPlaying = false
        progress = 0
        currentTime = 0
        stopProgressTimer()
    }
    
    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor in
                self.updateProgress()
            }
        }
    }
    
    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
    
    @MainActor
    private func updateProgress() {
        guard let player = audioPlayer else { return }
        currentTime = player.currentTime
        if duration > 0 {
            progress = currentTime / duration
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension AudioPlayerViewModel: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.progress = 1.0
            self.stopProgressTimer()
        }
    }
}