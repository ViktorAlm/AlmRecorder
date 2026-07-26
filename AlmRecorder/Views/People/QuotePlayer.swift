import SwiftUI
import AVFoundation

/// A unified, lightweight quote used by the People profile (from either text or semantic search).
struct QuoteItem: Identifiable, Equatable {
    let id: Int                 // utterance id
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let audioPath: String?      // original recording file (nil if unavailable)
    let recordingTitle: String
    let recordingDate: Date?
}

/// Plays a single utterance by opening the ORIGINAL recording, seeking to its start, and auto-stopping
/// at its end. This is the same reliable approach as `RecordingPlayerBar` — no temp-WAV extraction
/// (which is what made the per-utterance player flaky). One player instance is reused per recording.
@MainActor
final class QuotePlayerViewModel: NSObject, ObservableObject {
    @Published var playingId: Int?

    private var player: AVAudioPlayer?
    private var currentPath: String?
    private var endTime: TimeInterval = 0
    private var timer: Timer?

    func toggle(_ item: QuoteItem) {
        if playingId == item.id { stop(); return }
        play(item)
    }

    private func play(_ item: QuoteItem) {
        guard let path = item.audioPath, FileManager.default.fileExists(atPath: path) else {
            stop(); return
        }
        // Reuse the open player when the same file is requested again.
        if currentPath != path || player == nil {
            guard let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else { stop(); return }
            p.delegate = self
            p.prepareToPlay()
            player = p
            currentPath = path
        }
        guard let player else { return }
        let dur = player.duration
        player.currentTime = max(0, min(item.start, max(0, dur - 0.05)))
        endTime = item.end > item.start ? min(item.end, dur) : dur
        player.play()
        playingId = item.id
        startTimer()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        player?.pause()
        playingId = nil
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                if !player.isPlaying || player.currentTime >= self.endTime { self.stop() }
            }
        }
    }
}

extension QuotePlayerViewModel: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

/// One quote row: tap anywhere (or the play button) to hear it; shows time + which recording it's from.
struct QuoteRow: View {
    let item: QuoteItem
    @ObservedObject var player: QuotePlayerViewModel

    private var isPlaying: Bool { player.playingId == item.id }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { player.toggle(item) } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(isPlaying ? Color.orange : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(item.audioPath == nil)
            .help(item.audioPath == nil ? "Audio unavailable" : "Play this moment")

            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    // Clip length (mm:ss). Showing the start offset read "0:00" for single-utterance
                    // tracks, which looked like zero-length clips.
                    Text(timeLabel(max(0, item.end - item.start))).monospacedDigit()
                    Text("·")
                    Text(item.recordingTitle).lineLimit(1)
                    if let d = item.recordingDate {
                        Text("·")
                        Text(d.formatted(date: .abbreviated, time: .omitted))
                    }
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(isPlaying ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { player.toggle(item) }
    }

    private func timeLabel(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}
