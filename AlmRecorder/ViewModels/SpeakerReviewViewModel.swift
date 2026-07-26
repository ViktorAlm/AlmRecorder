import Foundation
import SwiftUI
import GRDB

@MainActor
class SpeakerReviewViewModel: ObservableObject {

    // MARK: - Published Properties

    @Published var session: SpeakerReviewSession?
    @Published var currentSpeakerIndex = 0
    @Published var potentialMatches: [SpeakerMatch] = []
    @Published var isLoadingMatches = false
    @Published var selectedAssignment: SpeakerAssignment?
    @Published var newSpeakerName = ""
    @Published var newSpeakerNotes = ""
    @Published var isProcessing = false
    @Published var error: String?

    /// True when initialized from SpeakerProfiles (on-demand mode) vs transcription
    @Published var isOnDemandMode = false

    /// Calendar-fused, ranked suggestions for the current speaker (meeting attendees + voice).
    @Published var suggestions: [SpeakerSuggestion] = []

    // MARK: - Private Properties

    private let speakerService = SpeakerIdentificationService()
    private let speakerRepo = GRDBSpeakerRepository()
    private let audioExtractor = AudioSegmentExtractor.shared
    private let db = GRDBDatabaseManager.shared
    private let logger = VoxtralLogger.shared
    private let suggestionProvider = MeetingSuggestionProvider()
    private let attendeeRepo = GRDBSpeakerAttendeeRepository()
    /// Attendees of the meeting linked to this recording (empty in on-demand mode).
    private var meetingAttendees: [AttendeeInfo] = []
    /// Detected-speaker tempId -> calendar attendee name, for assignments made from a chip.
    private var attendeeAssignment: [String: String] = [:]

    // MARK: - Computed Properties
    
    var currentSpeaker: DetectedSpeaker? {
        guard let session = session,
              currentSpeakerIndex < session.detectedSpeakers.count else {
            return nil
        }
        return session.detectedSpeakers[currentSpeakerIndex]
    }
    
    var hasNextSpeaker: Bool {
        guard let session = session else { return false }
        return currentSpeakerIndex < session.detectedSpeakers.count - 1
    }
    
    var hasPreviousSpeaker: Bool {
        currentSpeakerIndex > 0
    }
    
    var progressText: String {
        guard let session = session else { return "" }
        return "Speaker \(currentSpeakerIndex + 1) of \(session.detectedSpeakers.count)"
    }
    
    // MARK: - Initialization
    
    func initializeSession(
        recordingId: Int64,
        audioFilePath: String,
        transcriptionResult: TranscriptionResult
    ) async {
        
        isProcessing = true
        
        // Group chunks by speaker
        let speakerChunks = Dictionary(grouping: transcriptionResult.chunks) { chunk in
            chunk.speaker ?? "Unknown"
        }
        
        // Create DetectedSpeaker objects
        var detectedSpeakers: [DetectedSpeaker] = []
        
        for (speakerId, chunks) in speakerChunks {
            // Skip if no meaningful speaker ID
            guard !speakerId.isEmpty && speakerId != "Unknown" else { continue }
                
            // Find corresponding embedding if available
            let embedding = transcriptionResult.speakerEmbeddings?.first { 
                $0.speakerId == speakerId 
            }?.embedding ?? []
                
            // Calculate total duration
            let totalDuration = chunks.reduce(0) { sum, chunk in
                sum + chunk.duration
            }
                
            // Create example segments (up to 3 longest chunks)
            let topChunks = chunks.sorted { $0.duration > $1.duration }.prefix(3)
            let segments = topChunks.map { chunk in
                AudioSegment(
                    startTime: chunk.startTime,
                    endTime: chunk.endTime,
                    text: chunk.text,
                    speakerTempId: speakerId
                )
            }
                
            let detectedSpeaker = DetectedSpeaker(
                tempId: speakerId,
                chunks: chunks,
                embedding: embedding,
                totalDuration: totalDuration,
                utteranceCount: chunks.count,
                exampleSegments: Array(segments)
            )
            
            detectedSpeakers.append(detectedSpeaker)
        }
            
            // Sort by total duration (most prominent speakers first)
            detectedSpeakers.sort { $0.totalDuration > $1.totalDuration }
            
            // Create session
            session = SpeakerReviewSession(
                recordingId: recordingId,
                audioFilePath: audioFilePath,
                detectedSpeakers: detectedSpeakers,
                transcriptionResult: transcriptionResult
            )

            // Load the linked meeting's attendees to seed calendar suggestions.
            meetingAttendees = suggestionProvider.attendees(forRecording: recordingId)

            // Load matches for first speaker
            if !detectedSpeakers.isEmpty {
                await loadPotentialMatches(for: detectedSpeakers[0])
            }
        
        isProcessing = false
    }
    
    // MARK: - On-Demand Initialization (from Speaker Management)

    /// Initialize from existing SpeakerProfiles for on-demand review/merge
    func initializeFromProfiles(_ profiles: [SpeakerProfile]) async {
        isProcessing = true
        isOnDemandMode = true

        var detectedSpeakers: [DetectedSpeaker] = []

        for profile in profiles {
            // Load example utterances from DB for this speaker
            var segments: [AudioSegment] = []
            do {
                let utterances = try speakerRepo.getUtterancesForSpeaker(uuid: profile.uuid)
                segments = utterances.prefix(3).map { (uRow, _, _) in
                    AudioSegment(
                        startTime: uRow.startTime,
                        endTime: uRow.endTime,
                        text: uRow.text,
                        speakerTempId: profile.uuid
                    )
                }
            } catch {
                logger.error("[SpeakerReview] Failed to load utterances for profile: \(error)")
            }

            let detected = DetectedSpeaker(
                tempId: profile.uuid,
                chunks: [],
                embedding: profile.averageEmbedding,
                totalDuration: profile.totalDuration,
                utteranceCount: profile.utteranceCount,
                exampleSegments: segments,
                resolvedName: profile.displayName   // show the name / stable label, not the raw uuid
            )
            detectedSpeakers.append(detected)
        }

        detectedSpeakers.sort { $0.totalDuration > $1.totalDuration }

        // For on-demand mode, use a dummy session (no recording/transcription)
        session = SpeakerReviewSession(
            recordingId: 0,
            audioFilePath: "",
            detectedSpeakers: detectedSpeakers,
            transcriptionResult: TranscriptionResult(
                fullTranscript: "", chunks: [], totalDuration: 0,
                language: nil, usedVAD: false
            )
        )

        if !detectedSpeakers.isEmpty {
            await loadPotentialMatches(for: detectedSpeakers[0])
        }

        isProcessing = false
    }

    // MARK: - Navigation
    
    func nextSpeaker() async {
        // Save current assignment
        if let speaker = currentSpeaker,
           let assignment = selectedAssignment {
            session?.assignments[speaker.tempId] = assignment
        }
        
        // Move to next
        if hasNextSpeaker {
            currentSpeakerIndex += 1
            selectedAssignment = nil
            newSpeakerName = ""
            newSpeakerNotes = ""
            
            // Load matches for new speaker
            if let speaker = currentSpeaker {
                await loadPotentialMatches(for: speaker)
            }
        }
    }
    
    func previousSpeaker() async {
        if hasPreviousSpeaker {
            currentSpeakerIndex -= 1
            
            // Restore previous assignment if any
            if let speaker = currentSpeaker,
               let previousAssignment = session?.assignments[speaker.tempId] {
                selectedAssignment = previousAssignment
                
                // Restore name if it was a new speaker
                if case .new(let name, let notes) = previousAssignment {
                    newSpeakerName = name
                    newSpeakerNotes = notes ?? ""
                }
            } else {
                selectedAssignment = nil
                newSpeakerName = ""
                newSpeakerNotes = ""
            }
            
            // Load matches
            if let speaker = currentSpeaker {
                await loadPotentialMatches(for: speaker)
            }
        }
    }
    
    // MARK: - Speaker Matching
    
    private func loadPotentialMatches(for speaker: DetectedSpeaker) async {
        isLoadingMatches = true
        potentialMatches = []
        
        guard !speaker.embedding.isEmpty else {
            logger.warning("[SpeakerReview] No embedding available for speaker \(speaker.tempId)")
            // Still offer calendar attendees even without a voice embedding.
            suggestions = SpeakerSuggestionRanker.rank(voiceMatches: [], attendees: meetingAttendees)
            isLoadingMatches = false
            return
        }
        
        do {
            // Find similar speakers in database
            let matches = try speakerService.findSimilarSpeakers(
                to: speaker.embedding,
                threshold: 0.6, // Lower threshold to show more options
                limit: 5
            )
            
            // Convert to SpeakerMatch objects
            potentialMatches = await matches.asyncMap { (profile, similarity) in
                // Get example recordings for this speaker
                let recordings = await self.getRecentRecordings(for: profile.uuid, limit: 3)
                
                return SpeakerMatch(
                    profile: profile,
                    similarity: similarity,
                    exampleRecordings: recordings
                )
            }
            
            // Sort by similarity
            potentialMatches.sort { $0.similarity > $1.similarity }
            
        } catch {
            logger.error("[SpeakerReview] Failed to load matches: \(error)")
        }

        // Fuse voice matches with the meeting's calendar attendees into ranked suggestions, plus any
        // cross-meeting identity the global engine deduced for this voice from its *other* meetings.
        let voiceMatches = potentialMatches.map {
            VoiceMatch(speakerUuid: $0.profile.uuid, displayName: $0.profile.displayName, similarity: $0.similarity)
        }
        suggestions = SpeakerSuggestionRanker.rank(
            voiceMatches: voiceMatches,
            attendees: meetingAttendees,
            extra: globalInferenceSuggestion(for: speaker)
        )

        isLoadingMatches = false
    }

    /// The global cross-meeting inference for a detected speaker, as a top-ranked suggestion (or nil).
    /// Resolves the persistent voice uuid first: in on-demand mode `tempId` already is it; post-transcription
    /// it's the `speaker_uuid` that diarization assigned to this recording's utterances for this label.
    private func globalInferenceSuggestion(for speaker: DetectedSpeaker) -> SpeakerSuggestion? {
        let uuid: String?
        if isOnDemandMode {
            uuid = speaker.tempId
        } else if let recordingId = session?.recordingId {
            uuid = (try? db.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT speaker_uuid FROM utterances WHERE recording_id = ? AND speaker = ? AND speaker_uuid IS NOT NULL LIMIT 1",
                    arguments: [recordingId, speaker.tempId]
                )
            }) ?? nil
        } else {
            uuid = nil
        }
        guard let uuid, let inf = IdentityInferenceCoordinator.shared.inference(forVoice: uuid) else { return nil }
        let score = inf.confidence >= .strong ? 120.0 : (inf.confidence == .likely ? 90.0 : 60.0)
        return SpeakerSuggestion(
            title: inf.attendeeName,
            kind: .newFromAttendee(name: inf.attendeeName),
            reason: inf.reason,
            inMeeting: false,
            similarity: nil,
            score: score
        )
    }
    
    private func getRecentRecordings(for speakerUUID: String, limit: Int) async -> [RecordingReference] {
        do {
            let recordings = try speakerRepo.getRecordingsForSpeaker(uuid: speakerUUID, limit: limit)
            return recordings.map { row in
                RecordingReference(
                    id: Int(row.id),
                    title: row.title,
                    date: row.createdAt,
                    audioFilePath: row.filePath,
                    speakerDuration: row.speakerDuration
                )
            }
        } catch {
            logger.error("[SpeakerReview] Failed to get recordings: \(error)")
            return []
        }
    }
    
    // MARK: - Assignment Actions
    
    func assignToExistingSpeaker(_ speakerProfile: SpeakerProfile) {
        selectedAssignment = .existing(
            speakerUUID: speakerProfile.uuid,
            speakerName: speakerProfile.displayName
        )
    }

    /// Apply a fused calendar/voice suggestion (tapping a "From this meeting" chip or a match).
    func assignToSuggestion(_ suggestion: SpeakerSuggestion) {
        guard let speaker = currentSpeaker else { return }
        switch suggestion.kind {
        case .existingSpeaker(let uuid):
            selectedAssignment = .existing(speakerUUID: uuid, speakerName: suggestion.title)
        case .newFromAttendee(let name):
            newSpeakerName = name
            selectedAssignment = .new(name: name, notes: nil)
        }
        // Remember the attendee name so the voice↔person mapping is persisted on save.
        attendeeAssignment[speaker.tempId] = suggestion.inMeeting ? suggestion.title : nil
    }
    
    func createNewSpeaker() {
        guard !newSpeakerName.isEmpty else {
            error = "Please enter a name for the new speaker"
            return
        }
        
        selectedAssignment = .new(
            name: newSpeakerName,
            notes: newSpeakerNotes.isEmpty ? nil : newSpeakerNotes
        )
    }
    
    func skipSpeaker() {
        selectedAssignment = .skip
    }
    
    // MARK: - Audio Playback
    
    func loadAudioSegment(for segment: AudioSegment) async -> Data? {
        guard let session = session else { return nil }
        
        do {
            let audioData = try await audioExtractor.extractSegment(
                from: session.audioFilePath,
                startTime: segment.startTime,
                endTime: segment.endTime
            )
            return audioData
        } catch {
            logger.error("[SpeakerReview] Failed to extract audio segment: \(error)")
            return nil
        }
    }
    
    // MARK: - Save Assignments
    
    func saveAssignments() async -> SpeakerAssignmentResult? {
        guard var finalizedSession = session else { return nil }

        // Save current speaker's assignment
        if let speaker = currentSpeaker,
           let assignment = selectedAssignment {
            finalizedSession.assignments[speaker.tempId] = assignment
            self.session = finalizedSession
        }

        isProcessing = true

        do {
            var speakerMappings: [String: String] = [:]
            var newSpeakersCreated = 0
            var existingMatches = 0
            var skipped = 0

            let mergeHistoryRepo = SpeakerMergeHistoryRepository()

            let reviewedAt = Date()
            for (tempId, assignment) in finalizedSession.assignments {
                switch assignment {
                case .existing(let targetUUID, _):
                    if isOnDemandMode {
                        // On-demand: merge the reviewed speaker into the target
                        try speakerRepo.mergeSpeakersWithHistory(
                            primaryUUID: targetUUID,
                            secondaryUUIDs: [tempId],
                            mergeHistoryRepo: mergeHistoryRepo
                        )
                    } else {
                        // Post-transcription: just remap utterances
                        try db.write { database in
                            try database.execute(
                                sql: """
                                    UPDATE utterances SET
                                        speaker_uuid = ?,
                                        speaker_assignment_source = ?,
                                        speaker_reviewed_at = ?
                                    WHERE recording_id = ? AND speaker = ?
                                """,
                                arguments: [
                                    targetUUID,
                                    SpeakerAssignmentSource.manual.rawValue,
                                    reviewedAt,
                                    finalizedSession.recordingId,
                                    tempId
                                ]
                            )
                        }
                    }
                    speakerMappings[tempId] = targetUUID
                    existingMatches += 1

                case .new(let name, let notes):
                    if isOnDemandMode {
                        // On-demand: just rename the existing speaker (user-assigned → manual provenance,
                        // which also clears any prior inferred/rejected marker on this voice).
                        try speakerRepo.setName(uuid: tempId, name: name, source: "manual")
                        if let notes = notes, var speaker = try speakerRepo.getByUUID(tempId) {
                            speaker.notes = notes
                            try speakerRepo.update(speaker)
                        }
                        speakerMappings[tempId] = tempId
                    } else {
                        // Post-transcription: create new speaker from embedding
                        if let detectedSpeaker = finalizedSession.detectedSpeakers.first(where: { $0.tempId == tempId }),
                           !detectedSpeaker.embedding.isEmpty {
                            let newProfile = try speakerService.createSpeaker(
                                embedding: detectedSpeaker.embedding,
                                name: name,
                                metadata: notes,
                                recordingId: Int(finalizedSession.recordingId)
                            )
                            speakerMappings[tempId] = newProfile.uuid

                            // Remap utterances
                            try db.write { database in
                                try database.execute(
                                    sql: """
                                        UPDATE utterances SET
                                            speaker_uuid = ?,
                                            speaker_assignment_source = ?,
                                            speaker_reviewed_at = ?
                                        WHERE recording_id = ? AND speaker = ?
                                    """,
                                    arguments: [
                                        newProfile.uuid,
                                        SpeakerAssignmentSource.manual.rawValue,
                                        reviewedAt,
                                        finalizedSession.recordingId,
                                        tempId
                                    ]
                                )
                            }
                        } else {
                            // A reviewed voice can lack an embedding (short/noisy speech). Preserve
                            // the human label as gold even though it cannot seed global matching.
                            try db.write { database in
                                try database.execute(
                                    sql: """
                                        UPDATE utterances SET
                                            speaker = ?,
                                            speaker_assignment_source = ?,
                                            speaker_reviewed_at = ?
                                        WHERE recording_id = ? AND speaker = ?
                                    """,
                                    arguments: [
                                        name,
                                        SpeakerAssignmentSource.manual.rawValue,
                                        reviewedAt,
                                        finalizedSession.recordingId,
                                        tempId
                                    ]
                                )
                            }
                        }
                    }
                    newSpeakersCreated += 1

                case .skip:
                    if !isOnDemandMode {
                        try db.write { database in
                            try database.execute(
                                sql: """
                                    UPDATE utterances SET
                                        speaker_assignment_source = ?,
                                        speaker_reviewed_at = ?
                                    WHERE recording_id = ? AND speaker = ?
                                """,
                                arguments: [
                                    SpeakerAssignmentSource.manual.rawValue,
                                    reviewedAt,
                                    finalizedSession.recordingId,
                                    tempId
                                ]
                            )
                        }
                    }
                    skipped += 1
                }

                // Persist the voice↔attendee mapping when this assignment came from a calendar
                // chip. This finally populates speaker_attendee_mappings so the same voice
                // auto-resolves to the same person in future meetings.
                if let attendeeName = attendeeAssignment[tempId], let uuid = speakerMappings[tempId] {
                    let email = meetingAttendees.first { $0.name == attendeeName }?.email
                    // The user explicitly picked this attendee → manual (locked truth that seeds inference).
                    try? attendeeRepo.setMapping(speakerUuid: uuid, attendeeName: attendeeName, attendeeEmail: email, source: .manual)
                }
            }

            let result = SpeakerAssignmentResult(
                recordingId: finalizedSession.recordingId,
                speakerMappings: speakerMappings,
                newSpeakersCreated: newSpeakersCreated,
                existingMatches: existingMatches,
                skipped: skipped
            )

            logger.info("[SpeakerReview] Assignments saved: \(existingMatches) existing, \(newSpeakersCreated) new, \(skipped) skipped")

            try db.write { database in
                // Reviewing detected clusters is valuable provenance, but it is not whole-
                // conversation gold: individual turns can still be assigned to the wrong
                // cluster. This also invalidates older gold when the on-demand wizard changes
                // identities. Only the transcript-detail confirmation can set `.gold`.
                try SpeakerGoldReviewStore.markInProgress(
                    database,
                    recordingId: finalizedSession.recordingId,
                    reviewedAt: reviewedAt
                )
            }

            // New manual names/mappings can unlock further deductions (e.g. now-known person makes a
            // 3-person meeting a solvable 1:1) — recompute inference in the background.
            IdentityInferenceCoordinator.shared.scheduleRecompute()

            isProcessing = false
            return result

        } catch {
            logger.error("[SpeakerReview] Failed to save assignments: \(error)")
            self.error = error.localizedDescription
            isProcessing = false
            return nil
        }
    }
}

// MARK: - Async Helpers

extension Sequence {
    func asyncMap<T>(
        _ transform: (Element) async -> T
    ) async -> [T] {
        var values = [T]()
        for element in self {
            await values.append(transform(element))
        }
        return values
    }
}
