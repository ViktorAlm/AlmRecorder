import SwiftUI

/// A live scrolling waveform driven by a 0…1 level (mic or system-audio RMS), reflecting the *real*
/// audio level (unlike the old simulated random bars).
///
/// It appends a new bar every time `level` changes. The recorder publishes the level on every audio
/// buffer (~10–20 Hz while recording), so the wave scrolls with the audio. (An earlier version used
/// an internal Timer, but the parent re-renders on every level update — which recreated the timer
/// before it could ever fire, leaving the wave flat.)
struct LiveWaveformView: View {
    let level: Float
    var color: Color = .accentColor
    var bars: Int = 56

    @State private var history: [CGFloat] = []

    var body: some View {
        GeometryReader { geo in
            let barWidth = max(2, geo.size.width / CGFloat(bars) - 2)
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    let v = i < history.count ? history[i] : 0
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color.opacity(0.85))
                        .frame(width: barWidth, height: max(2, geo.size.height * v))
                        .animation(.linear(duration: 0.08), value: v)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
        .onChange(of: level) { _, newValue in
            history.append(CGFloat(min(1, max(0, newValue))))
            if history.count > bars { history.removeFirst(history.count - bars) }
        }
    }
}
