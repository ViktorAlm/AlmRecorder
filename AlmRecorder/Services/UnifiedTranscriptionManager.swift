import Foundation
import Combine
import AVFoundation
import GRDB
import NaturalLanguage

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
    private let vibeVoiceService = VibeVoiceService.shared
    private let logger = VoxtralLogger.shared
    private let recordingRepo = GRDBRecordingRepository()

    struct ResolvedLanguage: Equatable {
        let code: String
        let source: String
        let confidence: Float?
    }
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
        } else if transcriptionService.currentBackend == .vibeVoice {
            capturedResult = vibeVoiceService.lastTranscriptionResult
            logger.info("[UnifiedTranscriptionManager.transcribeWithResult] Captured VibeVoice result: \(capturedResult != nil ? "Present" : "nil")")
        } else {
            capturedResult = voxtralService.lastTranscriptionResult
            logger.info("[UnifiedTranscriptionManager.transcribeWithResult] Captured VoxtralService result: \(capturedResult != nil ? "Present" : "nil")")
        }
        
        // A failed attempt did not create or update a recording. Never attach the most recently
        // modified, unrelated database row to a queue failure.
        if item.status == .failed {
            capturedRecordingId = nil
            logger.info(
                "[UnifiedTranscriptionManager.transcribeWithResult] Failed attempt has no recording ID"
            )
        } else if let recordingId = self.lastCreatedRecordingId {
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
            desiredBackend = .native
        case .vibeVoice:
            desiredBackend = .vibeVoice
        }

        var backendPreparationError: Error?
        if engineSelection.backend == .llm, engineSelection.llmEngine == .gemma {
            // Fail closed for legacy persisted jobs. New snapshots are normalized to Voxtral.
            backendPreparationError = TranscriptionError.transcriptionFailed(
                "Gemma audio transcription is deferred. Choose Whisper, VibeVoice, or Voxtral."
            )
        } else if transcriptionService.currentBackend != desiredBackend {
            logger.info("[UnifiedTranscriptionManager] Switching to \(desiredBackend) backend")
            do {
                switch desiredBackend {
                case .whisper:
                    try await transcriptionService.switchToWhisper()
                case .vibeVoice:
                    try await transcriptionService.switchToVibeVoice(
                        quantization: engineSelection.vibeVoiceQuantization
                            ?? TranscriptionProductionDefaults.vibeVoiceQuantization
                    )
                default:
                    try await transcriptionService.switchToNative()
                }
            } catch {
                backendPreparationError = error
                logger.error("[UnifiedTranscriptionManager] Failed to prepare \(desiredBackend): \(error)")
            }
        }
        
        // Respect an explicit caller selection. `auto-detected` is a UI sentinel, not a language
        // and must never be persisted as Whisper's answer.
        let requestedLanguage: String
        let normalizedRequested = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalizedRequested.isEmpty,
           normalizedRequested != "auto",
           normalizedRequested != "auto-detected",
           normalizedRequested != "unknown" {
            requestedLanguage = normalizedRequested
        } else {
            requestedLanguage = detectLanguage(from: actualFileName, source: source) ?? "auto"
        }
        logger.info("[UnifiedTranscriptionManager] Requested language: \(requestedLanguage)")
        
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
            
            // Monitor the active backend's unified progress. VibeVoice long-window passes must be
            // visible to the queue just like Whisper VAD chunks.
            var progressTask: Task<Void, Never>? = nil
            if progressHandler != nil {
                progressTask = Task { [weak self] in
                    var lastProgress: Double = 0
                    var lastStatus = ""
                    var chunkCount = 0
                    
                    while !Task.isCancelled {
                        // Safely check if self still exists
                        guard let self = self else { break }
                        
                        let currentProgress = await MainActor.run { self.transcriptionProgress }
                        let currentStatus = await MainActor.run { self.transcriptionStatus }
                        
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
                            
                            let lowerStatus = currentStatus.lowercased()
                            if lowerStatus.contains("chunk") || lowerStatus.contains("pass") {
                                // Parse "Processing chunk X of Y" or "Chunk X/Y" or similar
                                // Try both patterns: "chunk X of Y" and "Chunk X/Y"
                                let patterns = [
                                    #"[Cc]hunk\s+(\d+)\s+of\s+(\d+)"#,
                                    #"[Cc]hunk\s+(\d+)/(\d+)"#,
                                    #"[Pp]ass\s+(\d+)\s+of\s+(\d+)"#,
                                    #"[Pp]ass\s+(\d+)/(\d+)"#
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
                            } else if lowerStatus.contains("chunk")
                                        || lowerStatus.contains("pass")
                                        || lowerStatus.contains("transcribing")
                                        || lowerStatus.contains("processing")
                                        || lowerStatus.contains("retrying") {
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
                language: requestedLanguage,
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
        
        let completedResult: TranscriptionResult?
        switch desiredBackend {
        case .whisper:
            completedResult = whisperService.lastTranscriptionResult
        case .vibeVoice:
            completedResult = vibeVoiceService.lastTranscriptionResult
        default:
            completedResult = voxtralService.lastTranscriptionResult
        }
        let resolvedLanguage = Self.resolveLanguage(
            requestedLanguage: requestedLanguage,
            result: completedResult,
            transcript: transcript
        )

        // Create transcription item
        let transcriptionItem = TranscriptionItem(
            fileName: actualFileName,
            filePath: audioFile,
            transcript: transcript,
            language: resolvedLanguage?.code ?? "unknown",
            duration: duration,
            fileSize: fileSize,
            createdDate: createdDate,
            transcribedDate: Date(),
            source: source,
            status: status,
            error: errorMessage
        )
        var finalTranscriptionItem = transcriptionItem
        
        // Process into utterances if transcription succeeded
        if status == .completed || status == .partialSuccess {
            await MainActor.run {
                self.transcriptionProgress = 0.75
                self.transcriptionStatus = "Processing utterances..."
            }

            // Notify progress handler - finalizing
            await progressHandler?(.finalizing, 0.75, "Processing utterances...", nil, nil)

            // Get chunks with speaker data from the transcription result
            let resultChunks = completedResult?.chunks

            let persisted = await processIntoUtterances(
                transcriptionItem: transcriptionItem,
                transcript: transcript,
                chunks: resultChunks,
                existingRecordingId: existingRecordingId,
                transcriptionProvenance: RecordingTranscriptionProvenance(
                    engineSelection: engineSelection,
                    runSettings: effectiveRunSettings,
                    completedAt: transcriptionItem.transcribedDate,
                    detectedLanguage: resolvedLanguage?.code,
                    languageDetectionSource: resolvedLanguage?.source,
                    languageDetectionConfidence: resolvedLanguage?.confidence
                ),
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

        let completedItem = finalTranscriptionItem
        saveTranscriptionItem(
            completedItem,
            recordingId: lastCreatedRecordingId ?? existingRecordingId
        )

        let succeeded = completedItem.status == .completed
            || completedItem.status == .partialSuccess
        let finalStatusMessage = succeeded ? "Completed" : "Failed"
        await MainActor.run {
            self.lastTranscriptionItem = completedItem
            self.transcriptionProgress = succeeded ? 1.0 : 0.0
            self.transcriptionStatus = finalStatusMessage
            self.isTranscribing = false
        }

        await progressHandler?(
            .finalizing,
            succeeded ? 1.0 : 0.0,
            finalStatusMessage,
            nil,
            nil
        )

        if succeeded {
            logger.info(
                "[UnifiedTranscriptionManager] Transcription completed and saved for: "
                    + actualFileName
            )
        } else {
            logger.error(
                "[UnifiedTranscriptionManager] Transcription attempt failed for: "
                    + actualFileName
            )
        }
        return completedItem
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
        transcriptionProvenance: RecordingTranscriptionProvenance,
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

            // Resolve the recording to update: an explicit re-transcription target, or — for a
            // "new" discovery — a row a prior attempt already left behind under this exact
            // file_name (even an empty/failed one). `file_name` is UNIQUE, so blindly INSERTing
            // in that case throws a constraint violation instead of ever reaching this transcript.
            let existingId = try existingRecordingId ?? recordingRepo.getByFileName(transcriptionItem.fileName)?.id

            if let existingId {
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
                replacementRecording?.transcriptionProvenance = transcriptionProvenance
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
                var recordingWithProvenance = recording
                recordingWithProvenance.transcriptionProvenance = transcriptionProvenance
                recordingId = try recordingRepo.create(recordingWithProvenance)
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
                replaceExisting: replacementRecording != nil,
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
                    force: replacementRecording != nil
                )
            }

            if GlobalModelSettings.shared.autoCleanTranscripts
                && TranscriptVerificationService.shared.isAvailable {
                await TranscriptCleanupQueueManager.shared.enqueue(
                    recordingId: recordingId,
                    recordingTitle: replacementRecording?.title ?? transcriptionItem.fileName,
                    mode: .auto,
                    force: replacementRecording != nil
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

    /// Produces the value saved in `recordings.language`. Whisper's audio result always wins for
    /// automatic runs. Text language ID exists only for legacy/checkpoint cases where no audio
    /// result survived; its provenance prevents that weaker fallback from masquerading as audio ID.
    static func resolveLanguage(
        requestedLanguage: String?,
        result: TranscriptionResult?,
        transcript: String
    ) -> ResolvedLanguage? {
        let requested = requestedLanguage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let requested,
           !requested.isEmpty,
           requested != "auto",
           requested != "auto-detected",
           requested != "unknown" {
            return ResolvedLanguage(code: requested, source: "user_selected", confidence: nil)
        }

        if let rawResultLanguage = result?.language {
            let resultLanguage = rawResultLanguage
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if !resultLanguage.isEmpty,
               resultLanguage != "auto",
               resultLanguage != "auto-detected",
               resultLanguage != "unknown" {
                return ResolvedLanguage(
                    code: resultLanguage,
                    source: result?.languageDetectionSource ?? "backend_reported",
                    confidence: result?.languageConfidence
                )
            }
        }

        let chunkText = result?.chunks.map(\.text).joined(separator: "\n")
        let sampleSource = (chunkText?.isEmpty == false ? chunkText : transcript) ?? transcript
        let sample = String(sampleSource.prefix(20_000))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let hypothesis = recognizer.languageHypotheses(withMaximum: 1).first else {
            return nil
        }
        return ResolvedLanguage(
            code: hypothesis.key.rawValue,
            source: "transcript_fallback",
            confidence: Float(hypothesis.value)
        )
    }
    
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
    
    private func saveTranscriptionItem(_ item: TranscriptionItem, recordingId: Int64?) {
        do {
            let encoded = try JSONEncoder().encode(item)
            let jsonString = String(data: encoded, encoding: .utf8) ?? "{}"
            let fileHash = "\(item.fileName)_\(item.transcribedDate.timeIntervalSince1970)"
                .data(using: .utf8)?.base64EncodedString() ?? ""

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
                        recordingId,
                        jsonString,
                        fileHash,
                        Date()
                    ]
                )
            }
            logger.info(
                "[UnifiedTranscriptionManager] Saved transcription attempt to history: "
                    + "\(item.fileName) [\(item.status)]"
            )
        } catch {
            logger.error(
                "[UnifiedTranscriptionManager] Failed to save transcription history: \(error)"
            )
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
                    saveTranscriptionItem(item, recordingId: nil)
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
            logger.info("[UnifiedTranscriptionManager] No embedding model installed; derived embeddings will remain queued")
            
            await MainActor.run {
                self.transcriptionStatus = "Embedding model not installed — indexing will wait"
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
