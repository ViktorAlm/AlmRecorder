import Foundation
import GRDB

/// Service for migrating existing transcriptions to the database
class MigrationService {
    
    private let unifiedManager = UnifiedTranscriptionManager.shared
    private let recordingRepo = GRDBRecordingRepository()
    private let utteranceProcessor = UtteranceProcessor()

    /// One-time: relocate recordings that still live in the old `~/Documents` location into the
    /// managed Recordings directory under Application Support, rewriting their stored DB paths.
    /// Older builds wrote `recording_*.m4a` straight into Documents; newer builds use
    /// `AudioRecorder.recordingsDirectory`. Existing rows hold absolute paths, so this moves the
    /// files and updates those paths. Idempotent: guarded by a flag and per-file existence checks.
    func migrateRecordingsToAppSupportIfNeeded() {
        let flagKey = "didMigrateRecordingsToAppSupport_v1"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        let fm = FileManager.default
        let documentsDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL.path
        let destDir = AudioRecorder.recordingsDirectory   // creates the directory

        var moved = 0
        var relinked = 0
        do {
            let recordings = try recordingRepo.getAll(limit: 1_000_000)
            for rec in recordings {
                guard let id = rec.id, let path = rec.filePath else { continue }
                // Only touch recordings still pointing into the old Documents directory.
                guard path.hasPrefix(documentsDir + "/") else { continue }
                guard fm.fileExists(atPath: path) else { continue }
                let dest = destDir.appendingPathComponent((path as NSString).lastPathComponent)
                if fm.fileExists(atPath: dest.path) {
                    // Already present at the destination — just repoint the DB row.
                    try? recordingRepo.updateFilePath(id: id, newPath: dest.path)
                    relinked += 1
                } else {
                    do {
                        try fm.moveItem(atPath: path, toPath: dest.path)
                        try recordingRepo.updateFilePath(id: id, newPath: dest.path)
                        moved += 1
                    } catch {
                        print("[MigrationService] Could not relocate \(path): \(error)")
                    }
                }
            }
        } catch {
            print("[MigrationService] Recordings relocation skipped (query failed): \(error)")
            return   // don't set the flag; retry on next launch
        }

        UserDefaults.standard.set(true, forKey: flagKey)
        if moved > 0 || relinked > 0 {
            print("[MigrationService] Relocated recordings to Application Support: moved \(moved), relinked \(relinked)")
        }
    }

    /// Migrate existing transcription history to database
    func migrateExistingTranscriptions() async throws -> (migrated: Int, failed: Int) {
        print("[MigrationService] Starting migration of existing transcriptions")
        
        // Load existing transcriptions from UserDefaults
        let existingTranscriptions = unifiedManager.loadSavedTranscriptions()
        
        if existingTranscriptions.isEmpty {
            print("[MigrationService] No existing transcriptions found")
            return (0, 0)
        }
        
        print("[MigrationService] Found \(existingTranscriptions.count) transcriptions to migrate")
        
        var migratedCount = 0
        var failedCount = 0
        
        for item in existingTranscriptions {
            do {
                // Check if already migrated (by checking if file path exists in database)
                let existing = try recordingRepo.getByFilePath(item.filePath)
                if existing != nil {
                    print("[MigrationService] Skipping already migrated: \(item.fileName)")
                    continue
                }
                
                // Create recording
                let recording = Recording(
                    id: nil,
                    title: item.fileName,
                    fileName: item.fileName,
                    filePath: item.filePath,
                    duration: item.duration,
                    language: item.language,
                    createdAt: item.createdDate,
                    transcribedAt: item.transcribedDate,
                    source: mapSource(item.source),
                    fullTranscript: item.transcript,
                    metadata: nil
                )
                
                let recordingId = try recordingRepo.create(recording)
                print("[MigrationService] Migrated recording: \(item.fileName) (ID: \(recordingId))")
                
                // Process into utterances if transcript exists
                if !item.transcript.isEmpty {
                    try await utteranceProcessor.processTranscriptionIntoUtterances(
                        recordingId: recordingId,
                        transcript: item.transcript,
                        audioFile: item.filePath,
                        generateEmbeddings: EmbeddingModelManager.shared.isModelLoaded
                    )
                }
                
                migratedCount += 1
                
            } catch {
                print("[MigrationService] Failed to migrate \(item.fileName): \(error)")
                failedCount += 1
            }
        }
        
        print("[MigrationService] Migration complete: \(migratedCount) migrated, \(failedCount) failed")
        return (migratedCount, failedCount)
    }
    
    /// Process all recordings without utterances
    func processUnprocessedRecordings() async throws -> Int {
        print("[MigrationService] Processing recordings without utterances")
        
        let recordings = try recordingRepo.getAll()
        var processedCount = 0
        
        for recording in recordings {
            guard let recordingId = recording.id,
                  let transcript = recording.fullTranscript,
                  !transcript.isEmpty else {
                continue
            }
            
            // Check if utterances already exist
            let utteranceRepo = GRDBUtteranceRepository()
            let existingUtterances = try utteranceRepo.getByRecording(id: recordingId, includeHidden: true)
            if !existingUtterances.isEmpty {
                continue
            }
            
            print("[MigrationService] Processing recording: \(recording.fileName)")
            
            try await utteranceProcessor.processTranscriptionIntoUtterances(
                recordingId: recordingId,
                transcript: transcript,
                audioFile: recording.filePath,
                generateEmbeddings: EmbeddingModelManager.shared.isModelLoaded
            )
            
            processedCount += 1
        }
        
        print("[MigrationService] Processed \(processedCount) recordings")
        return processedCount
    }
    
    /// Generate embeddings for utterances that don't have them
    func generateMissingEmbeddings() async throws -> Int {
        guard EmbeddingModelManager.shared.isModelLoaded else {
            throw MigrationError.noEmbeddingModel
        }
        
        print("[MigrationService] Generating missing embeddings")
        
        let utteranceRepo = GRDBUtteranceRepository()
        let totalUtterances = try utteranceRepo.count()
        let utterancesWithEmbeddings = try utteranceRepo.countWithEmbeddings()
        
        let missing = totalUtterances - utterancesWithEmbeddings
        if missing == 0 {
            print("[MigrationService] All utterances have embeddings")
            return 0
        }
        
        print("[MigrationService] Found \(missing) utterances without embeddings")
        
        // Process would go here - need to add method to UtteranceRepository
        // to get utterances without embeddings
        
        await utteranceProcessor.generateMissingEmbeddings()
        
        return missing
    }
    
    /// Remove stale placeholder speakers from old per-recording backfills.
    /// NULLs out speaker_uuid on utterances pointing to confidence=0.0 speakers,
    /// then deletes those speakers so the corrected global backfill can re-run.
    func cleanupStaleBackfillSpeakers() throws -> Int {
        let db = GRDBDatabaseManager.shared
        // Never touch a placeholder the user has since identified (named or manually mapped) — culling those
        // silently destroyed user work (a named voice vanished on relaunch).
        let keep = GRDBSpeakerRepository.userIdentifiedSpeakerSQL

        return try db.write { database in
            // NULL out speaker_uuid on utterances linked to (un-identified) placeholder speakers
            try database.execute(sql: """
                UPDATE utterances SET speaker_uuid = NULL
                WHERE speaker_uuid IN (
                    SELECT uuid FROM speakers WHERE confidence = 0.0 AND NOT \(keep)
                )
            """)
            let unlinked = database.changesCount

            // Delete (un-identified) placeholder speakers
            try database.execute(sql: "DELETE FROM speakers WHERE confidence = 0.0 AND NOT \(keep)")
            let deleted = database.changesCount

            // Heal any dangling attendee mappings — including pre-existing orphans from before deletions
            // started cleaning up after themselves.
            try database.execute(sql: "DELETE FROM speaker_attendee_mappings WHERE speaker_uuid NOT IN (SELECT uuid FROM speakers)")

            if deleted > 0 || unlinked > 0 {
                print("[MigrationService] Cleaned up \(deleted) stale placeholder speakers, unlinked \(unlinked) utterances")
            }
            return deleted
        }
    }

    /// Backfill speaker_uuid for utterances that have speaker labels but no speaker_uuid.
    /// Creates one speaker record per unique label (shared across recordings) and links them.
    /// Idempotent — safe to re-run.
    func backfillSpeakerUUIDs() async throws -> Int {
        print("[MigrationService] Checking for speaker UUID backfill...")

        let db = GRDBDatabaseManager.shared
        let speakerRepo = GRDBSpeakerRepository()

        // Find all unique speaker labels that need backfill
        let labelsToFix: [String] = try db.read { database in
            let rows = try Row.fetchAll(database, sql: """
                SELECT DISTINCT speaker
                FROM utterances
                WHERE speaker IS NOT NULL
                  AND speaker != ''
                  AND speaker_uuid IS NULL
            """)
            return rows.compactMap { row in
                row["speaker"] as String?
            }
        }

        if labelsToFix.isEmpty {
            return 0
        }

        print("[MigrationService] Found \(labelsToFix.count) unique speaker labels needing backfill")

        // Create one speaker record per unique label, shared across all recordings
        var labelToUUID: [String: String] = [:]
        for label in labelsToFix {
            let uuid = UUID().uuidString
            do {
                let _ = try speakerRepo.create(
                    uuid: uuid,
                    name: nil,
                    embedding: [Float](repeating: 0, count: SpeakerEmbeddingPolicy.dimension),
                    confidence: 0.0
                )
                labelToUUID[label] = uuid
            } catch {
                print("[MigrationService] Failed to create backfill speaker for '\(label)': \(error)")
            }
        }

        // Link all utterances with each label to the shared speaker UUID
        var totalFixed = 0
        try db.write { database in
            for (label, uuid) in labelToUUID {
                try database.execute(
                    sql: """
                        UPDATE utterances
                        SET speaker_uuid = ?
                        WHERE speaker = ? AND speaker_uuid IS NULL
                    """,
                    arguments: [uuid, label]
                )
                totalFixed += database.changesCount
            }
        }

        print("[MigrationService] Backfilled \(totalFixed) utterance links for \(labelToUUID.count) speakers")
        return totalFixed
    }

    private func mapSource(_ source: TranscriptionItem.TranscriptionSource) -> Recording.RecordingSource {
        switch source {
        case .recording:
            return .recording
        case .voiceMemos:
            return .voiceMemos
        case .imported:
            return .imported
        }
    }
}

enum MigrationError: LocalizedError {
    case noEmbeddingModel
    
    var errorDescription: String? {
        switch self {
        case .noEmbeddingModel:
            return "No embedding model loaded. Please download a model first."
        }
    }
}