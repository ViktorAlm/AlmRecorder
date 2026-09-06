import Foundation

struct NightlyProcessingWindow: Codable, Equatable {
    var startMinute: Int
    var endMinute: Int

    static let defaultWindow = NightlyProcessingWindow(
        startMinute: 22 * 60,
        endMinute: 7 * 60
    )

    var duration: TimeInterval {
        let minutes = startMinute == endMinute
            ? 24 * 60
            : (endMinute - startMinute + 24 * 60) % (24 * 60)
        return TimeInterval(minutes * 60)
    }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if startMinute == endMinute { return true }
        if startMinute < endMinute {
            return minute >= startMinute && minute < endMinute
        }
        return minute >= startMinute || minute < endMinute
    }

    func nextStart(after date: Date, calendar: Calendar = .current) -> Date? {
        let startHour = startMinute / 60
        let startMinuteOfHour = startMinute % 60
        let today = calendar.date(
            bySettingHour: startHour,
            minute: startMinuteOfHour,
            second: 0,
            of: date
        )
        if let today, today > date { return today }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) else {
            return nil
        }
        return calendar.date(
            bySettingHour: startHour,
            minute: startMinuteOfHour,
            second: 0,
            of: tomorrow
        )
    }
}

struct TranscriptionSchedulingPolicy: Codable, Equatable {
    let nightlyRunID: UUID
    let window: NightlyProcessingWindow

    func allows(_ date: Date = Date(), calendar: Calendar = .current) -> Bool {
        window.contains(date, calendar: calendar)
    }
}

/// Run settings for a transcription job
struct RunSettings: Codable, Equatable {
    let temperature: Double
    let topK: Int
    let topP: Double?
    let maxTokens: Int
    let contextKeep: Int
    let gpuLayers: Int
    let seed: Int?
    let prompt: String

    /// Engine/model snapshot captured when the job enters the queue. Optional for backwards
    /// compatibility with jobs persisted before engine snapshots existed.
    var engineSelection: TranscriptionEngineSelection? = nil

    /// Speaker-pipeline snapshot captured with the engine. A long or nightly queue must not change
    /// behavior halfway through because the user experiments with Settings while later jobs wait.
    var speakerProfile: SpeakerPipelineProfile? = nil
    var speakerConfiguration: SpeakerPipelineConfiguration? = nil
    var schedulingPolicy: TranscriptionSchedulingPolicy? = nil
    
    // Default settings
    static let defaultSettings = RunSettings(
        temperature: 0.0,
        topK: 1,
        topP: nil,
        maxTokens: 15000,
        contextKeep: 512,
        gpuLayers: -1,  // Use all GPU layers
        seed: nil,
        prompt: "Transcribe the following audio verbatim. Output only the transcription without any explanations or notes."
    )
    
    // Format for display
    var displayString: String {
        var parts: [String] = []
        parts.append("T:\(String(format: "%.1f", temperature))")
        parts.append("K:\(topK)")
        if let topP = topP {
            parts.append("P:\(String(format: "%.1f", topP))")
        }
        if let seed = seed {
            parts.append("S:\(seed)")
        }
        return parts.joined(separator: " ")
    }
    
    var compactDisplay: String {
        if let engineSelection {
            return "\(engineSelection.displayName) · T:\(String(format: "%.1f", temperature)) K:\(topK)"
        }
        return "T:\(String(format: "%.1f", temperature)) K:\(topK)"
    }

    func snapshottingEngineIfNeeded(
        from settings: GlobalModelSettings = .shared
    ) -> RunSettings {
        var copy = self
        if copy.engineSelection == nil {
            copy.engineSelection = .snapshot(from: settings)
        }
        if copy.speakerProfile == nil {
            copy.speakerProfile = SpeakerPipelineSettings.shared.selectedProfile
        }
        if copy.speakerConfiguration == nil {
            copy.speakerConfiguration = SpeakerPipelineSettings.shared.activeConfiguration
        }
        return copy
    }

    /// Preserve the immutable job snapshot while changing only llama.cpp's layer offload. This is
    /// used for the one-shot Voxtral CPU recovery path after a typed Metal OOM.
    func withGpuLayers(_ gpuLayers: Int) -> RunSettings {
        var copy = RunSettings(
            temperature: temperature,
            topK: topK,
            topP: topP,
            maxTokens: maxTokens,
            contextKeep: contextKeep,
            gpuLayers: gpuLayers,
            seed: seed,
            prompt: prompt
        )
        copy.engineSelection = engineSelection
        copy.speakerProfile = speakerProfile
        copy.speakerConfiguration = speakerConfiguration
        copy.schedulingPolicy = schedulingPolicy
        return copy
    }
}

/// Checkpoint data for resuming interrupted jobs
struct TranscriptionCheckpoint: Codable {
    /// Backend that produced this checkpoint. A nil value is a legacy Whisper checkpoint from
    /// before backend-tagged checkpoints existed.
    var backend: TranscriptionBackend? = nil
    /// Indices of VAD chunks or VibeVoice outer windows that have been fully processed.
    var processedChunks: [Int]
    /// Per-chunk transcript results, keyed by VAD chunk or VibeVoice window index.
    var chunkTranscripts: [Int: [ChunkResult]]
    /// Global time offset after each chunk/window, keyed by its index.
    var chunkOffsets: [Int: Double]
    /// Smallest recovery depth known to be necessary for each VibeVoice outer window. Optional so
    /// checkpoints written before adaptive VibeVoice recovery remain decodable.
    var vibeVoiceRecoveryDepths: [Int: Int]? = nil
    /// When the checkpoint was last saved
    var lastProcessedTime: Date

    /// Transcript result for a single segment within a VAD chunk
    struct ChunkResult: Codable {
        let text: String
        let startTime: Double
        let endTime: Double
        let speaker: String?
        let speakerUUID: String?
        let nativeSpeakerLabel: String?

        init(
            text: String,
            startTime: Double,
            endTime: Double,
            speaker: String?,
            speakerUUID: String?,
            nativeSpeakerLabel: String? = nil
        ) {
            self.text = text
            self.startTime = startTime
            self.endTime = endTime
            self.speaker = speaker
            self.speakerUUID = speakerUUID
            self.nativeSpeakerLabel = nativeSpeakerLabel
        }

        init(chunk: TranscriptionChunk) {
            self.init(
                text: chunk.text,
                startTime: chunk.startTime,
                endTime: chunk.endTime,
                speaker: chunk.speaker,
                speakerUUID: chunk.speakerUUID,
                nativeSpeakerLabel: chunk.nativeSpeakerLabel
            )
        }

        var transcriptionChunk: TranscriptionChunk {
            TranscriptionChunk(
                text: text,
                startTime: startTime,
                endTime: endTime,
                speaker: speaker,
                speakerUUID: speakerUUID,
                nativeSpeakerLabel: nativeSpeakerLabel,
                confidence: nil
            )
        }
    }

    static var empty: TranscriptionCheckpoint {
        TranscriptionCheckpoint(processedChunks: [], chunkTranscripts: [:],
                                chunkOffsets: [:], lastProcessedTime: Date())
    }
}

/// Represents a single transcription job in the queue
struct TranscriptionJob: Identifiable, Equatable {
    var id = UUID()  // Made var to support restoration from persistence
    let audioFilePath: String
    let fileName: String
    let source: TranscriptionItem.TranscriptionSource
    
    var priority: Priority = .normal
    var status: JobStatus = .pending
    var progress: Double = 0.0
    var progressMessage: String = ""
    
    // Detailed progress tracking
    var progressPhase: ProgressPhase = .waiting
    var totalChunks: Int = 0
    var completedChunks: Int = 0
    var currentChunkProgress: Double = 0.0
    var estimatedTimeRemaining: TimeInterval? = nil
    var chunkProcessingTimes: [TimeInterval] = []
    
    let createdAt = Date()
    var startedAt: Date?
    var completedAt: Date?
    
    var transcript: String?
    var error: String?
    var errorDiagnostics: String? // JSON string containing detailed diagnostic data
    var retryCount: Int = 0
    let maxRetries: Int = 2
    
    // Store the full transcription result for speaker detection
    var transcriptionResult: TranscriptionResult?
    var recordingId: Int64?
    var existingRecordingId: Int64?  // Set for re-transcription: update existing recording instead of creating new
    
    // Additional metadata
    var fileSize: Int64?
    var duration: TimeInterval?
    var modelUsed: String?
    
    // Model requirements
    var requiredModel: String? = nil  // The model this job needs
    var modelDownloadId: String? = nil  // ID of active model download
    
    // Prompt test specific
    var promptConfig: PromptTestConfig? = nil  // For prompt lab tests
    var isPromptTest: Bool = false
    
    // Run settings used for this job
    var runSettings: RunSettings = RunSettings.defaultSettings
    
    // Worker tracking for multi-worker system
    var workerId: String?
    var lastHeartbeat: Date?
    
    // Checkpoint for resuming interrupted jobs
    var checkpointData: TranscriptionCheckpoint?
    
    enum ProgressPhase: String {
        case waiting = "Waiting"
        case preparingAudio = "Preparing Audio"
        case splittingChunks = "Splitting into Chunks"
        case transcribingChunks = "Transcribing Chunks"
        case combiningResults = "Combining Results"
        case finalizing = "Finalizing"
        
        var displayName: String {
            return self.rawValue
        }
        
        var icon: String {
            switch self {
            case .waiting:
                return "clock"
            case .preparingAudio:
                return "waveform"
            case .splittingChunks:
                return "scissors"
            case .transcribingChunks:
                return "text.bubble"
            case .combiningResults:
                return "doc.on.doc"
            case .finalizing:
                return "checkmark.circle"
            }
        }
    }
    
    enum Priority: Int, Comparable {
        case low = 0
        case normal = 1
        case high = 2
        case immediate = 3  // For user recordings that need instant feedback
        
        static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }
    
    enum JobStatus: String {
        case pending = "Pending"
        case processing = "Processing"
        case paused = "Paused"
        case interrupted = "Interrupted"  // Was processing when app crashed
        case completed = "Completed"
        case failed = "Failed"
        case cancelled = "Cancelled"
        case retrying = "Retrying"
        case waitingForModel = "Waiting for Model"
        
        var isActive: Bool {
            switch self {
            case .processing, .retrying, .waitingForModel:
                return true
            default:
                return false
            }
        }
        
        var isFinished: Bool {
            switch self {
            case .completed, .failed, .cancelled:
                return true
            default:
                return false
            }
        }
    }
    
    // Computed properties
    var canRetry: Bool {
        status == .failed && retryCount < maxRetries
    }

    /// A pending job may be deliberately deferred rather than merely waiting its turn. Keep the
    /// reason on the job so every queue surface can explain the state consistently.
    var pendingReason: String? {
        guard status == .pending else { return nil }
        let reason = progressMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? nil : reason
    }

    var isWaitingForSafeMemory: Bool {
        pendingReason?.hasPrefix("Waiting for safe memory") == true
    }

    var pendingReasonDetail: String? {
        guard let pendingReason else { return nil }
        let prefix = "Waiting for safe memory · "
        if pendingReason.hasPrefix(prefix) {
            return String(pendingReason.dropFirst(prefix.count))
        }
        return pendingReason
    }
    
    var processingTime: TimeInterval? {
        guard let start = startedAt else { return nil }
        let end = completedAt ?? Date()
        return end.timeIntervalSince(start)
    }
    
    // Calculate detailed progress based on chunks
    var detailedProgress: Double {
        switch progressPhase {
        case .waiting:
            return 0.0
        case .preparingAudio:
            return 0.05 // 5% for audio preparation
        case .splittingChunks:
            return 0.10 // 10% for splitting
        case .transcribingChunks:
            // 10% to 90% for transcription based on chunks
            if totalChunks > 0 {
                // completedChunks: number of fully completed chunks
                // currentChunkProgress: progress of the current chunk (0.0 to 1.0)
                let completedProgress = Double(completedChunks) / Double(totalChunks)
                let currentProgress = currentChunkProgress / Double(totalChunks)  // Current chunk's contribution
                return 0.10 + (completedProgress + currentProgress) * 0.80
            }
            return 0.10
        case .combiningResults:
            return 0.90 // 90% for combining
        case .finalizing:
            return 0.95 // 95% for finalizing
        }
    }
    
    // Calculate ETA based on chunk processing times
    var calculatedETA: TimeInterval? {
        guard progressPhase == .transcribingChunks,
              totalChunks > 0,
              completedChunks > 0,
              !chunkProcessingTimes.isEmpty else {
            return estimatedTimeRemaining
        }
        
        let averageChunkTime = chunkProcessingTimes.reduce(0, +) / Double(chunkProcessingTimes.count)
        let remainingChunks = totalChunks - completedChunks
        return averageChunkTime * Double(remainingChunks)
    }
    
    // Format progress message with details
    var detailedProgressMessage: String {
        switch progressPhase {
        case .waiting:
            return progressMessage.isEmpty ? "Waiting to start..." : progressMessage
        case .preparingAudio:
            return "Preparing audio file..."
        case .splittingChunks:
            return "Splitting audio into chunks..."
        case .transcribingChunks:
            if totalChunks > 0 {
                let percentage = Int(detailedProgress * 100)
                // Show the current chunk being processed (completedChunks + 1)
                // But if we're at 100% of current chunk, we're actually done with it
                let currentChunk = currentChunkProgress >= 1.0 ? completedChunks : completedChunks + 1
                var message = "Processing chunk \(currentChunk) of \(totalChunks) (\(percentage)%)"
                if let eta = calculatedETA, eta > 0 {
                    let formatter = DateComponentsFormatter()
                    formatter.allowedUnits = [.minute, .second]
                    formatter.unitsStyle = .abbreviated
                    if let etaString = formatter.string(from: eta) {
                        message += " - ETA: \(etaString)"
                    }
                }
                return message
            }
            return "Transcribing audio..."
        case .combiningResults:
            return "Combining transcription results..."
        case .finalizing:
            return "Finalizing transcription..."
        }
    }
    
    var formattedFileSize: String? {
        guard let size = fileSize else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
    
    var formattedDuration: String? {
        guard let duration = duration else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration)
    }
    
    static func == (lhs: TranscriptionJob, rhs: TranscriptionJob) -> Bool {
        lhs.id == rhs.id
    }
}
