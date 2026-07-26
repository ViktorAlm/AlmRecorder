import Foundation
import GRDB

/// Repository for managing Recording entities with GRDB
class GRDBRecordingRepository {
    private let logger = VoxtralLogger.shared
    private let db = GRDBDatabaseManager.shared
    
    // MARK: - CRUD Operations
    
    /// Create a new recording
    func create(_ recording: Recording) throws -> Int64 {
        try db.write { db in
            let metadataJSON: String? = recording.metadata.flatMap { metadata in
                guard let data = try? JSONEncoder().encode(metadata) else { return nil }
                return String(data: data, encoding: .utf8)
            }
            
            try db.execute(
                sql: """
                    INSERT INTO recordings (
                        title, file_name, file_path, duration, language,
                        created_at, transcribed_at, source, full_transcript, metadata,
                        external_id, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    recording.title,
                    recording.fileName,
                    recording.filePath,
                    recording.duration,
                    recording.language,
                    recording.createdAt,
                    recording.transcribedAt,
                    recording.source.rawValue,
                    recording.fullTranscript,
                    metadataJSON,
                    recording.externalId ?? "rec_\(UUID().uuidString.lowercased())",
                    recording.updatedAt ?? recording.createdAt
                ]
            )
            
            return db.lastInsertedRowID
        }
    }
    
    /// Get a recording by ID
    func getById(_ id: Int64) throws -> Recording? {
        try db.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM recordings WHERE id = ?",
                arguments: [id]
            )
            
            return row.flatMap { Recording(row: $0) }
        }
    }

    /// Get a recording by file path
    func getByFilePath(_ filePath: String) throws -> Recording? {
        try db.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM recordings WHERE file_path = ?",
                arguments: [filePath]
            )

            return row.flatMap { Recording(row: $0) }
        }
    }

    /// Update only a recording's `file_path` (used by the recordings-location migration).
    func updateFilePath(id: Int64, newPath: String) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE recordings SET file_path = ? WHERE id = ?",
                arguments: [newPath, id]
            )
        }
    }

    func markSpeakerPipeline(
        id: Int64,
        profile: SpeakerPipelineProfile,
        configuration: SpeakerPipelineConfiguration,
        version: Int = 1
    ) throws {
        let data = try JSONEncoder().encode(configuration)
        guard let configurationJSON = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE recordings SET
                        speaker_pipeline_profile = ?,
                        speaker_pipeline_version = ?,
                        speaker_pipeline_config = ?,
                        speaker_review_status = NULL,
                        speaker_reviewed_at = NULL
                    WHERE id = ?
                """,
                arguments: [profile.rawValue, version, configurationJSON, id]
            )
        }
    }

    func setSpeakerReviewStatus(id: Int64, status: RecordingSpeakerReviewStatus?) throws {
        try db.write { db in
            switch status {
            case .gold?: try SpeakerGoldReviewStore.confirmGold(db, recordingId: id)
            case .needsCorrection?: try SpeakerGoldReviewStore.markNeedsCorrection(db, recordingId: id)
            case .inProgress?, .complete?: try SpeakerGoldReviewStore.markInProgress(db, recordingId: id)
            case nil: try SpeakerGoldReviewStore.clear(db, recordingId: id)
            }
        }
    }

    /// Get all recordings
    func getAll(limit: Int = 100) throws -> [Recording] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM recordings
                    ORDER BY created_at DESC
                    LIMIT ?
                """,
                arguments: [limit]
            )

            return rows.compactMap { Recording(row: $0) }
        }
    }

    /// Recordings with no utterances — failed or empty transcriptions ("No transcript available").
    func getRecordingsWithoutTranscript() throws -> [Recording] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM recordings
                    WHERE id NOT IN (
                        SELECT DISTINCT recording_id FROM utterances WHERE recording_id IS NOT NULL
                    )
                    ORDER BY created_at DESC
                """
            )
            return rows.compactMap { Recording(row: $0) }
        }
    }

    /// All recordings whose file name starts with `prefix` — used to pair the two meeting tracks
    /// (meeting_<stamp>_mic / meeting_<stamp>_system) into one merged transcript.
    func getByFileNamePrefix(_ prefix: String) throws -> [Recording] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM recordings WHERE file_name LIKE ? ORDER BY created_at",
                arguments: ["\(prefix)%"]
            )
            return rows.compactMap { Recording(row: $0) }
        }
    }

    /// Get recordings by source
    func getBySource(_ source: Recording.RecordingSource) throws -> [Recording] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM recordings
                    WHERE source = ?
                    ORDER BY created_at DESC
                """,
                arguments: [source.rawValue]
            )

            return rows.compactMap { Recording(row: $0) }
        }
    }
    
    /// Update a recording
    func update(_ recording: Recording) throws {
        try db.write { db in
            try Self.update(db, recording)
        }
    }

    /// Transaction-friendly update used when a re-transcription swaps the recording text and all
    /// utterances in one commit.
    static func update(_ db: Database, _ recording: Recording) throws {
        guard let id = recording.id else {
            throw NSError(domain: "GRDBRecordingRepository", code: 1, userInfo: [NSLocalizedDescriptionKey: "Recording ID is required for update"])
        }

        let metadataJSON: String? = recording.metadata.flatMap { metadata in
            guard let data = try? JSONEncoder().encode(metadata) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        try db.execute(
            sql: """
                UPDATE recordings SET
                    title = ?,
                    file_name = ?,
                    file_path = ?,
                    duration = ?,
                    language = ?,
                    transcribed_at = ?,
                    source = ?,
                    full_transcript = ?,
                    metadata = ?,
                    updated_at = ?
                WHERE id = ?
            """,
            arguments: [
                recording.title,
                recording.fileName,
                recording.filePath,
                recording.duration,
                recording.language,
                recording.transcribedAt,
                recording.source.rawValue,
                recording.fullTranscript,
                metadataJSON,
                Date(),
                id
            ]
        )
    }
    
    /// Delete a recording
    func delete(_ id: Int64) throws {
        try db.write { db in
            // Cascading delete will handle utterances and embeddings
            try db.execute(
                sql: "DELETE FROM recordings WHERE id = ?",
                arguments: [id]
            )
        }
    }
    
    // MARK: - Search Operations
    
    /// Search recordings by title or transcript
    func searchByText(query: String, limit: Int = 20) throws -> [Recording] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM recordings 
                    WHERE title LIKE ? OR full_transcript LIKE ?
                    ORDER BY created_at DESC
                    LIMIT ?
                """,
                arguments: ["%\(query)%", "%\(query)%", limit]
            )
            
            return rows.compactMap { Recording(row: $0) }
        }
    }
    
    /// Get recordings in date range
    func getInDateRange(from startDate: Date, to endDate: Date) throws -> [Recording] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM recordings 
                    WHERE created_at BETWEEN ? AND ?
                    ORDER BY created_at DESC
                """,
                arguments: [startDate, endDate]
            )
            
            return rows.compactMap { Recording(row: $0) }
        }
    }
    
    /// Get recent recordings
    func getRecent(days: Int = 7, limit: Int = 50) throws -> [Recording] {
        let startDate = Date().addingTimeInterval(-Double(days * 24 * 60 * 60))
        
        return try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM recordings 
                    WHERE created_at >= ?
                    ORDER BY created_at DESC
                    LIMIT ?
                """,
                arguments: [startDate, limit]
            )
            
            return rows.compactMap { Recording(row: $0) }
        }
    }
    
    // MARK: - Statistics
    
    /// Get total number of recordings
    func count() throws -> Int {
        try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recordings") ?? 0
        }
    }
    
    /// Get count by source
    func countBySource() throws -> [String: Int] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT source, COUNT(*) as count 
                    FROM recordings 
                    GROUP BY source
                """
            )
            
            var counts: [String: Int] = [:]
            for row in rows {
                let source: String? = row["source"]
                let count: Int? = row["count"]
                if let source, let count {
                    counts[source] = count
                }
            }
            return counts
        }
    }
    
    /// Get total duration of all recordings
    func totalDuration() throws -> TimeInterval {
        try db.read { db in
            try Double.fetchOne(db, sql: "SELECT SUM(duration) FROM recordings WHERE duration IS NOT NULL") ?? 0
        }
    }
    
    /// Check if a recording exists by file name
    func existsByFileName(_ fileName: String) throws -> Bool {
        try db.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM recordings WHERE file_name = ?",
                arguments: [fileName]
            )
            return (count ?? 0) > 0
        }
    }
    
    /// Get all transcribed file names as a Set (efficient for bulk duplicate checking)
    func getTranscribedFileNames() throws -> Set<String> {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT file_name FROM recordings")
            var names = Set<String>()
            for row in rows {
                let name: String? = row["file_name"]
                if let name { names.insert(name) }
            }
            return names
        }
    }

    // MARK: - Dashboard Queries

    /// Get recordings grouped by date period (Today, Yesterday, This Week, This Month, Older)
    func getGroupedByDate() throws -> [(period: String, recordings: [Recording])] {
        let all = try getAll(limit: 500)
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
        let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!

        var groups: [String: [Recording]] = [
            "Today": [], "Yesterday": [], "This Week": [], "This Month": [], "Older": []
        ]

        for recording in all {
            let date = recording.createdAt
            if date >= startOfToday {
                groups["Today"]!.append(recording)
            } else if date >= startOfYesterday {
                groups["Yesterday"]!.append(recording)
            } else if date >= startOfWeek {
                groups["This Week"]!.append(recording)
            } else if date >= startOfMonth {
                groups["This Month"]!.append(recording)
            } else {
                groups["Older"]!.append(recording)
            }
        }

        let order = ["Today", "Yesterday", "This Week", "This Month", "Older"]
        return order.compactMap { period in
            let recordings = groups[period] ?? []
            return recordings.isEmpty ? nil : (period: period, recordings: recordings)
        }
    }

    /// One zero-filled bucket per local calendar day, for the dashboard activity chart.
    struct DailyActivityBucket: Identifiable, Equatable {
        var id: Date { day }
        let day: Date   // startOfDay in the given calendar
        let count: Int
    }

    /// Pure query core (testable against an in-memory DatabaseQueue, mirrors the
    /// SpeakerQueriesTests shape). Buckets Swift-side with `Calendar` like `getGroupedByDate()`.
    static func dailyActivity(_ db: Database, days: Int,
                              now: Date = Date(),
                              calendar: Calendar = .current) throws -> [DailyActivityBucket] {
        guard days > 0,
              let windowStart = calendar.date(byAdding: .day, value: -(days - 1), to: now)
        else { return [] }
        let startDay = calendar.startOfDay(for: windowStart)

        let dates = try Date.fetchAll(
            db,
            sql: "SELECT created_at FROM recordings WHERE created_at >= ?",
            arguments: [startDay]
        )
        var counts: [Date: Int] = [:]
        for date in dates {
            counts[calendar.startOfDay(for: date), default: 0] += 1
        }

        return (0..<days).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDay) else { return nil }
            return DailyActivityBucket(day: day, count: counts[day] ?? 0)
        }
    }

    /// Instance wrapper used by the app.
    func getDailyActivity(days: Int) throws -> [DailyActivityBucket] {
        try db.read { try Self.dailyActivity($0, days: days) }
    }

    /// Get recordings that contain utterances from a specific speaker
    func getRecordingsForSpeaker(speakerUuid: String) throws -> [Recording] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT r.* FROM recordings r
                    JOIN utterances u ON r.id = u.recording_id
                    WHERE u.speaker_uuid = ?
                    ORDER BY r.created_at DESC
                """,
                arguments: [speakerUuid]
            )
            return rows.compactMap { Recording(row: $0) }
        }
    }

    /// Get all speakers with their recording counts (for browse-by-speaker)
    func getSpeakersWithRecordingCounts() throws -> [(speakerUuid: String, speakerName: String?, recordingCount: Int)] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT s.uuid, s.name, COUNT(DISTINCT u.recording_id) as recording_count
                    FROM speakers s
                    LEFT JOIN utterances u ON u.speaker_uuid = s.uuid
                    GROUP BY s.uuid
                    HAVING recording_count > 0
                    ORDER BY recording_count DESC
                """
            )
            return rows.compactMap { row in
                let uuid: String? = row["uuid"]
                let count: Int? = row["recording_count"]
                guard let uuid, let count else { return nil }
                let name: String? = row["name"]
                return (speakerUuid: uuid, speakerName: name, recordingCount: count)
            }
        }
    }

    /// Compound filter for Dashboard browsing
    func getFiltered(
        tagIds: [Int64]? = nil,
        speakerUuid: String? = nil,
        dateFrom: Date? = nil,
        dateTo: Date? = nil,
        source: Recording.RecordingSource? = nil,
        searchText: String? = nil,
        limit: Int = 200
    ) throws -> [Recording] {
        try db.read { db in
            var sql = "SELECT DISTINCT r.* FROM recordings r"
            var joins: [String] = []
            var conditions: [String] = []
            var arguments: [DatabaseValueConvertible?] = []

            // Join recording_tags if filtering by tags
            if let tagIds = tagIds, !tagIds.isEmpty {
                joins.append("JOIN recording_tags rt ON r.id = rt.recording_id")
                let placeholders = tagIds.map { _ in "?" }.joined(separator: ", ")
                conditions.append("rt.tag_id IN (\(placeholders))")
                arguments.append(contentsOf: tagIds)
            }

            // Join utterances if filtering by speaker
            if let speakerUuid = speakerUuid {
                joins.append("JOIN utterances u ON r.id = u.recording_id")
                conditions.append("u.speaker_uuid = ?")
                arguments.append(speakerUuid)
            }

            // Date range
            if let dateFrom = dateFrom {
                conditions.append("r.created_at >= ?")
                arguments.append(dateFrom)
            }
            if let dateTo = dateTo {
                conditions.append("r.created_at <= ?")
                arguments.append(dateTo)
            }

            // Source filter
            if let source = source {
                conditions.append("r.source = ?")
                arguments.append(source.rawValue)
            }

            // Text search
            if let searchText = searchText, !searchText.isEmpty {
                conditions.append("(r.title LIKE ? OR r.full_transcript LIKE ?)")
                arguments.append("%\(searchText)%")
                arguments.append("%\(searchText)%")
            }

            // Build final SQL
            sql += " " + joins.joined(separator: " ")
            if !conditions.isEmpty {
                sql += " WHERE " + conditions.joined(separator: " AND ")
            }
            sql += " ORDER BY r.created_at DESC LIMIT ?"
            arguments.append(limit)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments.map { $0 ?? DatabaseValue.null }))
            return rows.compactMap { Recording(row: $0) }
        }
    }

    /// Get the most recently created recording
    func getLastRecording() -> Recording? {
        do {
            return try db.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM recordings ORDER BY created_at DESC LIMIT 1"
                )
                
                guard let row = rows.first else { return nil }
                return Recording(row: row)
            }
        } catch {
            logger.error("[GRDBRecordingRepository] Failed to get last recording: \(error)")
            return nil
        }
    }
}

// MARK: - Recording Extension for GRDB

extension Recording {
    /// Initialize from GRDB Row using typed subscripts
    init?(row: Row) {
        let sourceRaw: String? = row["source"]
        guard let sourceRaw, let source = RecordingSource(rawValue: sourceRaw) else {
            return nil
        }

        let id: Int64? = row["id"]
        let title: String? = row["title"]
        let fileName: String? = row["file_name"]
        let createdAt: Date? = row["created_at"]
        guard let id, let title, let fileName, let createdAt else { return nil }

        self.id = id
        self.title = title
        self.fileName = fileName
        self.createdAt = createdAt
        self.source = source

        let filePath: String? = row["file_path"]
        self.filePath = filePath
        let duration: TimeInterval? = row["duration"]
        self.duration = duration
        let language: String? = row["language"]
        self.language = language
        let transcribedAt: Date? = row["transcribed_at"]
        self.transcribedAt = transcribedAt
        let fullTranscript: String? = row["full_transcript"]
        self.fullTranscript = fullTranscript
        self.speakerReviewStatus = row["speaker_review_status"]
        self.speakerReviewedAt = row["speaker_reviewed_at"]
        self.speakerPipelineProfile = row["speaker_pipeline_profile"]
        self.speakerPipelineVersion = row["speaker_pipeline_version"]
        let pipelineJSON: String? = row["speaker_pipeline_config"]
        self.speakerPipelineConfiguration = pipelineJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(SpeakerPipelineConfiguration.self, from: $0) }
        self.externalId = row["external_id"]
        self.updatedAt = row["updated_at"]

        // Parse metadata JSON if present
        let metadataJSON: String? = row["metadata"]
        if let metadataJSON,
           let data = metadataJSON.data(using: .utf8),
           let metadata = try? JSONDecoder().decode(RecordingMetadata.self, from: data) {
            self.metadata = metadata
        } else {
            self.metadata = nil
        }
    }
}
