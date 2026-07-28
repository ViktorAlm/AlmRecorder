import Foundation

/// Lightweight streaming endpoint detector for the push-to-talk path. It adapts to the current
/// microphone noise floor, retains pre-roll, and never decides what text is valid; it only avoids
/// submitting long silent windows and flushes a partial after a natural pause.
struct RealtimeVoiceActivityDetector {
    struct Update {
        let started: Bool
        let ended: Bool
    }

    private static let blockSampleCount = 480 // 20 ms at 24 kHz
    private static let startBlockCount = 4    // 80 ms
    private static let endBlockCount = 18     // 360 ms

    private var remainder: [Float] = []
    private var noiseFloor: Float = 0.0015
    private var speechBlocks = 0
    private var silenceBlocks = 0
    private(set) var isSpeechActive = false

    mutating func process(_ samples: [Float]) -> Update {
        remainder.append(contentsOf: samples)
        var started = false
        var ended = false

        while remainder.count >= Self.blockSampleCount {
            let block = remainder.prefix(Self.blockSampleCount)
            remainder.removeFirst(Self.blockSampleCount)

            var sumSquares: Float = 0
            var peak: Float = 0
            for sample in block {
                sumSquares += sample * sample
                peak = max(peak, abs(sample))
            }
            let rms = sqrt(sumSquares / Float(Self.blockSampleCount))
            let threshold = max(0.0025, min(0.03, noiseFloor * 3.2))
            let soundsLikeSpeech = rms >= threshold && peak >= 0.008

            if soundsLikeSpeech {
                speechBlocks += 1
                silenceBlocks = 0
                if !isSpeechActive, speechBlocks >= Self.startBlockCount {
                    isSpeechActive = true
                    started = true
                }
            } else {
                speechBlocks = 0
                if isSpeechActive {
                    silenceBlocks += 1
                    if silenceBlocks >= Self.endBlockCount {
                        isSpeechActive = false
                        silenceBlocks = 0
                        ended = true
                    }
                } else {
                    // Only learn the ambient floor while outside an active utterance.
                    noiseFloor = noiseFloor * 0.97 + rms * 0.03
                }
            }
        }
        return Update(started: started, ended: ended)
    }
}
