import Foundation
import AVFoundation

// Helper for synchronously getting AVAsset duration
public func getAssetDurationSync(_ asset: AVAsset) -> TimeInterval? {
    let semaphore = DispatchSemaphore(value: 0)
    var duration: TimeInterval?
    
    Task {
        do {
            let durationTime = try await asset.load(.duration)
            if durationTime.isValid && !durationTime.isIndefinite {
                duration = CMTimeGetSeconds(durationTime)
            }
        } catch {
            duration = nil
        }
        semaphore.signal()
    }
    
    semaphore.wait()
    return duration
}

// Helper for synchronously getting AVAsset tracks and duration
public func getAssetAudioDurationSync(_ asset: AVAsset) -> TimeInterval {
    let semaphore = DispatchSemaphore(value: 0)
    var duration: TimeInterval = 0
    
    Task {
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            if !tracks.isEmpty {
                let durationTime = try await asset.load(.duration)
                duration = CMTimeGetSeconds(durationTime)
            }
        } catch {
            duration = 0
        }
        semaphore.signal()
    }
    
    semaphore.wait()
    return duration
}