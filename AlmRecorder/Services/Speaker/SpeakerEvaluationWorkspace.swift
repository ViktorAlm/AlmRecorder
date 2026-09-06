import Foundation
import GRDB
import AlmRecorderEvaluationKit

struct SpeakerEvaluationCoverage: Equatable, Sendable {
    var singleSpeaker = 0
    var twoSpeakers = 0
    var threeSpeakers = 0
    var fourPlusSpeakers = 0
    var microphone = 0
    var system = 0
    var mixed = 0
    var unknown = 0

    func count(forSpeakerCount count: Int) -> Int {
        switch count {
        case ...1: return singleSpeaker
        case 2: return twoSpeakers
        case 3: return threeSpeakers
        default: return fourPlusSpeakers
        }
    }

    func count(forTrack track: MeetingTrackSource) -> Int {
        switch track {
        case .microphone: return microphone
        case .system: return system
        case .mixed: return mixed
        case .unknown: return unknown
        }
    }

    mutating func add(speakerCount: Int, track: MeetingTrackSource) {
        switch speakerCount {
        case ...1: singleSpeaker += 1
        case 2: twoSpeakers += 1
        case 3: threeSpeakers += 1
        default: fourPlusSpeakers += 1
        }
        switch track {
        case .microphone: microphone += 1
        case .system: system += 1
        case .mixed: mixed += 1
        case .unknown: unknown += 1
        }
    }
}

struct SpeakerEvaluationCandidate: Identifiable, Equatable {
    let recording: Recording
    let visibleUtteranceCount: Int
    let visibleSpeakerCount: Int
    let manuallyAssignedCount: Int
    let humanTranscriptActionCount: Int
    let voiceEmbeddingCount: Int
    let unassignedCount: Int
    let nonManualVisibleCount: Int
    let unreviewedVisibleCount: Int
    let trackSource: MeetingTrackSource
    let audioExists: Bool
    let isGoldReady: Bool
    let activeLearning: SpeakerEvaluationActiveLearningSignals
    var recommendationScore: Double
    var recommendationReasons: [String]

    var id: Int64 { recording.id ?? -1 }
    var reviewStatus: RecordingSpeakerReviewStatus? {
        recording.speakerReviewStatus.flatMap(RecordingSpeakerReviewStatus.init(rawValue:))
    }
    var duration: TimeInterval { recording.duration ?? 0 }
    var estimatedReviewMinutes: Int {
        // Transcript review is mostly visual, with selective listening. Keep the estimate intentionally
        // conservative and bounded so it remains a useful queue-order hint rather than a promise.
        let transcriptEffort = Double(visibleUtteranceCount) / 12.0
        let listeningEffort = duration / 180.0
        return max(2, min(60, Int(ceil(transcriptEffort + listeningEffort))))
    }
    var assignmentProgress: Double {
        guard visibleUtteranceCount > 0 else { return 0 }
        return Double(manuallyAssignedCount) / Double(visibleUtteranceCount)
    }
    var vectorCoverage: Double {
        guard visibleUtteranceCount > 0 else { return 0 }
        return Double(voiceEmbeddingCount) / Double(visibleUtteranceCount)
    }
}

struct SpeakerEvaluationSummary: Equatable, Sendable {
    var goldRecordingCount = 0
    var goldVisibleUtteranceCount = 0
    var goldDuration: TimeInterval = 0
    var inProgressCount = 0
    var needsCorrectionCount = 0
    var coverage = SpeakerEvaluationCoverage()
    var goldRevision = ""
}

struct SpeakerEvaluationSnapshot: @unchecked Sendable {
    let summary: SpeakerEvaluationSummary
    let candidates: [SpeakerEvaluationCandidate]
}

struct SpeakerEvaluationDatasetRecording {
    let recording: Recording
    let recordingKey: String
    let reference: [SpeakerEvaluationSegment]
    /// Unscored inspection calls still provide ASR timestamps to the diarizer, but must never
    /// become reference labels or affect gold metrics.
    var isGold: Bool = true
}

struct SpeakerEvaluationDataset: @unchecked Sendable {
    let recordings: [SpeakerEvaluationDatasetRecording]
    let goldRevision: String
}

protocol SpeakerEvaluationDataProviding: Sendable {
    func loadSnapshot() throws -> SpeakerEvaluationSnapshot
    func loadDataset() throws -> SpeakerEvaluationDataset
    func loadPairGoldBenchmark() throws -> SpeakerPairGoldBenchmarkReport?
    func loadCalibrationBackend() throws -> GlobalSpeakerCalibrationBackend?
    func loadSpeakerResolver() throws -> SpeakerNameResolver
}

/// The production adapter reads only the current user's local library and locally created labels.
/// Alternative developer providers can be injected without adding their datasets to this target.
struct LocalSpeakerEvaluationDataProvider: SpeakerEvaluationDataProviding,
    EvaluationDatasetProvider {
    func loadSnapshot() throws -> SpeakerEvaluationSnapshot {
        try GRDBDatabaseManager.shared.read { db in
            try SpeakerEvaluationWorkspace.loadSnapshot(db)
        }
    }

    func loadDataset() throws -> SpeakerEvaluationDataset {
        try GRDBDatabaseManager.shared.read { db in
            try SpeakerEvaluationWorkspace.loadDataset(db)
        }
    }

    func loadDatasetIncludingLatest(limit: Int = 5) throws -> SpeakerEvaluationDataset {
        try GRDBDatabaseManager.shared.read { db in
            try SpeakerEvaluationWorkspace.loadDatasetIncludingLatest(db, limit: limit)
        }
    }

    func loadEvaluationDataset() throws -> SpeakerEvaluationDataset {
        try loadDataset()
    }

    func loadPairGoldBenchmark() throws -> SpeakerPairGoldBenchmarkReport? {
        try SpeakerPairGoldStore.loadBenchmark()
    }

    func loadCalibrationBackend() throws -> GlobalSpeakerCalibrationBackend? {
        try GRDBDatabaseManager.shared.read { db in
            try GlobalSpeakerLibraryReconciliation.calibrationBackend(db)
        }
    }

    func loadSpeakerResolver() throws -> SpeakerNameResolver {
        try SpeakerNameResolver(speakers: GRDBSpeakerRepository().getAll())
    }
}

enum SpeakerEvaluationWorkspace {
    struct RankingSignals: Equatable {
        let audioExists: Bool
        let reviewStatus: RecordingSpeakerReviewStatus?
        let duration: TimeInterval
        let visibleUtterances: Int
        let visibleSpeakers: Int
        let manuallyAssigned: Int
        let humanTranscriptActions: Int
        let voiceEmbeddings: Int
        let trackSource: MeetingTrackSource
        let isGoldReady: Bool
        var activeLearningScore: Double = 0
        var activeLearningReasons: [String] = []
    }

    static func loadSnapshot(
        using provider: any SpeakerEvaluationDataProviding =
            LocalSpeakerEvaluationDataProvider()
    ) throws -> SpeakerEvaluationSnapshot {
        try provider.loadSnapshot()
    }

    static func loadDataset(
        using provider: any SpeakerEvaluationDataProviding =
            LocalSpeakerEvaluationDataProvider()
    ) throws -> SpeakerEvaluationDataset {
        try provider.loadDataset()
    }

    static func loadSnapshot(_ db: Database) throws -> SpeakerEvaluationSnapshot {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT r.*,
                       COUNT(CASE WHEN COALESCE(u.is_hidden, 0) = 0 THEN 1 END)
                           AS eval_visible_utterances,
                       COUNT(DISTINCT CASE
                           WHEN COALESCE(u.is_hidden, 0) = 0
                           THEN COALESCE(u.speaker_uuid, u.speaker)
                       END) AS eval_visible_speakers,
                       SUM(CASE
                           WHEN COALESCE(u.is_hidden, 0) = 0
                            AND COALESCE(u.speaker_assignment_source, '')
                                IN ('manual', 'global_manual')
                           THEN 1 ELSE 0
                       END) AS eval_manual_assignments,
                       SUM(CASE
                           WHEN u.review_status IN ('user_corrected', 'user_hidden', 'user_kept')
                           THEN 1 ELSE 0
                       END) AS eval_human_actions,
                       SUM(CASE
                           WHEN COALESCE(u.is_hidden, 0) = 0 AND v.utterance_id IS NOT NULL
                           THEN 1 ELSE 0
                       END) AS eval_voice_embeddings,
                       SUM(CASE
                           WHEN COALESCE(u.is_hidden, 0) = 0
                            AND u.speaker_uuid IS NULL
                            AND TRIM(COALESCE(u.speaker, '')) = ''
                           THEN 1 ELSE 0
                       END) AS eval_unassigned,
                       SUM(CASE
                           WHEN COALESCE(u.is_hidden, 0) = 0
                            AND COALESCE(u.speaker_assignment_source, '')
                                NOT IN ('manual', 'global_manual')
                           THEN 1 ELSE 0
                       END) AS eval_non_manual,
                       SUM(CASE
                           WHEN COALESCE(u.is_hidden, 0) = 0
                            AND u.speaker_reviewed_at IS NULL
                           THEN 1 ELSE 0
                       END) AS eval_unreviewed,
                       SUM(CASE
                           WHEN COALESCE(u.is_hidden, 0) = 0 AND u.audio_source = 'microphone'
                           THEN 1 ELSE 0
                       END) AS eval_microphone,
                       SUM(CASE
                           WHEN COALESCE(u.is_hidden, 0) = 0 AND u.audio_source = 'system'
                           THEN 1 ELSE 0
                       END) AS eval_system
                FROM recordings r
                JOIN utterances u ON u.recording_id = r.id
                LEFT JOIN utterance_voice_embeddings v ON v.utterance_id = u.id
                GROUP BY r.id
                HAVING eval_visible_utterances > 0
            """
        )

        let voiceRows = try Row.fetchAll(
            db,
            sql: """
                SELECT u.recording_id,
                       COALESCE(u.speaker_uuid, '') AS speaker_uuid,
                       COALESCE(u.speaker, '') AS local_speaker,
                       v.embedding
                FROM utterance_voice_embeddings v
                JOIN utterances u ON u.id = v.utterance_id
                WHERE COALESCE(u.is_hidden, 0) = 0
                  AND v.dimensions = ?
                  AND (
                    u.speaker_uuid IS NOT NULL
                    OR TRIM(COALESCE(u.speaker, '')) != ''
                  )
            """,
            arguments: [VoiceEmbeddingStore.dimensions]
        )
        let observations = voiceRows.compactMap { row -> SpeakerEvaluationVoiceObservation? in
            guard let recordingId: Int64 = row["recording_id"],
                  let data: Data = row["embedding"] else { return nil }
            let uuid: String = row["speaker_uuid"] ?? ""
            let local: String = row["local_speaker"] ?? ""
            let assignmentKey = uuid.isEmpty ? "local:\(local)" : "global:\(uuid)"
            return SpeakerEvaluationVoiceObservation(
                recordingId: recordingId,
                assignmentKey: assignmentKey,
                globalSpeakerUUID: uuid.isEmpty ? nil : uuid,
                embedding: VoiceEmbeddingStore.dataToFloats(data)
            )
        }
        let activeLearning = SpeakerEvaluationActiveLearning.analyze(observations: observations)

        var raw: [SpeakerEvaluationCandidate] = []
        raw.reserveCapacity(rows.count)
        for row in rows {
            guard let recording = Recording(row: row), recording.id != nil else { continue }
            let visible: Int = row["eval_visible_utterances"] ?? 0
            let speakers: Int = row["eval_visible_speakers"] ?? 0
            let manual: Int = row["eval_manual_assignments"] ?? 0
            let actions: Int = row["eval_human_actions"] ?? 0
            let embeddings: Int = row["eval_voice_embeddings"] ?? 0
            let unassigned: Int = row["eval_unassigned"] ?? 0
            let nonManual: Int = row["eval_non_manual"] ?? 0
            let unreviewed: Int = row["eval_unreviewed"] ?? 0
            let microphone: Int = row["eval_microphone"] ?? 0
            let system: Int = row["eval_system"] ?? 0
            let track: MeetingTrackSource
            if microphone > 0, system > 0 {
                track = .mixed
            } else if microphone > 0 {
                track = .microphone
            } else if system > 0 {
                track = .system
            } else {
                track = MeetingTrackSource.classify(
                    fileName: recording.filePath ?? recording.fileName
                )
            }
            let status = recording.speakerReviewStatus.flatMap(RecordingSpeakerReviewStatus.init(rawValue:))
            let isMarkedGold = status == .gold
            let hasCompleteAssignments = visible > 0 && unassigned == 0
            let hasManualProvenance = nonManual == 0
            let hasReviewTimestamps = unreviewed == 0
            let goldReady = isMarkedGold
                && hasCompleteAssignments
                && hasManualProvenance
                && hasReviewTimestamps
            let path = recording.filePath ?? ""
            let audioExists = !path.isEmpty && FileManager.default.fileExists(atPath: path)
            raw.append(SpeakerEvaluationCandidate(
                recording: recording,
                visibleUtteranceCount: visible,
                visibleSpeakerCount: speakers,
                manuallyAssignedCount: manual,
                humanTranscriptActionCount: actions,
                voiceEmbeddingCount: embeddings,
                unassignedCount: unassigned,
                nonManualVisibleCount: nonManual,
                unreviewedVisibleCount: unreviewed,
                trackSource: track,
                audioExists: audioExists,
                isGoldReady: goldReady,
                activeLearning: activeLearning[recording.id ?? -1]
                    ?? SpeakerEvaluationActiveLearningSignals(),
                recommendationScore: 0,
                recommendationReasons: []
            ))
        }

        var summary = SpeakerEvaluationSummary()
        var revisionParts: [String] = []
        for item in raw {
            switch item.reviewStatus {
            case .inProgress, .complete: summary.inProgressCount += 1
            case .needsCorrection: summary.needsCorrectionCount += 1
            default: break
            }
            guard item.isGoldReady else { continue }
            summary.goldRecordingCount += 1
            summary.goldVisibleUtteranceCount += item.visibleUtteranceCount
            summary.goldDuration += item.duration
            summary.coverage.add(
                speakerCount: item.visibleSpeakerCount,
                track: item.trackSource
            )
            revisionParts.append(
                "\(item.id):\(item.recording.speakerReviewedAt?.timeIntervalSince1970 ?? 0)"
            )
        }
        let pairRevision = try SpeakerPairGoldStore.revision(db)
        summary.goldRevision = revisionParts.sorted().joined(separator: "|")
            + "|pairs:\(pairRevision)"

        let ranked = raw.map { item -> SpeakerEvaluationCandidate in
            var copy = item
            let signals = RankingSignals(
                audioExists: item.audioExists,
                reviewStatus: item.reviewStatus,
                duration: item.duration,
                visibleUtterances: item.visibleUtteranceCount,
                visibleSpeakers: item.visibleSpeakerCount,
                manuallyAssigned: item.manuallyAssignedCount,
                humanTranscriptActions: item.humanTranscriptActionCount,
                voiceEmbeddings: item.voiceEmbeddingCount,
                trackSource: item.trackSource,
                isGoldReady: item.isGoldReady,
                activeLearningScore: item.activeLearning.score,
                activeLearningReasons: item.activeLearning.reasons
            )
            copy.recommendationScore = recommendationScore(
                signals: signals,
                currentCoverage: summary.coverage
            )
            copy.recommendationReasons = recommendationReasons(
                signals: signals,
                currentCoverage: summary.coverage
            )
            return copy
        }
        .sorted {
            if $0.isGoldReady != $1.isGoldReady { return !$0.isGoldReady }
            if $0.recommendationScore != $1.recommendationScore {
                return $0.recommendationScore > $1.recommendationScore
            }
            return $0.recording.createdAt > $1.recording.createdAt
        }

        return SpeakerEvaluationSnapshot(summary: summary, candidates: ranked)
    }

    static func loadDataset(_ db: Database) throws -> SpeakerEvaluationDataset {
        let goldRows = try Row.fetchAll(
            db,
            sql: """
                SELECT r.*
                FROM recordings r
                JOIN utterances u ON u.recording_id = r.id
                WHERE r.speaker_review_status = 'gold'
                GROUP BY r.id
                HAVING SUM(CASE WHEN COALESCE(u.is_hidden, 0) = 0 THEN 1 ELSE 0 END) > 0
                   AND SUM(CASE
                       WHEN COALESCE(u.is_hidden, 0) = 0
                        AND u.speaker_uuid IS NULL
                        AND TRIM(COALESCE(u.speaker, '')) = ''
                       THEN 1 ELSE 0
                   END) = 0
                   AND SUM(CASE
                       WHEN COALESCE(u.is_hidden, 0) = 0
                        AND COALESCE(u.speaker_assignment_source, '')
                            NOT IN ('manual', 'global_manual')
                       THEN 1 ELSE 0
                   END) = 0
                   AND SUM(CASE
                       WHEN COALESCE(u.is_hidden, 0) = 0
                        AND u.speaker_reviewed_at IS NULL
                       THEN 1 ELSE 0
                   END) = 0
                ORDER BY r.id
            """
        )
        var recordings: [SpeakerEvaluationDatasetRecording] = []
        var revisionParts: [String] = []
        for goldRow in goldRows {
            guard let recording = Recording(row: goldRow),
                  let recordingId = recording.id else { continue }
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, start_time, end_time, speaker, speaker_uuid, text
                    FROM utterances
                    WHERE recording_id = ? AND COALESCE(is_hidden, 0) = 0
                    ORDER BY start_time, utterance_index, id
                """,
                arguments: [recordingId]
            )
            let recordingKey = "recording:\(recordingId)"
            let reference = rows.compactMap { row -> SpeakerEvaluationSegment? in
                let uuid: String? = row["speaker_uuid"]
                let local: String? = row["speaker"]
                let speakerKey = uuid ?? local.map { "local:\(recordingId):\($0)" }
                guard let speakerKey else { return nil }
                let start: Double = row["start_time"] ?? 0
                let end: Double = row["end_time"] ?? start
                let text: String? = row["text"]
                return SpeakerEvaluationSegment(
                    recordingKey: recordingKey,
                    speakerKey: speakerKey,
                    startTime: max(0, start),
                    endTime: max(start, end),
                    text: text,
                    timingIsGold: false
                )
            }
            recordings.append(SpeakerEvaluationDatasetRecording(
                recording: recording,
                recordingKey: recordingKey,
                reference: reference
            ))
            revisionParts.append(
                "\(recordingId):\(recording.speakerReviewedAt?.timeIntervalSince1970 ?? 0)"
            )
        }
        let pairRevision = try SpeakerPairGoldStore.revision(db)
        return SpeakerEvaluationDataset(
            recordings: recordings.sorted {
                ($0.recording.id ?? 0) < ($1.recording.id ?? 0)
            },
            goldRevision: revisionParts.sorted().joined(separator: "|")
                + "|pairs:\(pairRevision)"
        )
    }

    /// Adds the newest accessible recordings as unscored inspection calls. Gold calls remain the
    /// only source of labels and metrics, while developers can see what every global matcher would
    /// do to the calls they are actively working on.
    static func loadDatasetIncludingLatest(
        _ db: Database,
        limit: Int = 5
    ) throws -> SpeakerEvaluationDataset {
        let gold = try loadDataset(db)
        guard limit > 0 else { return gold }

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT r.*
                FROM recordings r
                WHERE r.file_path IS NOT NULL
                  AND TRIM(r.file_path) != ''
                ORDER BY r.created_at DESC, r.id DESC
                LIMIT ?
            """,
            arguments: [max(50, limit * 10)]
        )
        var latest: [SpeakerEvaluationDatasetRecording] = []
        latest.reserveCapacity(limit)
        for row in rows {
            guard latest.count < limit,
                  let recording = Recording(row: row),
                  let recordingId = recording.id,
                  let path = recording.filePath,
                  FileManager.default.fileExists(atPath: path) else {
                continue
            }
            let recordingKey = "recording:\(recordingId)"
            let transcriptRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT start_time, end_time, text
                    FROM utterances
                    WHERE recording_id = ? AND COALESCE(is_hidden, 0) = 0
                    ORDER BY start_time, utterance_index, id
                """,
                arguments: [recordingId]
            )
            let timingContext = transcriptRows.map { transcriptRow in
                let start: Double = transcriptRow["start_time"] ?? 0
                let end: Double = transcriptRow["end_time"] ?? start
                let text: String? = transcriptRow["text"]
                return SpeakerEvaluationSegment(
                    recordingKey: recordingKey,
                    speakerKey: nil,
                    startTime: max(0, start),
                    endTime: max(start, end),
                    text: text,
                    timingIsGold: false
                )
            }
            latest.append(SpeakerEvaluationDatasetRecording(
                recording: recording,
                recordingKey: recordingKey,
                reference: timingContext,
                isGold: false
            ))
        }

        let latestIDs = Set(latest.compactMap(\.recording.id))
        let retainedGold = gold.recordings.filter {
            guard let id = $0.recording.id else { return true }
            return !latestIDs.contains(id)
        }
        // The latest calls run last, after the gold calls have established reusable voice evidence.
        // If a latest call is itself gold, retain its gold-labeled version rather than the unscored
        // duplicate.
        let goldByID: [Int64: SpeakerEvaluationDatasetRecording] = Dictionary(
            uniqueKeysWithValues: gold.recordings.compactMap {
                guard let id = $0.recording.id else { return nil }
                return (id, $0) as (Int64, SpeakerEvaluationDatasetRecording)
            }
        )
        let inspectedLatest = latest.map {
            guard let id = $0.recording.id else { return $0 }
            return goldByID[id] ?? $0
        }
        return SpeakerEvaluationDataset(
            recordings: retainedGold + inspectedLatest,
            goldRevision: gold.goldRevision
        )
    }

    static func loadLatestRecordings(
        _ db: Database,
        limit: Int = 5
    ) throws -> [Recording] {
        guard limit > 0 else { return [] }
        return try Row.fetchAll(
            db,
            sql: """
                SELECT r.*
                FROM recordings r
                ORDER BY r.created_at DESC, r.id DESC
                LIMIT ?
            """,
            arguments: [limit]
        )
        .compactMap(Recording.init(row:))
    }

    static func recommendationScore(
        signals: RankingSignals,
        currentCoverage: SpeakerEvaluationCoverage
    ) -> Double {
        if signals.isGoldReady { return -1_000 }
        var score = signals.activeLearningScore
        if signals.audioExists { score += 35 } else { score -= 80 }
        switch signals.reviewStatus {
        case .needsCorrection: score += 55
        case .inProgress, .complete: score += 45
        case .gold: score += 20 // stale gold: bring it back into the correction queue.
        case nil: break
        }
        score += min(25, Double(signals.humanTranscriptActions) * 2.5)
        if signals.visibleUtterances > 0 {
            score += 20 * Double(signals.manuallyAssigned) / Double(signals.visibleUtterances)
            score += 12 * Double(signals.voiceEmbeddings) / Double(signals.visibleUtterances)
        }
        switch signals.visibleSpeakers {
        case 1: score += 8
        case 2: score += 24
        case 3: score += 30
        default: score += signals.visibleSpeakers > 3 ? 26 : 0
        }
        if currentCoverage.count(forSpeakerCount: signals.visibleSpeakers) == 0 {
            score += 24
        }
        if signals.trackSource != .unknown,
           currentCoverage.count(forTrack: signals.trackSource) == 0 {
            score += 18
        }
        let minutes = signals.duration / 60
        switch minutes {
        case 1...12: score += 22
        case 12...25: score += 12
        case 25...45: score += 2
        case 45...: score -= min(30, (minutes - 45) / 2)
        default: score -= 15
        }
        if signals.visibleUtterances > 500 { score -= 20 }
        return score
    }

    static func recommendationReasons(
        signals: RankingSignals,
        currentCoverage: SpeakerEvaluationCoverage
    ) -> [String] {
        if signals.isGoldReady { return ["Already in the gold set"] }
        var reasons = signals.activeLearningReasons
        switch signals.reviewStatus {
        case .needsCorrection: reasons.append("Previously marked for correction")
        case .inProgress, .complete: reasons.append("Review already started")
        case .gold: reasons.append("Gold verdict needs refreshing")
        case nil: break
        }
        if currentCoverage.count(forSpeakerCount: signals.visibleSpeakers) == 0 {
            reasons.append("Fills missing \(speakerBucketLabel(signals.visibleSpeakers)) coverage")
        }
        if signals.trackSource != .unknown,
           currentCoverage.count(forTrack: signals.trackSource) == 0 {
            reasons.append("Adds \(trackLabel(signals.trackSource)) audio")
        }
        if signals.humanTranscriptActions > 0 {
            reasons.append("\(signals.humanTranscriptActions) existing human decision\(signals.humanTranscriptActions == 1 ? "" : "s")")
        }
        let minutes = Int(ceil(signals.duration / 60))
        if minutes <= 12 { reasons.append("Quick review · about \(max(1, minutes)) min audio") }
        if !signals.audioExists { reasons.append("Audio file unavailable") }
        if reasons.isEmpty {
            reasons.append("\(signals.visibleSpeakers) speaker\(signals.visibleSpeakers == 1 ? "" : "s") · \(signals.visibleUtterances) lines")
        }
        return Array(reasons.prefix(2))
    }

    static func speakerBucketLabel(_ count: Int) -> String {
        switch count {
        case ...1: return "single-speaker"
        case 2: return "two-speaker"
        case 3: return "three-speaker"
        default: return "four-plus-speaker"
        }
    }

    static func trackLabel(_ track: MeetingTrackSource) -> String {
        switch track {
        case .microphone: return "microphone"
        case .system: return "system"
        case .mixed: return "mixed-track"
        case .unknown: return "unknown-track"
        }
    }
}
