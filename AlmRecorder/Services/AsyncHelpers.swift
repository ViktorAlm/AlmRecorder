import Foundation
import AVFoundation

/// Small lock-backed storage for state shared with Foundation callback queues.
/// Keeping the mutation behind a synchronous lock avoids captured-var races while preserving the
/// callback APIs used by Process, Pipe, and AVFoundation.
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&storage)
    }

    var snapshot: Value {
        withValue { $0 }
    }
}

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
