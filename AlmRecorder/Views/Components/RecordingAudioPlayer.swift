import SwiftUI
import AVFoundation

/// Full-recording audio player: loads the whole audio file once and supports play / pause / seek /
/// scrub, plus a published `currentTime` so a transcript can highlight the line being spoken and
/// jump playback to any utterance. Unlike the per-segment player, this never extracts WAV slices —
/// it plays the original file (m4a/wav) directly, so seeking around the transcript is instant.
@MainActor
final class RecordingPlayerViewModel: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isLoaded = false
    @Published var loadError: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    /// Load the file once. Safe to call repeatedly (no-op after the first successful load).
    func load(path: String) {
        guard player == nil else { return }
        guard FileManager.default.fileExists(atPath: path) else {
            loadError = "Audio file not found"
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            p.delegate = self
            p.prepareToPlay()
            player = p
            duration = p.duration
            isLoaded = true
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard let p = player else { return }
        p.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        currentTime = 0
        stopTimer()
    }

    /// Jump to a time (e.g. an utterance start) and, by default, start playing from there.
    func seek(to time: TimeInterval, autoplay: Bool = true) {
        guard let p = player else { return }
        p.currentTime = max(0, min(time, p.duration))
        currentTime = p.currentTime
        if autoplay && !isPlaying { play() }
    }

    /// Used by the scrubber while dragging — moves the playhead without toggling play state.
    func scrub(to time: TimeInterval) {
        guard let p = player else { return }
        p.currentTime = max(0, min(time, p.duration))
        currentTime = p.currentTime
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let p = player else { return }
        currentTime = p.currentTime
    }
}

extension RecordingPlayerViewModel: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = 0
            self.stopTimer()
        }
    }
}

/// Compact transport bar: play/pause, a draggable scrubber, and current / total time.
struct RecordingPlayerBar: View {
    @ObservedObject var player: RecordingPlayerViewModel

    var body: some View {
        HStack(spacing: 12) {
            Button(action: player.togglePlay) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(player.isLoaded ? Color.accentColor : Color.secondary.opacity(0.3))
                    .foregroundColor(.white)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!player.isLoaded)

            Text(timeString(player.currentTime))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 42, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.scrub(to: $0) }
                ),
                in: 0...max(player.duration, 0.01)
            )
            .disabled(!player.isLoaded)

            Text(timeString(player.duration))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 42, alignment: .leading)
        }
        .opacity(player.isLoaded ? 1 : 0.6)
        .overlay(alignment: .leading) {
            if let err = player.loadError {
                Text(err)
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .padding(.leading, 46)
            }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}
