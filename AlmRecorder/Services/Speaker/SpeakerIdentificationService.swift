import Foundation
import Accelerate

/// Service for persistent speaker identification and management
class SpeakerIdentificationService {
    
    // MARK: - Types

    // SpeakerProfile is now a top-level type in Models/SpeakerProfile.swift

    struct SpeakerStats {
        let totalDuration: TimeInterval
        let utteranceCount: Int
        let averageUtteranceLength: TimeInterval
        let lastSeenDaysAgo: Int
        let recordings: [String]
    }
    
    // MARK: - Properties
    
    private let speakerRepo = GRDBSpeakerRepository()
    private let logger = VoxtralLogger.shared
    private let similarityThreshold: Float
    
    // Cache of known speakers for fast lookup
    private var speakerCache: [String: SpeakerProfile] = [:]
    private let cacheQueue = DispatchQueue(label: "speaker.cache.queue", attributes: .concurrent)
    
    // MARK: - Initialization
    
    init(
        similarityThreshold: Float = 0.85
    ) {
        self.similarityThreshold = similarityThreshold
    }
    
    // MARK: - Public Methods
    
    /// Find similar speakers in the database
    func findSimilarSpeakers(
        to embedding: [Float],
        threshold: Float = 0.7,
        limit: Int = 10
    ) throws -> [(profile: SpeakerProfile, similarity: Float)] {
        // Use GRDB repository
        let results = try speakerRepo.findSimilarSpeakers(
            to: embedding,
            threshold: threshold,
            limit: limit
        )
        
        // Convert to SpeakerProfile format
        return results.map { speaker, similarity in
            let profile = SpeakerProfile(
                id: Int(speaker.id ?? 0),
                uuid: speaker.uuid,
                name: speaker.name,
                embedding: speaker.embeddingArray,
                totalDuration: speaker.totalDuration,
                utteranceCount: speaker.utteranceCount,
                firstSeen: speaker.createdAt,
                lastSeen: speaker.lastSeenAt,
                confidence: speaker.confidence
            )
            return (profile, similarity)
        }
    }
    
    /// Create a new speaker profile
    func createSpeaker(
        embedding: [Float],
        name: String?,
        metadata: String? = nil,
        recordingId: Int? = nil,
        confidence: Float = 0.95
    ) throws -> SpeakerProfile {
        // Refuse to write a wrong-dimension vector into the identity DB. This is the guard
        // that stops the 192-dim Pyannote fallback (or any future model swap) from silently
        // orphaning speakers in the cross-recording matcher.
        try SpeakerEmbeddingPolicy.validate(embedding)

        let uuid = UUID().uuidString
        
        // Use GRDB repository
        let speakerId = try speakerRepo.create(
            uuid: uuid,
            name: name,
            embedding: embedding,
            confidence: confidence,
            notes: metadata,
            sourceRecordingId: recordingId.map(Int64.init)
        )
        
        logger.info("[SpeakerIdentification] Created new speaker profile: \(uuid)")
        
        var profile = SpeakerProfile(
            id: Int(speakerId),
            uuid: uuid,
            name: name,
            embedding: embedding,
            totalDuration: 0,
            utteranceCount: 0,
            firstSeen: Date(),
            lastSeen: Date(),
            confidence: confidence
        )
        
        // Add notes if provided
        if let metadata = metadata {
            profile.notes = metadata
        }
        
        // Update cache
        cacheQueue.sync(flags: .barrier) {
            self.speakerCache[uuid] = profile
        }
        
        return profile
    }
    
    /// Resolve a recording's per-file speaker clusters to stable cross-file UUIDs.
    ///
    /// Tuple-compatible entry point for older callers that do not have the diarizer turn timeline.
    func resolveClusters(
        _ clusters: [(label: String, embedding: [Float])],
        recordingId: Int?,
        threshold: Float? = nil,
        configuration: SpeakerPipelineConfiguration = SpeakerPipelineSettings.shared.activeConfiguration
    ) -> [String: String] {
        resolveClusters(
            clusters.map {
                SpeakerIdentityCluster(label: $0.label, embedding: $0.embedding)
            },
            recordingId: recordingId,
            threshold: threshold,
            configuration: configuration
        )
    }

    /// Each local cluster is compared with the global mean and the recording-level prototypes for
    /// every known person. The multi-prototype matcher keeps the first pass one-to-one, then permits
    /// a strongly supported identity to absorb another over-split local cluster only when the two
    /// local timelines do not overlap.
    func resolveClusters(
        _ clusters: [SpeakerIdentityCluster],
        recordingId: Int?,
        threshold: Float? = nil,
        configuration: SpeakerPipelineConfiguration = SpeakerPipelineSettings.shared.activeConfiguration
    ) -> [String: String] {
        let dim = SpeakerEmbeddingPolicy.dimension
        let valid = clusters.filter { $0.embedding.count == dim }
        guard !valid.isEmpty else { return [:] }

        let known: [SpeakerProfile] = (try? loadKnownSpeakers()) ?? []
        let eligibleUUIDs = Set(
            known.filter {
                $0.averageEmbedding.count == dim && $0.confidence >= 0.55
            }.map(\.uuid)
        )
        let durableEvidence: [SpeakerIdentityProfileEvidence] =
            (try? GRDBDatabaseManager.shared.read {
            guard try $0.tableExists("speaker_global_assignments") else {
                return [SpeakerIdentityProfileEvidence]()
            }
            return try GlobalSpeakerIdentityStore.loadProfileEvidence($0)
        }) ?? []
        let prototypesByUUID = (try? GRDBDatabaseManager.shared.read {
            try SpeakerVoicePrototypeStore.loadAll($0)
        }) ?? [:]
        let legacyEvidence = known
            .filter { eligibleUUIDs.contains($0.uuid) }
            .map {
                SpeakerIdentityProfileEvidence(
                    uuid: $0.uuid,
                    meanEmbedding: $0.averageEmbedding,
                    prototypes: prototypesByUUID[$0.uuid] ?? []
                )
            }
        let existing = durableEvidence
            .filter { eligibleUUIDs.contains($0.uuid) }
            .isEmpty
            ? legacyEvidence
            : durableEvidence.filter { eligibleUUIDs.contains($0.uuid) }

        let unifier = SpeakerUnifier(
            matchThreshold: threshold ?? configuration.identitySimilarityThreshold,
            strategy: configuration.identityMatcher,
            ambiguityMargin: configuration.identityAmbiguityMargin
        )
        let matches = unifier.assign(
            newClusters: valid,
            existing: existing
        )

        var labelToUUID: [String: String] = [:]
        var durableAssignments: [String: GlobalSpeakerIdentityStore.AssignmentInput] = [:]
        var durableCandidates: [String: [GlobalSpeakerIdentityStore.CandidateEvidence]] = [:]
        for (idx, cluster) in valid.enumerated() {
            let ranked = unifier.rankedProfileScores(for: cluster, existing: existing)
            let topMargin = ranked.count > 1
                ? ranked[0].value - ranked[1].value
                : ranked.first.map { $0.value + 1 }
            switch matches[idx] {
            case .existing(let uuid):
                labelToUUID[cluster.label] = uuid
                let winner = ranked.first { $0.uuid == uuid }
                let nextBest = ranked.first { $0.uuid != uuid }
                durableAssignments[cluster.label] = .init(
                    speakerUUID: uuid,
                    state: .automatic,
                    source: .globalAutomatic,
                    confidence: winner?.value ?? cluster.confidence,
                    score: winner?.value,
                    margin: winner.map { $0.value - (nextBest?.value ?? -1) },
                    supportingPrototypeCount: winner?.supportingPrototypeCount,
                    matcher: configuration.identityMatcher.rawValue,
                    evidenceJSON: nil
                )
            case .new:
                if let profile = try? createSpeaker(
                    embedding: cluster.embedding,
                    name: nil,
                    metadata: nil,
                    recordingId: recordingId,
                    confidence: cluster.embeddingTurnCount <= 1
                        ? cluster.confidence
                        : min(cluster.confidence, cluster.cohesion)
                ) {
                    labelToUUID[cluster.label] = profile.uuid
                    durableAssignments[cluster.label] = .init(
                        speakerUUID: profile.uuid,
                        state: .isolated,
                        source: .model,
                        confidence: cluster.embeddingTurnCount <= 1
                            ? cluster.confidence
                            : min(cluster.confidence, cluster.cohesion),
                        score: ranked.first?.value,
                        margin: topMargin,
                        supportingPrototypeCount: ranked.first?.supportingPrototypeCount,
                        matcher: configuration.identityMatcher.rawValue,
                        evidenceJSON: nil
                    )
                }
            }
            let selectedUUID = labelToUUID[cluster.label]
            durableCandidates[cluster.label] = ranked.prefix(5).enumerated().map { rank, item in
                let selected = selectedUUID == item.uuid
                let rejection: String?
                if selected {
                    rejection = nil
                } else if !cluster.isReliableForGlobalIdentity {
                    rejection = "unreliable_local_cluster"
                } else if item.value < (threshold ?? configuration.identitySimilarityThreshold) {
                    rejection = "below_similarity_threshold"
                } else if let topMargin,
                          topMargin < configuration.identityAmbiguityMargin {
                    rejection = "ambiguous_margin"
                } else {
                    rejection = "not_selected_by_global_assignment"
                }
                return .init(
                    candidateUUID: item.uuid,
                    rank: rank + 1,
                    score: item.value,
                    bestPrototypeScore: item.bestPrototype,
                    margin: rank == 0 ? topMargin : nil,
                    supportingPrototypeCount: item.supportingPrototypeCount,
                    eligible: selected,
                    rejectionReason: rejection
                )
            }
        }

        if let recordingId {
            do {
                try GRDBDatabaseManager.shared.write { db in
                    guard try db.tableExists("speaker_global_assignments") else { return }
                    try GlobalSpeakerIdentityStore.register(
                        db,
                        recordingId: Int64(recordingId),
                        clusters: valid,
                        assignments: durableAssignments,
                        candidates: durableCandidates
                    )
                }
            } catch {
                logger.warning(
                    "[SpeakerIdentification] Could not persist local/global assignment evidence: \(error)"
                )
            }
        }
        return labelToUUID
    }

    /// Load all known speakers from database into memory
    func loadKnownSpeakers() throws -> [SpeakerProfile] {
        // Use GRDB repository
        let speakers = try speakerRepo.getAll()
        
        // Convert to SpeakerProfile format
        return speakers.map { speaker in
            var profile = SpeakerProfile(
                id: Int(speaker.id ?? 0),
                uuid: speaker.uuid,
                name: speaker.name,
                embedding: speaker.embeddingArray,
                totalDuration: speaker.totalDuration,
                utteranceCount: speaker.utteranceCount,
                firstSeen: speaker.createdAt,
                lastSeen: speaker.lastSeenAt,
                confidence: speaker.confidence
            )
            
            // Add metadata if present
            if let notes = speaker.notes {
                profile.notes = notes
            }
            
            // Update cache
            cacheQueue.sync(flags: .barrier) {
                self.speakerCache[profile.uuid] = profile
            }
            
            return profile
        }
        
    }
    
    /// Save or update speaker profile in database
    func saveSpeaker(_ profile: SpeakerProfile, recordingId: Int? = nil) throws {
        
        if let existingId = profile.id {
            // Update existing speaker using GRDB
            if let existingSpeaker = try speakerRepo.getById(Int64(existingId)) {
                var updatedSpeaker = existingSpeaker
                updatedSpeaker.name = profile.name
                updatedSpeaker.embedding = profile.averageEmbedding.withUnsafeBytes { bytes in
                    Data(bytes: bytes.baseAddress!, count: bytes.count)
                }
                updatedSpeaker.totalDuration = profile.totalDuration
                updatedSpeaker.utteranceCount = profile.utteranceCount
                updatedSpeaker.lastSeenAt = profile.lastSeen
                updatedSpeaker.confidence = profile.confidence
                updatedSpeaker.notes = profile.notes
                
                try speakerRepo.update(updatedSpeaker)
            }
            
        } else {
            // Check if speaker with this UUID already exists
            if let existingSpeaker = try speakerRepo.getByUUID(profile.uuid) {
                // Update existing speaker statistics
                try speakerRepo.updateStatistics(
                    uuid: profile.uuid,
                    addDuration: profile.totalDuration,
                    addUtteranceCount: profile.utteranceCount,
                    newEmbedding: profile.averageEmbedding,
                    confidence: profile.confidence
                )
                
                // Update the profile's ID for cache
                var updatedProfile = profile
                updatedProfile.id = Int(existingSpeaker.id ?? 0)
                
                // Update cache with the correct ID
                cacheQueue.sync(flags: .barrier) {
                    self.speakerCache[profile.uuid] = updatedProfile
                }
                
                return // Exit early since we handled the update
            } else {
                // Insert new speaker
                let speakerId = try speakerRepo.create(
                    uuid: profile.uuid,
                    name: profile.name,
                    embedding: profile.averageEmbedding,
                    confidence: profile.confidence,
                    notes: profile.notes
                )
                
                // Update profile with ID
                var updatedProfile = profile
                updatedProfile.id = Int(speakerId)
                
                // Update cache
                cacheQueue.sync(flags: .barrier) {
                    self.speakerCache[profile.uuid] = updatedProfile
                }
            }
        }
    }
    
    /// Load all speakers from database into cache
    /// Merge two speakers when we discover they're the same person
    func mergeSpeakers(speaker1UUID: String, speaker2UUID: String) throws {
        guard speakerCache[speaker1UUID] != nil,
              speakerCache[speaker2UUID] != nil else {
            throw NSError(domain: "SpeakerIdentification", code: 1, 
                         userInfo: [NSLocalizedDescriptionKey: "Speaker not found"])
        }
        
        // Merge using GRDB repository
        try speakerRepo.mergeSpeakersWithHistory(
            primaryUUID: speaker1UUID,
            secondaryUUIDs: [speaker2UUID],
            mergeHistoryRepo: SpeakerMergeHistoryRepository()
        )
        
        // Update cache - reload merged speaker and remove the other
        if let mergedSpeaker = try speakerRepo.getByUUID(speaker1UUID) {
            let profile = SpeakerProfile(
                id: Int(mergedSpeaker.id ?? 0),
                uuid: mergedSpeaker.uuid,
                name: mergedSpeaker.name,
                embedding: mergedSpeaker.embeddingArray,
                totalDuration: mergedSpeaker.totalDuration,
                utteranceCount: mergedSpeaker.utteranceCount,
                firstSeen: mergedSpeaker.createdAt,
                lastSeen: mergedSpeaker.lastSeenAt,
                confidence: mergedSpeaker.confidence
            )
            
            cacheQueue.sync(flags: .barrier) {
                self.speakerCache[speaker1UUID] = profile
                self.speakerCache.removeValue(forKey: speaker2UUID)
            }
        }
        
        logger.info("[SpeakerIdentification] Merged speakers \(speaker1UUID) and \(speaker2UUID)")
    }
    
    /// Get statistics for a specific speaker
    func getSpeakerStats(speakerUUID: String) throws -> SpeakerStats? {
        guard let speaker = speakerCache[speakerUUID] else {
            return nil
        }
        
        // Get recordings where this speaker appears using GRDB
        let db = GRDBDatabaseManager.shared
        let recordings = try db.read { database in
            try String.fetchAll(database,
                sql: """
                    SELECT DISTINCT r.title
                    FROM recordings r
                    JOIN utterances u ON r.id = u.recording_id
                    WHERE u.speaker_uuid = ?
                    ORDER BY r.created_at DESC
                    LIMIT 10
                """,
                arguments: [speakerUUID]
            )
        }
        
        let daysSinceLastSeen = Calendar.current.dateComponents(
            [.day], from: speaker.lastSeen, to: Date()
        ).day ?? 0
        
        let avgLength = speaker.utteranceCount > 0 
            ? speaker.totalDuration / Double(speaker.utteranceCount) 
            : 0
        
        return SpeakerStats(
            totalDuration: speaker.totalDuration,
            utteranceCount: speaker.utteranceCount,
            averageUtteranceLength: avgLength,
            lastSeenDaysAgo: daysSinceLastSeen,
            recordings: recordings
        )
    }
    
    // MARK: - Private Methods
    
    /// Calculate cosine similarity between two embeddings
    private func calculateCosineSimilarity(_ embedding1: [Float], _ embedding2: [Float]) -> Float {
        return computeSimilarity(embedding1, embedding2)
    }
    
    private func computeSimilarity(_ embedding1: [Float], _ embedding2: [Float]) -> Float {
        guard embedding1.count == embedding2.count else { return 0.0 }
        
        var dotProduct: Float = 0
        var norm1: Float = 0
        var norm2: Float = 0
        
        vDSP_dotpr(embedding1, 1, embedding2, 1, &dotProduct, vDSP_Length(embedding1.count))
        vDSP_svesq(embedding1, 1, &norm1, vDSP_Length(embedding1.count))
        vDSP_svesq(embedding2, 1, &norm2, vDSP_Length(embedding2.count))
        
        let denominator = sqrt(norm1) * sqrt(norm2)
        return denominator > 0 ? dotProduct / denominator : 0
    }
    
    private func updateSpeakerEmbedding(
        speaker: SpeakerProfile,
        newEmbedding: [Float],
        recordingId: Int?
    ) throws -> SpeakerProfile {
        
        var updated = speaker
        
        // Update embedding using exponential moving average
        let alpha: Float = 0.9  // Weight for existing embedding
        for i in 0..<updated.averageEmbedding.count {
            updated.averageEmbedding[i] = alpha * updated.averageEmbedding[i] + 
                                          (1 - alpha) * newEmbedding[i]
        }
        
        // Normalize
        var norm: Float = 0
        vDSP_svesq(updated.averageEmbedding, 1, &norm, vDSP_Length(updated.averageEmbedding.count))
        if norm > 0 {
            var scale = 1.0 / sqrt(norm)
            vDSP_vsmul(updated.averageEmbedding, 1, &scale, 
                      &updated.averageEmbedding, 1, 
                      vDSP_Length(updated.averageEmbedding.count))
        }
        
        updated.lastSeen = Date()
        updated.utteranceCount += 1
        
        try saveSpeaker(updated, recordingId: recordingId)
        return updated
    }
    
    private func saveEmbeddingHistory(
        speakerId: Int,
        embedding: [Float],
        recordingId: Int,
        confidence: Float
    ) throws {
        // This is now handled by the GRDB repository's updateStatistics method
        // which automatically saves to speaker_embedding_history
    }
    
    private func getLastInsertedId() -> Int {
        // No longer needed with GRDB repository
        return 0
    }
    
    // MARK: - Speaker Management
    
    /// Update speaker name
    func updateSpeakerName(uuid: String, name: String) throws {
        try speakerRepo.updateName(uuid: uuid, name: name)
        
        // Update cache
        cacheQueue.sync(flags: .barrier) {
            if var speaker = self.speakerCache[uuid] {
                speaker.name = name
                self.speakerCache[uuid] = speaker
            }
        }
    }
    
    /// Delete a speaker and all associated data
    func deleteSpeaker(uuid: String) throws {
        try speakerRepo.delete(uuid: uuid)
        
        // Update cache
        _ = cacheQueue.sync(flags: .barrier) {
            self.speakerCache.removeValue(forKey: uuid)
        }
    }
    
    /// Get all speakers sorted by last seen date
    func getAllSpeakers() -> [SpeakerProfile] {
        return cacheQueue.sync {
            Array(speakerCache.values).sorted { $0.lastSeen > $1.lastSeen }
        }
    }
}
