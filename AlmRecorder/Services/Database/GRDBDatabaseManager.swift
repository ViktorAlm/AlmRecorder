import Foundation
import GRDB

/// Database manager using GRDB with vectorlite extension for HNSW vector search
class GRDBDatabaseManager {
    static let shared = GRDBDatabaseManager()
    
    // Load custom SQLite with extension support before GRDB initializes
    private static let loadCustomSQLite: Void = {
        // First try to load our custom SQLite build
        let bundlePath = Bundle.main.bundlePath
        let customSQLitePath = "\(bundlePath)/Contents/Resources/Libraries/libsqlite3_custom.dylib"
        
        if FileManager.default.fileExists(atPath: customSQLitePath) {
            // Load with RTLD_NOW | RTLD_GLOBAL to override system SQLite
            if let handle = dlopen(customSQLitePath, RTLD_NOW | RTLD_GLOBAL) {
                print("[GRDBDatabaseManager] Loaded custom SQLite from: \(customSQLitePath)")
                print("[GRDBDatabaseManager] This SQLite has extension loading enabled")
                return
            } else if let error = dlerror() {
                print("[GRDBDatabaseManager] Failed to load custom SQLite: \(String(cString: error))")
            }
        }
        
        // Fallback to Homebrew SQLite if available
        let homebrewPaths = [
            "/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib",  // ARM Mac
            "/usr/local/opt/sqlite/lib/libsqlite3.dylib"      // Intel Mac
        ]
        
        for sqlitePath in homebrewPaths {
            if FileManager.default.fileExists(atPath: sqlitePath) {
                if let handle = dlopen(sqlitePath, RTLD_NOW | RTLD_GLOBAL) {
                    print("[GRDBDatabaseManager] Loaded Homebrew SQLite from: \(sqlitePath)")
                    print("[GRDBDatabaseManager] This SQLite has extension loading enabled")
                    return
                } else if let error = dlerror() {
                    print("[GRDBDatabaseManager] Failed to load SQLite from \(sqlitePath): \(String(cString: error))")
                }
            }
        }
        
        print("[GRDBDatabaseManager] WARNING: No custom SQLite found. Extension loading will not work.")
        print("[GRDBDatabaseManager] The app requires a custom SQLite build with SQLITE_ENABLE_LOAD_EXTENSION.")
    }()
    
    private var dbQueue: DatabaseQueue
    private let dbPath: String
    private let logger = VoxtralLogger.shared
    private var queryCount = 0
    private var totalQueryTime: TimeInterval = 0
    private var isMigrating = false
    
    private init() {
        // Ensure custom SQLite is loaded
        _ = Self.loadCustomSQLite
        
        // Set up database path in Application Support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("AlmRecorder")
        
        // Create directory if needed
        try? FileManager.default.createDirectory(at: appFolder,
                                                withIntermediateDirectories: true)
        
        self.dbPath = appFolder.appendingPathComponent("transcriptions_grdb.db").path
        
        do {
            // Create database queue with custom configuration
            var config = Configuration()
            
            // Enable foreign key constraints (will be checked after migrations)
            config.foreignKeysEnabled = true
            
            // Use WAL mode for better concurrency
            config.journalMode = .wal
            
            // Prepare database with extension loading
            let vectorlitePath = Self.getVectorlitePath() // Will fatal error if not found
            let capturedLogger = logger
            config.prepareDatabase { db in
                // Enable extension loading (required for custom SQLite)
                sqlite3_enable_load_extension(db.sqliteConnection, 1)
                
                // Enable trusted schema for extension loading
                try? db.execute(sql: "PRAGMA trusted_schema=1")
                
                // Try to load vectorlite extension
                do {
                    // Try with entry point first
                    try db.execute(sql: "SELECT load_extension(?, 'sqlite3_vectorlite_init')",
                                 arguments: [vectorlitePath])
                    capturedLogger.info("[GRDBDatabaseManager] Vectorlite loaded successfully | entryPoint=sqlite3_vectorlite_init")
                } catch {
                    // Try without entry point
                    do {
                        try db.execute(sql: "SELECT load_extension(?)",
                                     arguments: [vectorlitePath])
                        capturedLogger.info("[GRDBDatabaseManager] Vectorlite loaded successfully")
                    } catch let loadError {
                        // This is a semantic search app - vectorlite is REQUIRED
                        capturedLogger.error("""
                            [GRDBDatabaseManager] FATAL: Cannot load vectorlite extension.
                            Path: \(vectorlitePath)
                            Error: \(loadError)
                            
                            This is a semantic search app - vectorlite is required.
                            The app was built with custom SQLite that includes SQLITE_ENABLE_LOAD_EXTENSION.
                            If this error occurs, the custom build is not working correctly.
                            """)
                        
                        // As the user said: "this is an ai search app if it doesnt work we should crash"
                        fatalError("""
                            Failed to load vectorlite extension - semantic search is required for this app.
                            Path: \(vectorlitePath)
                            Error: \(loadError)
                            """)
                    }
                }
                
                #if DEBUG
                // Enable statement tracing for debugging  
                // Note: We'll set up tracing after initialization completes
                #endif
            }
            
            // Create database queue
            dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
            logger.info("[GRDBDatabaseManager] Database initialized | path=\(dbPath) WAL=enabled foreignKeys=enabled")
            
            // Validate vectorlite is properly loaded after migrations
            // This will be done after setupMigrations() is called
            
            // Clean up orphaned records before migrations
            try cleanupOrphanedRecordsBeforeMigration()
            
            #if DEBUG
            // Set up statement tracing after initialization
            try dbQueue.write { db in
                db.trace { [weak self] event in
                    if case let .statement(statement) = event {
                        self?.logger.debug("[GRDB SQL] \(statement)")
                    } else if case let .profile(statement, duration) = event {
                        self?.queryCount += 1
                        self?.totalQueryTime += duration
                        if duration > 0.1 { // Log slow queries over 100ms
                            self?.logger.warning("[GRDB SLOW] Query took \(String(format: "%.3f", duration))s | \(statement)")
                        }
                    }
                }
            }
            #endif
            
            // Run migrations
            try migrate()
            
        } catch {
            fatalError("[GRDBDatabaseManager] Failed to initialize database: \(error)")
        }
    }
    
    // MARK: - Pre-Migration Cleanup
    
    private func cleanupOrphanedRecordsBeforeMigration() throws {
        // This runs before migrations to clean up any orphaned records
        // that would cause foreign key violations
        try dbQueue.write { db in
            // Temporarily disable foreign keys for cleanup
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            
            defer {
                // Re-enable foreign keys
                try? db.execute(sql: "PRAGMA foreign_keys = ON")
            }
            
            // Vectorlite is now the only embedding storage mechanism
            // No fallback table cleanup needed
            
            // Clean up speaker embedding history if needed
            let hasEmbeddingHistory = try db.tableExists("speaker_embedding_history")
            let hasSpeakers = try db.tableExists("speakers")
            
            if hasEmbeddingHistory && hasSpeakers {
                try db.execute(sql: """
                    DELETE FROM speaker_embedding_history
                    WHERE speaker_id NOT IN (
                        SELECT id FROM speakers
                    )
                """)
            }
        }
    }
    
    // MARK: - Database Migrations
    
    private func migrate() throws {
        var migrator = DatabaseMigrator()
        
        // Ensure foreign key violations don't block migrations
        migrator.eraseDatabaseOnSchemaChange = false
        
        logger.info("[GRDBDatabaseManager] Starting database migrations")
        
        // Migration 1: Create base tables
        migrator.registerMigration("v1_initial") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v1_initial")
            // Vectorlite should already be loaded in prepareDatabase
            
            // Create recordings table
            try db.create(table: "recordings") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("file_name", .text).notNull()
                t.column("file_path", .text)
                t.column("duration", .double)
                t.column("language", .text)
                t.column("created_at", .datetime).notNull().defaults(to: Date())
                t.column("transcribed_at", .datetime)
                t.column("source", .text).notNull()
                    .check { ["recording", "voiceMemos", "imported"].contains($0) }
                t.column("full_transcript", .text)
                t.column("metadata", .text) // JSON
            }
            
            // Create utterances table
            try db.create(table: "utterances") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("recording_id", .integer).notNull()
                    .indexed()
                    .references("recordings", onDelete: .cascade)
                t.column("utterance_index", .integer).notNull()
                t.column("start_time", .double).notNull()
                t.column("end_time", .double).notNull()
                t.column("speaker", .text)
                t.column("speaker_uuid", .text)
                t.column("text", .text).notNull()
                t.column("confidence", .double)
            }
            
            // Create vectorlite virtual table (required for semantic search)
            do {
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE IF NOT EXISTS utterance_vectors USING vectorlite(
                        embedding float32[1024],
                        hnsw(max_elements=1000000, ef_construction=200)
                    )
                """)
                self.logger.info("[GRDBDatabaseManager] Vectorlite HNSW table created | dimensions=1024 maxElements=1000000 m=32 ef_construction=200")
            } catch {
                self.logger.error("[GRDBDatabaseManager] Failed to create utterance_vectors table: \(error)")
                throw error
            }
            
            // Create speakers table
            try db.create(table: "speakers") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("uuid", .text).notNull().unique()
                t.column("name", .text)
                t.column("embedding", .blob).notNull()
                t.column("embedding_count", .integer).notNull().defaults(to: 1)
                t.column("total_duration", .double).notNull().defaults(to: 0)
                t.column("utterance_count", .integer).notNull().defaults(to: 0)
                t.column("created_at", .datetime).notNull().defaults(to: Date())
                t.column("updated_at", .datetime).notNull().defaults(to: Date())
                t.column("last_seen_at", .datetime).notNull().defaults(to: Date())
                t.column("confidence", .double).notNull().defaults(to: 0.0)
                t.column("notes", .text)
            }
            
            // Create speaker_embedding_history table
            try db.create(table: "speaker_embedding_history") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("speaker_id", .integer).notNull()
                    .indexed()
                    .references("speakers", onDelete: .cascade)
                t.column("embedding", .blob).notNull()
                t.column("recording_id", .integer)
                    .references("recordings", onDelete: .setNull)
                t.column("confidence", .double).notNull()
                t.column("created_at", .datetime).notNull().defaults(to: Date())
            }
            
            // Create indexes
            try db.create(index: "idx_speakers_uuid", on: "speakers", columns: ["uuid"])
            try db.create(index: "idx_speakers_updated", on: "speakers", columns: ["updated_at"])
            
            try db.create(index: "idx_utterances_recording_time", 
                        on: "utterances", 
                        columns: ["recording_id", "start_time"])
            
            try db.create(index: "idx_recordings_created", 
                        on: "recordings", 
                        columns: ["created_at"])
            
            try db.create(index: "idx_recordings_source", 
                        on: "recordings", 
                        columns: ["source"])
        }
        
        // Migration 2: Add speaker merge history table
        migrator.registerMigration("v2_speaker_merge_history") { db in
            try db.create(table: "speaker_merge_history", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("primary_speaker_uuid", .text).notNull()
                t.column("merged_speaker_uuid", .text).notNull()
                t.column("merged_speaker_name", .text)
                t.column("merged_speaker_data", .blob).notNull()
                t.column("merged_at", .datetime).notNull()
                t.column("merged_by", .text).notNull()
            }
            
            // Create indexes for efficient queries
            try db.create(index: "idx_merge_history_primary", 
                        on: "speaker_merge_history", 
                        columns: ["primary_speaker_uuid"])
            
            try db.create(index: "idx_merge_history_date", 
                        on: "speaker_merge_history", 
                        columns: ["merged_at"])
        }
        
        // Migration 3: Clean up orphaned embeddings
        // This migration must run with foreign keys disabled to clean up inconsistent data
        migrator.registerMigration("v3_cleanup_orphaned_embeddings") { db in
            // Temporarily disable foreign keys for cleanup
            let foreignKeysEnabled = try Bool.fetchOne(db, sql: "PRAGMA foreign_keys") ?? false
            if foreignKeysEnabled {
                try db.execute(sql: "PRAGMA foreign_keys = OFF")
            }
            
            defer {
                // Re-enable foreign keys if they were enabled
                if foreignKeysEnabled {
                    try? db.execute(sql: "PRAGMA foreign_keys = ON")
                }
            }
            
            // Drop the obsolete fallback table if it still exists
            if try db.tableExists("utterance_embeddings_fallback") {
                try db.execute(sql: "DROP TABLE utterance_embeddings_fallback")
                self.logger.info("[GRDBDatabaseManager] Dropped obsolete utterance_embeddings_fallback table")
            }
            
            // Also clean up any orphaned speaker embedding history
            if try db.tableExists("speaker_embedding_history") {
                try db.execute(sql: """
                    DELETE FROM speaker_embedding_history
                    WHERE speaker_id NOT IN (
                        SELECT id FROM speakers
                    )
                """)
            }
        }
        
        // Migration 4: Add transcription queue persistence
        migrator.registerMigration("v4_transcription_queue") { db in
            // Create transcription queue table
            try db.create(table: "transcription_queue", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("audio_file_path", .text).notNull()
                t.column("file_name", .text).notNull()
                t.column("source", .text).notNull()
                t.column("priority", .integer).notNull().defaults(to: 1)
                t.column("status", .text).notNull()
                t.column("progress", .double).defaults(to: 0.0)
                t.column("progress_message", .text)
                t.column("progress_phase", .text)
                t.column("total_chunks", .integer).defaults(to: 0)
                t.column("completed_chunks", .integer).defaults(to: 0)
                t.column("created_at", .datetime).notNull()
                t.column("started_at", .datetime)
                t.column("completed_at", .datetime)
                t.column("transcript", .text)
                t.column("error", .text)
                t.column("retry_count", .integer).defaults(to: 0)
                t.column("max_retries", .integer).defaults(to: 2)
                t.column("file_size", .integer)
                t.column("duration", .double)
                t.column("model_used", .text)
                t.column("required_model", .text)
                t.column("run_settings", .text)  // JSON encoded
                t.column("worker_id", .text)  // Track which worker is processing
                t.column("last_heartbeat", .datetime)  // For crash recovery
                t.column("checkpoint_data", .text)  // JSON encoded checkpoint
            }
            
            // Create index for efficient queries
            try db.create(index: "idx_queue_status_priority", on: "transcription_queue", 
                         columns: ["status", "priority", "created_at"])
            try db.create(index: "idx_queue_worker", on: "transcription_queue", 
                         columns: ["worker_id", "status"])
            
            self.logger.info("[GRDBDatabaseManager] Created transcription_queue table")
        }
        
        // Migration 5: Add settings and queue tables
        migrator.registerMigration("v5_settings_and_queues") { db in
            // App settings table (replaces UserDefaults)
            try db.create(table: "app_settings", ifNotExists: true) { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
                t.column("type", .text).notNull() // string, bool, int, double, data
                t.column("updated_at", .datetime).notNull()
            }
            
            // Voice memo settings
            try db.create(table: "voice_memo_settings", ifNotExists: true) { t in
                t.column("id", .integer).primaryKey()
                t.column("is_enabled", .boolean).notNull().defaults(to: true)
                t.column("check_interval", .double).notNull().defaults(to: 60)
                t.column("max_processing_duration", .double).notNull().defaults(to: 36000) // 10 hours default
                t.column("enable_duration_limit", .boolean).notNull().defaults(to: false) // Disabled by default
                t.column("auto_generate_summary", .boolean).notNull().defaults(to: true)
                t.column("auto_process_new", .boolean).notNull().defaults(to: true)
                t.column("delete_after_import", .boolean).notNull().defaults(to: false)
                t.column("last_check_date", .datetime)
                t.column("updated_at", .datetime).notNull()
            }
            
            // Voice memo processed files tracking
            try db.create(table: "voice_memo_processed", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("file_name", .text).notNull().unique()
                t.column("file_path", .text).notNull()
                t.column("file_size", .integer)
                t.column("processed_date", .datetime).notNull()
                t.column("status", .text).notNull() // completed, failed, skipped
                t.column("summary", .text)
                t.column("transcript_snippet", .text)
                t.column("duration", .double)
            }
            
            // Embedding queue (replaces JSON file)
            try db.create(table: "embedding_queue", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("utterance_id", .integer).notNull()
                t.column("priority", .integer).notNull().defaults(to: 0)
                t.column("status", .text).notNull() // pending, processing, completed, failed
                t.column("retry_count", .integer).notNull().defaults(to: 0)
                t.column("created_at", .datetime).notNull()
                t.column("started_at", .datetime)
                t.column("completed_at", .datetime)
                t.column("error", .text)
            }
            
            // Create indexes for efficient queries
            try db.create(index: "idx_settings_updated", on: "app_settings", columns: ["updated_at"])
            try db.create(index: "idx_voice_memo_file", on: "voice_memo_processed", columns: ["file_name"])
            try db.create(index: "idx_embedding_queue_status", on: "embedding_queue", columns: ["status", "priority"])
            
            self.logger.info("[GRDBDatabaseManager] Created settings and queue tables")
        }
        
        // v6: Add transcription history table
        migrator.registerMigration("v6_transcription_history") { db in
            try db.create(table: "transcription_history", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("file_name", .text).notNull()
                t.column("file_path", .text).notNull()
                t.column("date", .datetime).notNull()
                t.column("duration", .double).notNull()
                t.column("source", .text).notNull() // recording, import, voiceMemo
                t.column("transcript_preview", .text)
                t.column("recording_id", .integer).references("recordings", onDelete: .cascade)
                t.column("data", .text).notNull() // JSON encoded TranscriptionItem
                t.column("created_at", .datetime).notNull()
                
                // Index for quick lookups
                t.column("file_hash", .text).indexed()
            }
            
            self.logger.info("[GRDBDatabaseManager] Created transcription history table")
        }
        
        migrator.registerMigration("v7_voice_memo_duration_limit") { db in
            // Add enable_duration_limit column to voice_memo_settings
            // Check if column already exists first
            let columns = try db.columns(in: "voice_memo_settings")
            if !columns.contains(where: { $0.name == "enable_duration_limit" }) {
                try db.alter(table: "voice_memo_settings") { t in
                    t.add(column: "enable_duration_limit", .boolean).notNull().defaults(to: false)
                }
                self.logger.info("[GRDBDatabaseManager] Added enable_duration_limit column to voice_memo_settings")
            }
            
            // Update existing max_processing_duration to 10 hours for existing records
            try db.execute(sql: "UPDATE voice_memo_settings SET max_processing_duration = 36000 WHERE max_processing_duration = 120")
            self.logger.info("[GRDBDatabaseManager] Updated default max_processing_duration to 10 hours")
        }
        
        // Migration 8: Remove obsolete fallback embedding table
        migrator.registerMigration("v8_remove_fallback_embeddings") { db in
            // Drop the obsolete fallback table if it exists
            // This table was replaced by vectorlite HNSW index
            if try db.tableExists("utterance_embeddings_fallback") {
                self.logger.info("[GRDBDatabaseManager] Removing obsolete utterance_embeddings_fallback table")
                try db.execute(sql: "DROP TABLE utterance_embeddings_fallback")
                self.logger.info("[GRDBDatabaseManager] Successfully removed fallback embedding table - using vectorlite exclusively")
            }
        }

        migrator.registerMigration("v9_tags") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v9_tags")

            try db.create(table: "tags") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
                t.column("color", .text)
                t.column("created_at", .datetime).notNull().defaults(to: Date())
            }

            try db.create(table: "recording_tags") { t in
                t.column("recording_id", .integer).notNull()
                    .references("recordings", onDelete: .cascade)
                t.column("tag_id", .integer).notNull()
                    .references("tags", onDelete: .cascade)
                t.column("created_at", .datetime).notNull().defaults(to: Date())
                t.primaryKey(["recording_id", "tag_id"])
            }

            try db.create(index: "idx_recording_tags_recording", on: "recording_tags", columns: ["recording_id"])
            try db.create(index: "idx_recording_tags_tag", on: "recording_tags", columns: ["tag_id"])

            self.logger.info("[GRDBDatabaseManager] Migration v9_tags completed - tags and recording_tags tables created")
        }

        migrator.registerMigration("v10_speaker_source_recording") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v10_speaker_source_recording")

            try db.alter(table: "speakers") { t in
                t.add(column: "source_recording_id", .integer)
                    .references("recordings", onDelete: .setNull)
            }

            try db.create(
                index: "idx_speakers_source_recording",
                on: "speakers",
                columns: ["source_recording_id"],
                ifNotExists: true
            )

            self.logger.info("[GRDBDatabaseManager] Migration v10 completed - added source_recording_id to speakers")
        }

        migrator.registerMigration("v11_deduplicate_recordings") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v11_deduplicate_recordings")

            // Delete duplicate recordings, keeping the one with the lowest id per file_name
            try db.execute(sql: """
                DELETE FROM recordings WHERE id NOT IN (
                    SELECT MIN(id) FROM recordings GROUP BY file_name
                )
            """)

            // Clean up orphaned utterances whose recording was deleted
            try db.execute(sql: """
                DELETE FROM utterances WHERE recording_id NOT IN (SELECT id FROM recordings)
            """)

            // Clean up orphaned recording_tags
            try db.execute(sql: """
                DELETE FROM recording_tags WHERE recording_id NOT IN (SELECT id FROM recordings)
            """)

            // Add UNIQUE index to prevent future duplicates
            try db.create(
                index: "idx_recordings_file_name_unique",
                on: "recordings",
                columns: ["file_name"],
                unique: true,
                ifNotExists: true
            )

            self.logger.info("[GRDBDatabaseManager] Migration v11 completed - deduplicated recordings and added unique index")
        }

        migrator.registerMigration("v12_cleanup_transcription_queue") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v12_cleanup_transcription_queue")

            // Delete completed, failed, and cancelled jobs — they're done
            try db.execute(sql: """
                DELETE FROM transcription_queue WHERE status IN ('Completed', 'Failed', 'Cancelled')
            """)

            // Deduplicate: keep only the newest record per file_name (UUID bug created duplicates)
            try db.execute(sql: """
                DELETE FROM transcription_queue WHERE rowid NOT IN (
                    SELECT MAX(rowid) FROM transcription_queue GROUP BY file_name
                )
            """)

            self.logger.info("[GRDBDatabaseManager] Migration v12 completed - cleaned up transcription queue duplicates")
        }

        migrator.registerMigration("v13_meetings") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v13_meetings")

            // Cached calendar events
            try db.create(table: "meetings") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("calendar_event_id", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("start_date", .datetime).notNull()
                t.column("end_date", .datetime).notNull()
                t.column("calendar_name", .text)
                t.column("calendar_color", .text)
                t.column("location", .text)
                t.column("notes", .text)
                t.column("attendees", .text)
                t.column("is_recurring", .boolean).notNull().defaults(to: false)
                t.column("last_synced_at", .datetime).notNull().defaults(to: Date())
            }

            // Many-to-many link between recordings and meetings
            try db.create(table: "recording_meetings") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("recording_id", .integer).notNull()
                    .references("recordings", onDelete: .cascade)
                t.column("meeting_id", .integer).notNull()
                    .references("meetings", onDelete: .cascade)
                t.column("link_type", .text).notNull().defaults(to: "auto")
            }

            // Indexes
            try db.create(index: "idx_meetings_start_date", on: "meetings", columns: ["start_date"])
            try db.create(index: "idx_meetings_end_date", on: "meetings", columns: ["end_date"])
            try db.create(index: "idx_meetings_calendar_event_id", on: "meetings", columns: ["calendar_event_id"], unique: true)
            try db.create(index: "idx_recording_meetings_recording", on: "recording_meetings", columns: ["recording_id"])
            try db.create(index: "idx_recording_meetings_meeting", on: "recording_meetings", columns: ["meeting_id"])
            try db.create(index: "idx_recording_meetings_unique", on: "recording_meetings", columns: ["recording_id", "meeting_id"], unique: true)

            self.logger.info("[GRDBDatabaseManager] Migration v13_meetings completed")
        }

        migrator.registerMigration("v14_utterance_has_embedding") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v14_utterance_has_embedding")

            // Add has_embedding column to utterances so we don't need to query
            // the vectorlite virtual table for status checks (it only supports knn_search)
            try db.execute(sql: "ALTER TABLE utterances ADD COLUMN has_embedding INTEGER NOT NULL DEFAULT 0")

            self.logger.info("[GRDBDatabaseManager] Migration v14_utterance_has_embedding completed")
        }

        migrator.registerMigration("v15_meeting_match_confidence") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v15_meeting_match_confidence")

            // Add confidence tier and dismiss support to recording_meetings
            try db.execute(sql: "ALTER TABLE recording_meetings ADD COLUMN match_confidence TEXT NOT NULL DEFAULT 'matched'")
            try db.execute(sql: "ALTER TABLE recording_meetings ADD COLUMN is_dismissed INTEGER NOT NULL DEFAULT 0")

            // Index for filtering by confidence and dismissed state
            try db.create(
                index: "idx_recording_meetings_confidence",
                on: "recording_meetings",
                columns: ["match_confidence", "is_dismissed"]
            )

            self.logger.info("[GRDBDatabaseManager] Migration v15_meeting_match_confidence completed")
        }

        migrator.registerMigration("v16_speaker_attendee_mappings") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v16_speaker_attendee_mappings")

            // Global mapping between detected speaker voices and calendar attendee names
            try db.create(table: "speaker_attendee_mappings") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("speaker_uuid", .text).notNull()
                t.column("attendee_name", .text).notNull()
                t.column("attendee_email", .text)
                t.column("source", .text).notNull().defaults(to: "manual")
                t.column("created_at", .datetime).notNull().defaults(to: Date())
            }

            // Unique: one speaker can map to one attendee name
            try db.create(
                index: "idx_speaker_attendee_unique",
                on: "speaker_attendee_mappings",
                columns: ["speaker_uuid", "attendee_name"],
                unique: true
            )

            try db.create(
                index: "idx_speaker_attendee_speaker",
                on: "speaker_attendee_mappings",
                columns: ["speaker_uuid"]
            )

            try db.create(
                index: "idx_speaker_attendee_name",
                on: "speaker_attendee_mappings",
                columns: ["attendee_name"]
            )

            self.logger.info("[GRDBDatabaseManager] Migration v16_speaker_attendee_mappings completed")
        }

        migrator.registerMigration("v17_durable_embeddings") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v17_durable_embeddings")
            // vectorlite's HNSW index is in-memory only, so vectors written to
            // utterance_vectors are lost on quit. Persist them durably so the index can be
            // rebuilt on every launch (see EmbeddingPersistence.hydrateIndex).
            try EmbeddingPersistence.createSchema(db)
            self.logger.info("[GRDBDatabaseManager] Migration v17_durable_embeddings completed")
        }

        migrator.registerMigration("v18_clear_stuck_jobs") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v18_clear_stuck_jobs")
            // Drop jobs orphaned by prior crashes/sessions. The embedding queue is a
            // transient work log; missing embeddings are re-queued on launch.
            if try db.tableExists("embedding_queue") {
                let n = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embedding_queue") ?? 0
                try db.execute(sql: "DELETE FROM embedding_queue")
                self.logger.info("[GRDBDatabaseManager] Cleared \(n) embedding_queue rows")
            }
            // Remove incomplete transcription jobs; keep completed history.
            if try db.tableExists("transcription_queue") {
                let n = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM transcription_queue
                    WHERE LOWER(status) IN ('pending','processing','queued','failed','waitingformodel')
                """) ?? 0
                try db.execute(sql: """
                    DELETE FROM transcription_queue
                    WHERE LOWER(status) IN ('pending','processing','queued','failed','waitingformodel')
                """)
                self.logger.info("[GRDBDatabaseManager] Cleared \(n) stuck transcription_queue rows")
            }
            self.logger.info("[GRDBDatabaseManager] Migration v18_clear_stuck_jobs completed")
        }

        migrator.registerMigration("v19_meeting_notes") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v19_meeting_notes")
            // User-editable agenda/notes per calendar meeting. Keyed by calendar_event_id so it
            // survives the `meetings` cache being fully rewritten on every calendar sync.
            try db.create(table: "meeting_notes") { t in
                t.column("calendar_event_id", .text).primaryKey()
                t.column("agenda", .text)
                t.column("notes", .text)
                t.column("updated_at", .datetime).notNull().defaults(to: Date())
            }
            self.logger.info("[GRDBDatabaseManager] Migration v19_meeting_notes completed")
        }

        migrator.registerMigration("v20_speaker_insights") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v20_speaker_insights")
            // AI "About this person" summary + topics per speaker, keyed by speaker uuid.
            // `version` makes regeneration idempotent (see SpeakerInsightsService).
            try db.create(table: "speaker_insights") { t in
                t.column("speaker_uuid", .text).primaryKey()
                t.column("summary", .text)
                t.column("topics", .text) // JSON-encoded [String]
                t.column("version", .text).notNull().defaults(to: "1")
                t.column("updated_at", .datetime).notNull().defaults(to: Date())
            }
            self.logger.info("[GRDBDatabaseManager] Migration v20_speaker_insights completed")
        }

        migrator.registerMigration("v21_speaker_name_source") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v21_speaker_name_source")
            // Provenance of speakers.name: NULL = unnamed, 'manual' = user-set/confirmed,
            // 'inferred' = auto-applied by the identity inference engine (shown with a badge, one-tap
            // undo). Lets us auto-name high-confidence voices non-destructively while keeping the
            // manual/inferred distinction so a confirm can promote and an undo can revert cleanly.
            try db.alter(table: "speakers") { t in
                t.add(column: "name_source", .text)
            }
            self.logger.info("[GRDBDatabaseManager] Migration v21_speaker_name_source completed")
        }

        migrator.registerMigration("v22_utterance_voice_embeddings") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v22_utterance_voice_embeddings")
            // Durable per-utterance VOICE embedding (256-dim WeSpeaker) so we can flag lines that
            // don't match their assigned speaker and reassign them. No vectorlite — small per-speaker
            // sets compared in-memory (see VoiceEmbeddingStore).
            try VoiceEmbeddingStore.createSchema(db)
            self.logger.info("[GRDBDatabaseManager] Migration v22_utterance_voice_embeddings completed")
        }

        migrator.registerMigration("v23_tag_descriptions") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v23_tag_descriptions")
            // One-line description per tag: gives the insights LLM semantic context to reuse the right
            // existing tag instead of coining near-duplicates; also user-editable in the tag UI.
            try db.alter(table: "tags") { t in
                t.add(column: "description", .text)
            }
            self.logger.info("[GRDBDatabaseManager] Migration v23_tag_descriptions completed")
        }

        migrator.registerMigration("v24_transcript_cleanup") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v24_transcript_cleanup")
            // Hallucination cleanup: soft-hide + text provenance + detector/verifier state on
            // utterances, and a cleaned-at stamp on recordings for backfill discovery.
            try UtteranceReviewStore.migrate(db)
            self.logger.info("[GRDBDatabaseManager] Migration v24_transcript_cleanup completed")
        }

        migrator.registerMigration("v25_hallucination_exemplars") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v25_hallucination_exemplars")
            // Learned bad-exemplar memory: confirmed hallucinations teach the detector to find
            // more like them (language-agnostic — nothing curated, user actions un-teach).
            try HallucinationExemplarStore.migrate(db)
            self.logger.info("[GRDBDatabaseManager] Migration v25_hallucination_exemplars completed")
        }

        migrator.registerMigration("v26_retranscribe_carryover") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v26_retranscribe_carryover")
            // Snapshot of user decisions (hides/fixes/keeps) taken when a re-transcription is
            // queued, re-applied onto the new utterances — user work survives re-transcribing.
            try RetranscribeCarryover.migrate(db)
            self.logger.info("[GRDBDatabaseManager] Migration v26_retranscribe_carryover completed")
        }

        migrator.registerMigration("v27_identity_llm_verdicts") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v27_identity_llm_verdicts")
            // LLM transcript-evidence verdicts on speaker-identity suggestions (confirm /
            // contradict / who the AI actually heard), keyed per (voice, suggested name).
            try IdentityLLMVerdictStore.migrate(db)
            self.logger.info("[GRDBDatabaseManager] Migration v27_identity_llm_verdicts completed")
        }

        migrator.registerMigration("v28_speaker_pipeline_provenance") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v28_speaker_pipeline_provenance")
            try SpeakerPipelineProvenanceStore.migrate(db)
            self.logger.info("[GRDBDatabaseManager] Migration v28_speaker_pipeline_provenance completed")
        }

        migrator.registerMigration("v29_speaker_profile_split_history") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v29_speaker_profile_split_history")
            try SpeakerProfileSplitter.migrate(db)
            self.logger.info("[GRDBDatabaseManager] Migration v29_speaker_profile_split_history completed")
        }

        migrator.registerMigration("v30_recording_voice_prototypes") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v30_recording_voice_prototypes")
            // Backfill one normalized prototype per local voice cluster per recording. The global
            // matcher can now adapt to room acoustics and microphones without letting a long call
            // outweigh every other observation.
            try SpeakerVoicePrototypeStore.migrate(db)
            self.logger.info("[GRDBDatabaseManager] Migration v30_recording_voice_prototypes completed")
        }

        migrator.registerMigration("v31_reversible_global_speaker_identity") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v31_reversible_global_speaker_identity")
            try GlobalSpeakerIdentityStore.migrate(db)
            self.logger.info("[GRDBDatabaseManager] Migration v31_reversible_global_speaker_identity completed")
        }

        migrator.registerMigration("v32_speaker_pair_gold") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v32_speaker_pair_gold")
            try SpeakerPairGoldStore.migrate(db)
            self.logger.info("[GRDBDatabaseManager] Migration v32_speaker_pair_gold completed")
        }

        migrator.registerMigration("v33_speaker_local_cluster_gold") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v33_speaker_local_cluster_gold")
            try SpeakerPairGoldStore.migrate(db)
            self.logger.info("[GRDBDatabaseManager] Migration v33_speaker_local_cluster_gold completed")
        }

        migrator.registerMigration("v34_overlap_aware_speaker_evidence") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v34_overlap_aware_speaker_evidence")
            let columns = Set(try db.columns(in: "utterances").map(\.name))
            if !columns.contains("speaker_overlap_ratio") {
                try db.alter(table: "utterances") {
                    $0.add(column: "speaker_overlap_ratio", .double)
                        .notNull().defaults(to: 0)
                }
            }
            if !columns.contains("active_speaker_count") {
                try db.alter(table: "utterances") {
                    $0.add(column: "active_speaker_count", .integer)
                        .notNull().defaults(to: 1)
                }
            }
            if !columns.contains("overlapping_speaker_labels_json") {
                try db.alter(table: "utterances") {
                    $0.add(column: "overlapping_speaker_labels_json", .text)
                }
            }
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_utterances_speaker_overlap
                ON utterances(speaker_overlap_ratio)
                WHERE speaker_overlap_ratio > 0
            """)
            // Existing human mixed-cluster labels become active safeguards immediately on upgrade.
            // Recompute only affected global centroids, then rebuild recording-level prototype
            // history with mixed/overlap evidence excluded.
            if try db.tableExists("speaker_local_cluster_gold_labels"),
               try db.tableExists("speaker_global_assignments") {
                let affectedUUIDs = try String.fetchAll(
                    db,
                    sql: """
                        SELECT DISTINCT a.speaker_uuid
                        FROM speaker_global_assignments a
                        JOIN speaker_local_cluster_gold_labels mixed
                          ON mixed.local_cluster_id = a.local_cluster_id
                        WHERE mixed.verdict = 'multiple_speakers'
                    """
                )
                for uuid in affectedUUIDs {
                    try GlobalSpeakerIdentityStore.refreshProfile(db, uuid: uuid)
                }
            }
            try SpeakerVoicePrototypeStore.rebuildAll(
                db,
                policy: .qualityDurationWeighted
            )
            self.logger.info("[GRDBDatabaseManager] Migration v34_overlap_aware_speaker_evidence completed")
        }

        migrator.registerMigration("v35_mcp_library_api") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v35_mcp_library_api")

            let recordingColumns = Set(try db.columns(in: "recordings").map(\.name))
            if !recordingColumns.contains("external_id") {
                try db.alter(table: "recordings") { $0.add(column: "external_id", .text) }
            }
            if !recordingColumns.contains("updated_at") {
                try db.alter(table: "recordings") {
                    $0.add(column: "updated_at", .datetime).notNull().defaults(to: Date())
                }
            }
            for id in try Int64.fetchAll(
                db,
                sql: "SELECT id FROM recordings WHERE external_id IS NULL OR external_id = ''"
            ) {
                try db.execute(
                    sql: "UPDATE recordings SET external_id = ?, updated_at = COALESCE(updated_at, created_at) WHERE id = ?",
                    arguments: ["rec_\(UUID().uuidString.lowercased())", id]
                )
            }
            try db.create(
                index: "idx_recordings_external_id",
                on: "recordings",
                columns: ["external_id"],
                unique: true,
                ifNotExists: true
            )

            let tagColumns = Set(try db.columns(in: "tags").map(\.name))
            if !tagColumns.contains("external_id") {
                try db.alter(table: "tags") { $0.add(column: "external_id", .text) }
            }
            if !tagColumns.contains("updated_at") {
                try db.alter(table: "tags") {
                    $0.add(column: "updated_at", .datetime).notNull().defaults(to: Date())
                }
            }
            for id in try Int64.fetchAll(
                db,
                sql: "SELECT id FROM tags WHERE external_id IS NULL OR external_id = ''"
            ) {
                try db.execute(
                    sql: "UPDATE tags SET external_id = ?, updated_at = COALESCE(updated_at, created_at) WHERE id = ?",
                    arguments: ["tag_\(UUID().uuidString.lowercased())", id]
                )
            }
            try db.create(
                index: "idx_tags_external_id",
                on: "tags",
                columns: ["external_id"],
                unique: true,
                ifNotExists: true
            )

            try db.create(table: "recording_comments", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("recording_id", .integer).notNull()
                    .references("recordings", onDelete: .cascade)
                t.column("body", .text).notNull()
                t.column("anchor_start", .double)
                t.column("anchor_end", .double)
                t.column("source_utterance_id", .integer)
                    .references("utterances", onDelete: .setNull)
                t.column("status", .text).notNull().defaults(to: "open")
                t.column("created_by", .text).notNull()
                t.column("idempotency_key", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("resolved_at", .datetime)
            }
            try db.create(
                index: "idx_recording_comments_recording",
                on: "recording_comments",
                columns: ["recording_id", "created_at"],
                ifNotExists: true
            )
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_recording_comments_idempotency
                ON recording_comments(created_by, idempotency_key)
                WHERE idempotency_key IS NOT NULL
            """)

            try db.create(table: "mcp_audit_log", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("method", .text).notNull()
                t.column("target_external_id", .text)
                t.column("success", .boolean).notNull()
                t.column("error_code", .text)
                t.column("response_bytes", .integer)
                t.column("created_at", .datetime).notNull()
            }
            try db.create(
                index: "idx_mcp_audit_log_created",
                on: "mcp_audit_log",
                columns: ["created_at"],
                ifNotExists: true
            )
            self.logger.info("[GRDBDatabaseManager] Migration v35_mcp_library_api completed")
        }

        migrator.registerMigration("v36_mcp_search_contract") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v36_mcp_search_contract")

            let auditColumns = Set(try db.columns(in: "mcp_audit_log").map(\.name))
            if !auditColumns.contains("client_id") {
                try db.alter(table: "mcp_audit_log") {
                    $0.add(column: "client_id", .text).notNull().defaults(to: "legacy")
                }
            }

            try MCPFTSIndex.install(in: db)

            self.logger.info("[GRDBDatabaseManager] Migration v36_mcp_search_contract completed")
        }

        migrator.registerMigration("v37_mcp_audit_metrics") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v37_mcp_audit_metrics")
            let columns = Set(try db.columns(in: "mcp_audit_log").map(\.name))
            if !columns.contains("duration_ms") {
                try db.alter(table: "mcp_audit_log") {
                    $0.add(column: "duration_ms", .integer).notNull().defaults(to: 0)
                }
            }
            try db.create(
                index: "idx_mcp_audit_log_client_created",
                on: "mcp_audit_log",
                columns: ["client_id", "created_at"],
                ifNotExists: true
            )
            self.logger.info("[GRDBDatabaseManager] Migration v37_mcp_audit_metrics completed")
        }

        migrator.registerMigration("v38_stable_external_id_invariants") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v38_stable_external_id_invariants")
            for id in try Int64.fetchAll(
                db,
                sql: "SELECT id FROM recordings WHERE external_id IS NULL OR TRIM(external_id) = ''"
            ) {
                try db.execute(
                    sql: "UPDATE recordings SET external_id = ? WHERE id = ?",
                    arguments: ["rec_\(UUID().uuidString.lowercased())", id]
                )
            }
            for id in try Int64.fetchAll(
                db,
                sql: "SELECT id FROM tags WHERE external_id IS NULL OR TRIM(external_id) = ''"
            ) {
                try db.execute(
                    sql: "UPDATE tags SET external_id = ? WHERE id = ?",
                    arguments: ["tag_\(UUID().uuidString.lowercased())", id]
                )
            }
            for trigger in [
                "mcp_recording_external_id_insert",
                "mcp_recording_external_id_update",
                "mcp_tag_external_id_insert",
                "mcp_tag_external_id_update"
            ] {
                try db.execute(sql: "DROP TRIGGER IF EXISTS \(trigger)")
            }
            try db.execute(sql: """
                CREATE TRIGGER mcp_recording_external_id_insert
                BEFORE INSERT ON recordings
                WHEN NEW.external_id IS NULL OR TRIM(NEW.external_id) = ''
                BEGIN
                    SELECT RAISE(ABORT, 'recordings.external_id is required');
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER mcp_recording_external_id_update
                BEFORE UPDATE OF external_id ON recordings
                WHEN NEW.external_id IS NULL OR TRIM(NEW.external_id) = ''
                BEGIN
                    SELECT RAISE(ABORT, 'recordings.external_id is required');
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER mcp_tag_external_id_insert
                BEFORE INSERT ON tags
                WHEN NEW.external_id IS NULL OR TRIM(NEW.external_id) = ''
                BEGIN
                    SELECT RAISE(ABORT, 'tags.external_id is required');
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER mcp_tag_external_id_update
                BEFORE UPDATE OF external_id ON tags
                WHEN NEW.external_id IS NULL OR TRIM(NEW.external_id) = ''
                BEGIN
                    SELECT RAISE(ABORT, 'tags.external_id is required');
                END
            """)
            self.logger.info("[GRDBDatabaseManager] Migration v38_stable_external_id_invariants completed")
        }

        migrator.registerMigration("v39_durable_retranscription_target") { db in
            self.logger.info("[GRDBDatabaseManager] Running migration v39_durable_retranscription_target")
            let columns = Set(try db.columns(in: "transcription_queue").map(\.name))
            if !columns.contains("existing_recording_id") {
                try db.alter(table: "transcription_queue") {
                    $0.add(column: "existing_recording_id", .integer)
                        .references("recordings", onDelete: .cascade)
                }
            }
            try db.create(
                index: "idx_transcription_queue_existing_recording",
                on: "transcription_queue",
                columns: ["existing_recording_id"],
                ifNotExists: true
            )
            self.logger.info("[GRDBDatabaseManager] Migration v39_durable_retranscription_target completed")
        }

        // Run migrations
        logger.info("[GRDBDatabaseManager] Starting database migrations...")
        isMigrating = true
        defer { isMigrating = false }
        
        try migrator.migrate(dbQueue)
        logger.info("[GRDBDatabaseManager] Database migrations completed")
        
        // Validate vectorlite is working after migrations
        try validateVectorlite()

        // Rebuild the in-memory vector index from durable storage (vectorlite does not
        // persist its HNSW index) and make has_embedding reflect what is actually stored.
        try hydrateVectorIndex()

        // Log database statistics
        do {
            let tableCount = try dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table'") ?? 0
            }
            let indexCount = try dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='index'") ?? 0
            }
            logger.debug("[GRDBDatabaseManager] Database schema | tables=\(tableCount) indexes=\(indexCount)")
        } catch {
            logger.warning("[GRDBDatabaseManager] Could not fetch schema statistics")
        }
    }
    
    // MARK: - Vector Index Hydration

    /// Rebuild the in-memory vectorlite index from the durable `utterance_embeddings`
    /// table and reconcile `has_embedding` flags with what is actually persisted.
    /// Runs on every launch because vectorlite's HNSW index is not saved to disk.
    private func hydrateVectorIndex() throws {
        try dbQueue.write { db in
            guard try db.tableExists("utterance_embeddings") else {
                self.logger.warning("[GRDBDatabaseManager] utterance_embeddings table missing - skipping hydration")
                return
            }

            let restored = try EmbeddingPersistence.hydrateIndex(db)
            // has_embedding must mirror durable presence (see reconcileFlags doc).
            let (embedded, total) = try EmbeddingPersistence.reconcileFlags(db)
            self.logger.info("[GRDBDatabaseManager] Vector index hydrated | restored=\(restored) embedded=\(embedded)/\(total)")
        }
    }

    // MARK: - Helper Methods

    private static func getVectorlitePath() -> String {
        // Try multiple paths in order of preference
        let bundlePath = Bundle.main.bundlePath
        let paths = [
            // Production: App bundle
            "\(bundlePath)/Contents/Resources/Libraries/vectorlite.dylib",
            // Development: Build directory
            "./build/Build/Products/Debug/Contents/Resources/Libraries/vectorlite.dylib",
            // Source: Direct project path  
            "./AlmRecorder/Resources/Libraries/vectorlite.dylib",
            // Development: repo-relative path (resolved via DevPaths)
            "\(DevPaths.resourcesLibraries)/vectorlite.dylib"
        ]
        
        for path in paths {
            let expandedPath = NSString(string: path).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expandedPath) {
                VoxtralLogger.shared.info("[GRDBDatabaseManager] Found vectorlite at: \(expandedPath)")
                return expandedPath
            }
        }
        
        // Fatal error - vectorlite is required for proper vector search
        let errorMsg = """
            FATAL: Vectorlite library not found. Vector search is required.
            Searched paths:
            \(paths.joined(separator: "\n"))
            """
        VoxtralLogger.shared.error("[GRDBDatabaseManager] \(errorMsg)")
        fatalError(errorMsg)
    }
    
    /// Validate vectorlite is properly loaded and working
    func validateVectorlite() throws {
        // Vectorlite is required - validate it's working properly
        try dbQueue.write { db in
            // Check if utterance_vectors table exists
            let tableCount = try Int.fetchOne(db, 
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='utterance_vectors'") ?? 0
            
            if tableCount == 0 {
                // This should never happen since we create the table during initialization
                logger.error("[GRDBDatabaseManager] FATAL: utterance_vectors table not found")
                fatalError("utterance_vectors table not found - vectorlite initialization failed")
            }
            
            // Test vector operations with a simple query
            do {
                // Create a test vector as blob (float32 array)
                let testVector = Array(repeating: Float(0.1), count: 1024)
                let vectorData = testVector.withUnsafeBytes { Data($0) }
                
                // Test KNN search (should not fail even if no results)
                _ = try Row.fetchAll(db, sql: """
                    SELECT rowid, distance
                    FROM utterance_vectors
                    WHERE knn_search(embedding, knn_param(?, 1))
                    LIMIT 1
                """, arguments: [vectorData])
                
                logger.info("[GRDBDatabaseManager] Vectorlite validation successful - HNSW index operational")
            } catch {
                logger.error("[GRDBDatabaseManager] FATAL: Vectorlite HNSW search failed: \(error)")
                print("[DEBUG] Vectorlite KNN search error: \(error)")
                fatalError("Vectorlite HNSW search failed - semantic search is required for this app")
            }
        }
    }
    
    /// Check if vectorlite is available (for backward compatibility)
    func isVectorliteAvailable() -> Bool {
        do {
            try validateVectorlite()
            return true
        } catch {
            logger.error("[GRDBDatabaseManager] Vectorlite not available: \(error)")
            return false
        }
    }
    
    /// Get database queue for direct access
    func getDatabaseQueue() -> DatabaseQueue {
        return dbQueue
    }
    
    /// Execute in a read transaction
    func read<T>(_ block: (Database) throws -> T) throws -> T {
        let startTime = Date()
        defer {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > 0.1 {
                logger.warning("[GRDBDatabaseManager] Slow read transaction | time=\(String(format: "%.3f", elapsed))s")
            }
        }
        return try dbQueue.read(block)
    }
    
    /// Execute in a write transaction
    func write<T>(_ block: (Database) throws -> T) throws -> T {
        let startTime = Date()
        defer {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > 0.1 {
                logger.warning("[GRDBDatabaseManager] Slow write transaction | time=\(String(format: "%.3f", elapsed))s")
            }
            logger.debug("[GRDBDatabaseManager] Write transaction completed | time=\(String(format: "%.3f", elapsed))s")
        }
        return try dbQueue.write(block)
    }
    
    /// Execute in a transaction
    func inTransaction<T>(_ block: (Database) throws -> T) throws -> T {
        let startTime = Date()
        defer {
            let elapsed = Date().timeIntervalSince(startTime)
            logger.debug("[GRDBDatabaseManager] Transaction completed | time=\(String(format: "%.3f", elapsed))s")
        }
        
        var result: T!
        try dbQueue.writeWithoutTransaction { db in
            try db.inTransaction(.immediate) {
                result = try block(db)
                return .commit
            }
        }
        return result
    }
    
    // MARK: - Performance Monitoring
    
    /// Get database statistics
    func getDatabaseStatistics() -> DatabaseStatistics {
        var stats = DatabaseStatistics()
        
        do {
            try dbQueue.read { db in
                // Get table sizes
                let tables = ["recordings", "utterances"]
                for table in tables {
                    if let count = try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") {
                        stats.tableCounts[table] = count
                        logger.debug("[GRDBDatabaseManager] Table count | table=\(table) count=\(count)")
                    }
                }
                // Vectorlite virtual table doesn't support COUNT(*) — use utterances.has_embedding
                if let count = try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM utterances WHERE has_embedding = 1") {
                    stats.tableCounts["utterance_vectors"] = count
                }
                
                // Get database file size
                if let fileSize = try? FileManager.default.attributesOfItem(atPath: dbPath)[.size] as? Int {
                    stats.fileSizeBytes = fileSize
                    let sizeMB = Double(fileSize) / (1024 * 1024)
                    logger.debug("[GRDBDatabaseManager] Database file size | bytes=\(fileSize) MB=\(String(format: "%.2f", sizeMB))")
                }
                
                // Get page statistics
                if let pageCount = try? Int.fetchOne(db, sql: "PRAGMA page_count") {
                    stats.pageCount = pageCount
                }
                if let pageSize = try? Int.fetchOne(db, sql: "PRAGMA page_size") {
                    stats.pageSize = pageSize
                }
                
                // Get cache statistics
                if let cacheSize = try? Int.fetchOne(db, sql: "PRAGMA cache_size") {
                    stats.cacheSize = cacheSize
                }
            }
            
            // Add query statistics
            stats.totalQueries = queryCount
            stats.totalQueryTime = totalQueryTime
            stats.averageQueryTime = queryCount > 0 ? totalQueryTime / Double(queryCount) : 0
            
        } catch {
            logger.error("[GRDBDatabaseManager] Failed to get database statistics | error=\(error)")
        }
        
        return stats
    }
    
    /// Log performance summary
    func logPerformanceSummary() {
        let stats = getDatabaseStatistics()
        
        logger.info("[GRDBDatabaseManager] === Performance Summary ===")
        logger.info("[GRDBDatabaseManager] Total queries: \(stats.totalQueries)")
        logger.info("[GRDBDatabaseManager] Total query time: \(String(format: "%.3f", stats.totalQueryTime))s")
        logger.info("[GRDBDatabaseManager] Average query time: \(String(format: "%.4f", stats.averageQueryTime))s")
        
        for (table, count) in stats.tableCounts {
            logger.info("[GRDBDatabaseManager] Table '\(table)': \(count) rows")
        }
        
        if let fileSize = stats.fileSizeBytes {
            let sizeMB = Double(fileSize) / (1024 * 1024)
            logger.info("[GRDBDatabaseManager] Database size: \(String(format: "%.2f", sizeMB)) MB")
        }
        
        logger.info("[GRDBDatabaseManager] === End Summary ===")
    }
    
    /// Reset performance counters
    func resetPerformanceCounters() {
        queryCount = 0
        totalQueryTime = 0
        logger.debug("[GRDBDatabaseManager] Performance counters reset")
    }
    
    /// Vacuum database to reclaim space
    func vacuum() throws {
        let startTime = Date()
        logger.info("[GRDBDatabaseManager] Starting database vacuum...")
        
        try dbQueue.write { db in
            try db.execute(sql: "VACUUM")
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        logger.info("[GRDBDatabaseManager] Database vacuum completed | time=\(String(format: "%.2f", elapsed))s")
    }
    
    // MARK: - Database Cleanup and Reset
    
    /// Completely reset the database - removes all data and recreates schema
    /// This method drops tables in correct dependency order to avoid foreign key issues
    func resetDatabase() throws {
        logger.warning("[GRDBDatabaseManager] ⚠️ Starting complete database reset...")
        
        try dbQueue.write { db in
            // Temporarily disable foreign keys for cleanup
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            
            defer {
                // Re-enable foreign keys
                try? db.execute(sql: "PRAGMA foreign_keys = ON")
            }
            
            // Define table drop order (child tables before parent tables)
            let tablesToDrop = [
                // Embedding tables first (they reference utterances)
                "utterance_vectors",
                
                // Speaker-related tables
                "speakers",
                
                // Utterances (references recordings)
                "utterances",
                
                // Transcription history
                "transcription_history",
                
                // Queue tables
                "embedding_queue",
                
                // Settings tables
                "voice_memo_processed",
                "voice_memo_settings",
                "app_settings",

                // Speaker-attendee mappings
                "speaker_attendee_mappings",

                // Meeting tables (reference recordings)
                "recording_meetings",
                "meetings",

                // Finally the parent table
                "recordings"
            ]
            
            // Drop tables in specified order
            for table in tablesToDrop {
                // Check if table exists before dropping
                let tableExists = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM sqlite_master 
                    WHERE type='table' AND name=?
                """, arguments: [table]) ?? 0 > 0
                
                if tableExists {
                    logger.info("[GRDBDatabaseManager] Dropping table: \(table)")
                    // Use SQL interpolation safely
                    try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
                }
            }
            
            // Drop any remaining tables not in our list
            let remainingTables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master 
                WHERE type='table' 
                AND name NOT LIKE 'sqlite_%'
                AND name NOT LIKE 'grdb_%'
            """)
            
            for table in remainingTables {
                logger.info("[GRDBDatabaseManager] Dropping remaining table: \(table)")
                try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
            }
            
            // Drop all indexes
            let indexes = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master 
                WHERE type='index' 
                AND name NOT LIKE 'sqlite_%'
            """)
            
            for index in indexes {
                try db.execute(sql: "DROP INDEX IF EXISTS \(index)")
            }
            
            // Vacuum to reclaim space
            try db.execute(sql: "VACUUM")
        }
        
        logger.info("[GRDBDatabaseManager] Database reset complete. Re-running migrations...")
        
        // Re-run migrations to recreate schema
        try migrate()
        
        logger.info("[GRDBDatabaseManager] ✅ Database has been completely reset")
    }
    
    /// Stop all services that might be using the database
    private func stopAllServices() async {
        logger.info("[GRDBDatabaseManager] Stopping all services...")
        
        // Stop transcription and embedding queues
        await TranscriptionQueueManager.shared.clearQueue()
        EmbeddingQueueManager.shared.clearQueue()
        
        // Stop Voice Memos monitoring
        await VoiceMemosMonitorService.shared.stopMonitoring()
        
        // Stop any background tasks
        NotificationCenter.default.post(name: NSNotification.Name("StopAllBackgroundTasks"), object: nil)
        
        // Give time for services to stop
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        logger.info("[GRDBDatabaseManager] All services stopped")
    }
    
    /// Restart services after database recreation
    private func restartServices() async {
        logger.info("[GRDBDatabaseManager] Restarting services...")
        
        // Services will restart themselves when accessed
        // But we can trigger initialization of critical ones
        
        // Post notification for services to restart
        NotificationCenter.default.post(name: NSNotification.Name("DatabaseRecreated"), object: nil)
        
        logger.info("[GRDBDatabaseManager] Services restart initiated")
    }
    
    /// Perform a complete database wipe by properly closing, deleting, and recreating the database
    /// This uses GRDB's built-in close() method for safe connection termination
    func performCompleteWipe() async throws {
        logger.warning("[GRDBDatabaseManager] ⚠️ Starting complete database file wipe...")
        
        // Step 1: Stop all active operations
        await stopAllServices()
        
        // Step 2: Properly close database connection using GRDB's close() method
        logger.info("[GRDBDatabaseManager] Closing database connection...")
        
        do {
            try dbQueue.close()
            logger.info("[GRDBDatabaseManager] Database connection closed successfully")
        } catch {
            logger.error("[GRDBDatabaseManager] Error closing database: \(error)")
            // Continue anyway - we'll delete the file
        }
        
        // Step 3: Delete the database file and related files
        logger.info("[GRDBDatabaseManager] Deleting database files...")
        
        let filesToDelete = [
            dbPath,
            dbPath + "-wal",
            dbPath + "-shm",
            dbPath + "-journal"
        ]
        
        for file in filesToDelete {
            if FileManager.default.fileExists(atPath: file) {
                do {
                    try FileManager.default.removeItem(atPath: file)
                    logger.info("[GRDBDatabaseManager] Deleted: \(file)")
                } catch {
                    logger.error("[GRDBDatabaseManager] Failed to delete \(file): \(error)")
                }
            }
        }
        
        // Step 4: Create a fresh database with proper configuration
        logger.info("[GRDBDatabaseManager] Creating fresh database...")
        
        var config = Configuration()
        config.prepareDatabase { db in
            // Enable foreign keys
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            // Enable WAL mode for better concurrency
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            // Set synchronous to NORMAL for better performance with safety
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            // Set cache size
            try db.execute(sql: "PRAGMA cache_size = -2000") // 2MB cache
            
            // Try to load vectorlite extension if available
            let vectorlitePath = Self.getVectorlitePath()
            if FileManager.default.fileExists(atPath: vectorlitePath) {
                do {
                    try db.execute(sql: "SELECT load_extension(?)", arguments: [vectorlitePath])
                    VoxtralLogger.shared.info("[GRDBDatabaseManager] Loaded vectorlite extension")
                } catch {
                    VoxtralLogger.shared.warning("[GRDBDatabaseManager] Failed to load vectorlite | error=\(error)")
                }
            }
        }
        
        // Create new database queue
        dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
        logger.info("[GRDBDatabaseManager] New database queue created")
        
        // Step 5: Run migrations to create schema
        logger.info("[GRDBDatabaseManager] Running migrations...")
        try migrate()
        
        // Step 6: Verify database is working
        do {
            let tableCount = try await dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table'")
            }
            logger.info("[GRDBDatabaseManager] Database verified: \(tableCount ?? 0) tables created")
        } catch {
            logger.warning("[GRDBDatabaseManager] Could not verify database: \(error)")
        }
        
        // Step 7: Restart services
        await restartServices()
        
        logger.info("[GRDBDatabaseManager] ✅ Complete database wipe successful")
    }
    
    /// Clear all data from tables without dropping schema
    func clearAllData() throws {
        logger.warning("[GRDBDatabaseManager] Clearing all data from database...")
        
        try dbQueue.write { db in
            // Temporarily disable foreign keys
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            
            defer {
                // Re-enable foreign keys
                try? db.execute(sql: "PRAGMA foreign_keys = ON")
            }
            
            // Get all table names except system tables
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master 
                WHERE type='table' 
                AND name NOT LIKE 'sqlite_%'
                AND name NOT LIKE 'grdb_%'
            """)
            
            // Clear all data from each table using DELETE (SQLite doesn't have TRUNCATE)
            // Order matters to respect foreign key constraints even when disabled
            let orderedTables = [
                // Clear child tables first
                "utterance_vectors",
                "speakers",
                "utterances",
                "transcription_history",
                "embedding_queue",
                "voice_memo_processed",
                "voice_memo_settings",
                "app_settings",
                "speaker_attendee_mappings",
                "recording_meetings",
                "meetings",
                "recordings"
            ]

            // Delete from known tables in order
            for table in orderedTables {
                if tables.contains(table) {
                    let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
                    if count > 0 {
                        logger.info("[GRDBDatabaseManager] Clearing \(count) rows from table: \(table)")
                        try db.execute(sql: "DELETE FROM \(table)")
                    }
                }
            }
            
            // Delete from any remaining tables not in our list
            for table in tables where !orderedTables.contains(table) {
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
                if count > 0 {
                    logger.info("[GRDBDatabaseManager] Clearing \(count) rows from additional table: \(table)")
                    try db.execute(sql: "DELETE FROM \(table)")
                }
            }
            
            // Reset autoincrement sequences
            try db.execute(sql: "DELETE FROM sqlite_sequence")
        }
        
        logger.info("[GRDBDatabaseManager] ✅ All data cleared from database")
    }
    
    /// Clear specific tables
    func clearTables(_ tableNames: [String]) throws {
        logger.info("[GRDBDatabaseManager] Clearing tables: \(tableNames.joined(separator: ", "))")
        
        try dbQueue.write { db in
            for table in tableNames {
                // Check if table exists
                let exists = try Bool.fetchOne(db, sql: """
                    SELECT COUNT(*) > 0 FROM sqlite_master 
                    WHERE type='table' AND name=?
                """, arguments: [table]) ?? false
                
                if exists {
                    let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
                    try db.execute(sql: "DELETE FROM \(table)")
                    logger.info("[GRDBDatabaseManager] Cleared \(count) rows from table: \(table)")
                } else {
                    logger.warning("[GRDBDatabaseManager] Table not found: \(table)")
                }
            }
        }
    }
    
    /// Get database file path
    func getDatabasePath() -> String {
        return dbPath
    }
    
    /// Public property for database path
    var databasePath: String {
        return dbPath
    }
    
    /// Comprehensive clear of all data including cache, temp files, and database
    func clearAllDataComprehensive() async throws {
        logger.warning("[GRDBDatabaseManager] ⚠️ Starting comprehensive data clear...")
        
        // Save critical settings before clearing
        let settingsRepo = GRDBSettingsRepository.shared
        let keysToPreserve = [
            "selectedWhisperModel",
            "selectedWhisperVariant", 
            "selectedVoxtralTranscriptionModel",
            "selectedSummaryModel",
            "selectedEmbeddingModel",
            "transcriptionBackend"
        ]
        
        // Store settings to preserve
        var preservedSettings: [String: String] = [:]
        for key in keysToPreserve {
            if let value = settingsRepo.getString(forKey: key) {
                preservedSettings[key] = value
            }
        }
        
        // 1. Clear WAV cache
        logger.info("[GRDBDatabaseManager] Clearing WAV cache...")
        WAVCacheManager.shared.clearCache()
        
        // 2. Clear temporary files
        logger.info("[GRDBDatabaseManager] Clearing temporary files...")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("AlmRecorder")
        if FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        // 3. Clear exported files in Documents
        logger.info("[GRDBDatabaseManager] Clearing exported files...")
        if let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let exportDir = documentsDir.appendingPathComponent("AlmRecorder")
            if FileManager.default.fileExists(atPath: exportDir.path) {
                try? FileManager.default.removeItem(at: exportDir)
            }
        }
        
        // 4. Perform complete database wipe using the robust file-based approach
        logger.info("[GRDBDatabaseManager] Performing complete database wipe...")
        try await performCompleteWipe()
        
        // 5. Restore preserved settings
        logger.info("[GRDBDatabaseManager] Restoring preserved settings...")
        for (key, value) in preservedSettings {
            settingsRepo.setString(value, forKey: key)
        }
        
        // 6. Notify that data clear is complete
        logger.info("[GRDBDatabaseManager] ✅ Comprehensive data clear complete")
    }
    
    /// Analyze database for query optimization
    func analyze() throws {
        let startTime = Date()
        logger.info("[GRDBDatabaseManager] Starting database analyze...")
        
        try dbQueue.write { db in
            try db.execute(sql: "ANALYZE")
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        logger.info("[GRDBDatabaseManager] Database analyze completed | time=\(String(format: "%.2f", elapsed))s")
    }
}

// MARK: - Database Statistics

struct DatabaseStatistics {
    var tableCounts: [String: Int] = [:]
    var fileSizeBytes: Int?
    var pageCount: Int?
    var pageSize: Int?
    var cacheSize: Int?
    var totalQueries: Int = 0
    var totalQueryTime: TimeInterval = 0
    var averageQueryTime: TimeInterval = 0
}

// MARK: - Queue Operations for TranscriptionQueueManager

extension GRDBDatabaseManager {
    func readQueue<T>(_ block: @escaping (Database) throws -> T) throws -> T {
        try dbQueue.read(block)
    }
    
    func writeQueue<T>(_ block: @escaping (Database) throws -> T) throws -> T {
        try dbQueue.write(block)
    }
    
    @discardableResult
    func writeQueueWithoutTransaction<T>(_ block: @escaping (Database) throws -> T) throws -> T {
        try dbQueue.writeWithoutTransaction(block)
    }
}
