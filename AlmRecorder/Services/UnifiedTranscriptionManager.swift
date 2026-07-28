import Foundation
import Combine
import AVFoundation
import GRDB

/// Unified manager for all transcription operations in the app
/// This ensures consistent handling of transcriptions from any source
class UnifiedTranscriptionManager: ObservableObject {
    static let shared = UnifiedTranscriptionManager()
    
    // MARK: - Published Properties
    @Published var isTranscribing = false
    @Published var transcriptionProgress: Double = 0.0
    @Published var transcriptionStatus: String = ""
    @Published var currentFileProgress: Double = 0.0
    @Published var lastTranscriptionItem: TranscriptionItem?
    
    // MARK: - Services
    private let transcriptionService = TranscriptionService()
    private let whisperService = WhisperService.shared
    private let voxtralService = VoxtralCppService()
    private let gemmaService = GemmaCppService()
    private let vibeVoiceService = VibeVoiceService.shared
    private let logger = VoxtralLogger.shared
    private let recordingRepo = GRDBRecordingRepository()
    private let utteranceProcessor = UtteranceProcessor()
    private let modelSettings = GlobalModelSettings.shared
    private let dbManager = GRDBDatabaseManager.shared
    private var cancellables = Set<AnyCancellable>()
    
    // Track the last created recording ID for transcribeWithResult
    private var lastCreatedRecordingId: Int64?
    /// Exact retryable resource failure from the last serialized transcription. The queue consumes
    /// this so an OOM or proactive memory stop returns the job to `.pending` instead of `.failed`.
    private var lastResourceFailure: TranscriptionError?
    
    // MARK: - Init
    private init() {
        setupBindings()
        logger.info("[UnifiedTranscriptionManager] Initialized")
    }
    
    private func setupBindings() {
        // Bind status from TranscriptionService (which manages the active backend)
        transcriptionService.$transcriptionStatus
            .receive(on: DispatchQueue.main)
            .assign(to: &$transcriptionStatus)
        
        transcriptionService.$transcriptionProgress
            .receive(on: DispatchQueue.main)
            .assign(to: &$transcriptionProgress)
        
        // Also monitor Whisper service status when it's active
        whisperService.$isTranscribing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isTranscribing in
                if self?.transcriptionService.currentBackend == .whisper {
                    self?.isTranscribing = isTranscribing
                }
            }
            .store(in: &cancellables)
        
        whisperService.$transcriptionProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                if self?.transcriptionService.currentBackend == .whisper {
                    self?.currentFileProgress = progress
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Public Methods
    
    /// Transcribe audio and return both the item and the full result with speaker information
    func transcribeWithResult(
        audioFile: String,
        fileName: String? = nil,
        source: TranscriptionItem.TranscriptionSource,
        language: String = "auto-detected",
        runSettings: RunSettings? = nil,
        existingRecordingId: Int64? = nil,
        progressHandler: ((TranscriptionJob.ProgressPhase, Double, String, Int?, Int?) async -> Void)? = nil
    ) async -> (TranscriptionItem, TranscriptionResult?, Int64?) {
        // Store the transcription result and recording ID
        var capturedResult: TranscriptionResult?
        var capturedRecordingId: Int64?
        
        logger.info("[UnifiedTranscriptionManager.transcribeWithResult] Starting transcription with result capture")
        logger.info("[UnifiedTranscriptionManager.transcribeWithResult] Backend: \(transcriptionService.currentBackend)")
        
        // Reset the last created recording ID before transcribing
        self.lastCreatedRecordingId = nil
        self.lastResourceFailure = nil
        
        // Call the regular transcribe method with progress handler
        let item = await transcribe(
            audioFile: audioFile,
            fileName: fileName,
            source: source,
            language: language,
            runSettings: runSettings,
            existingRecordingId: existingRecordingId,
            progressHandler: progressHandler
        )
        
        // Try to get the result from the transcription service
        if transcriptionService.currentBackend == .whisper {
            capturedResult = whisperService.lastTranscriptionResult
            logger.info("[UnifiedTranscriptionManager.transcribeWithResult] Captured WhisperService result: \(capturedResult != nil ? "Present" : "nil")")
            if let result = capturedResult {
                logger.info("[UnifiedTranscriptionManager.transcribeWithResult] Speaker count: \(result.detectedSpeakerCount ?? -1), embeddings: \(result.speakerEmbeddings?.count ?? 0)")
            }
        } else if transcriptionService.currentBackend == .gemma {
            capturedResult = gemmaService.lastTranscriptionResult
            logger.info("[UnifiedTranscriptionManager.transcribeWithResult] Captured GemmaService result: \(capturedResult != nil ? "Present" : "nil")")
        } else if transcriptionService.currentBackend == .vibeVoice {
            capturedResult = vibeVoiceService.lastTranscriptionResult
            logger.info("[UnifiedTranscriptionManager.transcribeWithResult] Captured VibeVoice result: \(capturedResult != nil ? "Present" : "nil")")
        } else {
            capturedResult = voxtralService.lastTranscriptionResult
            logger.info("[UnifiedTranscriptionManager.transcribeWithResult] Captured VoxtralService result: \(capturedResult != nil ? "Present" : "nil")")
        }
        
        // Get the recording ID that was created during processIntoUtterances
        if let recordingId = self.lastCreatedRecordingId {
            capturedRecordingId = recordingId
            logger.info("[UnifiedTranscriptionManager.transcribeWithResult] Using captured recording ID: \(recordingId)")
        } else {
            // Fallback to getting last recording from database (less reliable in batch scenarios)
            if let lastRecording = recordingRepo.getLastRecording() {
                capturedRecordingId = lastRecording.id
                logger.warning("[UnifiedTranscriptionManager.transcribeWithResult] Fallback to last recording from DB: \(capturedRecordingId ?? -1)")
            } else {
                logger.error("[UnifiedTranscriptionManager.transcribeWithResult] No recording found - this will prevent speaker review!")
            }
        }
        
        logger.info("[UnifiedTranscriptionManager.transcribeWithResult] Returning - Item: \(item.status), Result: \(capturedResult != nil), RecordingID: \(capturedRecordingId ?? -1)")
        
        return (item, capturedResult, capturedRecordingId)
    }

    func consumeLastResourceFailure() -> TranscriptionError? {
        defer { lastResourceFailure = nil }
        return lastResourceFailure
    }
    
    /// Transcribe audio from any source and automatically save to history
    func transcribe(
        audioFile: String,
        fileName: String? = nil,
        source: TranscriptionItem.TranscriptionSource,
        language: String = "auto-detected",
        runSettings: RunSettings? = nil,
        existingRecordingId: Int64? = nil,
        progressHandler: ((TranscriptionJob.ProgressPhase, Double, String, Int?, Int?) async -> Void)? = nil
    ) async -> TranscriptionItem {
        logger.info("[UnifiedTranscriptionManager] Starting transcription for: \(audioFile)")
        logger.info("[UnifiedTranscriptionManager] Source: \(source.rawValue)")
        let effectiveRunSettings = (runSettings ?? .defaultSettings).snapshottingEngineIfNeeded()
        let speakerProfileAtStart = effectiveRunSettings.speakerProfile
            ?? SpeakerPipelineSettings.shared.selectedProfile
        let speakerConfigurationAtStart = effectiveRunSettings.speakerConfiguration
            ?? SpeakerPipelineSettings.shared.activeConfiguration
        let engineSelection = effectiveRunSettings.engineSelection
            ?? TranscriptionEngineSelection.snapshot()
        
        // Update progress: Starting
        await MainActor.run {
            self.isTranscribing = true
            self.transcriptionProgress = 0.0
            self.transcriptionStatus = "Preparing transcription..."
        }
        
        // Notify progress handler
        await progressHandler?(.preparingAudio, 0.0, "Preparing transcription...", nil, nil)
        
        // Get file info
        let url = URL(fileURLWithPath: audioFile)
        let actualFileName = fileName ?? url.lastPathComponent
        let fileSize = getFileSize(url)
        let duration = getAudioDuration(url)
        let createdDate = getFileCreationDate(url)
        
        // Ensure embedding model is loaded first
        await ensureEmbeddingModelLoaded()
        
        // Use the backend selected by the user. The "LLM" backend routes to the selected engine.
        let desiredBackend: TranscriptionService.Backend
        switch engineSelection.backend {
        case .whisper:
            desiredBackend = .whisper
        case .llm:
            desiredBackend = engineSelection.llmEngine == .gemma ? .gemma : .native
        case .vibeVoice:
            desiredBackend = .vibeVoice
        }

        var backendPreparationError: Error?
        if transcriptionService.currentBackend != desiredBackend {
            logger.info("[UnifiedTranscriptionManager] Switching to \(desiredBackend) backend")
            do {
                switch desiredBackend {
                case .whisper:
                    try await transcriptionService.switchToWhisper()
                case .gemma:
                    try await transcriptionService.switchToGemma()
                case .vibeVoice:
                    try await transcriptionService.switchToVibeVoice(
                        quantization: engineSelection.vibeVoiceQuantization ?? .sixBit
                    )
                default:
                    try await transcriptionService.switchToNative()
                }
            } catch {
                backendPreparationError = error
                logger.error("[UnifiedTranscriptionManager] Failed to prepare \(desiredBackend): \(error)")
            }
        }
        
        // Detect language from filename or source
        let detectedLanguage = detectLanguage(from: actualFileName, source: source) ?? "auto"
        logger.info("[UnifiedTranscriptionManager] Using language: \(detectedLanguage)")
        
        // Perform transcription
        let transcript: String
        let status: TranscriptionItem.TranscriptionStatus
        let errorMessage: String?
        
        do {
            if let backendPreparationError { throw backendPreparationError }
            // ALWAYS use the user's selected model from settings - no fallbacks
            let modelVariant = engineSelection.whisperVariantIdentifier
                .flatMap { WhisperModelVariant.fromIdentifier($0) }
                ?? modelSettings.selectedWhisperVariant
            
            // Download model if needed
            if desiredBackend == .whisper, let variant = modelVariant {
                if !WhisperModelManager.shared.isModelDownloaded(variant) {
                    logger.info("[UnifiedTranscriptionManager] Model not downloaded, downloading: \(variant.displayName)")
                    await progressHandler?(.preparingAudio, 0.02, "Downloading model: \(variant.displayName)...", nil, nil)
                    
                    do {
                        try await WhisperModelManager.shared.downloadModel(variant)
                        logger.info("[UnifiedTranscriptionManager] Model downloaded successfully: \(variant.displayName)")
                    } catch {
                        logger.error("[UnifiedTranscriptionManager] Failed to download model: \(error)")
                        throw error
                    }
                }
            }
            
            // Update progress: Starting transcription
            await progressHandler?(.preparingAudio, 0.05, "Preparing audio...", nil, nil)
            
            // Monitor WhisperService progress if using Whisper backend
            var progressTask: Task<Void, Never>? = nil
            if transcriptionService.currentBackend == .whisper && progressHandler != nil {
                progressTask = Task { [weak self] in
                    var lastProgress: Double = 0
                    var lastStatus = ""
                    var chunkCount = 0
                    
                    while !Task.isCancelled {
                        // Safely check if self still exists
                        guard let self = self else { break }
                        
                        let currentProgress = await MainActor.run { self.whisperService.transcriptionProgress }
                        let currentStatus = await MainActor.run { self.whisperService.transcriptionStatus }
                        
                        if currentProgress != lastProgress || currentStatus != lastStatus {
                            lastProgress = currentProgress
                            lastStatus = currentStatus
                            
                            // Update local status too
                            await MainActor.run {
                                self.transcriptionProgress = currentProgress
                                self.transcriptionStatus = currentStatus
                                self.currentFileProgress = currentProgress
                            }
                            
                            // Parse chunk information from status
                            var totalChunks: Int? = nil
                            var completedChunks: Int? = nil
                            
                            if currentStatus.lowercased().contains("chunk") {
                                // Parse "Processing chunk X of Y" or "Chunk X/Y" or similar
                                // Try both patterns: "chunk X of Y" and "Chunk X/Y"
                                let patterns = [
                                    #"[Cc]hunk\s+(\d+)\s+of\s+(\d+)"#,
                                    #"[Cc]hunk\s+(\d+)/(\d+)"#
                                ]
                                
                                for pattern in patterns {
                                    if let regex = try? NSRegularExpression(pattern: pattern, options: []),
                                       let match = regex.firstMatch(in: currentStatus, range: NSRange(currentStatus.startIndex..., in: currentStatus)) {
                                        if let currentRange = Range(match.range(at: 1), in: currentStatus),
                                           let totalRange = Range(match.range(at: 2), in: currentStatus),
                                           let current = Int(currentStatus[currentRange]),
                                           let total = Int(currentStatus[totalRange]) {
                                            completedChunks = current - 1  // Current chunk is in progress, not completed
                                            totalChunks = total
                                            chunkCount = total
                                            break
                                        }
                                    }
                                }
                            }
                            
                            // Determine phase based on status
                            let phase: TranscriptionJob.ProgressPhase
                            if currentStatus.contains("Preparing") || currentStatus.contains("Converting") {
                                phase = .preparingAudio
                            } else if currentStatus.contains("VAD") || currentStatus.contains("Splitting") || currentStatus.contains("Analyzing voice") {
                                phase = .splittingChunks
                            } else if currentStatus.contains("chunk") || currentStatus.contains("Transcribing") || currentStatus.contains("Processing") {
                                phase = .transcribingChunks
                            } else if currentStatus.contains("Combining") || currentStatus.contains("Unifying") {
                                phase = .combiningResults
                            } else if currentStatus.contains("Finalizing") {
                                phase = .finalizing
                            } else {
                                // Map based on progress value
                                if currentProgress < 0.1 {
                                    phase = .preparingAudio
                                } else if currentProgress < 0.2 {
                                    phase = .splittingChunks
                                } else if currentProgress < 0.9 {
                                    phase = .transcribingChunks
                                } else if currentProgress < 0.95 {
                                    phase = .combiningResults
                                } else {
                                    phase = .finalizing
                                }
                            }
                            
                            // Report progress with proper chunk counts
                            if chunkCount > 0 && completedChunks == nil {
                                // Estimate chunks based on progress
                                let estimatedCompleted = Int(Double(chunkCount) * currentProgress)
                                await progressHandler?(phase, currentProgress, currentStatus, chunkCount, estimatedCompleted)
                            } else {
                                await progressHandler?(phase, currentProgress, currentStatus, totalChunks, completedChunks)
                            }
                        }
                        
                        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms for more responsive updates
                    }
                }
            }
            
            // Use TranscriptionService which will use the appropriate backend
            transcript = try await transcriptionService.transcribe(
                audioFile: audioFile,
                modelKey: nil,  // Use variant instead of legacy modelKey
                variant: modelVariant,
                language: detectedLanguage,
                speakerConfiguration: speakerConfigurationAtStart,
                engineSelection: engineSelection,
                runSettings: effectiveRunSettings
            )
            
            // Cancel progress monitoring
            progressTask?.cancel()
            
            // Check if transcript contains chunk failure markers
            if transcript.contains("[Chunk") && transcript.contains("failed:") {
                status = .partialSuccess
                errorMessage = "Some chunks failed during processing"
            } else {
                status = .completed
                errorMessage = nil
            }
        } catch {
            // For errors, still create an item but with failed status
            if let transcriptionError = error as? TranscriptionError {
                switch transcriptionError {
                case .gpuOutOfMemory, .resourcesUnavailable:
                    lastResourceFailure = transcriptionError
                default:
                    break
                }
            }
            transcript = ""
            status = .failed
            errorMessage = error.localizedDescription
            logger.error("[UnifiedTranscriptionManager] Transcription failed: \(error)")
        }
        
        // Create transcription item
        let transcriptionItem = TranscriptionItem(
            fileName: actualFileName,
            filePath: audioFile,
            transcript: transcript,
            language: language,
            duration: duration,
            fileSize: fileSize,
            createdDate: createdDate,
            transcribedDate: Date(),
            source: source,
            status: status,
            error: errorMessage
        )
        var finalTranscriptionItem = transcriptionItem
        
        // Save to history
        saveTranscriptionItem(transcriptionItem)
        
        // Update last item for UI
        await MainActor.run {
            self.lastTranscriptionItem = transcriptionItem
        }
        
        // Process into utterances if transcription succeeded
        if status == .completed || status == .partialSuccess {
            await MainActor.run {
                self.transcriptionProgress = 0.75
                self.transcriptionStatus = "Processing utterances..."
            }

            // Notify progress handler - finalizing
            await progressHandler?(.finalizing, 0.75, "Processing utterances...", nil, nil)

            // Get chunks with speaker data from the transcription result
            let resultChunks: [TranscriptionChunk]?
            if transcriptionService.currentBackend == .whisper {
                resultChunks = whisperService.lastTranscriptionResult?.chunks
            } else if transcriptionService.currentBackend == .gemma {
                resultChunks = gemmaService.lastTranscriptionResult?.chunks
            } else if transcriptionService.currentBackend == .vibeVoice {
                resultChunks = vibeVoiceService.lastTranscriptionResult?.chunks
            } else {
                resultChunks = voxtralService.lastTranscriptionResult?.chunks
            }

            let persisted = await processIntoUtterances(
                transcriptionItem: transcriptionItem,
                transcript: transcript,
                chunks: resultChunks,
                existingRecordingId: existingRecordingId,
                speakerProfile: speakerProfileAtStart,
                speakerConfiguration: speakerConfigurationAtStart
            )

            if persisted {
                await MainActor.run {
                    self.transcriptionProgress = 0.9
                    self.transcriptionStatus = "Generating embeddings..."
                }

                // Notify progress handler - embeddings
                await progressHandler?(.finalizing, 0.9, "Generating embeddings...", nil, nil)

                // Ensure embeddings are generated or queued
                await ensureEmbeddingsProcessed()
            } else {
                finalTranscriptionItem = TranscriptionItem(
                    fileName: transcriptionItem.fileName,
                    filePath: transcriptionItem.filePath,
                    transcript: "",
                    language: transcriptionItem.language,
                    duration: transcriptionItem.duration,
                    fileSize: transcriptionItem.fileSize,
                    createdDate: transcriptionItem.createdDate,
                    transcribedDate: transcriptionItem.transcribedDate,
                    source: transcriptionItem.source,
                    status: .failed,
                    error: "Fresh output could not be safely committed; the previous transcript was kept."
                )
            }
        }
        
        await MainActor.run {
            self.transcriptionProgress = 1.0
            self.transcriptionStatus = "Completed"
            self.isTranscribing = false
        }
        
        // Notify progress handler - completed
        await progressHandler?(.finalizing, 1.0, "Completed", nil, nil)
        
        logger.info("[UnifiedTranscriptionManager] Transcription completed and saved for: \(actualFileName)")
        return finalTranscriptionItem
    }
    
    /// Transcribe multiple files in batch
    func transcribeBatch(
        files: [(path: String, name: String)],
        source: TranscriptionItem.TranscriptionSource,
        runSettings: RunSettings? = nil
    ) async -> (completed: [TranscriptionItem], failed: [(file: String, error: String)]) {
        var completedItems: [TranscriptionItem] = []
        var failedFiles: [(file: String, error: String)] = []
        
        let totalFiles = files.count
        
        for (index, file) in files.enumerated() {
            await MainActor.run {
                self.transcriptionProgress = Double(index) / Double(totalFiles)
                self.transcriptionStatus = "Processing \(file.name) (\(index + 1)/\(totalFiles))"
            }
            
            // Always create an item, even for failures
            let item = await transcribe(
                audioFile: file.path,
                fileName: file.name,
                source: source,
                runSettings: runSettings
            )
            
            if item.status == .completed || item.status == .partialSuccess {
                completedItems.append(item)
            } else if item.status == .failed {
                failedFiles.append((file: file.name, error: item.error ?? "Unknown error"))
            }
        }
        
        let successCount = completedItems.count
        let failureCount = failedFiles.count
        await MainActor.run {
            self.transcriptionProgress = 1.0
            self.transcriptionStatus = "Batch completed: \(successCount) succeeded, \(failureCount) failed"
        }
        
        return (completed: completedItems, failed: failedFiles)
    }
    
    /// Cancel current transcription
    func cancelTranscription() {
        whisperService.cancelTranscription()
        voxtralService.cancelTranscription()
        gemmaService.cancelTranscription()
        vibeVoiceService.cancel()
    }
    
    // MARK: - Utterance Processing
    
    /// A transcription is worth persisting only if it produced real text — either in the full
    /// transcript or in at least one chunk. Empty/whitespace-only output (a near-silent clip) is not.
    static func isPersistableTranscript(_ transcript: String, chunks: [TranscriptionChunk]?) -> Bool {
        if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if let chunks {
            return chunks.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        return false
    }

    /// Process transcription into utterances and save to database
    private func processIntoUtterances(
        transcriptionItem: TranscriptionItem,
        transcript: String,
        chunks: [TranscriptionChunk]? = nil,
        existingRecordingId: Int64? = nil,
        speakerProfile: SpeakerPipelineProfile,
        speakerConfiguration: SpeakerPipelineConfiguration
    ) async -> Bool {
        logger.info("[UnifiedTranscriptionManager] Processing utterances for: \(transcriptionItem.fileName)")

        // Don't persist a recording for a transcription that produced no words (near-silent/empty
        // clips). For re-transcription this is a failure, not a replacement: the old transcript
        // remains intact and the nightly controller can retry or surface it for review.
        guard Self.isPersistableTranscript(transcript, chunks: chunks) else {
            logger.info("[UnifiedTranscriptionManager] Empty transcript for \(transcriptionItem.fileName) — skipping persistence (no recording created)")
            self.lastCreatedRecordingId = nil
            return false
        }

        do {
            let recordingId: Int64
            var replacementRecording: Recording?

            if let existingId = existingRecordingId {
                guard let original = try recordingRepo.getById(existingId) else {
                    throw NSError(
                        domain: "AlmRecorder.Retranscription",
                        code: 404,
                        userInfo: [NSLocalizedDescriptionKey: "Original recording no longer exists"]
                    )
                }
                // Keep the user's title, source, creation time, and metadata. The recording row is
                // updated only after the atomic utterance swap succeeds.
                replacementRecording = Recording(
                    id: existingId,
                    title: original.title,
                    fileName: original.fileName,
                    filePath: original.filePath ?? transcriptionItem.filePath,
                    duration: transcriptionItem.duration > 0
                        ? transcriptionItem.duration
                        : original.duration,
                    language: transcriptionItem.language,
                    createdAt: original.createdAt,
                    transcribedAt: Date(),
                    source: original.source,
                    fullTranscript: transcript,
                    metadata: original.metadata
                )
                recordingId = existingId
            } else {
                // Normal path: create new recording
                let recording = Recording(
                    id: nil,
                    title: transcriptionItem.fileName,
                    fileName: transcriptionItem.fileName,
                    filePath: transcriptionItem.filePath,
                    duration: transcriptionItem.duration,
                    language: transcriptionItem.language,
                    createdAt: transcriptionItem.createdDate,
                    transcribedAt: transcriptionItem.transcribedDate,
                    source: mapTranscriptionSource(transcriptionItem.source),
                    fullTranscript: transcript,
                    metadata: nil
                )
                recordingId = try recordingRepo.create(recording)
                logger.info("[UnifiedTranscriptionManager] Saved recording to database with ID: \(recordingId)")

                // Auto-link recording to overlapping calendar meetings
                let savedRecording = Recording(
                    id: recordingId,
                    title: recording.title,
                    fileName: recording.fileName,
                    filePath: recording.filePath,
                    duration: recording.duration,
                    language: recording.language,
                    createdAt: recording.createdAt,
                    transcribedAt: recording.transcribedAt,
                    source: recording.source,
                    fullTranscript: recording.fullTranscript,
                    metadata: recording.metadata
                )
                Task { @MainActor in
                    CalendarService.shared.autoLinkRecording(savedRecording)
                }
            }

            // Process transcript into utterances with embeddings
            // Pass chunks if available (contains speaker data from diarization)
            try await utteranceProcessor.processTranscriptionIntoUtterances(
                recordingId: recordingId,
                transcript: transcript,
                audioFile: transcriptionItem.filePath,
                chunks: chunks,
                generateEmbeddings: true,  // Always true - will queue if model not loaded
                queueEmbeddings: !EmbeddingModelManager.shared.isModelLoaded,  // Queue if not loaded
                audioSource: MeetingTrackSource.classify(fileName: transcriptionItem.fileName),
                replaceExisting: existingRecordingId != nil,
                replacementRecording: replacementRecording,
                speakerConfiguration: speakerConfiguration
            )

            if replacementRecording != nil {
                logger.info(
                    "[UnifiedTranscriptionManager] Atomically replaced transcript for recording "
                        + "\(recordingId)"
                )
            }

            // Store the recording ID for transcribeWithResult only after persistence succeeds.
            self.lastCreatedRecordingId = recordingId

            try? recordingRepo.markSpeakerPipeline(
                id: recordingId,
                profile: speakerProfile,
                configuration: speakerConfiguration
            )

            // Enqueue background LLM insight generation after the fresh transcript is committed.
            if LLMTextService.shared.isAvailable {
                await RecordingInsightsQueueManager.shared.enqueue(
                    recordingId: recordingId,
                    recordingTitle: replacementRecording?.title ?? transcriptionItem.fileName,
                    force: existingRecordingId != nil
                )
            }

            if GlobalModelSettings.shared.autoCleanTranscripts
                && TranscriptVerificationService.shared.isAvailable {
                await TranscriptCleanupQueueManager.shared.enqueue(
                    recordingId: recordingId,
                    recordingTitle: replacementRecording?.title ?? transcriptionItem.fileName,
                    mode: .auto,
                    force: existingRecordingId != nil
                )
            }
            
            logger.info("[UnifiedTranscriptionManager] Successfully processed utterances for recording \(recordingId)")
            return true
        } catch {
            logger.error("[UnifiedTranscriptionManager] Failed to process utterances: \(error)")
            self.lastCreatedRecordingId = nil
            return false
        }
    }
    
    /// Map TranscriptionItem source to Recording source
    private func mapTranscriptionSource(_ source: TranscriptionItem.TranscriptionSource) -> Recording.RecordingSource {
        switch source {
        case .recording:
            return .recording
        case .voiceMemos:
            return .voiceMemos
        case .imported:
            return .imported
        }
    }
    
    // MARK: - History Management
    
    /// Save a transcription item to history
    /// Detect language from filename or source
    private func detectLanguage(from fileName: String, source: TranscriptionItem.TranscriptionSource) -> String? {
        // Check for Swedish indicators in filename
        let lowercaseName = fileName.lowercased()
        if lowercaseName.contains("svensk") || 
           lowercaseName.contains("swedish") ||
           lowercaseName.contains("sverige") ||
           lowercaseName.contains("se_") ||
           lowercaseName.contains("_se") {
            logger.info("[UnifiedTranscriptionManager] Detected Swedish from filename")
            return "sv"
        }
        
        // Return "auto" to explicitly force auto-detection without translation
        // Returning nil would use whisper's default which is "en" and can cause issues
        logger.info("[UnifiedTranscriptionManager] No language detected from filename, using auto-detection")
        return "auto"
    }
    
    // REMOVED: selectModelForLanguage - no automatic model selection
    
    private func saveTranscriptionItem(_ item: TranscriptionItem) {
        Task {
            do {
                // Encode the item as JSON
                let encoded = try JSONEncoder().encode(item)
                let jsonString = String(data: encoded, encoding: .utf8) ?? "{}"
                
                // Generate a hash for the file
                let fileHash = "\(item.fileName)_\(item.transcribedDate.timeIntervalSince1970)".data(using: .utf8)?.base64EncodedString() ?? ""
                
                // Save to database
                try dbManager.writeQueue { db in
                    try db.execute(
                        sql: """
                        INSERT INTO transcription_history 
                        (file_name, file_path, date, duration, source, transcript_preview, 
                         recording_id, data, file_hash, created_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            item.fileName,
                            item.filePath,
                            item.transcribedDate,
                            item.duration,
                            item.source.rawValue,
                            String(item.transcript.prefix(200)),
                            self.lastCreatedRecordingId,
                            jsonString,
                            fileHash,
                            Date()
                        ]
                    )
                }
                logger.info("[UnifiedTranscriptionManager] Saved transcription to history: \(item.fileName)")
            } catch {
                logger.error("[UnifiedTranscriptionManager] Failed to save transcription to history: \(error)")
            }
        }
    }
    
    /// Load all saved transcriptions
    func loadSavedTranscriptions() -> [TranscriptionItem] {
        do {
            return try dbManager.readQueue { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT data FROM transcription_history 
                    ORDER BY date DESC
                """)
                
                return rows.compactMap { row in
                    let jsonString: String? = row["data"]
                    guard let jsonString,
                          let data = jsonString.data(using: .utf8),
                          let item = try? JSONDecoder().decode(TranscriptionItem.self, from: data) else {
                        return nil
                    }
                    return item
                }
            }
        } catch {
            logger.error("[UnifiedTranscriptionManager] Failed to load transcription history: \(error)")
            
            // Try to load from UserDefaults as fallback during migration
            if let data = UserDefaults.standard.data(forKey: "SavedTranscriptions"),
               let items = try? JSONDecoder().decode([TranscriptionItem].self, from: data) {
                // Migrate to GRDB
                for item in items {
                    saveTranscriptionItem(item)
                }
                // Clear UserDefaults after migration
                UserDefaults.standard.removeObject(forKey: "SavedTranscriptions")
                return items
            }
            
            return []
        }
    }
    
    /// Clear transcription history
    func clearHistory() {
        do {
            try dbManager.writeQueue { db in
                try db.execute(sql: "DELETE FROM transcription_history")
            }
            // Also clear UserDefaults in case there's legacy data
            UserDefaults.standard.removeObject(forKey: "SavedTranscriptions")
            logger.info("[UnifiedTranscriptionManager] Cleared transcription history")
        } catch {
            logger.error("[UnifiedTranscriptionManager] Failed to clear history: \(error)")
        }
    }
    
    // MARK: - Helper Methods
    
    private func getFileSize(_ url: URL) -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }
    
    private func getAudioDuration(_ url: URL) -> TimeInterval {
        let asset = AVAsset(url: url)
        
        // Use synchronous helper for async API
        return getAssetAudioDurationSync(asset)
    }
    
    private func getFileCreationDate(_ url: URL) -> Date {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.creationDate] as? Date ?? Date()
        } catch {
            return Date()
        }
    }
    
    // MARK: - Model Management (delegates to VoxtralService)
    
    var isModelLoaded: Bool {
        voxtralService.isModelLoaded
    }
    
    func downloadModel(quantization: String = VoxtralConfiguration.defaultModel) async throws {
        try await voxtralService.downloadModel(quantization: quantization)
    }
    
    func ensureModelLoaded() async throws {
        if !isModelLoaded {
            try await downloadModel()
        }
    }
    
    // MARK: - Embedding Management
    
    /// Ensure embedding model is loaded before transcription
    private func ensureEmbeddingModelLoaded() async {
        if !EmbeddingModelManager.shared.isModelLoaded {
            logger.info("[UnifiedTranscriptionManager] Loading embedding model...")
            
            await MainActor.run {
                self.transcriptionStatus = "Loading embedding model..."
            }
            
            await EmbeddingModelManager.shared.ensureDefaultModel()
            
            if EmbeddingModelManager.shared.isModelLoaded {
                logger.info("[UnifiedTranscriptionManager] Embedding model loaded successfully")
            } else {
                logger.warning("[UnifiedTranscriptionManager] Failed to load embedding model - embeddings will be queued")
            }
        }
    }
    
    /// Ensure embeddings are processed or queued
    private func ensureEmbeddingsProcessed() async {
        let embeddingQueue = EmbeddingQueueManager.shared
        
        // Check if there are pending embeddings
        if embeddingQueue.hasActiveJobs {
            logger.info("[UnifiedTranscriptionManager] Found \(embeddingQueue.queueSize) pending embeddings")
            
            // Start processing if not already running
            if !embeddingQueue.isProcessing {
                embeddingQueue.startProcessing()
                logger.info("[UnifiedTranscriptionManager] Started embedding queue processing")
            }
        }
        
        // Also check for any utterances without embeddings
        if EmbeddingModelManager.shared.isModelLoaded {
            let utteranceProcessor = UtteranceProcessor()
            await utteranceProcessor.generateMissingEmbeddings(queueForBackground: true)
        }
    }
}
