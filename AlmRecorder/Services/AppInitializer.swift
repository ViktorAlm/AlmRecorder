import Foundation

/// Service to handle app initialization tasks
class AppInitializer {
    static let shared = AppInitializer()
    
    private init() {}
    
    /// Initialize all services and download required models
    func initializeApp() async {
        print("[AppInitializer] Starting app initialization...")
        
        // Initialize GRDB database with Vectorlite
        // IMPORTANT: Do this first and synchronously to ensure migrations complete
        // before any other services try to access the database
        print("[AppInitializer] Initializing database...")
        _ = GRDBDatabaseManager.shared
        print("[AppInitializer] Database initialized")

        // Wall-clock backstop that SIGKILLs any model subprocess wedged past the hard ceiling,
        // even if its per-run watchdog was starved during a system freeze (the 12h-orphan case).
        ChildProcessReaper.shared.start()
        
        // Migrate model preferences to variant system
        await migrateModelPreferences()
        
        // Discover already-installed models. First-run downloads belong to the setup wizard, where
        // their size and purpose are visible and the user explicitly starts them.
        await ensureEmbeddingModel()
        
        // Ensure default Whisper model is downloaded
        await ensureWhisperModel()
        
        // Start background embedding processor
        await startBackgroundEmbeddingProcessor()
        await startBackgroundInsightsProcessor()

        // Start background transcript-cleanup processor (resume + backfill discovery)
        await startBackgroundCleanupProcessor()

        // Speaker-identity LLM review runs automatically: catch up on unchecked suggestions
        // (pre-existing ones, and runs skipped while the GPU was busy) without any button.
        IdentityInferenceCoordinator.shared.startPeriodicReview()

        // Start Voice Memos monitoring if enabled
        await startVoiceMemosMonitoring()
        
        // Initialize and auto-start transcription queue
        await initializeTranscriptionQueue()

        // Start calendar sync if access is granted
        await startCalendarSync()

        print("[AppInitializer] App initialization complete")
    }
    
    /// Ensure embedding model is ready
    private func ensureEmbeddingModel() async {
        print("[AppInitializer] Checking embedding model...")
        
        let modelManager = EmbeddingModelManager.shared
        
        if modelManager.isModelLoaded {
            print("[AppInitializer] Embedding model ready: \(modelManager.currentModel)")
        } else {
            print("[AppInitializer] No embedding model installed; waiting for setup/user action")
        }
    }
    
    /// Migrate model preferences from legacy string keys to variants
    private func migrateModelPreferences() async {
        print("[AppInitializer] Migrating model preferences...")
        
        await MainActor.run {
            let modelSettings = GlobalModelSettings.shared
            modelSettings.migrateToVariantSystem()
            
            // Ensure variant is set if we have a selected model
            if modelSettings.selectedWhisperVariant == nil && !modelSettings.selectedWhisperModel.isEmpty {
                print("[AppInitializer] Migrating legacy model selection: \(modelSettings.selectedWhisperModel)")
                
                // Try to find variant for the legacy model
                if let variant = WhisperModelManager.shared.getVariant(for: modelSettings.selectedWhisperModel) {
                    modelSettings.selectedWhisperVariant = variant
                    print("[AppInitializer] Successfully migrated to variant: \(variant.displayName)")
                }
            }
        }
    }
    
    /// Ensure Whisper model is ready
    private func ensureWhisperModel() async {
        print("[AppInitializer] Checking Whisper model...")
        
        let whisperManager = WhisperModelManager.shared
        let modelSettings = GlobalModelSettings.shared
        
        // Check if we have the selected model downloaded
        if let selectedVariant = modelSettings.selectedWhisperVariant {
            if !whisperManager.isModelDownloaded(selectedVariant) {
                print("[AppInitializer] Selected Whisper model is not installed; waiting for setup/user action: \(selectedVariant.displayName)")
            } else {
                print("[AppInitializer] Selected model ready: \(selectedVariant.displayName)")
            }
        } else {
            print("[AppInitializer] No model selected yet - user will select on first use")
        }
    }
    
    /// Start background embedding processor
    private func startBackgroundEmbeddingProcessor() async {
        print("[AppInitializer] Starting background embedding processor...")
        
        let embeddingQueue = EmbeddingQueueManager.shared
        
        // Check if there are any pending jobs from previous session
        if embeddingQueue.hasActiveJobs {
            print("[AppInitializer] Found \(embeddingQueue.queueSize) pending embedding jobs")
            embeddingQueue.startProcessing()
        }
        
        // Check for any utterances without embeddings
        if EmbeddingModelManager.shared.isModelLoaded {
            let utteranceProcessor = UtteranceProcessor()
            await utteranceProcessor.generateMissingEmbeddings(queueForBackground: true)
        }
        
        // Start periodic maintenance for embeddings
        await MainActor.run {
            embeddingQueue.startPeriodicMaintenance()
            print("[AppInitializer] Started periodic embedding maintenance")
        }
    }

    /// Start the background LLM-insights processor (title/summary/tags for all recordings).
    /// No-op until a Gemma text model is downloaded.
    private func startBackgroundInsightsProcessor() async {
        guard LLMTextService.shared.isAvailable else {
            print("[AppInitializer] No Gemma text model — skipping insights backfill")
            return
        }
        let queue = RecordingInsightsQueueManager.shared
        if queue.hasActiveJobs {
            print("[AppInitializer] Found \(queue.queueSize) pending insights jobs")
            queue.startProcessing()
        }
        // performMaintenance (run by startPeriodicMaintenance) discovers + enqueues the backfill.
        await MainActor.run {
            queue.startPeriodicMaintenance()
            print("[AppInitializer] Started periodic insights maintenance")
        }
    }

    /// Start the background transcript-cleanup processor (hallucination detection + review
    /// routing). Resumes interrupted jobs; backfill discovery only runs while enabled.
    private func startBackgroundCleanupProcessor() async {
        let queue = TranscriptCleanupQueueManager.shared
        if queue.hasActiveJobs {
            print("[AppInitializer] Found \(queue.queueSize) pending transcript-cleanup jobs")
            queue.startProcessing()
        }
        await MainActor.run {
            queue.startPeriodicMaintenance()
            print("[AppInitializer] Started periodic transcript-cleanup maintenance")
        }
    }
    
    /// Initialize and auto-start transcription queue
    private func initializeTranscriptionQueue() async {
        print("[AppInitializer] Initializing transcription queue...")
        
        await MainActor.run {
            let queueManager = TranscriptionQueueManager.shared
            
            // Check if we have pending or interrupted jobs
            let pendingCount = queueManager.pendingJobs.count
            let interruptedCount = queueManager.jobs.filter { $0.status == .interrupted }.count
            let totalJobs = queueManager.jobs.count
            
            if totalJobs > 0 {
                print("[AppInitializer] Found \(totalJobs) jobs in queue:")
                print("[AppInitializer]   - Pending: \(pendingCount)")
                print("[AppInitializer]   - Interrupted: \(interruptedCount)")
                
                // Check if auto-resume is enabled (default to true)
                let autoResume = GRDBSettingsRepository.shared.getBool(forKey: "autoResumeQueue") ?? true
                
                if autoResume && (pendingCount > 0 || interruptedCount > 0) {
                    print("[AppInitializer] Auto-resuming queue processing...")
                    
                    // Mark interrupted jobs as pending
                    for index in queueManager.jobs.indices {
                        if queueManager.jobs[index].status == .interrupted {
                            queueManager.jobs[index].status = .pending
                            print("[AppInitializer] Marked interrupted job as pending: \(queueManager.jobs[index].fileName)")
                        }
                    }
                    
                    // Start processing
                    queueManager.resumeAllProcessing()
                    print("[AppInitializer] Queue processing started with \(queueManager.maxConcurrentJobs) workers")
                } else if !autoResume {
                    print("[AppInitializer] Auto-resume disabled, queue not started")
                } else {
                    print("[AppInitializer] No pending jobs to process")
                }
            } else {
                print("[AppInitializer] Transcription queue is empty")
            }
        }
    }
    
    /// Start Voice Memos monitoring
    private func startVoiceMemosMonitoring() async {
        print("[AppInitializer] Starting Voice Memos monitoring...")
        
        await MainActor.run {
            let voiceMemosMonitor = VoiceMemosMonitorService.shared
            
            // Check if monitoring is enabled in settings
            if voiceMemosMonitor.settings.isEnabled {
                voiceMemosMonitor.startMonitoring()
                
                // Check for any pending memos from previous session
                if !voiceMemosMonitor.pendingMemos.isEmpty {
                    print("[AppInitializer] Found \(voiceMemosMonitor.pendingMemos.count) pending Voice Memos")
                    
                    // Process them in the background
                    Task {
                        await voiceMemosMonitor.processAllPending()
                    }
                }
            } else {
                print("[AppInitializer] Voice Memos monitoring is disabled in settings")
            }
        }
    }
    
    /// Start calendar sync if access is granted
    private func startCalendarSync() async {
        print("[AppInitializer] Checking calendar sync...")

        await MainActor.run {
            let calendarService = CalendarService.shared
            if calendarService.hasAccess {
                print("[AppInitializer] Calendar access granted, starting sync...")
                Task {
                    await calendarService.syncEvents()
                    calendarService.startPeriodicSync()
                }
                // Offer to auto-record meetings (no-op unless the user enabled it in Settings).
                MeetingMonitor.shared.startMonitoring()
            } else {
                print("[AppInitializer] No calendar access, skipping sync")
            }
        }
    }

    /// Migrate existing transcriptions to database
    func migrateExistingData() async {
        print("[AppInitializer] Checking for data migration...")
        
        let migrationService = MigrationService()
        
        do {
            // Relocate recordings out of ~/Documents into Application Support (one-time)
            migrationService.migrateRecordingsToAppSupportIfNeeded()

            // Migrate existing transcriptions
            let (migrated, failed) = try await migrationService.migrateExistingTranscriptions()
            if migrated > 0 || failed > 0 {
                print("[AppInitializer] Migration complete: \(migrated) migrated, \(failed) failed")
            }
            
            // Process any recordings without utterances
            let processed = try await migrationService.processUnprocessedRecordings()
            if processed > 0 {
                print("[AppInitializer] Processed \(processed) recordings into utterances")
            }

            // Cleanup stale placeholder speakers from old per-recording backfills
            let cleaned = try migrationService.cleanupStaleBackfillSpeakers()
            if cleaned > 0 {
                print("[AppInitializer] Cleaned up \(cleaned) stale placeholder speakers")
            }

            // Backfill speaker_uuid for old recordings with speaker labels but no linked speaker records
            let backfilled = try await migrationService.backfillSpeakerUUIDs()
            if backfilled > 0 {
                print("[AppInitializer] Backfilled \(backfilled) speaker links")
            }
            
            // Note: Missing embeddings will be handled by background processor
            // Just queue them for processing
            if EmbeddingModelManager.shared.isModelLoaded {
                let utteranceProcessor = UtteranceProcessor()
                await utteranceProcessor.generateMissingEmbeddings(queueForBackground: true)
            }
            
        } catch {
            print("[AppInitializer] Migration error: \(error)")
        }
    }
}
