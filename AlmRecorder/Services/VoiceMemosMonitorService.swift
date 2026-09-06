import Foundation
import Combine
import AVFoundation

/// Service to monitor Voice Memos folder and process new recordings
@MainActor
class VoiceMemosMonitorService: ObservableObject {
    static let shared = VoiceMemosMonitorService()
    
    // MARK: - Published Properties
    
    @Published var isMonitoring = false
    @Published var pendingMemos: [VoiceMemoEntry] = []
    @Published var processedMemos: [VoiceMemoEntry] = []
    @Published var currentlyProcessing: Set<UUID> = [] // Track multiple processing items
    @Published var settings = VoiceMemoMonitorSettings.defaultSettings
    @Published var lastError: String?
    @Published var processingProgress: Double = 0.0
    
    // Speaker review queue for voice memos with multiple speakers
    @Published var pendingSpeakerReviews: [(recordingId: Int64, audioPath: String, result: TranscriptionResult, memoName: String)] = []
    
    // MARK: - Private Properties
    
    private let logger = VoxtralLogger.shared
    private let transcriptionManager = UnifiedTranscriptionManager.shared
    private let queueManager = TranscriptionQueueManager.shared
    private let recordingRepo = GRDBRecordingRepository()
    private let utteranceProcessor = UtteranceProcessor()
    private let database = GRDBDatabaseManager.shared
    private let settingsRepo = GRDBSettingsRepository.shared
    private var monitoringTimer: Timer?
    private var fileSystemObserver: DispatchSourceFileSystemObject?
    private let fileMonitorQueue = DispatchQueue(label: "com.almrecorder.voicememos.monitor")
    private var cancellables = Set<AnyCancellable>()
    
    // Debounce rapid file system events
    private var scanDebounceTimer: Timer?
    private let scanDebounceInterval: TimeInterval = 0.5
    
    // Processing control
    private var processingTasks: [UUID: Task<Void, Never>] = [:]
    private let maxConcurrentProcessing = 2
    
    // Processed files tracking (use Set for O(1) lookup)
    private var processedFileNames: Set<String> = []
    private let maxProcessedHistory = 100
    
    // Voice Memos folder paths
    private var voiceMemosURL: URL? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            // Newer macOS versions with iCloud sync (case sensitive variations)
            homeDir
                .appendingPathComponent("Library")
                .appendingPathComponent("Group Containers")
                .appendingPathComponent("group.com.apple.VoiceMemos.shared")
                .appendingPathComponent("Recordings"),
            
            homeDir
                .appendingPathComponent("Library")
                .appendingPathComponent("Group Containers")
                .appendingPathComponent("group.com.apple.voicememos.shared")
                .appendingPathComponent("Recordings"),
            
            // Standard Voice Memos location
            homeDir
                .appendingPathComponent("Library")
                .appendingPathComponent("Application Support")
                .appendingPathComponent("com.apple.voicememos")
                .appendingPathComponent("Recordings")
        ]
        
        for path in paths {
            if FileManager.default.fileExists(atPath: path.path) {
                logger.info("[VoiceMemosMonitor] Found Voice Memos folder at: \(path.path)")
                return path
            }
        }
        
        return nil
    }
    
    // MARK: - Init & Deinit
    
    private init() {
        migrateFromUserDefaultsIfNeeded()  // Migrate old data first
        loadSettings()  // Load from GRDB
        setupBindings()
        
        // Load processed files from database
        loadProcessedFilesFromDatabase()
        
        // Also load already-transcribed files from recordings to prevent re-processing
        if let transcribed = try? recordingRepo.getTranscribedFileNames() {
            processedFileNames.formUnion(transcribed)
            logger.info("[VoiceMemosMonitor] Loaded \(transcribed.count) already-transcribed files into processed set")
        }

        // Also load files currently in the transcription queue to prevent re-queuing
        let queued = TranscriptionQueueManager.shared.getQueuedFileNames()
        processedFileNames.formUnion(queued)
        if !queued.isEmpty {
            logger.info("[VoiceMemosMonitor] Loaded \(queued.count) queued files into processed set")
        }
        
        logger.info("[VoiceMemosMonitor] Initialized | voiceMemosPath=\(voiceMemosURL?.path ?? "not found") | processedFiles=\(processedFileNames.count)")
    }
    
    // Note: Cleanup happens when stopMonitoring is called explicitly
    
    // MARK: - Setup
    
    private func setupBindings() {
        // Auto-save settings when changed (debounced)
        $settings
            .debounce(for: .seconds(2), scheduler: RunLoop.main) // Increased debounce
            .sink { [weak self] _ in
                self?.saveSettings()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Public Methods
    
    /// Start monitoring Voice Memos folder
    func startMonitoring() {
        guard !isMonitoring else {
            logger.warning("[VoiceMemosMonitor] Already monitoring")
            return
        }
        
        guard let voiceMemosURL = voiceMemosURL else {
            lastError = "Voice Memos folder not found. Please check if Voice Memos app is installed."
            logger.error("[VoiceMemosMonitor] Voice Memos folder not found")
            return
        }
        
        isMonitoring = true
        lastError = nil
        logger.info("[VoiceMemosMonitor] Started monitoring | path=\(voiceMemosURL.path) interval=\(settings.checkInterval)s")
        
        // Initial scan
        Task {
            await performScan()
        }
        
        // Set up file system monitoring
        setupFileSystemMonitoring(for: voiceMemosURL)
        
        // Set up periodic check timer
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: settings.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.performScan()
            }
        }
    }
    
    /// Stop monitoring
    func stopMonitoring() {
        guard isMonitoring else { return }
        
        // Cancel all processing tasks
        for (_, task) in processingTasks {
            task.cancel()
        }
        processingTasks.removeAll()
        
        // Stop timers
        monitoringTimer?.invalidate()
        monitoringTimer = nil
        
        scanDebounceTimer?.invalidate()
        scanDebounceTimer = nil
        
        // Stop file system observer
        fileSystemObserver?.cancel()
        fileSystemObserver = nil
        
        isMonitoring = false
        logger.info("[VoiceMemosMonitor] Stopped monitoring")
    }
    
    /// Manually scan for new memos
    func scanForNewMemos() {
        guard isMonitoring else { return }
        
        // Debounce rapid calls
        scanDebounceTimer?.invalidate()
        scanDebounceTimer = Timer.scheduledTimer(withTimeInterval: scanDebounceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.performScan()
            }
        }
    }
    
    /// Process a specific memo
    func processMemo(_ memo: VoiceMemoEntry) async {
        guard memo.status == .pending else {
            logger.warning("[VoiceMemosMonitor] Memo not pending | file=\(memo.fileName) status=\(memo.status)")
            return
        }
        
        // Check if already processing
        guard !currentlyProcessing.contains(memo.id) else {
            logger.warning("[VoiceMemosMonitor] Already processing memo | file=\(memo.fileName)")
            return
        }
        
        // Check concurrent processing limit
        if currentlyProcessing.count >= maxConcurrentProcessing {
            logger.info("[VoiceMemosMonitor] Max concurrent processing reached, queueing | file=\(memo.fileName)")
            return
        }
        
        // Mark as processing
        currentlyProcessing.insert(memo.id)
        updateMemoStatus(memo.id, status: .processing)
        
        // Create processing task
        let task = Task {
            await processVoiceMemo(memo)
            
            await MainActor.run {
                currentlyProcessing.remove(memo.id)
                processingTasks.removeValue(forKey: memo.id)
            }
        }
        
        processingTasks[memo.id] = task
    }
    
    /// Process all pending memos
    func processAllPending() async {
        let pending = pendingMemos.filter { !currentlyProcessing.contains($0.id) }
        logger.info("[VoiceMemosMonitor] Processing all pending | count=\(pending.count)")
        
        processingProgress = 0.0
        let total = Double(pending.count)
        
        for (index, memo) in pending.enumerated() {
            // Check if cancelled
            if !isMonitoring { break }
            
            // Update progress
            processingProgress = Double(index) / total
            
            // Process with concurrency control
            while currentlyProcessing.count >= maxConcurrentProcessing {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            }
            
            await processMemo(memo)
        }
        
        processingProgress = 1.0
    }
    
    /// Retry a failed memo
    func retryMemo(_ memoId: UUID) {
        guard let memo = processedMemos.first(where: { $0.id == memoId && $0.status == .failed }) else {
            return
        }
        
        // Move back to pending
        if let index = processedMemos.firstIndex(where: { $0.id == memoId }) {
            processedMemos.remove(at: index)
            
            // Create new pending entry
            let retryMemo = VoiceMemoEntry(
                id: memo.id,
                fileName: memo.fileName,
                filePath: memo.filePath,
                fileSize: memo.fileSize,
                createdDate: memo.createdDate,
                processedDate: nil,
                summary: nil,
                transcriptSnippet: nil,
                duration: nil,
                status: .pending
            )
            
            pendingMemos.append(retryMemo)
            
            // Process immediately
            Task {
                await processMemo(retryMemo)
            }
        }
    }
    
    // MARK: - Private Processing Methods
    
    private func processVoiceMemo(_ memo: VoiceMemoEntry) async {
        let startTime = Date()
        
        // Validate file exists
        guard FileManager.default.fileExists(atPath: memo.filePath) else {
            logger.error("[VoiceMemosMonitor] File not found | path=\(memo.filePath)")
            updateMemoStatus(memo.id, status: .failed)
            lastError = "Voice Memo file not found"
            return
        }
        
        // Validate file is within Voice Memos folder (security)
        // Check both possible Voice Memos locations
        let validPaths = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings").path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Group Containers/group.com.apple.voicememos.shared/Recordings").path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/com.apple.voicememos/Recordings").path
        ]
        
        let isValidPath = validPaths.contains { path in
            memo.filePath.hasPrefix(path)
        }
        
        guard isValidPath else {
            logger.error("[VoiceMemosMonitor] Invalid file path | path=\(memo.filePath)")
            updateMemoStatus(memo.id, status: .failed)
            lastError = "Invalid file location"
            return
        }
        
        do {
            logger.info("[VoiceMemosMonitor] Processing memo | file=\(memo.fileName) size=\(memo.fileSize) bytes")
            
            // Check if already exists in recordings
            if try recordingRepo.existsByFileName(memo.fileName) {
                logger.info("[VoiceMemosMonitor] Memo already imported | file=\(memo.fileName)")
                updateMemoStatus(memo.id, status: .completed)
                return
            }
            
            // Get audio duration
            let asset = AVURLAsset(url: URL(fileURLWithPath: memo.filePath))
            let duration = try await asset.load(.duration).seconds
            
            // Check if we should apply duration limit
            let shouldApplyLimit = settings.enableDurationLimit && duration > settings.maxProcessingDuration
            
            // Create temporary file if trimming needed
            var tempFilePath: String?
            let fileToProcess: String
            
            if shouldApplyLimit {
                let processingDuration = min(duration, settings.maxProcessingDuration)
                logger.info("[VoiceMemosMonitor] Duration limit enabled | total=\(duration)s processing=\(processingDuration)s")
                tempFilePath = try await trimAudioFile(
                    inputPath: memo.filePath,
                    duration: processingDuration
                )
                guard let trimmedPath = tempFilePath else {
                    throw NSError(domain: "VoiceMemosMonitor", code: -1, 
                                 userInfo: [NSLocalizedDescriptionKey: "Failed to trim audio file"])
                }
                fileToProcess = trimmedPath
            } else {
                logger.info("[VoiceMemosMonitor] Processing full audio | duration=\(duration)s")
                fileToProcess = memo.filePath
            }
            
            // Clean up temp file on exit
            defer {
                if let tempPath = tempFilePath {
                    try? FileManager.default.removeItem(atPath: tempPath)
                }
            }
            
            // Double-check that file hasn't been transcribed while waiting in queue
            if (try? recordingRepo.existsByFileName(memo.fileName)) == true {
                logger.info("[VoiceMemosMonitor] File was transcribed while in queue, skipping | file=\(memo.fileName)")
                updateMemoStatus(memo.id, status: .completed)
                return
            }
            
            // Use queue for transcription to prevent concurrent processing and memory issues
            let queueManager = TranscriptionQueueManager.shared
            let (transcriptionItem, transcriptionResult, recordingId) = await queueManager.addJobAndWait(
                audioFile: fileToProcess,
                fileName: memo.fileName,
                source: .voiceMemos,
                priority: .high  // Voice memos get high priority; queue memory waits are unbounded.
            )
            
            // Quick heuristic summary for the voice-memo list preview. The full LLM insights
            // (title/summary/tags) are generated for the recording by RecordingInsightsQueueManager.
            var summary: String?
            if settings.autoGenerateSummary && !transcriptionItem.transcript.isEmpty {
                summary = await generateSummary(from: transcriptionItem.transcript)
            }
            
            // Check if we got a recording ID from the transcription manager
            guard let recordingId = recordingId else {
                logger.error("[VoiceMemosMonitor] No recording ID returned from transcription")
                updateMemoStatus(memo.id, status: .failed)
                lastError = "Failed to save recording"
                return
            }
            
            logger.info("[VoiceMemosMonitor] Using recording ID \(recordingId) from transcription")
            
            // Check if we have multiple speakers that need review
            // Use detectedSpeakerCount OR multiple embeddings as trigger
            if let result = transcriptionResult {
                let hasMultipleSpeakers = (result.detectedSpeakerCount ?? 0) > 1 || 
                                         (result.speakerEmbeddings?.count ?? 0) > 1
                
                logger.info("[VoiceMemosMonitor] Speaker detection: detectedSpeakerCount=\(result.detectedSpeakerCount ?? 0), embeddings=\(result.speakerEmbeddings?.count ?? 0), chunks=\(result.chunks.count)")
                
                if hasMultipleSpeakers {
                    // Add to speaker review queue
                    await MainActor.run {
                        self.pendingSpeakerReviews.append((
                            recordingId: recordingId,
                            audioPath: memo.filePath,
                            result: result,
                            memoName: memo.fileName
                        ))
                    }
                    let speakerCount = result.detectedSpeakerCount ?? result.speakerEmbeddings?.count ?? 0
                    logger.info("[VoiceMemosMonitor] \(speakerCount) speakers detected in \(memo.fileName), added to review queue")
                } else {
                    // Single speaker detected - process utterances using the chunks from result
                    logger.info("[VoiceMemosMonitor] Single speaker detected, processing utterances with chunks")
                    
                    if !result.chunks.isEmpty {
                        // Use the chunks from the transcription result (which have speaker info)
                        try await utteranceProcessor.processTranscriptionResult(
                            recordingId: recordingId,
                            result: result,
                            generateEmbeddings: true,
                            queueEmbeddings: true
                        )
                    } else if !transcriptionItem.transcript.isEmpty {
                        // Fallback to simple text processing if no chunks
                        try await utteranceProcessor.processTranscriptionIntoUtterances(
                            recordingId: recordingId,
                            transcript: transcriptionItem.transcript,
                            audioFile: memo.filePath,
                            generateEmbeddings: true,
                            queueEmbeddings: true
                        )
                    }
                }
            } else {
                // No transcription result - fallback to simple processing
                logger.info("[VoiceMemosMonitor] No transcription result available, using simple utterance processing")
                
                if !transcriptionItem.transcript.isEmpty {
                    try await utteranceProcessor.processTranscriptionIntoUtterances(
                        recordingId: recordingId,
                        transcript: transcriptionItem.transcript,
                        audioFile: memo.filePath,
                        generateEmbeddings: true,
                        queueEmbeddings: true
                    )
                }
            }
            
            // Get transcript snippet
            let snippet = transcriptionItem.transcript.isEmpty ? "" : String(transcriptionItem.transcript.prefix(200))
            
            // Update status
            updateMemoStatus(
                memo.id,
                status: .completed,
                summary: summary,
                transcriptSnippet: snippet,
                duration: duration
            )
            
            let processingTime = Date().timeIntervalSince(startTime)
            logger.info("[VoiceMemosMonitor] Processed memo | file=\(memo.fileName) time=\(String(format: "%.2f", processingTime))s recordingId=\(recordingId)")
            
        } catch {
            logger.error("[VoiceMemosMonitor] Failed to process memo | file=\(memo.fileName) error=\(error)")
            updateMemoStatus(memo.id, status: .failed)
            lastError = error.localizedDescription
        }
    }
    
    // MARK: - Private Methods
    
    private func setupFileSystemMonitoring(for url: URL) {
        let fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            logger.error("[VoiceMemosMonitor] Failed to open directory for monitoring")
            return
        }
        
        let observer = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend],
            queue: fileMonitorQueue
        )
        
        observer.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.logger.debug("[VoiceMemosMonitor] File system event detected")
                self?.scanForNewMemos()
            }
        }
        
        observer.setCancelHandler {
            close(fileDescriptor)
        }
        
        observer.resume()
        fileSystemObserver = observer
        logger.debug("[VoiceMemosMonitor] File system monitoring setup complete")
    }
    
    @MainActor
    private func performScan() async {
        guard let url = voiceMemosURL else { return }
        
        do {
            let fileManager = FileManager.default
            let contents = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            )
            
            let audioFiles = contents.filter { url in
                let ext = url.pathExtension.lowercased()
                // "qta" = QuickTime Audio, written by Voice Memos for iPhone 16 Pro+ "layered"
                // (spatial) recordings — a multi-stream container (AAC + an APAC ambisonic
                // stream). Without this, those recordings were silently invisible: never
                // discovered, never queued, no error. VibeVoiceService already routes any
                // extension outside {wav, m4a, mp3} through AVFoundation's convertToWAV, which
                // — being Apple's own framework — reads the plain AAC track natively rather than
                // needing ffmpeg to understand the unsupported APAC stream.
                return ext == "m4a" || ext == "mp3" || ext == "wav" || ext == "qta"
            }
            
            logger.debug("[VoiceMemosMonitor] Found audio files | count=\(audioFiles.count)")
            
            var newMemos: [VoiceMemoEntry] = []
            
            // Check if recordings exist in database for status
            let transcribedFileNames = (try? recordingRepo.getTranscribedFileNames()) ?? Set()
            // Also check files currently in the transcription queue
            let queuedFileNames = TranscriptionQueueManager.shared.getQueuedFileNames()

            for fileURL in audioFiles {
                let fileName = fileURL.lastPathComponent

                // Check if already transcribed or currently queued
                let isTranscribed = transcribedFileNames.contains(fileName)
                let isQueued = queuedFileNames.contains(fileName)
                
                // Quick check using Set for O(1) lookup
                guard !processedFileNames.contains(fileName) else { continue }
                
                // Check if not already in pending or processed
                guard !pendingMemos.contains(where: { $0.fileName == fileName }) else { continue }
                
                let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
                let fileSize = attributes[.size] as? Int64 ?? 0
                let createdDate = attributes[.creationDate] as? Date ?? Date()
                
                // Try to get duration
                let asset = AVURLAsset(url: fileURL)
                let duration = try? await asset.load(.duration).seconds
                
                let memo = VoiceMemoEntry(
                    id: UUID(),
                    fileName: fileName,
                    filePath: fileURL.path,
                    fileSize: fileSize,
                    createdDate: createdDate,
                    processedDate: isTranscribed ? createdDate : nil,
                    summary: nil,
                    transcriptSnippet: nil,
                    duration: duration,
                    status: isTranscribed ? .completed : .pending
                )
                
                if isTranscribed {
                    // Add to processed list if already transcribed
                    processedMemos.append(memo)
                    processedFileNames.insert(fileName)
                    logger.info("[VoiceMemosMonitor] Found already transcribed memo | file=\(fileName)")
                } else if isQueued {
                    // Already in transcription queue — don't re-add
                    processedFileNames.insert(fileName)
                    logger.info("[VoiceMemosMonitor] Memo already in transcription queue | file=\(fileName)")
                } else {
                    // File is not transcribed and not queued
                    newMemos.append(memo)
                    logger.info("[VoiceMemosMonitor] Found new memo | file=\(fileName) size=\(fileSize) bytes")

                    // Immediately add to processedFileNames to prevent duplicates in subsequent scans
                    processedFileNames.insert(fileName)
                }
            }
            
            // Sort processed memos if any were added
            if processedMemos.count > 0 {
                processedMemos.sort { $0.createdDate > $1.createdDate }
            }
            
            if !newMemos.isEmpty {
                pendingMemos.append(contentsOf: newMemos)
                // Sort pending memos by created date (newest first)
                pendingMemos.sort { $0.createdDate > $1.createdDate }
                settings.lastCheckDate = Date()
                
                // Auto-process if setting enabled
                if settings.autoProcessNew {
                    for memo in newMemos {
                        await processMemo(memo)
                    }
                }
            }
            
        } catch {
            logger.error("[VoiceMemosMonitor] Scan failed | error=\(error)")
            lastError = "Scan failed: \(error.localizedDescription)"
        }
    }
    
    @MainActor
    private func updateMemoStatus(
        _ id: UUID,
        status: VoiceMemoEntry.ProcessingStatus,
        summary: String? = nil,
        transcriptSnippet: String? = nil,
        duration: TimeInterval? = nil
    ) {
        if let index = pendingMemos.firstIndex(where: { $0.id == id }) {
            let memo = pendingMemos[index]
            
            // Create updated memo
            let updatedMemo = VoiceMemoEntry(
                id: memo.id,
                fileName: memo.fileName,
                filePath: memo.filePath,
                fileSize: memo.fileSize,
                createdDate: memo.createdDate,
                processedDate: status == .completed ? Date() : memo.processedDate,
                summary: summary ?? memo.summary,
                transcriptSnippet: transcriptSnippet ?? memo.transcriptSnippet,
                duration: duration ?? memo.duration,
                status: status
            )
            
            if status == .processing {
                // Just update status
                pendingMemos[index] = updatedMemo
            } else if status == .completed || status == .failed || status == .skipped {
                // Move to processed
                pendingMemos.remove(at: index)
                processedMemos.insert(updatedMemo, at: 0) // Add to beginning
                processedFileNames.insert(memo.fileName)
                
                // Keep processed memos sorted by date (newest first)
                processedMemos.sort { $0.createdDate > $1.createdDate }
                
                // Limit processed history
                cleanupProcessedHistory()
                
                // Save the updated processed files list
                saveSettings()
            }
        }
    }
    
    private func cleanupProcessedHistory() {
        if processedMemos.count > maxProcessedHistory {
            // Keep only the most recent
            let toRemove = processedMemos.suffix(from: maxProcessedHistory)
            processedMemos = Array(processedMemos.prefix(maxProcessedHistory))
            
            // Update Set
            for memo in toRemove {
                processedFileNames.remove(memo.fileName)
            }
        }
    }
    
    private func trimAudioFile(inputPath: String, duration: TimeInterval) async throws -> String {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        
        let asset = AVURLAsset(url: URL(fileURLWithPath: inputPath))
        
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw VoiceMemosError.exportSessionCreationFailed
        }
        
        exportSession.outputURL = tempURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: duration, preferredTimescale: 1)
        )
        
        await exportSession.export()
        
        guard exportSession.status == .completed else {
            throw VoiceMemosError.exportFailed(exportSession.error?.localizedDescription ?? "Unknown error")
        }
        
        return tempURL.path
    }
    
    private func generateSummary(from transcript: String) async -> String {
        // TODO: Integrate with proper AI summarization
        // For now, use improved heuristic summarization
        
        let sentences = transcript.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 20 } // Filter out very short sentences
        
        guard !sentences.isEmpty else { return "" }
        
        // Try to identify key sentences (those with important keywords)
        let importantKeywords = ["important", "remember", "note", "key", "main", "summary", "conclusion", "result"]
        var keySentences: [String] = []
        
        for sentence in sentences {
            let lowercased = sentence.lowercased()
            if importantKeywords.contains(where: { lowercased.contains($0) }) {
                keySentences.append(sentence)
            }
        }
        
        // If no key sentences, take first few
        if keySentences.isEmpty {
            keySentences = Array(sentences.prefix(3))
        } else {
            keySentences = Array(keySentences.prefix(3))
        }
        
        let summary = keySentences.joined(separator: ". ")
        
        if summary.count > 300 {
            return String(summary.prefix(297)) + "..."
        }
        
        return summary.hasSuffix(".") ? summary : summary + "."
    }
    
    // MARK: - Persistence
    
    private func saveSettings() {
        do {
            // Save settings to GRDB
            try database.writeQueue { [weak self] db in
                guard let self = self else { return }
                let voiceMemoSettings = VoiceMemoSettings(
                    id: 1,  // Single settings record
                    isEnabled: self.settings.isEnabled,
                    checkInterval: self.settings.checkInterval,
                    maxProcessingDuration: self.settings.maxProcessingDuration,
                    enableDurationLimit: self.settings.enableDurationLimit,
                    autoGenerateSummary: self.settings.autoGenerateSummary,
                    autoProcessNew: self.settings.autoProcessNew,
                    deleteAfterImport: self.settings.deleteAfterImport,
                    lastCheckDate: self.settings.lastCheckDate,
                    updatedAt: Date()
                )
                try voiceMemoSettings.save(db)
            }
            
            // Save processed files to database
            saveProcessedFilesToDatabase()
            
            logger.debug("[VoiceMemosMonitor] Settings saved to GRDB | processedFiles=\(processedFileNames.count)")
        } catch {
            logger.error("[VoiceMemosMonitor] Failed to save settings: \(error)")
        }
    }
    
    private func loadSettings() {
        do {
            // Load settings from GRDB
            if let voiceMemoSettings = try database.readQueue({ db in
                try VoiceMemoSettings.fetchOne(db, key: 1)
            }) {
                settings = VoiceMemoMonitorSettings(
                    isEnabled: voiceMemoSettings.isEnabled,
                    checkInterval: voiceMemoSettings.checkInterval,
                    maxProcessingDuration: voiceMemoSettings.maxProcessingDuration,
                    enableDurationLimit: voiceMemoSettings.enableDurationLimit,
                    autoGenerateSummary: voiceMemoSettings.autoGenerateSummary,
                    autoProcessNew: voiceMemoSettings.autoProcessNew,
                    deleteAfterImport: voiceMemoSettings.deleteAfterImport,
                    lastCheckDate: voiceMemoSettings.lastCheckDate
                )
                logger.debug("[VoiceMemosMonitor] Loaded settings from GRDB")
            }
        } catch {
            logger.error("[VoiceMemosMonitor] Failed to load settings from GRDB: \(error)")
        }
    }
    
    /// Clear all processed memos history
    func clearHistory() {
        processedMemos.removeAll()
        processedFileNames.removeAll()
        saveSettings()
        
        // Also clear from database
        do {
            _ = try database.writeQueue { db in
                try VoiceMemoProcessed.deleteAll(db)
            }
        } catch {
            logger.error("[VoiceMemosMonitor] Failed to clear history from database: \(error)")
        }
        
        logger.info("[VoiceMemosMonitor] History cleared")
    }
    
    // MARK: - Database Operations
    
    private func saveProcessedFilesToDatabase() {
        do {
            try database.writeQueue { [weak self] db in
                guard let self = self else { return }
                // Clear existing and save fresh
                try VoiceMemoProcessed.deleteAll(db)
                
                // Save processed memos to database
                for memo in self.processedMemos.prefix(self.maxProcessedHistory) {
                    let processed = VoiceMemoProcessed(
                        id: nil,
                        fileName: memo.fileName,
                        filePath: memo.filePath,
                        fileSize: memo.fileSize,
                        processedDate: memo.processedDate ?? Date(),
                        status: memo.status.rawValue,
                        summary: memo.summary,
                        transcriptSnippet: memo.transcriptSnippet,
                        duration: memo.duration
                    )
                    try processed.save(db)
                }
            }
        } catch {
            logger.error("[VoiceMemosMonitor] Failed to save processed files: \(error)")
        }
    }
    
    private func loadProcessedFilesFromDatabase() {
        do {
            let processedFiles = try database.readQueue { db in
                try VoiceMemoProcessed.fetchAll(db)
            }
            
            // Convert to VoiceMemoEntry and populate processedMemos
            processedMemos = processedFiles.map { processed in
                VoiceMemoEntry(
                    id: UUID(),
                    fileName: processed.fileName,
                    filePath: processed.filePath,
                    fileSize: processed.fileSize ?? 0,
                    createdDate: processed.processedDate,
                    processedDate: processed.processedDate,
                    summary: processed.summary,
                    transcriptSnippet: processed.transcriptSnippet,
                    duration: processed.duration,
                    status: VoiceMemoEntry.ProcessingStatus(rawValue: processed.status) ?? .completed
                )
            }
            
            // Build processedFileNames set
            processedFileNames = Set(processedFiles.map { $0.fileName })
            
            logger.info("[VoiceMemosMonitor] Loaded \(processedFiles.count) processed files from database")
        } catch {
            logger.error("[VoiceMemosMonitor] Failed to load processed files: \(error)")
        }
    }
    
    // MARK: - Migration
    
    private func migrateFromUserDefaultsIfNeeded() {
        // Check if migration has been done
        if settingsRepo.getBool(forKey: "voiceMemosMonitor.migrated") == true {
            return
        }
        
        logger.info("[VoiceMemosMonitor] Migrating from UserDefaults to GRDB...")
        
        // Migrate settings
        if let data = UserDefaults.standard.data(forKey: "VoiceMemosMonitorSettings"),
           let oldSettings = try? JSONDecoder().decode(VoiceMemoMonitorSettings.self, from: data) {
            settings = oldSettings
            saveSettings()
        }
        
        // Migrate processed memos
        if let memosData = UserDefaults.standard.data(forKey: "VoiceMemosProcessedMemos"),
           let oldMemos = try? JSONDecoder().decode([VoiceMemoEntry].self, from: memosData) {
            processedMemos = oldMemos
            saveProcessedFilesToDatabase()
        }
        
        // Migrate processed file names
        if let namesData = UserDefaults.standard.data(forKey: "VoiceMemosProcessedFileNames"),
           let oldNames = try? JSONDecoder().decode([String].self, from: namesData) {
            processedFileNames = Set(oldNames)
        }
        
        // Mark migration complete
        settingsRepo.setBool(true, forKey: "voiceMemosMonitor.migrated")
        
        // Clean up UserDefaults
        UserDefaults.standard.removeObject(forKey: "VoiceMemosMonitorSettings")
        UserDefaults.standard.removeObject(forKey: "VoiceMemosProcessedMemos")
        UserDefaults.standard.removeObject(forKey: "VoiceMemosProcessedFileNames")
        
        logger.info("[VoiceMemosMonitor] Migration complete")
    }
    
    /// Get statistics about monitoring
    func getStatistics() -> (pending: Int, processed: Int, failed: Int, processing: Int) {
        let failed = processedMemos.filter { $0.status == .failed }.count
        let processed = processedMemos.filter { $0.status == .completed }.count
        return (
            pending: pendingMemos.filter { !currentlyProcessing.contains($0.id) }.count,
            processed: processed,
            failed: failed,
            processing: currentlyProcessing.count
        )
    }
}

// MARK: - Error Types

enum VoiceMemosError: LocalizedError {
    case exportSessionCreationFailed
    case exportFailed(String)
    case fileNotFound(String)
    case invalidPath(String)
    
    var errorDescription: String? {
        switch self {
        case .exportSessionCreationFailed:
            return "Failed to create audio export session"
        case .exportFailed(let reason):
            return "Audio export failed: \(reason)"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .invalidPath(let path):
            return "Invalid file path: \(path)"
        }
    }
}
