import Foundation
import SwiftUI
import GRDB

// MARK: - Error Types

enum SpeakerError: LocalizedError {
    case loadFailed(String)
    case updateFailed(String)
    case mergeFailed(String)
    case unmergeFailed(String)
    case deleteFailed(String)
    case noSpeakersToMerge
    case speakerNotFound(String)

    var errorDescription: String? {
        switch self {
        case .loadFailed(let detail): return "Failed to load speakers: \(detail)"
        case .updateFailed(let detail): return "Failed to update speaker: \(detail)"
        case .mergeFailed(let detail): return "Failed to merge speakers: \(detail)"
        case .unmergeFailed(let detail): return "Failed to unmerge speakers: \(detail)"
        case .deleteFailed(let detail): return "Failed to delete speaker: \(detail)"
        case .noSpeakersToMerge: return "Select at least two speakers to merge"
        case .speakerNotFound(let uuid): return "Speaker not found: \(uuid)"
        }
    }
}

// MARK: - View Model

@MainActor
class SpeakerManagementViewModel: ObservableObject {

    // MARK: - Published Properties

    @Published var speakers: [SpeakerProfile] = []
    @Published var unnamedSpeakers: [SpeakerProfile] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var mergeHistory: [String: [SpeakerMergeHistory]] = [:]

    /// Set to trigger presentation of the review wizard for specific speakers
    @Published var reviewWizardSpeakers: [SpeakerProfile]?
    /// Set to trigger review wizard for a specific recording
    @Published var reviewWizardRecordingId: Int64?

    // MARK: - Private Properties

    private let speakerRepo = GRDBSpeakerRepository()
    private let mergeHistoryRepo = SpeakerMergeHistoryRepository()
    private let logger = VoxtralLogger.shared

    // MARK: - Load

    func loadSpeakers() async {
        isLoading = true
        error = nil

        do {
            let allSpeakers = try speakerRepo.getAll()
            speakers = allSpeakers.map { $0.toProfile() }
            unnamedSpeakers = allSpeakers
                .filter { $0.name == nil }
                .map { $0.toProfile() }
            await loadMergeHistory()
            logger.info("[SpeakerManagement] Loaded \(speakers.count) speakers (\(unnamedSpeakers.count) unnamed)")
        } catch {
            self.error = SpeakerError.loadFailed(error.localizedDescription).localizedDescription
            logger.error("[SpeakerManagement] Failed to load speakers: \(error)")
        }

        isLoading = false
    }

    // MARK: - Update

    func updateSpeaker(_ speaker: SpeakerProfile) async {
        do {
            // A name edited here is user-assigned → record manual provenance (clears any inferred/rejected
            // marker so it shows without an "inferred" badge); leave provenance nil when clearing the name.
            try speakerRepo.setName(uuid: speaker.uuid, name: speaker.name,
                                    source: speaker.name?.isEmpty == false ? "manual" : nil)
            if let notes = speaker.notes {
                // Update notes via raw update since repo doesn't have a dedicated method yet
                if var dbSpeaker = try speakerRepo.getByUUID(speaker.uuid) {
                    dbSpeaker.notes = notes
                    try speakerRepo.update(dbSpeaker)
                }
            }

            // Update local list
            if let index = speakers.firstIndex(where: { $0.uuid == speaker.uuid }) {
                speakers[index] = speaker
            }

            logger.info("[SpeakerManagement] Updated speaker: \(speaker.displayName)")
        } catch {
            self.error = SpeakerError.updateFailed(error.localizedDescription).localizedDescription
            logger.error("[SpeakerManagement] Failed to update speaker: \(error)")
        }
    }

    func deleteSpeaker(uuid: String) async {
        do {
            try speakerRepo.delete(uuid: uuid)
            speakers.removeAll { $0.uuid == uuid }
            unnamedSpeakers.removeAll { $0.uuid == uuid }
            logger.info("[SpeakerManagement] Deleted speaker: \(uuid)")
        } catch {
            self.error = SpeakerError.deleteFailed(error.localizedDescription).localizedDescription
            logger.error("[SpeakerManagement] Failed to delete speaker: \(error)")
        }
    }

    // MARK: - Merge / Unmerge

    func mergeSpeakers(uuids: [String]) async {
        guard uuids.count > 1 else {
            error = SpeakerError.noSpeakersToMerge.localizedDescription
            return
        }

        do {
            let speakersToMerge = speakers.filter { uuids.contains($0.uuid) }
            guard speakersToMerge.count > 1 else {
                error = SpeakerError.noSpeakersToMerge.localizedDescription
                return
            }

            // Keep the most prominent speaker
            let sorted = speakersToMerge.sorted { $0.totalDuration > $1.totalDuration }
            let primaryUUID = sorted[0].uuid
            let secondaryUUIDs = sorted.dropFirst().map { $0.uuid }

            logger.info("[SpeakerManagement] Merging \(secondaryUUIDs.count) speakers into \(sorted[0].displayName)")

            try speakerRepo.mergeSpeakersWithHistory(
                primaryUUID: primaryUUID,
                secondaryUUIDs: secondaryUUIDs,
                mergeHistoryRepo: mergeHistoryRepo
            )

            await loadSpeakers()
            logger.info("[SpeakerManagement] Successfully merged speakers")
        } catch {
            self.error = SpeakerError.mergeFailed(error.localizedDescription).localizedDescription
            logger.error("[SpeakerManagement] Failed to merge speakers: \(error)")
        }
    }

    func canUnmergeSpeaker(_ speakerUUID: String) -> Bool {
        (try? mergeHistoryRepo.canUnmerge(speakerUUID: speakerUUID)) ?? false
    }

    func unmergeSpeaker(_ speakerUUID: String, restoreUUIDs: [String]? = nil) async {
        do {
            let mergedSpeakers = try mergeHistoryRepo.getMergedSpeakers(for: speakerUUID)
            let toRestore = restoreUUIDs != nil
                ? mergedSpeakers.filter { restoreUUIDs!.contains($0.data.uuid) }
                : mergedSpeakers

            guard !toRestore.isEmpty else {
                self.error = SpeakerError.unmergeFailed("No speakers to restore").localizedDescription
                return
            }

            logger.info("[SpeakerManagement] Unmerging \(toRestore.count) speakers from \(speakerUUID)")

            for (history, speakerData) in toRestore {
                try restoreSpeaker(speakerData, fromPrimary: speakerUUID)
                if let historyId = history.id {
                    try mergeHistoryRepo.deleteMergeHistory(historyId: historyId)
                }
            }

            await loadSpeakers()
            logger.info("[SpeakerManagement] Successfully unmerged speakers")
        } catch {
            self.error = SpeakerError.unmergeFailed(error.localizedDescription).localizedDescription
            logger.error("[SpeakerManagement] Failed to unmerge speakers: \(error)")
        }
    }

    // MARK: - Review Wizard Launch

    /// Launch review wizard for specific speakers (e.g. unnamed ones)
    func launchReviewWizard(for speakerProfiles: [SpeakerProfile]) {
        reviewWizardSpeakers = speakerProfiles
    }

    /// Launch review wizard for all speakers in a recording
    func launchReviewForRecording(recordingId: Int64) {
        reviewWizardRecordingId = recordingId
    }

    /// Get speakers for a recording (for review wizard integration)
    func getSpeakersForRecording(recordingId: Int64) async -> [SpeakerProfile] {
        do {
            let results = try speakerRepo.getSpeakersForRecording(recordingId: recordingId)
            return results.map { $0.speaker.toProfile() }
        } catch {
            logger.error("[SpeakerManagement] Failed to get speakers for recording: \(error)")
            return []
        }
    }

    // MARK: - Query Methods

    func searchSpeakerInRecordings(speakerUUID: String) async throws -> [RecordingInfo] {
        let recordings = try speakerRepo.getRecordingsForSpeaker(uuid: speakerUUID)
        return recordings.map { row in
            RecordingInfo(
                id: Int(row.id),
                title: row.title,
                date: row.createdAt,
                speakerDuration: formatDuration(row.speakerDuration)
            )
        }
    }

    func getAllUtterancesForSpeaker(_ speakerUUID: String) async throws -> [(utterance: UtteranceDetail, recording: RecordingDetail)] {
        let rows = try speakerRepo.getUtterancesForSpeaker(uuid: speakerUUID)
        return rows.map { (uRow, title, audioPath) in
            let utterance = UtteranceDetail(
                id: Int(uRow.id),
                text: uRow.text,
                startTime: uRow.startTime,
                endTime: uRow.endTime,
                speakerUUID: uRow.speakerUUID
            )
            let recording = RecordingDetail(
                id: Int(uRow.recordingId),
                title: title,
                audioPath: audioPath ?? "",
                createdAt: uRow.recordingDate, // real recording date from the join (was a Date() placeholder)
                duration: 0
            )
            return (utterance, recording)
        }
    }

    func getSpeakerStatsForRecording(_ recordingId: Int) async throws -> [(speaker: SpeakerProfile, duration: TimeInterval)] {
        let results = try speakerRepo.getSpeakersForRecording(recordingId: Int64(recordingId))
        return results.map { ($0.speaker.toProfile(), $0.duration) }
    }

    func findRecordingsWithSpeakers(_ speakerUUIDs: [String]) async throws -> [RecordingInfo] {
        guard !speakerUUIDs.isEmpty else { return [] }

        // Use the repository's DB access for this complex query
        let db = GRDBDatabaseManager.shared
        let placeholders = speakerUUIDs.map { _ in "?" }.joined(separator: ",")

        let rows = try db.read { database in
            var args: [DatabaseValueConvertible] = speakerUUIDs
            args.append(speakerUUIDs.count)

            return try Row.fetchAll(database,
                sql: """
                    SELECT
                        r.id, r.title, r.created_at,
                        COUNT(DISTINCT u.speaker_uuid) as speaker_count
                    FROM recordings r
                    JOIN utterances u ON u.recording_id = r.id
                    WHERE u.speaker_uuid IN (\(placeholders))
                    GROUP BY r.id
                    HAVING speaker_count = ?
                    ORDER BY r.created_at DESC
                """,
                arguments: StatementArguments(args)
            )
        }

        return rows.compactMap { row in
            guard let id: Int64 = row["id"],
                  let title: String = row["title"],
                  let createdAt: Date = row["created_at"] else { return nil }
            return RecordingInfo(id: Int(id), title: title, date: createdAt, speakerDuration: "")
        }
    }

    // MARK: - Private

    func loadMergeHistory() async {
        do {
            var history: [String: [SpeakerMergeHistory]] = [:]
            for speaker in speakers {
                let speakerHistory = try mergeHistoryRepo.getMergeHistory(for: speaker.uuid)
                if !speakerHistory.isEmpty {
                    history[speaker.uuid] = speakerHistory
                }
            }
            mergeHistory = history
        } catch {
            logger.error("[SpeakerManagement] Failed to load merge history: \(error)")
        }
    }

    private func restoreSpeaker(_ speakerData: SerializedSpeakerData, fromPrimary primaryUUID: String) throws {
        let db = GRDBDatabaseManager.shared
        let restoredReversibleLink = try db.write { database -> Bool in
            guard try database.tableExists("speaker_global_link_operations") else {
                return false
            }
            return try GlobalSpeakerIdentityStore.undoLatestLink(
                database,
                sourceUUID: speakerData.uuid
            )
        }
        if restoredReversibleLink { return }

        // Legacy pre-v31 history deleted the source speaker, so it still needs reconstruction.
        try db.write { database in
            try database.execute(
                sql: """
                    INSERT INTO speakers (
                        uuid, name, notes, embedding, embedding_count,
                        total_duration, utterance_count, created_at,
                        updated_at, last_seen_at, confidence
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    speakerData.uuid,
                    speakerData.name,
                    speakerData.notes,
                    Data(bytes: speakerData.embedding, count: speakerData.embedding.count * MemoryLayout<Float>.size),
                    speakerData.embeddingCount,
                    speakerData.totalDuration,
                    speakerData.utteranceCount,
                    speakerData.createdAt,
                    Date(),
                    speakerData.lastSeenAt,
                    speakerData.confidence
                ]
            )

            if !speakerData.originalUtteranceIds.isEmpty {
                let placeholders = speakerData.originalUtteranceIds.map { _ in "?" }.joined(separator: ",")
                var arguments: [DatabaseValueConvertible] = [speakerData.uuid, primaryUUID]
                arguments.append(contentsOf: speakerData.originalUtteranceIds)
                try database.execute(
                    sql: """
                        UPDATE utterances
                        SET speaker_uuid = ?
                        WHERE speaker_uuid = ?
                        AND id IN (\(placeholders))
                    """,
                    arguments: StatementArguments(arguments)
                )
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "0s"
    }
}
