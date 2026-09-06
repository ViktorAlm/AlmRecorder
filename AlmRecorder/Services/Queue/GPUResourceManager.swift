import Foundation
import Combine

/// GPU/Metal consumers, lowest→highest priority. A higher-priority consumer preempts a lower one.
/// (Raw values define the ordering; do not reuse.)
enum GPUConsumer: Int, Comparable, CaseIterable, CustomStringConvertible {
    case identityReview = -5 // SpeakerIdentityLLMReviewer Gemma passes — distinct from `insights`
                             // so the two NEVER both acquire the GPU (they share LLMTextService;
                             // a shared case would let both spawn Gemma → dual-resident OOM).
    case cleanup = -4      // transcript cleanup — yields even to insights
    case insights = -3     // background LLM insights — yields to everything user-facing
    case speakerEvidenceBackfill = -2 // resumable FluidAudio evidence repair for legacy voices
    case embedding = -1    // background indexing must never interrupt a requested quality run
    case nightlyEnhancement = 0 // VibeVoice candidate + persistent Gemma finalization
    case transcription = 1
    case search = 2
    case dictation = 3       // foreground hold-to-talk; model is released before lower work resumes

    static func < (lhs: GPUConsumer, rhs: GPUConsumer) -> Bool { lhs.rawValue < rhs.rawValue }

    var description: String {
        switch self {
        case .identityReview: return "identityReview"
        case .cleanup: return "cleanup"
        case .insights: return "insights"
        case .speakerEvidenceBackfill: return "speakerEvidenceBackfill"
        case .nightlyEnhancement: return "nightlyEnhancement"
        case .embedding: return "embedding"
        case .transcription: return "transcription"
        case .search: return "search"
        case .dictation: return "dictation"
        }
    }
}

/// Pure arbitration state machine for the GPU. Tested in `GPUArbiterTests`. `GPUResourceManager`
/// is a thin async executor over this — all priority / preemption / single-resident decisions live
/// here so they're deterministic and unit-testable.
///
/// Invariant: at most ONE consumer is `holder`, and a higher-priority requester becomes holder only
/// after the current holder calls `release` (i.e. after its model subprocess has actually exited).
/// That ordering is what prevents two multi-GB Metal models being resident at once — the
/// `kIOGPUCommandBufferCallbackErrorOutOfMemory` freeze on 2026-06-13.
struct GPUArbiter {
    enum Effect: Hashable {
        case proceed(GPUConsumer)        // requester holds the GPU now — no suspension
        case rejectDuplicate(GPUConsumer) // a second worker of the holder must not share its lease
        case suspend(GPUConsumer)        // requester must park until a later grant
        case preemptHolder(GPUConsumer)  // stop + kill the current holder's in-flight work
        case resume(GPUConsumer)         // wake a parked (suspended) consumer; it becomes holder
        case restart(GPUConsumer)        // restart a preempted (cancelled) consumer's worker
    }

    private(set) var holder: GPUConsumer?
    /// Called `acquire` and parked on a continuation, waiting for a turn.
    private var suspended: Set<GPUConsumer> = []
    /// Was the holder, got preempted (worker cancelled); awaits restart once it's the top candidate.
    private var preempted: Set<GPUConsumer> = []

    /// A worker requests the GPU.
    mutating func acquire(_ c: GPUConsumer) -> [Effect] {
        preempted.remove(c)                 // re-acquiring supersedes any pending restart
        guard let current = holder else {
            holder = c
            return [.proceed(c)]
        }
        if current == c {
            // Consumer cases identify queues, not individual tasks. Treating this as re-entrancy
            // let duplicate cleanup workers share one logical lease and load two 8 GiB Gemma
            // instances concurrently.
            return [.rejectDuplicate(c)]
        }
        suspended.insert(c)
        if c > current {
            preempted.insert(current)       // it will be stopped; remember to bring it back
            return [.suspend(c), .preemptHolder(current)]
        }
        return [.suspend(c)]
    }

    /// The holder finished (or released after being preempted+cancelled).
    mutating func release(_ c: GPUConsumer) -> [Effect] {
        guard holder == c else { return [] }
        holder = nil
        return grantNext()
    }

    /// Deadlock backstop: force `c` through (used when a holder is wedged past the timeout).
    mutating func forceGrant(_ c: GPUConsumer) -> [Effect] {
        suspended.remove(c)
        preempted.remove(c)
        holder = c
        return [.resume(c)]
    }

    /// A parked waiter's task was cancelled — drop it so it isn't granted later.
    mutating func dropWaiter(_ c: GPUConsumer) {
        suspended.remove(c)
        preempted.remove(c)
    }

    /// Cheap non-mutating guard: would `c` be allowed to run right now?
    func canProceed(_ c: GPUConsumer) -> Bool {
        guard let current = holder else { return true }
        return c >= current
    }

    private mutating func grantNext() -> [Effect] {
        let candidates = suspended.union(preempted)
        guard let next = candidates.max() else { return [] }
        if suspended.contains(next) {
            suspended.remove(next)
            preempted.remove(next)
            holder = next
            return [.resume(next)]
        }
        preempted.remove(next)
        return [.restart(next)]      // holder stays nil until the restarted worker re-acquires
    }
}

/// Serializes GPU access across queues so only one model subprocess is resident at a time.
/// `acquire` suspends until the caller exclusively holds the GPU; a higher-priority caller preempts
/// the holder and is granted only once the holder releases (its subprocess gone).
@MainActor
final class GPUResourceManager: ObservableObject {
    static let shared = GPUResourceManager()

    @Published private(set) var activeConsumer: GPUConsumer?

    private let logger = VoxtralLogger.shared
    private var arbiter = GPUArbiter()
    private var continuations: [GPUConsumer: CheckedContinuation<Bool, Never>] = [:]
    private var backstops: [GPUConsumer: Task<Void, Never>] = [:]
    /// How long a waiter can sit before we log it for observability. NOT a force-through: a
    /// lower-priority waiter legitimately waits as long as a higher-priority holder runs (a long
    /// transcription can hold the GPU for minutes), and force-granting would relaunch a second
    /// model into Metal — the exact concurrent-residency OOM this manager exists to prevent.
    private let backstopTimeout: TimeInterval = 90

    /// Background (deferrable) consumers, as opposed to user-initiated `.transcription`/`.search` —
    /// matches `SystemMemoryGate`'s own "only background queues consult it" contract.
    private static let backgroundConsumers: [GPUConsumer] = [
        .identityReview,
        .cleanup,
        .insights,
        .speakerEvidenceBackfill,
        .nightlyEnhancement,
        .embedding
    ]

    private init() {
        // New heavy launches already defer at warning. Let one previously admitted model finish
        // through ordinary compressor/pager activity; its own live monitor still stops below 1 GB
        // headroom, above the compressor/swap ceilings, on Metal OOM, or at critical pressure.
        // Killing at warning caused an endless load → warning → kill cycle on a 24 GB Mac.
        SystemMemoryGate.shared.onPressureEscalated = { [weak self] level in
            guard level == .critical else { return }
            Task { @MainActor in self?.stopAllBackgroundConsumers(reason: level) }
        }
    }

    /// Critical system memory pressure overrides every background lease.
    private func stopAllBackgroundConsumers(reason level: MemoryPressureLevel) {
        logger.warning("[GPUResource] Memory pressure → \(level.rawValue): stopping all background GPU consumers")
        for consumer in Self.backgroundConsumers {
            stopHook(consumer)
        }
    }

    /// Acquire the GPU, suspending until granted. Returns `false` if the calling task was cancelled
    /// while waiting (the caller then must NOT run GPU work and must NOT call `release`).
    func acquire(_ consumer: GPUConsumer) async -> Bool {
        let effects = arbiter.acquire(consumer)
        if effects.contains(.rejectDuplicate(consumer)) {
            execute(effects)
            return false
        }
        execute(effects)
        if arbiter.holder == consumer { return true }   // GPU was free — proceeded immediately

        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    arbiter.dropWaiter(consumer)
                    cont.resume(returning: false)
                    return
                }
                continuations[consumer] = cont
                startBackstop(for: consumer)
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiter(consumer) }
        }

        // We had to wait, so another model was just resident. Give the kernel a beat to reclaim its
        // GPU memory before we map our own weights — closes the residual-overlap window that the
        // bare priority arbiter left open.
        if granted { try? await Task.sleep(nanoseconds: 250_000_000) }
        return granted
    }

    /// Release the GPU and grant the next-highest-priority waiter.
    func release(_ consumer: GPUConsumer) {
        execute(arbiter.release(consumer))
    }

    /// Cheap synchronous guard (e.g. to decide whether to even enqueue GPU work).
    func canProceed(_ consumer: GPUConsumer) -> Bool {
        arbiter.canProceed(consumer)
    }

    // MARK: - Effect execution

    private func execute(_ effects: [GPUArbiter.Effect]) {
        for effect in effects {
            switch effect {
            case let .proceed(c):
                logger.info("[GPUResource] Acquired by \(c)")
            case let .rejectDuplicate(c):
                logger.error("[GPUResource] Rejected duplicate \(c) worker — existing lease remains exclusive")
            case .suspend:
                break   // parking handled in `acquire`
            case let .preemptHolder(h):
                logger.info("[GPUResource] preempting \(h)")
                stopHook(h)
            case let .resume(c):
                cancelBackstop(c)
                continuations.removeValue(forKey: c)?.resume(returning: true)
                logger.info("[GPUResource] Granted to \(c)")
            case let .restart(c):
                logger.info("[GPUResource] Restarting preempted \(c)")
                startHook(c)
            }
        }
        activeConsumer = arbiter.holder
    }

    private func cancelWaiter(_ consumer: GPUConsumer) {
        guard let cont = continuations.removeValue(forKey: consumer) else { return }
        cancelBackstop(consumer)
        arbiter.dropWaiter(consumer)
        cont.resume(returning: false)
        activeConsumer = arbiter.holder
    }

    // MARK: - Deadlock backstop

    private func startBackstop(for consumer: GPUConsumer) {
        backstops[consumer]?.cancel()
        let timeout = backstopTimeout
        backstops[consumer] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, !Task.isCancelled, self.continuations[consumer] != nil else { return }
            // Observability ONLY — never force a concurrent grant. A long-running higher-priority
            // holder (e.g. transcription) legitimately makes lower waiters wait this long.
            let holder = self.arbiter.holder.map(String.init(describing:)) ?? "none"
            self.logger.warning("[GPUResource] \(consumer) has waited \(Int(timeout))s for holder \(holder) — expected if a long transcription holds the GPU; investigate if it persists")
        }
    }

    private func cancelBackstop(_ consumer: GPUConsumer) {
        backstops[consumer]?.cancel()
        backstops[consumer] = nil
    }

    // MARK: - Queue hooks (stop the holder / restart the preempted)

    private func stopHook(_ consumer: GPUConsumer) {
        switch consumer {
        case .identityReview: LLMTextService.shared.cancel()   // kill its in-flight Gemma call
        case .cleanup:       TranscriptCleanupQueueManager.shared.stopProcessing()
        case .insights:      RecordingInsightsQueueManager.shared.stopProcessing()
        case .speakerEvidenceBackfill:
            SpeakerBackfillService.shared.stopProcessingForPreemption()
        case .nightlyEnhancement:
            NightlyQualityController.shared.stopProcessingForPreemption()
        case .embedding:     EmbeddingQueueManager.shared.stopProcessing()
        case .transcription: TranscriptionQueueManager.shared.pauseAllProcessing()
        case .search:        break   // no persistent search worker to stop
        case .dictation:     break   // highest priority; cannot be preempted
        }
    }

    private func startHook(_ consumer: GPUConsumer) {
        switch consumer {
        case .identityReview: break   // ad-hoc reviewer; re-runs on its next scheduled pass
        case .cleanup:       TranscriptCleanupQueueManager.shared.startProcessing()
        case .insights:      RecordingInsightsQueueManager.shared.startProcessing()
        case .speakerEvidenceBackfill:
            SpeakerBackfillService.shared.resumeAfterPreemption()
        case .nightlyEnhancement:
            NightlyQualityController.shared.resumeAfterPreemption()
        case .embedding:     EmbeddingQueueManager.shared.startProcessing()
        // Must force-clear the stuck `isProcessing` flag: `pauseAllProcessing` (the stop hook)
        // cancels the workers but never clears it, so `resumeAllProcessing`'s `if !isProcessing`
        // guard is dead and the transcription queue would never respawn a worker after a preempt.
        case .transcription: TranscriptionQueueManager.shared.startOrResumeProcessing()
        case .search:        break
        case .dictation:     break
        }
    }
}
