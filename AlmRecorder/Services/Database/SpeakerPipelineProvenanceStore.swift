import GRDB

enum SpeakerPipelineProvenanceStore {
    static func migrate(_ db: Database) throws {
        try db.alter(table: "utterances") { table in
            table.add(column: "audio_source", .text)
            table.add(column: "speaker_assignment_source", .text)
                .notNull().defaults(to: SpeakerAssignmentSource.model.rawValue)
            table.add(column: "speaker_reviewed_at", .datetime)
            table.add(column: "voice_embedding_quality", .double)
        }
        try db.alter(table: "recordings") { table in
            table.add(column: "speaker_review_status", .text)
            table.add(column: "speaker_reviewed_at", .datetime)
            table.add(column: "speaker_pipeline_profile", .text)
            table.add(column: "speaker_pipeline_version", .integer)
            table.add(column: "speaker_pipeline_config", .text)
        }
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_recordings_speaker_review_status ON recordings(speaker_review_status)")
    }
}
