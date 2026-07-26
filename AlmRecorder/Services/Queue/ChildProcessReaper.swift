import Foundation

/// Wall-clock backstop that SIGKILLs model subprocesses (whisper-cli, llama) which outlive a hard
/// ceiling. Each runner `track`s its child after launch and `untrack`s on completion; a periodic
/// sweep reaps any still-running child older than the ceiling.
///
/// Why this exists beyond the per-run timeout loops: on 2026-06-14 a whisper-cli hung at 0% CPU
/// holding the GPU for 12 hours. During a system-wide 96%-swap freeze the app's own per-run
/// watchdog task was CPU-starved and never ran to kill it, and one run path (`runTranscriptionWithJSON`)
/// used a bare `waitUntilExit()` with no timeout at all. This reaper is the independent safety net:
/// even if a run's watchdog is starved or absent, the sweep eventually reaps the orphan and frees
/// the GPU so the transcription queue can't stall forever.
final class ChildProcessReaper {
    static let shared = ChildProcessReaper()

    /// Hard ceiling: longer than the per-run transcription timeout (max 30 min) so this only ever
    /// catches genuine orphans the per-run watchdog missed.
    static let ceiling: TimeInterval = 40 * 60
    private static let sweepInterval: TimeInterval = 120

    enum Action: Equatable { case keep, removeCompleted, reapOrphan }

    /// Pure decision core (unit-tested): what to do with one tracked child.
    static func classify(running: Bool, ageSeconds: TimeInterval, ceiling: TimeInterval) -> Action {
        if !running { return .removeCompleted }       // finished (possibly a missed untrack) — clean up
        if ageSeconds > ceiling { return .reapOrphan } // wedged past the ceiling — kill it
        return .keep
    }

    private final class Entry {
        let process: Process
        let started: Date
        let label: String
        init(_ process: Process, _ label: String) {
            self.process = process; self.started = Date(); self.label = label
        }
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let logger = VoxtralLogger.shared
    private var sweepTask: Task<Void, Never>?

    private init() {}

    /// Begin the periodic sweep. Idempotent; call once at app launch.
    func start() {
        lock.lock(); let already = sweepTask != nil; lock.unlock()
        guard !already else { return }
        let task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.sweepInterval * 1_000_000_000))
                self?.sweep()
            }
        }
        lock.lock(); sweepTask = task; lock.unlock()
    }

    /// Track a freshly-launched child so the sweep can reap it if its run never untracks.
    func track(_ process: Process, label: String) {
        lock.lock(); entries.append(Entry(process, label)); lock.unlock()
        start()   // ensure the sweep is running
    }

    /// A run finished normally — stop tracking its child.
    func untrack(_ process: Process) {
        lock.lock()
        entries.removeAll { $0.process === process }
        lock.unlock()
    }

    private func sweep() {
        let now = Date()
        lock.lock()
        let snapshot = entries
        lock.unlock()

        var toRemove: [Entry] = []
        for entry in snapshot {
            switch Self.classify(running: entry.process.isRunning,
                                 ageSeconds: now.timeIntervalSince(entry.started),
                                 ceiling: Self.ceiling) {
            case .keep:
                continue
            case .removeCompleted:
                toRemove.append(entry)
            case .reapOrphan:
                let pid = entry.process.processIdentifier
                logger.warning("[ChildProcessReaper] \(entry.label) pid \(pid) alive \(Int(now.timeIntervalSince(entry.started)))s (> \(Int(Self.ceiling))s) — SIGKILL (per-run watchdog missed it, likely starved during a freeze)")
                entry.process.terminate()
                if entry.process.isRunning { kill(pid, SIGKILL) }
                toRemove.append(entry)
            }
        }
        if !toRemove.isEmpty {
            lock.lock()
            entries.removeAll { e in toRemove.contains { $0 === e } }
            lock.unlock()
        }
    }
}
