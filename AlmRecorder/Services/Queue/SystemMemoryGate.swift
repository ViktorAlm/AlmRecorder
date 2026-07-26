import Foundation

/// System memory pressure as reported by the dispatch memory-pressure source.
enum MemoryPressureLevel: String, Comparable {
    case normal, warning, critical

    private var ordinal: Int {
        switch self {
        case .normal: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }

    static func < (lhs: MemoryPressureLevel, rhs: MemoryPressureLevel) -> Bool { lhs.ordinal < rhs.ordinal }
}

/// Pure decision core for launching background GPU work (insights / cleanup / embedding) under
/// memory pressure. Unit-tested in `BackgroundGPUGateTests`; `SystemMemoryGate` supplies the live
/// inputs.
///
/// Why: on 2026-06-10 the machine kernel-panicked twice (watchdog timeout) while background queues
/// kept launching multi-GB llama.cpp model loads into a starved system — the second freeze came
/// ~10s after an insights run died with `kIOGPUCommandBufferCallbackErrorOutOfMemory` while
/// launchd was jetsam-killing daemons. Background work is deferrable by definition; the gate makes
/// it actually defer. User-initiated transcription is exempt: only the background queues consult it.
enum BackgroundGPUAdmission {

    enum Decision: Equatable {
        case proceed
        /// `retryAfter` is a poll interval — the caller sleeps and re-checks, it does not encode
        /// the full cooldown.
        case deferred(reason: String, retryAfter: TimeInterval)
    }

    private static let gib: UInt64 = 1_073_741_824

    /// Free memory required before launching a child that maps `modelBytes` of weights: the
    /// weights themselves plus slack for KV cache / compute buffers, never below a floor.
    /// `.critical` is unsatisfiable — nothing launches until pressure clears.
    static func requiredBytes(modelBytes: UInt64?, pressure: MemoryPressureLevel) -> UInt64 {
        let model = modelBytes ?? 0
        switch pressure {
        case .normal: return max(model + model / 4, 2 * gib)
        case .warning: return max(model + model / 2, 3 * gib)
        case .critical: return .max
        }
    }

    static func decision(availableBytes: UInt64?, modelBytes: UInt64?,
                         pressure: MemoryPressureLevel,
                         oomCooldownRemaining: TimeInterval) -> Decision {
        if oomCooldownRemaining > 0 {
            return .deferred(reason: "Metal OOM cooldown (\(Int(oomCooldownRemaining))s remaining)",
                             retryAfter: 30)
        }
        if pressure == .critical {
            return .deferred(reason: "system memory pressure critical", retryAfter: 30)
        }
        // Fail open when sampling is unavailable — pressure and cooldown above still guard, and a
        // broken stats call must not brick the whole pipeline.
        guard let available = availableBytes else { return .proceed }
        let required = requiredBytes(modelBytes: modelBytes, pressure: pressure)
        if available < required {
            return .deferred(reason: "insufficient memory headroom (\(formatGB(available)) available < \(formatGB(required)) required)",
                             retryAfter: 60)
        }
        return .proceed
    }

    /// Does this stderr/output carry the Metal (or allocator) out-of-memory signature?
    /// Matched against what llama.cpp actually emits — the first two are verbatim from the
    /// 2026-06-10 incident. A bare `llama_decode ret = -3` is NOT enough: it has non-GPU causes,
    /// so it only counts alongside a ggml_metal error.
    static func isMetalOOM(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("kiogpucommandbuffercallbackerroroutofmemory") { return true }
        if lowered.contains("insufficient memory") { return true }
        if lowered.contains("out of memory") { return true }
        if lowered.contains("failed to decode, ret = -3") && lowered.contains("ggml_metal") { return true }
        return false
    }

    /// Minutes-scale backoff after a Metal OOM: 5 min doubling per consecutive OOM, capped at 30.
    /// An immediate relaunch just re-OOMs into the same starved system (and reloading the weights
    /// is itself a multi-GB allocation spike).
    static func cooldown(consecutiveOOMs: Int) -> TimeInterval {
        guard consecutiveOOMs > 0 else { return 0 }
        return min(300 * pow(2, Double(consecutiveOOMs - 1)), 1800)
    }

    private static func formatGB(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / Double(gib))
    }
}

/// Live gate the background queue workers poll before each GPU job launch. Combines a system
/// memory sample, the dispatch memory-pressure source, and a Metal-OOM cooldown that the process
/// runners feed via `reportMetalOOM`.
final class SystemMemoryGate {
    static let shared = SystemMemoryGate()

    private let logger = VoxtralLogger.shared
    private let lock = NSLock()
    private var pressure: MemoryPressureLevel = .normal
    private var cooldownUntil: Date?
    private var consecutiveOOMs = 0
    private var lastDeferralReason: String?
    private let pressureSource: DispatchSourceMemoryPressure

    /// Fired when pressure gets WORSE (normal→warning, warning→critical, or normal→critical) —
    /// never on recovery. The per-job `deferral` check only blocks NEW launches, so a job that
    /// started before pressure escalated would otherwise keep its multi-GB model resident until it
    /// finishes on its own; this lets a listener (`GPUResourceManager`) stop it immediately instead.
    /// Invoked on the pressure source's own utility queue, NOT the main actor.
    var onPressureEscalated: ((MemoryPressureLevel) -> Void)?

    private init() {
        pressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: DispatchQueue(label: "com.almrecorder.memorygate", qos: .utility))
        pressureSource.setEventHandler { [weak self] in
            guard let self else { return }
            let event = self.pressureSource.data
            let level: MemoryPressureLevel = event.contains(.critical) ? .critical
                : event.contains(.warning) ? .warning : .normal
            self.lock.lock()
            let previous = self.pressure
            let changed = previous != level
            self.pressure = level
            self.lock.unlock()
            if changed { self.logger.info("[MemoryGate] System memory pressure → \(level.rawValue)") }
            if level > previous { self.onPressureEscalated?(level) }
        }
        pressureSource.activate()
    }

    /// Why a background GPU launch must wait right now, or nil to proceed. `modelBytes` is the
    /// on-disk size of the model(s) the job would load.
    func deferral(modelBytes: UInt64?) -> (reason: String, retryAfter: TimeInterval)? {
        lock.lock()
        let remaining = max(0, cooldownUntil.map { $0.timeIntervalSinceNow } ?? 0)
        let level = pressure
        lock.unlock()

        let decision = BackgroundGPUAdmission.decision(
            availableBytes: Self.availableMemoryBytes(),
            modelBytes: modelBytes,
            pressure: level,
            oomCooldownRemaining: remaining)

        switch decision {
        case .proceed:
            lock.lock()
            let cleared = lastDeferralReason != nil
            lastDeferralReason = nil
            lock.unlock()
            if cleared { logger.info("[MemoryGate] Background GPU launches resumed") }
            return nil
        case let .deferred(reason, retryAfter):
            lock.lock()
            let isNewReason = lastDeferralReason != reason
            lastDeferralReason = reason
            lock.unlock()
            // Log transitions only — workers poll this every 30-60s while deferred.
            if isNewReason { logger.info("[MemoryGate] Background GPU launches deferred: \(reason)") }
            return (reason, retryAfter)
        }
    }

    /// A llama.cpp/whisper child died with the Metal OOM signature: open (or extend) the cooldown.
    func reportMetalOOM(source: String) {
        lock.lock()
        consecutiveOOMs += 1
        let cooldown = BackgroundGPUAdmission.cooldown(consecutiveOOMs: consecutiveOOMs)
        cooldownUntil = Date().addingTimeInterval(cooldown)
        let count = consecutiveOOMs
        lock.unlock()
        logger.warning("[MemoryGate] Metal OOM from \(source) (consecutive: \(count)) — background GPU launches paused \(Int(cooldown / 60)) min")
    }

    /// A GPU child process completed successfully — the OOM streak (if any) is over.
    func reportGPUJobSuccess() {
        lock.lock()
        let hadCooldown = consecutiveOOMs > 0 || cooldownUntil != nil
        consecutiveOOMs = 0
        cooldownUntil = nil
        lock.unlock()
        if hadCooldown { logger.info("[MemoryGate] GPU job succeeded — OOM cooldown cleared") }
    }

    // MARK: - Inputs

    /// Memory reclaimable without paging anonymous pages out: free + purgeable + file-backed.
    /// (At the 2026-06-10 panic the box had 28 swapfiles on 24 GB — anonymous memory was already
    /// the problem, so only genuinely cheap-to-reclaim pages count as available.)
    static func availableMemoryBytes() -> UInt64? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pageSize = UInt64(vm_page_size)
        return (UInt64(stats.free_count) + UInt64(stats.purgeable_count) + UInt64(stats.external_page_count)) * pageSize
    }

    /// On-disk size of a model file, for the headroom requirement.
    static func fileSize(at url: URL?) -> UInt64? {
        guard let path = url?.path,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64 else { return nil }
        return size
    }
}
