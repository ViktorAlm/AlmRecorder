import Darwin
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

/// A conservative view of memory which is cheap to reclaim before a large model is loaded.
///
/// `availableBytes` intentionally excludes compressed anonymous memory. Counting it as available
/// would make a launch look safe precisely when macOS is already relying on its compressor/swap.
struct SystemMemorySnapshot: Equatable, Sendable {
    let physicalBytes: UInt64
    let availableBytes: UInt64
    let compressorBytes: UInt64
    let swapUsedBytes: UInt64?
    let swapAvailableBytes: UInt64?
}

/// Peak working-set estimate for a transcription backend. Model file size alone is not enough:
/// VibeVoice 4-bit is 5.7 GB on disk, measured 9.64 GB on short gold calls, and reached 15.1 GB
/// resident on the 55-minute pass involved in the 2026-07-27 watchdog panic.
struct TranscriptionResourceProfile: Equatable {
    let label: String
    let estimatedPeakBytes: UInt64
    let isHeavy: Bool

    private static let gib: UInt64 = 1_073_741_824

    static func forSelection(_ selection: TranscriptionEngineSelection?) -> Self {
        let selection = selection ?? TranscriptionEngineSelection.snapshot()
        switch selection.backend {
        case .vibeVoice:
            return vibeVoice(selection.vibeVoiceQuantization ?? .fourBit)
        case .whisper:
            let variant = selection.whisperVariantIdentifier
                .flatMap(WhisperModelVariant.fromIdentifier)
                ?? GlobalModelSettings.shared.selectedWhisperVariant
                ?? WhisperModelVariant.defaultVariant()
            let modelBytes = UInt64(max(0, variant.estimatedSize))
            return Self(
                label: "Whisper \(variant.displayName)",
                estimatedPeakBytes: max(3 * gib, modelBytes + modelBytes / 2 + gib),
                isHeavy: false
            )
        case .llm:
            if selection.llmEngine == .gemma {
                // Legacy persisted selection only. Do not reserve or load Gemma audio resources;
                // the unified transcription boundary rejects this job with an actionable error.
                return Self(
                    label: "Gemma audio (deferred)",
                    estimatedPeakBytes: 0,
                    isHeavy: false
                )
            }
            let key = selection.llmModelKey ?? VoxtralConfiguration.defaultModel
            let modelBytes = catalogBytes(
                sizeGB: VoxtralConfiguration.models[key]?.sizeGB,
                directory: VoxtralConfiguration.modelsDirectory,
                fileNames: [
                    VoxtralConfiguration.models[key]?.modelFile,
                    VoxtralConfiguration.models[key]?.mmprojFile
                ]
            )
            return Self(
                label: "Voxtral \(key)",
                estimatedPeakBytes: max(5 * gib, modelBytes + 2 * gib),
                isHeavy: true
            )
        }
    }

    static func vibeVoice(_ quantization: VibeVoiceQuantization) -> Self {
        let peak: UInt64
        switch quantization {
        case .fourBit:
            peak = 12 * gib
        case .sixBit:
            peak = 15 * gib
        case .eightBit:
            peak = 18 * gib
        }
        return Self(
            label: "VibeVoice \(quantization.rawValue)",
            estimatedPeakBytes: peak,
            isHeavy: true
        )
    }

    /// Gemma text generation reuses the language-model GGUF but does not load the multimodal audio
    /// projector. Keeping a distinct profile prevents the UI and admission gate from claiming the
    /// removed audio path still consumes several extra gigabytes.
    static func gemmaText(_ modelKey: String) -> Self {
        let model = GemmaConfiguration.models[modelKey]
        let modelBytes = catalogBytes(
            sizeGB: model?.sizeGB,
            directory: GemmaConfiguration.modelsDirectory,
            fileNames: [model?.modelFile]
        )
        return Self(
            label: "Gemma text \(modelKey)",
            estimatedPeakBytes: max(5 * gib, modelBytes + 2 * gib),
            isHeavy: true
        )
    }

    static func gemmaAudio(_ modelKey: String = GemmaConfiguration.defaultAudioModel) -> Self {
        let model = GemmaConfiguration.models[modelKey]
        let modelBytes = catalogBytes(
            sizeGB: model?.sizeGB,
            directory: GemmaConfiguration.modelsDirectory,
            fileNames: [model?.modelFile, model?.mmprojFile]
        )
        return Self(
            label: "Gemma audio consensus \(modelKey)",
            // Preserve the proven 12B admission profile: mapped model + projector plus 2 GiB
            // runtime allowance. The shared pressure/compressor/swap checks and the live
            // llama-server emergency monitor remain the hard safety boundaries.
            estimatedPeakBytes: max(8 * gib, modelBytes + 2 * gib),
            isHeavy: true
        )
    }

    private static func catalogBytes(
        sizeGB: Double?,
        directory: URL,
        fileNames: [String?]
    ) -> UInt64 {
        let actual = fileNames.compactMap { name -> UInt64? in
            guard let name else { return nil }
            return SystemMemoryGate.fileSize(at: directory.appendingPathComponent(name))
        }.reduce(0, +)
        if actual > 0 { return actual }
        return UInt64(max(0, sizeGB ?? 0) * Double(gib))
    }
}

/// The exact memory thresholds used to decide whether a transcription model may start.
///
/// Keeping this as a value shared by the gate and UI prevents the displayed target from drifting
/// away from the safety decision. `readiness` is deliberately an at-a-glance indicator: the
/// lowest-scoring requirement wins, while the individual byte shortfalls explain what must change.
struct TranscriptionMemoryRequirements: Equatable, Sendable {
    let profileLabel: String
    let estimatedPeakBytes: UInt64
    let launchReserveBytes: UInt64
    /// Comfortable launch target that avoids deliberately paging other applications.
    let idealHeadroomBytes: UInt64
    /// Maximum part of the ideal target macOS may satisfy through compression/swap.
    let pagingAllowanceBytes: UInt64
    /// Hard launch floor after applying the controlled paging allowance.
    let requiredHeadroomBytes: UInt64
    let systemReserveBytes: UInt64
    let minimumPhysicalBytes: UInt64
    let compressorLimitBytes: UInt64?
    let swapLimitBytes: UInt64?

    func headroomShortfall(for snapshot: SystemMemorySnapshot) -> UInt64 {
        requiredHeadroomBytes > snapshot.availableBytes
            ? requiredHeadroomBytes - snapshot.availableBytes
            : 0
    }

    func expectedPagingBytes(for snapshot: SystemMemorySnapshot) -> UInt64 {
        idealHeadroomBytes > snapshot.availableBytes
            ? idealHeadroomBytes - snapshot.availableBytes
            : 0
    }

    func physicalMemoryShortfall(for snapshot: SystemMemorySnapshot) -> UInt64 {
        minimumPhysicalBytes > snapshot.physicalBytes
            ? minimumPhysicalBytes - snapshot.physicalBytes
            : 0
    }

    func compressorExcess(for snapshot: SystemMemorySnapshot) -> UInt64 {
        guard let limit = compressorLimitBytes,
              snapshot.compressorBytes > limit else { return 0 }
        return snapshot.compressorBytes - limit
    }

    func swapExcess(for snapshot: SystemMemorySnapshot) -> UInt64 {
        guard let limit = swapLimitBytes,
              let used = snapshot.swapUsedBytes,
              used > limit else { return 0 }
        return used - limit
    }

    func readiness(for snapshot: SystemMemorySnapshot) -> Double {
        var ratios = [
            progress(current: snapshot.availableBytes, target: requiredHeadroomBytes),
            progress(current: snapshot.physicalBytes, target: minimumPhysicalBytes)
        ]

        if let limit = compressorLimitBytes, snapshot.compressorBytes > limit {
            ratios.append(progress(current: limit, target: snapshot.compressorBytes))
        }
        if let limit = swapLimitBytes,
           let used = snapshot.swapUsedBytes,
           used > limit {
            ratios.append(progress(current: limit, target: used))
        }
        return ratios.min() ?? 0
    }

    private func progress(current: UInt64, target: UInt64) -> Double {
        guard target > 0 else { return 1 }
        return min(1, max(0, Double(current) / Double(target)))
    }
}

/// Strict admission for user and scheduled transcription. Unlike the background gate below, this
/// fails closed when sampling is unavailable and blocks heavy launches on existing compressor/swap
/// debt. A queued job remains pending and is re-evaluated as the machine becomes safe.
enum TranscriptionMemoryAdmission {
    enum Decision: Equatable {
        case proceed
        case deferred(reason: String, retryAfter: TimeInterval)
    }

    private static let gib: UInt64 = 1_073_741_824
    /// A foreground transcription gets first claim on recovered memory shortly after an OOM.
    /// The longer exponential backoff still protects deferrable background work.
    private static let minimumForegroundRecoveryGrace: TimeInterval = 15

    static func requirements(
        snapshot: SystemMemorySnapshot,
        profile: TranscriptionResourceProfile
    ) -> TranscriptionMemoryRequirements {
        let systemReserve = max(4 * gib, snapshot.physicalBytes / 5)
        let launchReserve = profile.isHeavy ? 2 * gib : gib
        let idealHeadroom = profile.estimatedPeakBytes + launchReserve
        // There is no supported API to command macOS to swap a particular process. Launching with
        // a bounded deficit is the safe equivalent: the VM compressor/pager reclaims cold pages as
        // the foreground model grows. Permit up to five-twelfths of physical RAM (10 GiB max) so a
        // 24 GiB Mac can run a single 12 GiB model while paging idle browser tabs. Only heavy
        // user-facing
        // models get this elasticity; pressure, compressor debt, physical reserve, headroom, and
        // emergency monitoring still gate it. Existing swap is a weak launch signal on macOS:
        // swap files and cold pages remain allocated long after a memory-heavy app exits. Allow
        // that historical debt up to 20 GiB, while the live pressure/compressor checks and the
        // stricter running-process emergency monitor continue to stop an actively deteriorating
        // machine.
        let pagingAllowance = profile.isHeavy
            ? min(10 * gib, snapshot.physicalBytes * 5 / 12)
            : 0
        return TranscriptionMemoryRequirements(
            profileLabel: profile.label,
            estimatedPeakBytes: profile.estimatedPeakBytes,
            launchReserveBytes: launchReserve,
            idealHeadroomBytes: idealHeadroom,
            pagingAllowanceBytes: pagingAllowance,
            requiredHeadroomBytes: idealHeadroom - min(idealHeadroom, pagingAllowance),
            systemReserveBytes: systemReserve,
            minimumPhysicalBytes: profile.estimatedPeakBytes + systemReserve,
            compressorLimitBytes: profile.isHeavy
                ? max(8 * gib, snapshot.physicalBytes * 3 / 4)
                : nil,
            swapLimitBytes: profile.isHeavy
                ? 20 * gib
                : nil
        )
    }

    static func decision(
        snapshot: SystemMemorySnapshot?,
        profile: TranscriptionResourceProfile,
        pressure: MemoryPressureLevel,
        oomCooldownRemaining: TimeInterval
    ) -> Decision {
        if pressure != .normal {
            return .deferred(
                reason: "system memory pressure \(pressure.rawValue)",
                retryAfter: 30
            )
        }
        guard let snapshot else {
            return .deferred(
                reason: "memory safety check unavailable",
                retryAfter: 60
            )
        }

        let requirements = requirements(snapshot: snapshot, profile: profile)
        if snapshot.physicalBytes < requirements.minimumPhysicalBytes {
            return .deferred(
                reason: "\(profile.label) needs about \(formatGB(profile.estimatedPeakBytes)) plus \(formatGB(requirements.systemReserveBytes)) system reserve; this Mac has \(formatGB(snapshot.physicalBytes))",
                retryAfter: 300
            )
        }

        if let compressorLimit = requirements.compressorLimitBytes,
           snapshot.compressorBytes > compressorLimit {
            return .deferred(
                reason: "memory compressor already holds \(formatGB(snapshot.compressorBytes)); close memory-heavy apps first",
                retryAfter: 60
            )
        }

        if let swapLimit = requirements.swapLimitBytes,
           let swapUsed = snapshot.swapUsedBytes,
           swapUsed > swapLimit {
            return .deferred(
                reason: "swap is already high (\(formatGB(swapUsed))); close memory-heavy apps first",
                retryAfter: 60
            )
        }

        if snapshot.availableBytes < requirements.requiredHeadroomBytes {
            return .deferred(
                reason: "\(formatGB(snapshot.availableBytes)) safe headroom available; \(profile.label) requires \(formatGB(requirements.requiredHeadroomBytes)) minimum (\(formatGB(requirements.idealHeadroomBytes)) ideal; macOS may page the difference)",
                retryAfter: 5
            )
        }
        if oomCooldownRemaining > 0 {
            return .deferred(
                reason: "GPU recovery grace (\(Int(ceil(oomCooldownRemaining)))s remaining)",
                retryAfter: min(5, oomCooldownRemaining)
            )
        }
        return .proceed
    }

    /// Once every strict live-memory target is met, foreground transcription only observes a short
    /// GPU-drain grace instead of inheriting the background queue's full exponential OOM backoff.
    /// Unsafe memory never bypasses anything: `decision` still evaluates pressure, compressor,
    /// swap, physical reserve, and headroom before considering this effective cooldown.
    static func foregroundCooldownRemaining(
        oomCooldownRemaining: TimeInterval,
        timeSinceLastOOM: TimeInterval?,
        consecutiveOOMs: Int
    ) -> TimeInterval {
        guard oomCooldownRemaining > 0 else { return 0 }
        guard let timeSinceLastOOM else { return oomCooldownRemaining }
        return min(
            oomCooldownRemaining,
            max(
                0,
                foregroundRecoveryGrace(consecutiveOOMs: consecutiveOOMs)
                    - max(0, timeSinceLastOOM)
            )
        )
    }

    /// Foreground remains responsive after an isolated background OOM, but a model which itself
    /// repeatedly fails gets enough drain time to avoid hammering Metal indefinitely.
    static func foregroundRecoveryGrace(consecutiveOOMs: Int) -> TimeInterval {
        guard consecutiveOOMs > 0 else { return 0 }
        return min(
            minimumForegroundRecoveryGrace * pow(2, Double(consecutiveOOMs - 1)),
            120
        )
    }

    /// Conditions under which an already-running large child must be stopped. We cannot compare
    /// remaining headroom with the full launch requirement after the model is resident; instead,
    /// react to macOS pressure and hard exhaustion signals.
    static func emergencyReason(
        snapshot: SystemMemorySnapshot?,
        profile: TranscriptionResourceProfile,
        pressure: MemoryPressureLevel
    ) -> String? {
        guard profile.isHeavy else { return nil }
        // A warning is macOS doing the compression/paging we explicitly budgeted for at launch.
        // Killing at warning made a single admitted model restart forever on a 24 GB Mac with
        // ordinary Chrome usage. Critical pressure and the concrete hard limits below still stop
        // the child immediately.
        if pressure == .critical {
            return "system memory pressure became \(pressure.rawValue)"
        }
        guard let snapshot else {
            return "memory safety monitor became unavailable"
        }
        if snapshot.availableBytes < gib {
            return "safe memory headroom fell below 1.0 GB"
        }
        if snapshot.compressorBytes > snapshot.physicalBytes * 3 / 4 {
            return "memory compressor exceeded 75% of physical memory"
        }
        if let swapUsed = snapshot.swapUsedBytes,
           swapUsed > 20 * gib {
            return "swap exceeded the 20 GB emergency limit"
        }
        return nil
    }

    private static func formatGB(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / Double(gib))
    }
}

/// Pure decision core for launching background GPU work (insights / cleanup / embedding) under
/// memory pressure. Unit-tested in `BackgroundGPUGateTests`; `SystemMemoryGate` supplies the live
/// inputs.
///
/// Why: on 2026-06-10 the machine kernel-panicked twice (watchdog timeout) while background queues
/// kept launching multi-GB llama.cpp model loads into a starved system — the second freeze came
/// ~10s after an insights run died with `kIOGPUCommandBufferCallbackErrorOutOfMemory` while
/// launchd was jetsam-killing daemons. Background work is deferrable by definition; the gate makes
/// it actually defer. Transcription uses the stricter `TranscriptionMemoryAdmission` above.
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

    /// Fast exponential backoff after a Metal OOM: retry after 30s, then 1/2/4 minutes, capped at
    /// 5 minutes. The queue must stop its current attempt at the first OOM, so this rate limits
    /// retries without idling healthy compute for half an hour.
    static func cooldown(consecutiveOOMs: Int) -> TimeInterval {
        guard consecutiveOOMs > 0 else { return 0 }
        return min(30 * pow(2, Double(consecutiveOOMs - 1)), 300)
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
    private var lastOOMAt: Date?
    private var consecutiveOOMs = 0
    private var lastDeferralReason: String?
    private var lastTranscriptionDeferralReason: String?
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

    /// Why a transcription launch must wait right now, or nil to proceed.
    func transcriptionDeferral(
        profile: TranscriptionResourceProfile
    ) -> (reason: String, retryAfter: TimeInterval)? {
        lock.lock()
        let remaining = max(0, cooldownUntil.map { $0.timeIntervalSinceNow } ?? 0)
        let timeSinceLastOOM = lastOOMAt.map { max(0, Date().timeIntervalSince($0)) }
        let oomCount = consecutiveOOMs
        let level = pressure
        lock.unlock()

        let effectiveCooldown = TranscriptionMemoryAdmission.foregroundCooldownRemaining(
            oomCooldownRemaining: remaining,
            timeSinceLastOOM: timeSinceLastOOM,
            consecutiveOOMs: oomCount
        )
        let decision = TranscriptionMemoryAdmission.decision(
            snapshot: Self.memorySnapshot(),
            profile: profile,
            pressure: level,
            oomCooldownRemaining: effectiveCooldown
        )
        switch decision {
        case .proceed:
            lock.lock()
            let cleared = lastTranscriptionDeferralReason != nil
            lastTranscriptionDeferralReason = nil
            lock.unlock()
            if cleared {
                logger.info("[MemoryGate] Transcription launches resumed")
            }
            return nil
        case let .deferred(reason, retryAfter):
            let loggedReason = "\(profile.label): \(reason)"
            lock.lock()
            let isNewReason = lastTranscriptionDeferralReason != loggedReason
            lastTranscriptionDeferralReason = loggedReason
            lock.unlock()
            if isNewReason {
                logger.warning("[MemoryGate] Transcription launch deferred: \(loggedReason)")
            }
            return (reason, retryAfter)
        }
    }

    /// Used by a running heavy child process to stop before warning pressure turns into a
    /// compressor/swap watchdog panic.
    func transcriptionEmergencyReason(
        profile: TranscriptionResourceProfile
    ) -> String? {
        lock.lock()
        let level = pressure
        lock.unlock()
        return TranscriptionMemoryAdmission.emergencyReason(
            snapshot: Self.memorySnapshot(),
            profile: profile,
            pressure: level
        )
    }

    /// A llama.cpp/whisper child died with the Metal OOM signature: open (or extend) the cooldown.
    func reportMetalOOM(source: String) {
        lock.lock()
        consecutiveOOMs += 1
        let cooldown = BackgroundGPUAdmission.cooldown(consecutiveOOMs: consecutiveOOMs)
        let now = Date()
        lastOOMAt = now
        cooldownUntil = now.addingTimeInterval(cooldown)
        let count = consecutiveOOMs
        lock.unlock()
        let foregroundGrace = TranscriptionMemoryAdmission.foregroundRecoveryGrace(
            consecutiveOOMs: count
        )
        logger.warning("[MemoryGate] Metal OOM from \(source) (consecutive: \(count)) — background GPU launches paused \(Int(cooldown))s; foreground may resume after live checks + \(Int(foregroundGrace))s grace")
    }

    /// A GPU child process completed successfully — the OOM streak (if any) is over.
    func reportGPUJobSuccess() {
        lock.lock()
        let hadCooldown = consecutiveOOMs > 0 || cooldownUntil != nil
        consecutiveOOMs = 0
        cooldownUntil = nil
        lastOOMAt = nil
        lock.unlock()
        if hadCooldown { logger.info("[MemoryGate] GPU job succeeded — OOM cooldown cleared") }
    }

    // MARK: - Inputs

    /// Memory reclaimable without paging anonymous pages out: free + purgeable + file-backed.
    /// (At the 2026-06-10 panic the box had 28 swapfiles on 24 GB — anonymous memory was already
    /// the problem, so only genuinely cheap-to-reclaim pages count as available.)
    static func availableMemoryBytes() -> UInt64? {
        memorySnapshot()?.availableBytes
    }

    static func memorySnapshot() -> SystemMemorySnapshot? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pageSize = UInt64(vm_page_size)
        let available = (
            UInt64(stats.free_count)
                + UInt64(stats.purgeable_count)
                + UInt64(stats.external_page_count)
        ) * pageSize
        let swap = swapUsage()
        return SystemMemorySnapshot(
            physicalBytes: ProcessInfo.processInfo.physicalMemory,
            availableBytes: available,
            compressorBytes: UInt64(stats.compressor_page_count) * pageSize,
            swapUsedBytes: swap?.used,
            swapAvailableBytes: swap?.available
        )
    }

    /// On-disk size of a model file, for the headroom requirement.
    static func fileSize(at url: URL?) -> UInt64? {
        guard let path = url?.path,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64 else { return nil }
        return size
    }

    private static func swapUsage() -> (used: UInt64, available: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let result = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        guard result == 0 else { return nil }
        return (usage.xsu_used, usage.xsu_avail)
    }
}
