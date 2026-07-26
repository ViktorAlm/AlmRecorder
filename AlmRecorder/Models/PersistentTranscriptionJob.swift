import Foundation
import GRDB

/// Database record for persistent transcription queue
struct PersistentTranscriptionJob: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "transcription_queue"
    
    var id: String
    var audioFilePath: String
    var fileName: String
    var source: String
    var priority: Int
    var status: String
    var progress: Double
    var progressMessage: String?
    var progressPhase: String?
    var totalChunks: Int
    var completedChunks: Int
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var transcript: String?
    var error: String?
    var retryCount: Int
    var maxRetries: Int
    var fileSize: Int64?
    var duration: Double?
    var modelUsed: String?
    var requiredModel: String?
    var existingRecordingId: Int64?
    var runSettings: String? // JSON encoded
    var workerId: String?
    var lastHeartbeat: Date?
    var checkpointData: String? // JSON encoded
    
    // CodingKeys for snake_case database columns
    enum Columns: String, ColumnExpression {
        case id
        case audioFilePath = "audio_file_path"
        case fileName = "file_name"
        case source
        case priority
        case status
        case progress
        case progressMessage = "progress_message"
        case progressPhase = "progress_phase"
        case totalChunks = "total_chunks"
        case completedChunks = "completed_chunks"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case transcript
        case error
        case retryCount = "retry_count"
        case maxRetries = "max_retries"
        case fileSize = "file_size"
        case duration
        case modelUsed = "model_used"
        case requiredModel = "required_model"
        case existingRecordingId = "existing_recording_id"
        case runSettings = "run_settings"
        case workerId = "worker_id"
        case lastHeartbeat = "last_heartbeat"
        case checkpointData = "checkpoint_data"
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case audioFilePath = "audio_file_path"
        case fileName = "file_name"
        case source
        case priority
        case status
        case progress
        case progressMessage = "progress_message"
        case progressPhase = "progress_phase"
        case totalChunks = "total_chunks"
        case completedChunks = "completed_chunks"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case transcript
        case error
        case retryCount = "retry_count"
        case maxRetries = "max_retries"
        case fileSize = "file_size"
        case duration
        case modelUsed = "model_used"
        case requiredModel = "required_model"
        case existingRecordingId = "existing_recording_id"
        case runSettings = "run_settings"
        case workerId = "worker_id"
        case lastHeartbeat = "last_heartbeat"
        case checkpointData = "checkpoint_data"
    }
}

// MARK: - Conversion Extensions

extension PersistentTranscriptionJob {
    /// Create from TranscriptionJob
    init(from job: TranscriptionJob) {
        self.id = job.id.uuidString
        self.audioFilePath = job.audioFilePath
        self.fileName = job.fileName
        self.source = job.source.rawValue
        self.priority = job.priority.rawValue
        self.status = job.status.rawValue
        self.progress = job.progress
        self.progressMessage = job.progressMessage
        self.progressPhase = job.progressPhase.rawValue
        self.totalChunks = job.totalChunks
        self.completedChunks = job.completedChunks
        self.createdAt = job.createdAt
        self.startedAt = job.startedAt
        self.completedAt = job.completedAt
        self.transcript = job.transcript
        self.error = job.error
        self.retryCount = job.retryCount
        self.maxRetries = job.maxRetries
        self.fileSize = job.fileSize
        self.duration = job.duration
        self.modelUsed = job.modelUsed
        self.requiredModel = job.requiredModel
        self.existingRecordingId = job.existingRecordingId
        
        // Encode RunSettings to JSON
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(job.runSettings) {
            self.runSettings = String(data: data, encoding: .utf8)
        }
        
        self.workerId = job.workerId
        self.lastHeartbeat = job.lastHeartbeat
        
        // Encode checkpoint data if present
        if let checkpoint = job.checkpointData {
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(checkpoint) {
                self.checkpointData = String(data: data, encoding: .utf8)
            }
        }
    }
    
    /// Convert to TranscriptionJob
    func toTranscriptionJob() -> TranscriptionJob? {
        guard let uuid = UUID(uuidString: id),
              let sourceEnum = TranscriptionItem.TranscriptionSource(rawValue: source),
              let statusEnum = TranscriptionJob.JobStatus(rawValue: status),
              let phaseEnum = TranscriptionJob.ProgressPhase(rawValue: progressPhase ?? "waiting") else {
            return nil
        }

        var job = TranscriptionJob(
            audioFilePath: audioFilePath,
            fileName: fileName,
            source: sourceEnum
        )

        // Restore the original UUID so persistJob() updates the existing DB record
        job.id = uuid

        job.priority = TranscriptionJob.Priority(rawValue: priority) ?? .normal
        job.status = statusEnum
        job.progress = progress
        job.progressMessage = progressMessage ?? ""
        job.progressPhase = phaseEnum
        job.totalChunks = totalChunks
        job.completedChunks = completedChunks
        job.startedAt = startedAt
        job.completedAt = completedAt
        job.transcript = transcript
        job.error = error
        job.retryCount = retryCount
        job.fileSize = fileSize
        job.duration = duration
        job.modelUsed = modelUsed
        job.requiredModel = requiredModel
        job.existingRecordingId = existingRecordingId
        
        // Decode RunSettings from JSON
        if let settingsJson = runSettings,
           let data = settingsJson.data(using: .utf8),
           let settings = try? JSONDecoder().decode(RunSettings.self, from: data) {
            job.runSettings = settings
        }
        
        job.workerId = workerId
        job.lastHeartbeat = lastHeartbeat
        
        // Decode checkpoint data
        if let checkpointJson = checkpointData,
           let data = checkpointJson.data(using: .utf8),
           let checkpoint = try? JSONDecoder().decode(TranscriptionCheckpoint.self, from: data) {
            job.checkpointData = checkpoint
        }
        
        return job
    }
}

// MARK: - Query Extensions

extension PersistentTranscriptionJob {
    /// Fetch all pending jobs sorted by priority and creation date
    static func fetchPending(_ db: Database) throws -> [PersistentTranscriptionJob] {
        return try PersistentTranscriptionJob
            .filter(Columns.status == "pending")
            .order(Columns.priority.desc, Columns.createdAt)
            .fetchAll(db)
    }
    
    /// Fetch jobs that were interrupted (for crash recovery)
    static func fetchInterrupted(_ db: Database) throws -> [PersistentTranscriptionJob] {
        return try PersistentTranscriptionJob
            .filter(Columns.status == "processing")
            .fetchAll(db)
    }
    
    /// Update heartbeat for a job
    static func updateHeartbeat(_ db: Database, jobId: String, workerId: String) throws {
        try db.execute(
            sql: "UPDATE transcription_queue SET last_heartbeat = ?, worker_id = ? WHERE id = ?",
            arguments: [Date(), workerId, jobId]
        )
    }
    
    /// Clean up stale jobs (heartbeat older than 5 minutes)
    static func markStaleJobsAsInterrupted(_ db: Database) throws -> Int {
        let staleDate = Date().addingTimeInterval(-5 * 60) // 5 minutes ago
        
        let staleJobs = try PersistentTranscriptionJob
            .filter(Columns.status == "processing")
            .filter(Columns.lastHeartbeat < staleDate)
            .fetchAll(db)
        
        for job in staleJobs {
            var updatedJob = job
            updatedJob.status = "interrupted"
            updatedJob.error = "Process interrupted unexpectedly"
            try updatedJob.update(db)
        }
        
        return staleJobs.count
    }
}
