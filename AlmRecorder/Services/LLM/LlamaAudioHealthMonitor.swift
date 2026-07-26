import Foundation
import Combine

/// Remembers when the llama multimodal runtime could not load the audio projector (mmproj), so
/// audio features can declare themselves unavailable instead of relaunching a doomed process.
///
/// A projector the binary doesn't understand (e.g. mmproj type "gemma4uv" on a llama.cpp older
/// than b9493) fails only at process runtime — `isAvailable`-style file checks all pass, and every
/// attempt pays a full model load before dying. The failure is structural, not per-run: it can't
/// succeed until the binary or the mmproj file changes. So the first detection is recorded here,
/// keyed by exact (binary, mmproj) file stamps; swapping either file invalidates the record and the
/// next attempt re-probes.
final class LlamaAudioHealthMonitor: ObservableObject {

    static let shared = LlamaAudioHealthMonitor()

    struct ProjectorFailure: Equatable {
        /// Short human-readable cause, e.g. `unknown projector type: gemma4uv`.
        let reason: String
        let binaryStamp: String
        let mmprojStamp: String
        let detectedAt: Date
    }

    /// Main-thread mirror of the failure state for SwiftUI; reads from logic code should use
    /// `knownFailure(binaryPath:mmprojPath:)`, which also re-checks the file stamps.
    @Published private(set) var projectorFailure: ProjectorFailure?

    private let lock = NSLock()
    private var failure: ProjectorFailure?
    private let logger = VoxtralLogger.shared

    init() {}

    // MARK: - Detection (pure)

    /// Returns a short reason when the process output shows the multimodal projector itself failed
    /// to load. Deliberately narrow: OOM, audio-format, or text-model load problems are per-run
    /// errors that retrying or smaller inputs can fix — matching them here would wrongly latch the
    /// whole audio stack off.
    static func projectorLoadFailureReason(stdout: String, stderr: String) -> String? {
        let markers = [
            "unknown projector type",
            "failed to load mmproj",
            "failed to load clip model",
            "clip_model_loader: failed",
            "mtmd_init_from_file: error",
        ]
        for output in [stderr, stdout] where !output.isEmpty {
            for line in output.components(separatedBy: .newlines) {
                let lowered = line.lowercased()
                guard markers.contains(where: { lowered.contains($0) }) else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Strip the log-prefix noise when the canonical cause is present.
                if let range = trimmed.range(of: "unknown projector type", options: .caseInsensitive) {
                    return String(trimmed[range.lowerBound...].prefix(160))
                }
                return String(trimmed.prefix(160))
            }
        }
        return nil
    }

    /// "path|size|mtime" — cheap identity for "did this exact file change". Empty for missing files
    /// so a record never matches a path that no longer exists.
    static func fileStamp(_ path: String) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64,
              let mtime = attrs[.modificationDate] as? Date else { return "" }
        return "\(path)|\(size)|\(Int(mtime.timeIntervalSince1970))"
    }

    // MARK: - Recording / querying

    /// Inspect a failed run's output; if the projector itself failed to load, latch the failure
    /// for this exact (binary, mmproj) pair. Safe to call on every process failure.
    func recordIfProjectorFailure(stdout: String, stderr: String, binaryPath: String, mmprojPath: String) {
        guard let reason = Self.projectorLoadFailureReason(stdout: stdout, stderr: stderr) else { return }
        let detected = ProjectorFailure(reason: reason,
                                        binaryStamp: Self.fileStamp(binaryPath),
                                        mmprojStamp: Self.fileStamp(mmprojPath),
                                        detectedAt: Date())
        lock.lock()
        let isNew = failure != detected
        failure = detected
        lock.unlock()

        if isNew {
            logger.error("[LlamaAudioHealth] Audio projector failed to load (\(reason)) — binary \(binaryPath), mmproj \(mmprojPath). Audio transcription/verification disabled until either file changes.")
            DispatchQueue.main.async { [weak self] in self?.projectorFailure = detected }
        }
    }

    /// The latched failure, but only while it still describes the files that would actually run —
    /// re-staged binaries or a re-downloaded mmproj change the stamps and clear the verdict.
    func knownFailure(binaryPath: String, mmprojPath: String) -> ProjectorFailure? {
        lock.lock()
        defer { lock.unlock() }
        guard let failure,
              !failure.binaryStamp.isEmpty, !failure.mmprojStamp.isEmpty,
              failure.binaryStamp == Self.fileStamp(binaryPath),
              failure.mmprojStamp == Self.fileStamp(mmprojPath) else { return nil }
        return failure
    }

    func reset() {
        lock.lock()
        failure = nil
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.projectorFailure = nil }
    }
}
