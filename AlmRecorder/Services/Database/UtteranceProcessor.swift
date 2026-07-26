import Foundation
import AVFoundation

/// Processes transcriptions into utterances with embeddings
class UtteranceProcessor {
    private let recordingRepo = GRDBRecordingRepository()
    private let utteranceRepo = GRDBUtteranceRepository()
    private let embeddingService = EmbeddingService.shared
    private let logger = VoxtralLogger.shared
    
    /// Process a transcription into utterances with embeddings
    /// - Parameters:
    ///   - recordingId: The recording ID to associate utterances with
    ///   - transcript: The full transcript text
    ///   - audioFile: Optional audio file path for time alignment
    ///   - chunks: Optional pre-segmented chunks with speaker information
    ///   - generateEmbeddings: Whether to generate embeddings for each utterance
    ///   - queueEmbeddings: Whether to queue embeddings for background processing (true) or process immediately (false)
    func processTranscriptionIntoUtterances(
        recordingId: Int64,
        transcript: String,
        audioFile: String? = nil,
        chunks: [TranscriptionChunk]? = nil,
        generateEmbeddings: Bool = true,
        queueEmbeddings: Bool = true,
        audioSource: MeetingTrackSource = .unknown,
        replaceExisting: Bool = false,
        replacementRecording: Recording? = nil,
        speakerConfiguration: SpeakerPipelineConfiguration = SpeakerPipelineSettings.shared.activeConfiguration
    ) async throws {
        
        let startTime = Date()
        logger.info("[UtteranceProcessor] Processing transcript | recordingId=\(recordingId) transcriptLength=\(transcript.count) queueEmbeddings=\(queueEmbeddings)")

        // Split transcript into utterances - use chunks if available
        let pending: [PendingUtterance]

        if let chunks = chunks, !chunks.isEmpty {
            // Score every chunk for hallucination-likelihood (whisper token probs, text heuristics,
            // cross-chunk repetition). Junk-tier chunks are persisted soft-hidden with provenance
            // (undoable in the review inbox) instead of silently destroyed — they used to pollute
            // the transcript, semantic search, and speaker-identity inference. Every utterance
            // keeps its suspicion score + reasons for the cleanup pass to build on.
            let verdicts = TranscriptSuspicionScorer.score(chunks.map { chunk in
                TranscriptSuspicionScorer.Input(
                    text: chunk.text,
                    startTime: chunk.startTime,
                    endTime: chunk.endTime,
                    speaker: chunk.speaker,
                    meanP: chunk.tokenStats?.meanP,
                    minP: chunk.tokenStats?.minP,
                    lowFrac: chunk.tokenStats?.lowFrac
                )
            })
            let junkCount = verdicts.filter { $0.tier == .junk }.count
            if junkCount > 0 {
                logger.info("[UtteranceProcessor] Auto-hiding \(junkCount) junk chunk(s) of \(chunks.count) — kept with provenance")
            }
            pending = zip(chunks, verdicts).map { chunk, verdict in
                PendingUtterance(
                    text: chunk.text,
                    startTime: chunk.startTime,
                    endTime: chunk.endTime,
                    speaker: chunk.speaker,
                    speakerUUID: chunk.speakerUUID,
                    confidence: chunk.confidence,
                    voiceEmbedding: chunk.voiceEmbedding,
                    voiceEmbeddingQuality: chunk.voiceEmbeddingQuality,
                    speakerOverlapRatio: chunk.speakerOverlapRatio,
                    activeSpeakerCount: chunk.activeSpeakerCount,
                    overlappingSpeakerLabels: chunk.overlappingSpeakerLabels,
                    speakerAssignmentSource: chunk.speakerAssignmentSource,
                    tokenStats: chunk.tokenStats,
                    verdict: verdict
                )
            }
            let hasSpeakers = chunks.contains { $0.speaker != nil }
            let method = hasSpeakers ? "speaker-segmented" : "vad-chunks"
            logger.debug("[UtteranceProcessor] Using provided chunks | utterances=\(pending.count) method=\(method) speakers=\(hasSpeakers)")
        } else {
            // No chunks — one utterance for the whole transcript, still scored (text-only signals).
            let verdict = TranscriptSuspicionScorer.score([
                TranscriptSuspicionScorer.Input(text: transcript, startTime: 0, endTime: 0,
                                                speaker: nil, meanP: nil, minP: nil, lowFrac: nil)
            ])[0]
            pending = [PendingUtterance(text: transcript, startTime: 0, endTime: 0, speaker: nil,
                                        speakerUUID: nil, confidence: nil, voiceEmbedding: nil,
                                        voiceEmbeddingQuality: nil,
                                        speakerOverlapRatio: 0,
                                        activeSpeakerCount: 1,
                                        overlappingSpeakerLabels: [],
                                        speakerAssignmentSource: SpeakerAssignmentSource.model.rawValue,
                                        tokenStats: nil, verdict: verdict)]
            logger.debug("[UtteranceProcessor] No chunks provided | utterances=1")
        }

        // Materialize every replacement row before opening the transaction. This lets
        // re-transcription delete + insert atomically instead of exposing a half-written call.
        var utteranceRecords: [Utterance] = []
        var voiceEmbeddings: [(offset: Int, embedding: [Float])] = []
        var hidAny = false

        for (index, item) in pending.enumerated() {
            var utterance = Utterance(
                id: nil,
                recordingId: recordingId,
                utteranceIndex: index,
                startTime: item.startTime,
                endTime: item.endTime,
                speaker: item.speaker,
                speakerUuid: item.speakerUUID,
                text: item.text,
                confidence: item.confidence
            )
            utterance.asrMinP = item.tokenStats?.minP
            utterance.asrLowFrac = item.tokenStats?.lowFrac
            utterance.audioSource = audioSource.rawValue
            utterance.speakerAssignmentSource = item.speakerAssignmentSource
            utterance.voiceEmbeddingQuality = item.voiceEmbeddingQuality
            utterance.speakerOverlapRatio = item.speakerOverlapRatio
            utterance.activeSpeakerCount = max(1, item.activeSpeakerCount)
            if !item.overlappingSpeakerLabels.isEmpty,
               let data = try? JSONEncoder().encode(item.overlappingSpeakerLabels) {
                utterance.overlappingSpeakerLabelsJSON = String(
                    data: data,
                    encoding: .utf8
                )
            }
            utterance.localSpeakerLabel = item.speaker
            if let verdict = item.verdict {
                utterance.suspicion = verdict.score
                utterance.suspicionReasons = TranscriptSuspicionScorer.reasonsJSON(verdict.reasons)
                if verdict.tier == .junk {
                    utterance.isHidden = true
                    utterance.reviewStatus = UtteranceReviewStatus.autoHidden.rawValue
                    hidAny = true
                }
            }

            utteranceRecords.append(utterance)
            if let voice = item.voiceEmbedding, voice.count == VoiceEmbeddingStore.dimensions {
                voiceEmbeddings.append((offset: index, embedding: voice))
            }
        }

        let utteranceIds: [Int64]
        var carriedOver: Set<Int64> = []
        if replaceExisting {
            guard let replacementRecording else {
                throw NSError(
                    domain: "AlmRecorder.Retranscription",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Replacement recording metadata is required"]
                )
            }
            let replacement = try utteranceRepo.replaceBatchForRetranscription(
                recordingId: recordingId,
                utterances: utteranceRecords,
                voiceEmbeddings: voiceEmbeddings,
                replacementRecording: replacementRecording
            )
            utteranceIds = replacement.ids
            carriedOver = replacement.carriedOver
        } else {
            utteranceIds = try utteranceRepo.createBatch(utteranceRecords)
            try? utteranceRepo.storeVoiceEmbeddingsBatch(
                voiceEmbeddings.compactMap { item in
                    guard utteranceIds.indices.contains(item.offset) else { return nil }
                    return (utteranceId: utteranceIds[item.offset], embedding: item.embedding)
                }
            )
        }

        // Hidden junk is excluded from semantic search, so don't embed it.
        var embeddingTargets = zip(utteranceIds, pending).compactMap { id, item in
            let hidden = item.verdict?.tier == .junk
            return hidden ? nil : (id: id, text: item.text)
        }

        // Bind the freshly inserted lines to their immutable recording-local cluster rows before
        // any centroid refresh or global consolidation reads them.
        do {
            try GRDBDatabaseManager.shared.write { db in
                guard try db.tableExists("speaker_global_assignments") else { return }
                try GlobalSpeakerIdentityStore.reconcileRecording(
                    db,
                    recordingId: recordingId
                )
            }
        } catch {
            logger.warning(
                "[UtteranceProcessor] Failed to reconcile recording-local speakers: \(error)"
            )
        }

        let affectedSpeakers = Set(pending.compactMap(\.speakerUUID))
        if speakerConfiguration.updateCentroidsAfterIngest {
            let speakerRepo = GRDBSpeakerRepository()
            for uuid in affectedSpeakers {
                do {
                    try speakerRepo.recomputeMean(
                        uuid: uuid,
                        policy: speakerConfiguration.centroidPolicy
                    )
                } catch {
                    logger.warning("[UtteranceProcessor] Failed to refresh voice centroid for \(uuid): \(error)")
                }
            }
        }
        // Evidence-graph mode always performs the graph pass: it intentionally creates local
        // identities during enrollment and resolves them only after their immutable recording
        // evidence has been persisted. Prototype consensus still follows the centroid-refresh flag.
        if speakerConfiguration.identityMatcher == .evidenceGraph
            || (speakerConfiguration.identityMatcher == .prototypeConsensus
                && speakerConfiguration.updateCentroidsAfterIngest) {
            do {
                let decisions = if speakerConfiguration.identityMatcher == .evidenceGraph {
                    try GlobalSpeakerConsolidator.consolidateEvidenceGraph(
                        configuration: speakerConfiguration,
                        priorityUUIDs: affectedSpeakers
                    )
                } else {
                    try GlobalSpeakerConsolidator.consolidatePending(
                        configuration: speakerConfiguration,
                        priorityUUIDs: affectedSpeakers
                    )
                }
                for decision in decisions {
                    logger.info(
                        "[UtteranceProcessor] Auto-consolidated global voice \(decision.sourceUUID) into \(decision.targetUUID) | score=\(decision.score) margin=\(decision.margin) support=\(decision.supportingPrototypeCount)"
                    )
                }
            } catch {
                logger.warning(
                    "[UtteranceProcessor] Continuous global voice consolidation skipped: \(error)"
                )
            }
        }

        // Re-apply user decisions snapshotted before a re-transcription (hides/fixes/keeps
        // matched onto the new utterances by text + nearest time). Touched lines leave the
        // embedding batch: hidden ones shouldn't embed, corrected ones re-embed with the
        // FIXED text via maintenance.
        if !carriedOver.isEmpty {
            embeddingTargets.removeAll { carriedOver.contains($0.id) }
            logger.info("[UtteranceProcessor] Re-applied \(carriedOver.count) user decision(s) after re-transcription")
        }

        // Junk was hidden at creation → make the stored transcript match the visible lines
        // (the recording row was saved with the raw transcript before utterances existed).
        if hidAny || !carriedOver.isEmpty {
            try? utteranceRepo.rebuildFullTranscript(recordingId: recordingId)
        }

        let dbTime = Date().timeIntervalSince(startTime)
        logger.info("[UtteranceProcessor] Created utterances | count=\(utteranceIds.count) hidden=\(utteranceIds.count - embeddingTargets.count) dbTime=\(String(format: "%.2f", dbTime))s")

        // Generate embeddings if requested
        if generateEmbeddings {
            // Ensure default model is loaded
            if !EmbeddingModelManager.shared.isModelLoaded {
                logger.warning("[UtteranceProcessor] No embedding model loaded, downloading default...")
                await EmbeddingModelManager.shared.ensureDefaultModel()
            }

            if EmbeddingModelManager.shared.isModelLoaded {
                if queueEmbeddings {
                    // Queue embeddings for background processing
                    await queueEmbeddingsForProcessing(
                        recordingId: recordingId,
                        utteranceIds: embeddingTargets.map(\.id),
                        texts: embeddingTargets.map(\.text)
                    )
                } else {
                    // Process immediately
                    await generateEmbeddingsForUtterances(
                        utteranceIds: embeddingTargets.map(\.id),
                        texts: embeddingTargets.map(\.text)
                    )
                }
            } else {
                logger.error("[UtteranceProcessor] Failed to load embedding model - queuing for later processing")
                await queueEmbeddingsForProcessing(
                    recordingId: recordingId,
                    utteranceIds: embeddingTargets.map(\.id),
                    texts: embeddingTargets.map(\.text)
                )
            }
        }
    }

    /// An utterance-to-be: chunk data plus its hallucination verdict and whisper token stats.
    private struct PendingUtterance {
        let text: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let speaker: String?
        let speakerUUID: String?
        let confidence: Float?
        let voiceEmbedding: [Float]?
        let voiceEmbeddingQuality: Float?
        let speakerOverlapRatio: Float
        let activeSpeakerCount: Int
        let overlappingSpeakerLabels: [String]
        let speakerAssignmentSource: String
        let tokenStats: WhisperTokenStats?
        let verdict: TranscriptSuspicionScorer.Verdict?
    }
    
    // MARK: - Private Methods
    
    /// Split transcript into utterances based on natural boundaries
    private func splitIntoUtterances(
        transcript: String,
        audioFile: String?
    ) -> [(text: String, startTime: TimeInterval, endTime: TimeInterval, speaker: String?, speakerUUID: String?, confidence: Float?)] {
        
        var utterances: [(text: String, startTime: TimeInterval, endTime: TimeInterval, speaker: String?, speakerUUID: String?, confidence: Float?)] = []
        
        // If we have an audio file, try to get time-aligned segments
        if let audioFile = audioFile,
           let audioSegments = getAudioSegments(from: audioFile) {
            return audioSegments
        }
        
        // Otherwise, split by sentence boundaries
        let sentences = splitBySentences(transcript)
        
        // Create utterances from sentences (estimate timing)
        let averageWordsPerMinute = 150.0
        var currentTime: TimeInterval = 0.0
        
        for sentence in sentences {
            let wordCount = sentence.components(separatedBy: .whitespaces).count
            let duration = (Double(wordCount) / averageWordsPerMinute) * 60.0
            
            utterances.append((
                text: sentence,
                startTime: currentTime,
                endTime: currentTime + duration,
                speaker: nil,
                speakerUUID: nil,
                confidence: nil
            ))
            
            currentTime += duration
        }
        
        return utterances
    }
    
    /// Split text by sentence boundaries
    private func splitBySentences(_ text: String) -> [String] {
        var sentences: [String] = []
        
        // Use linguistic tagger for better sentence detection
        let tagger = NSLinguisticTagger(
            tagSchemes: [.tokenType],
            options: 0
        )
        
        tagger.string = text
        let range = NSRange(location: 0, length: text.utf16.count)
        
        var currentSentence = ""
        
        tagger.enumerateTags(in: range, unit: .sentence, scheme: .tokenType, options: [.omitWhitespace]) { _, tokenRange, _ in
            if let sentenceRange = Range(tokenRange, in: text) {
                let sentence = String(text[sentenceRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                if !sentence.isEmpty {
                    // Group short sentences together (minimum ~50 words per utterance)
                    if currentSentence.isEmpty {
                        currentSentence = sentence
                    } else {
                        let combinedWordCount = (currentSentence + " " + sentence)
                            .components(separatedBy: .whitespaces).count
                        
                        if combinedWordCount < 50 {
                            currentSentence += " " + sentence
                        } else {
                            sentences.append(currentSentence)
                            currentSentence = sentence
                        }
                    }
                }
            }
        }
        
        // Add remaining sentence
        if !currentSentence.isEmpty {
            sentences.append(currentSentence)
        }
        
        // If no sentences found, split by newlines or fixed chunks
        if sentences.isEmpty {
            sentences = text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        
        // If still no sentences, create chunks of ~100 words
        if sentences.isEmpty {
            let words = text.components(separatedBy: .whitespaces)
            var currentChunk: [String] = []
            
            for word in words {
                currentChunk.append(word)
                if currentChunk.count >= 100 {
                    sentences.append(currentChunk.joined(separator: " "))
                    currentChunk = []
                }
            }
            
            if !currentChunk.isEmpty {
                sentences.append(currentChunk.joined(separator: " "))
            }
        }
        
        return sentences
    }
    
    /// Get time-aligned segments from audio file (if VAD data available)
    private func getAudioSegments(from audioFile: String) -> [(text: String, startTime: TimeInterval, endTime: TimeInterval, speaker: String?, speakerUUID: String?, confidence: Float?)]? {
        // This would integrate with VADAudioSplitter if we have time-aligned data
        // For now, return nil to use text-based splitting
        return nil
    }
    
    /// Queue embeddings for background processing
    private func queueEmbeddingsForProcessing(
        recordingId: Int64,
        utteranceIds: [Int64],
        texts: [String]
    ) async {
        guard let recording = try? recordingRepo.getById(recordingId) else {
            logger.error("[UtteranceProcessor] Recording not found | recordingId=\(recordingId)")
            return
        }
        
        logger.info("[UtteranceProcessor] Queueing embeddings | recordingId=\(recordingId) utterances=\(texts.count)")
        
        // Create utterance data for the job
        let utteranceData = zip(utteranceIds, texts).map { (id: $0, text: $1) }
        
        // Add job to embedding queue with normal priority for new recordings
        _ = await MainActor.run {
            EmbeddingQueueManager.shared.addJob(
                recordingId: recordingId,
                recordingTitle: recording.title,
                utteranceData: utteranceData,
                priority: .normal
            )
        }
        
        logger.debug("[UtteranceProcessor] Embeddings queued | recording=\(recording.title) priority=normal")
    }
    
    /// Generate embeddings for utterances immediately (synchronous processing)
    private func generateEmbeddingsForUtterances(
        utteranceIds: [Int64],
        texts: [String]
    ) async {
        let embeddingStartTime = Date()
        logger.info("[UtteranceProcessor] Generating embeddings synchronously | utterances=\(texts.count)")
        
        do {
            // Generate embeddings in batch
            let embeddings = try await embeddingService.generateEmbeddings(for: texts)

            // Store only successful embeddings; nils are failures that stay unembedded
            // (has_embedding=0) so they are retried, instead of being poisoned with zeros.
            let embeddingPairs: [(utteranceId: Int64, embedding: Data)] = zip(utteranceIds, embeddings).compactMap { id, embedding in
                guard let embedding else { return nil }
                return (id, embedding)
            }
            try utteranceRepo.storeEmbeddingsBatch(embeddingPairs)

            let embeddingTime = Date().timeIntervalSince(embeddingStartTime)
            let failed = embeddings.count - embeddingPairs.count
            logger.info("[UtteranceProcessor] Embeddings stored | stored=\(embeddingPairs.count) failed=\(failed) time=\(String(format: "%.2f", embeddingTime))s")
            
        } catch {
            logger.error("[UtteranceProcessor] Failed to generate embeddings | error=\(error.localizedDescription)")
            // Continue without embeddings - they can be generated later
        }
    }
    
    // MARK: - Public Utilities
    
    /// Process a TranscriptionResult directly (with speaker information)
    func processTranscriptionResult(
        recordingId: Int64,
        result: TranscriptionResult,
        generateEmbeddings: Bool = true,
        queueEmbeddings: Bool = true
    ) async throws {
        
        logger.info("[UtteranceProcessor] Processing TranscriptionResult | recordingId=\(recordingId) chunks=\(result.chunks.count) hasVAD=\(result.usedVAD)")
        
        // If we have chunks with speaker information, use them directly
        if !result.chunks.isEmpty {
            try await processTranscriptionIntoUtterances(
                recordingId: recordingId,
                transcript: result.fullTranscript,
                audioFile: nil,
                chunks: result.chunks,
                generateEmbeddings: generateEmbeddings,
                queueEmbeddings: queueEmbeddings
            )
            
            // Log speaker statistics if available
            let speakerChunks = result.chunks.filter { $0.speaker != nil }
            if !speakerChunks.isEmpty {
                let speakers = Set(speakerChunks.compactMap { $0.speaker })
                logger.info("[UtteranceProcessor] Speaker statistics | speakers=\(speakers.count) segments=\(speakerChunks.count)")
                
                for speaker in speakers {
                    let speakerSegments = speakerChunks.filter { $0.speaker == speaker }
                    let totalDuration = speakerSegments.reduce(0.0) { sum, chunk in
                        sum + (chunk.endTime - chunk.startTime)
                    }
                    logger.debug("[UtteranceProcessor] \(speaker): \(speakerSegments.count) segments, \(String(format: "%.1f", totalDuration))s total")
                }
            }
        } else {
            // Fall back to text-only processing
            try await processTranscriptionIntoUtterances(
                recordingId: recordingId,
                transcript: result.fullTranscript,
                audioFile: nil,
                chunks: nil,
                generateEmbeddings: generateEmbeddings,
                queueEmbeddings: queueEmbeddings
            )
        }

        // New voices/utterances landed → refresh speaker-identity inference (owner detection + cross-meeting
        // matching) in the background.
        IdentityInferenceCoordinator.shared.scheduleRecompute()
    }

    /// Process all recordings without utterances
    func processUnprocessedRecordings() async {
        do {
            let allRecordings = try recordingRepo.getAll()
            
            for recording in allRecordings {
                guard let recordingId = recording.id,
                      let transcript = recording.fullTranscript,
                      !transcript.isEmpty else {
                    continue
                }
                
                // Check if utterances already exist (hidden ones count — a recording whose every
                // line was auto-hidden junk is still processed, not re-processed into duplicates).
                let existingUtterances = try utteranceRepo.getByRecording(id: recordingId, includeHidden: true)
                if !existingUtterances.isEmpty {
                    continue
                }
                
                logger.debug("[UtteranceProcessor] Processing unprocessed recording | fileName=\(recording.fileName) recordingId=\(recordingId)")
                
                try await processTranscriptionIntoUtterances(
                    recordingId: recordingId,
                    transcript: transcript,
                    audioFile: recording.filePath,
                    generateEmbeddings: true
                )
            }
            
        } catch {
            logger.error("[UtteranceProcessor] Error processing recordings | error=\(error.localizedDescription)")
        }
    }
    
    /// Generate missing embeddings for existing utterances
    func generateMissingEmbeddings(queueForBackground: Bool = true) async {
        guard EmbeddingModelManager.shared.isModelLoaded else {
            logger.warning("[UtteranceProcessor] No embedding model loaded - cannot generate missing embeddings")
            return
        }
        
        do {
            let totalUtterances = try utteranceRepo.count()
            let utterancesWithEmbeddings = try utteranceRepo.countWithEmbeddings()
            
            let missing = totalUtterances - utterancesWithEmbeddings
            if missing == 0 {
                logger.info("[UtteranceProcessor] All utterances have embeddings | total=\(totalUtterances)")
                return
            }
            
            logger.info("[UtteranceProcessor] Found missing embeddings | missing=\(missing) total=\(totalUtterances) coverage=\(String(format: "%.1f", Double(utterancesWithEmbeddings)/Double(totalUtterances)*100))%")
            
            // Get all recordings with missing embeddings
            let recordings = try recordingRepo.getAll()
            
            for recording in recordings {
                guard let recordingId = recording.id else { continue }
                
                // Get utterances for this recording
                let utterances = try utteranceRepo.getByRecording(id: recordingId)
                
                // Filter utterances without embeddings (hasEmbedding is set by the LEFT JOIN in getByRecording).
                // Skip empty-text utterances — they can never embed, so queuing them just produces jobs
                // that fail and retry forever (e.g. near-silent meeting clips).
                let utterancesNeedingEmbeddings = utterances.filter {
                    !$0.hasEmbedding && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                
                if !utterancesNeedingEmbeddings.isEmpty {
                    let utteranceData = utterancesNeedingEmbeddings.compactMap { utterance -> (id: Int64, text: String)? in
                        guard let id = utterance.id else { return nil }
                        return (id: id, text: utterance.text)
                    }
                    
                    if queueForBackground {
                        // Queue for background processing with low priority
                        _ = await MainActor.run {
                            EmbeddingQueueManager.shared.addJob(
                                recordingId: recordingId,
                                recordingTitle: recording.title,
                                utteranceData: utteranceData,
                                priority: .low
                            )
                        }
                    } else {
                        // Process immediately
                        await generateEmbeddingsForUtterances(
                            utteranceIds: utteranceData.map { $0.id },
                            texts: utteranceData.map { $0.text }
                        )
                    }
                }
            }
            
            logger.info("[UtteranceProcessor] Queued missing embeddings | queueForBackground=\(queueForBackground)")
            
        } catch {
            logger.error("[UtteranceProcessor] Error generating missing embeddings | error=\(error.localizedDescription)")
        }
    }
}
