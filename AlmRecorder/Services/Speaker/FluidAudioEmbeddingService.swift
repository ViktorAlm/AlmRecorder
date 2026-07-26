import Foundation
import FluidAudio
import AVFoundation
import Accelerate

/// Service for extracting speaker embeddings using FluidAudio's CoreML models
class FluidAudioEmbeddingService {
    
    // MARK: - Types
    
    enum EmbeddingError: LocalizedError {
        case initializationFailed(String)
        case audioLoadFailed(String)
        case embeddingExtractionFailed(String)
        case invalidAudioFormat
        
        var errorDescription: String? {
            switch self {
            case .initializationFailed(let error):
                return "Failed to initialize FluidAudio: \(error)"
            case .audioLoadFailed(let error):
                return "Failed to load audio: \(error)"
            case .embeddingExtractionFailed(let error):
                return "Failed to extract embedding: \(error)"
            case .invalidAudioFormat:
                return "Invalid audio format - must be 16kHz mono"
            }
        }
    }
    
    // Use the common SpeakerEmbedding from SpeakerEmbeddingProtocol.swift
    
    // MARK: - Properties
    
    private var diarizer: DiarizerManager?
    private var targetedSortformer: OfflineSortformerDiarizer?
    private let defaultConfiguration: SpeakerPipelineConfiguration
    private let logger = VoxtralLogger.shared
    private let sampleRate: Double = 16000
    
    // MARK: - Initialization
    
    init(configuration: SpeakerPipelineConfiguration = SpeakerPipelineSettings.shared.activeConfiguration) async throws {
        self.defaultConfiguration = configuration
        logger.info("[FluidAudioEmbedding] === INITIALIZATION START ===")
        logger.info("[FluidAudioEmbedding] Initializing FluidAudio speaker embedding service")
        Self.configureFluidAudioModelRegistry(logger: logger)
        
        do {
            guard configuration.diarizationBackend != .offlineVBx,
                  configuration.diarizationBackend != .offlineVBxTargetedSortformer else {
                logger.info("[FluidAudioEmbedding] Offline speaker pipeline selected; legacy model loading deferred")
                logger.info("[FluidAudioEmbedding] === INITIALIZATION COMPLETE ===")
                return
            }
            // Download models if needed
            logger.info("[FluidAudioEmbedding] Downloading models if needed...")
            let startTime = Date()
            let downloadedModels = try await DiarizerModels.downloadIfNeeded()
            let downloadTime = Date().timeIntervalSince(startTime)
            logger.info("[FluidAudioEmbedding] Model download/check completed in \(String(format: "%.2f", downloadTime))s")
            
            // Initialize diarizer
            let manager = DiarizerManager(config: DiarizerConfig(
                clusteringThreshold: configuration.streamingClusteringThreshold
            ))
            
            logger.info("[FluidAudioEmbedding] Initializing diarizer with models...")
            manager.initialize(models: downloadedModels)
            diarizer = manager
            logger.info("[FluidAudioEmbedding] ✅ FluidAudio initialized successfully")
            logger.info("[FluidAudioEmbedding] === INITIALIZATION COMPLETE ===")
            
        } catch {
            logger.error("[FluidAudioEmbedding] === INITIALIZATION FAILED ===")
            logger.error("[FluidAudioEmbedding] Error type: \(type(of: error))")
            logger.error("[FluidAudioEmbedding] Error: \(error)")
            logger.error("[FluidAudioEmbedding] Error description: \(error.localizedDescription)")
            logger.error("[FluidAudioEmbedding] === END INITIALIZATION FAILED ===")
            throw EmbeddingError.initializationFailed(error.localizedDescription)
        }
    }
    
    // MARK: - Public Methods
    
    /// Extract speaker embedding from audio file
    func extractEmbedding(from audioURL: URL) async throws -> SpeakerEmbedding {
        logger.info("[FluidAudioEmbedding] === EMBEDDING EXTRACTION START ===")
        logger.info("[FluidAudioEmbedding] Audio file: \(audioURL.path)")
        logger.info("[FluidAudioEmbedding] File name: \(audioURL.lastPathComponent)")
        
        // Check file existence and size
        if let attrs = try? FileManager.default.attributesOfItem(atPath: audioURL.path) {
            let size = (attrs[.size] as? Int64 ?? 0) / 1024
            logger.info("[FluidAudioEmbedding] File size: \(size)KB")
        } else {
            logger.warning("[FluidAudioEmbedding] Could not get file attributes")
        }
        
        // Load audio
        let loadStartTime = Date()
        let audioData = try await loadAudio(from: audioURL)
        let loadTime = Date().timeIntervalSince(loadStartTime)
        logger.info("[FluidAudioEmbedding] Audio loaded in \(String(format: "%.2f", loadTime))s")
        logger.info("[FluidAudioEmbedding] Audio duration: \(String(format: "%.2f", audioData.duration))s")
        logger.info("[FluidAudioEmbedding] Sample count: \(audioData.samples.count)")
        
        // The offline pipeline does not expose its embedding model directly. Lazily prepare the
        // legacy extractor only for callers that explicitly request a standalone embedding.
        try await ensureLegacyDiarizer(
            clusteringThreshold: defaultConfiguration.streamingClusteringThreshold
        )
        
        do {
            // Extract real embeddings using FluidAudio's models
            let extractStartTime = Date()
            let embedding = try await extractRealEmbeddings(from: audioData.samples)
            let extractTime = Date().timeIntervalSince(extractStartTime)
            
            logger.info("[FluidAudioEmbedding] Embedding extracted in \(String(format: "%.2f", extractTime))s")
            logger.info("[FluidAudioEmbedding] Embedding size: \(embedding.count) floats")
            logger.info("[FluidAudioEmbedding] === EMBEDDING EXTRACTION COMPLETE ===")
            
            return SpeakerEmbedding(
                vector: embedding,
                audioPath: audioURL.path,
                duration: audioData.duration,
                confidence: 0.95  // FluidAudio has high confidence with real models
            )
            
        } catch {
            logger.error("[FluidAudioEmbedding] === EXTRACTION FAILED ===")
            logger.error("[FluidAudioEmbedding] Audio file: \(audioURL.path)")
            logger.error("[FluidAudioEmbedding] Error type: \(type(of: error))")
            logger.error("[FluidAudioEmbedding] Error: \(error)")
            logger.error("[FluidAudioEmbedding] Audio duration: \(audioData.duration)s")
            logger.error("[FluidAudioEmbedding] Sample count: \(audioData.samples.count)")
            logger.error("[FluidAudioEmbedding] === END EXTRACTION FAILED ===")
            throw EmbeddingError.embeddingExtractionFailed(error.localizedDescription)
        }
    }
    
    /// Compare two embeddings for similarity
    func similarity(_ embedding1: [Float], _ embedding2: [Float]) -> Float {
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
    
    /// Check if two embeddings are from the same speaker
    func isSameSpeaker(_ embedding1: [Float], _ embedding2: [Float], threshold: Float = 0.85) -> Bool {
        return similarity(embedding1, embedding2) >= threshold
    }

    /// Full-file diarization using either the original streaming engine or FluidAudio's newer
    /// offline community-1 + VBx pipeline. The selected backend is an explicit argument so the
    /// evaluator can run every profile over exactly the same audio.
    func diarize(
        _ audioURL: URL,
        configuration: SpeakerPipelineConfiguration? = nil
    ) async throws -> [DiarizationTurn] {
        try await diarizeDetailed(audioURL, configuration: configuration).turns
    }

    func diarizeDetailed(
        _ audioURL: URL,
        configuration: SpeakerPipelineConfiguration? = nil,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> SpeakerDiarizationRun {
        let configuration = configuration ?? defaultConfiguration
        let startedAt = Date()

        switch configuration.diarizationBackend {
        case .legacyStreaming, .segmentDBSCAN:
            // The manager is configured at initialization. Create a threshold-specific manager
            // when an evaluator asks this instance to run a different streaming configuration.
            let manager: DiarizerManager
            if configuration.streamingClusteringThreshold == defaultConfiguration.streamingClusteringThreshold {
                try await ensureLegacyDiarizer(
                    clusteringThreshold: configuration.streamingClusteringThreshold
                )
                guard let diarizer else {
                    throw EmbeddingError.initializationFailed("Diarizer not initialized")
                }
                manager = diarizer
            } else {
                let downloadedModels = try await DiarizerModels.downloadIfNeeded()
                manager = DiarizerManager(config: DiarizerConfig(
                    clusteringThreshold: configuration.streamingClusteringThreshold
                ))
                manager.initialize(models: downloadedModels)
            }

            let audio = try await loadAudio(from: audioURL)
            let result = try manager.performCompleteDiarization(
                audio.samples,
                sampleRate: Int(sampleRate)
            )
            return SpeakerDiarizationRun(
                turns: Self.turns(from: result),
                wallClockSeconds: Date().timeIntervalSince(startedAt),
                stageTimings: result.timings.map(Self.stageTimings)
            )

        case .offlineVBx, .offlineVBxTargetedSortformer:
            var offline = OfflineDiarizerConfig.default
            // Community-1/VBx produces a regular (possibly overlapping) diarization. FluidAudio's
            // default converts it to an exclusive timeline, permanently throwing simultaneous
            // speech away. Preserve the regular timeline here; SpeakerAlignment still chooses one
            // primary display speaker while carrying overlap evidence beside it.
            offline.postProcessing.exclusiveSegments = false
            offline.clustering.threshold = configuration.offlineClusteringThreshold
            offline.segmentation.stepRatio = configuration.offlineStepRatio
            offline.embedding.minSegmentDurationSeconds = configuration.offlineMinimumSegmentDuration
            offline.zeroVoteReembed = .init(
                enabled: configuration.enableZeroVoteReembedding,
                minDurationSeconds: 0.4
            )
            offline.exposeChunkEmbeddings = true
            offline = offline.withSpeakers(
                min: configuration.minimumSpeakers,
                max: configuration.maximumSpeakers
            )

            let manager = OfflineDiarizerManager(config: offline)
            let result = try await manager.process(audioURL, progressCallback: progress)
            return SpeakerDiarizationRun(
                turns: Self.turns(from: result),
                wallClockSeconds: Date().timeIntervalSince(startedAt),
                stageTimings: result.timings.map(Self.stageTimings)
            )
        }
    }

    /// Aim short Sortformer windows at recording-local utterance spans after the full-file VBx pass. Sortformer
    /// supplies local segmentation/overlap; 256-dim WeSpeaker embeddings map its four window-local
    /// slots back onto stable recording-local labels before the global identity matcher runs.
    func repairWithTargetedSortformer(
        _ audioURL: URL,
        baseline: SpeakerDiarizationRun,
        targetSegments: [WhisperTimedSegment],
        configuration: SpeakerPipelineConfiguration? = nil
    ) async throws -> SpeakerDiarizationRun {
        let configuration = configuration ?? defaultConfiguration
        guard configuration.diarizationBackend == .offlineVBxTargetedSortformer else {
            return baseline
        }

        let repairStartedAt = Date()
        let audio = try await loadAudio(from: audioURL)
        let windows = TargetedSortformerRepair.windows(
            for: targetSegments,
            audioDuration: audio.duration
        )
        guard !windows.isEmpty else { return baseline }

        let sortformer = try await ensureTargetedSortformer()
        var repairedTurns = baseline.turns
        let originalBaselineEmbeddings = Dictionary(
            uniqueKeysWithValues: SpeakerAlignment.clusterEmbeddings(
                from: baseline.turns,
                policy: configuration.centroidPolicy
            ).map { ($0.speaker, $0.embedding) }
        )
        var voiceProfiles = Dictionary(
            uniqueKeysWithValues: originalBaselineEmbeddings.map {
                // Use the baseline centroid as the initial window-mapping hint. Clean Sortformer
                // observations may refine this temporary mapper, but an existing VBx identity's
                // full-call prototype remains the enrollment embedding emitted below.
                ($0.key, RepairVoiceProfile(embedding: $0.value, observations: 0))
            }
        )
        var nextRepairSpeaker = 1
        var identitySampleWindowCount: [String: Int] = [:]
        var acceptedTargetCount = 0
        var mixedTargetCount = 0

        for (windowIndex, window) in windows.enumerated() {
            try Task.checkCancellation()
            let samples = Self.samples(
                from: audio.samples,
                sampleRate: Int(sampleRate),
                ranges: [window.start..<window.end],
                maximumCount: Int((window.end - window.start) * sampleRate)
            )
            guard !samples.isEmpty else { continue }

            let timeline = try sortformer.processComplete(
                samples,
                sourceSampleRate: sampleRate
            )
            let localTurns = timeline.speakers.values.flatMap { speaker in
                speaker.finalizedSegments.map {
                    TargetedSortformerRepair.LocalTurn(
                        speakerIndex: speaker.index,
                        start: window.start + TimeInterval($0.startTime),
                        end: min(window.end, window.start + TimeInterval($0.endTime)),
                        activity: $0.activity
                    )
                }
            }.filter { $0.end > $0.start }

            let acceptedTargets = window.targets.filter {
                TargetedSortformerRepair.hasMaterialSpeaker(target: $0, turns: localTurns)
            }
            guard !acceptedTargets.isEmpty else { continue }
            acceptedTargetCount += acceptedTargets.count
            mixedTargetCount += acceptedTargets.filter {
                TargetedSortformerRepair.shouldRepair(target: $0, turns: localTurns)
            }.count

            let activeSlots = Set(
                acceptedTargets.flatMap {
                    TargetedSortformerRepair.meaningfulSpeakerIndices(
                        in: $0,
                        turns: localTurns
                    )
                }
            )
            guard !activeSlots.isEmpty else { continue }

            // The embedding extractor is loaded only after Sortformer has found a real repair,
            // avoiding the extra model cost on clean calls.
            try await ensureLegacyDiarizer(
                clusteringThreshold: configuration.streamingClusteringThreshold
            )

            var slotEmbeddings: [Int: [Float]] = [:]
            var slotExclusiveSpans: [Int: [Range<TimeInterval>]] = [:]
            for slot in activeSlots.sorted() {
                let spans = TargetedSortformerRepair.exclusiveSpans(
                    for: slot,
                    turns: localTurns,
                    within: window.start..<window.end
                )
                slotExclusiveSpans[slot] = spans
                let cleanSamples = Self.samples(
                    from: audio.samples,
                    sampleRate: Int(sampleRate),
                    ranges: spans,
                    maximumCount: 94_240
                )
                guard cleanSamples.count >= Int(sampleRate * 0.24) else { continue }
                if let embedding = try? await extractRealEmbeddings(from: cleanSamples) {
                    slotEmbeddings[slot] = embedding
                }
            }

            let slotLabels = Self.mapSortformerSlots(
                activeSlots,
                localTurns: localTurns,
                targets: acceptedTargets,
                baseline: repairedTurns,
                embeddings: slotEmbeddings,
                profiles: &voiceProfiles,
                nextRepairSpeaker: &nextRepairSpeaker,
                minimumVoiceSimilarity: max(
                    0.55,
                    min(0.68, configuration.identitySimilarityThreshold)
                ),
                minimumVoiceMargin: 0.04
            )

            var emittedIdentityInWindow: Set<String> = []
            for target in acceptedTargets {
                let meaningful = Set(
                    TargetedSortformerRepair.meaningfulSpeakerIndices(
                        in: target,
                        turns: localTurns
                    )
                )
                var replacements: [DiarizationTurn] = []
                for local in TargetedSortformerRepair.localTurns(localTurns, in: target)
                    where meaningful.contains(local.speakerIndex) {
                    guard let label = slotLabels[local.speakerIndex] else { continue }
                    let isBaselineIdentity = originalBaselineEmbeddings[label] != nil
                    let embedding = originalBaselineEmbeddings[label]
                        ?? slotEmbeddings[local.speakerIndex]
                        ?? voiceProfiles[label]?.embedding
                        ?? []
                    var samplesForIdentity: [SpeakerIdentityEmbeddingSample] = []
                    if !isBaselineIdentity,
                       !embedding.isEmpty,
                       !emittedIdentityInWindow.contains(label),
                       identitySampleWindowCount[label, default: 0] < 4,
                       let spans = slotExclusiveSpans[local.speakerIndex],
                       !spans.isEmpty {
                        samplesForIdentity = spans.map {
                            SpeakerIdentityEmbeddingSample(
                                embedding: embedding,
                                start: $0.lowerBound,
                                end: $0.upperBound,
                                qualityScore: max(0.05, local.activity)
                            )
                        }
                        emittedIdentityInWindow.insert(label)
                        identitySampleWindowCount[label, default: 0] += 1
                    }
                    replacements.append(DiarizationTurn(
                        speaker: label,
                        start: local.start,
                        end: local.end,
                        embedding: embedding,
                        qualityScore: max(0.05, local.activity),
                        identityEmbeddingSamples: samplesForIdentity,
                        acousticSpeaker: "sortformer:\(windowIndex):\(local.speakerIndex)"
                    ))
                }
                repairedTurns = TargetedSortformerRepair.replacing(
                    baseline: repairedTurns,
                    target: target,
                    with: replacements
                )
            }
        }

        let repairLabels = Set(repairedTurns.map(\.speaker).filter { $0.hasPrefix("SF") })
        var unconfirmedAliases: [String: String] = [:]
        for label in repairLabels {
            let labelTurns = repairedTurns.filter { $0.speaker == label }
            let observedDuration = labelTurns.reduce(0.0) {
                $0 + max(0, $1.end - $1.start)
            }
            let hasRepeatedSupport =
                identitySampleWindowCount[label, default: 0] >= 3
                && observedDuration >= 8
            guard !hasRepeatedSupport else { continue }

            let overlapByBaseline = Dictionary(grouping: baseline.turns, by: \.speaker)
                .mapValues { baselineTurns in
                    labelTurns.reduce(0.0) { total, repairTurn in
                        total + baselineTurns.reduce(0.0) { subtotal, baselineTurn in
                            subtotal + max(
                                0,
                                min(repairTurn.end, baselineTurn.end)
                                    - max(repairTurn.start, baselineTurn.start)
                            )
                        }
                    }
                }
            if let anchor = overlapByBaseline.max(by: {
                $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key
            }), anchor.value >= 0.24 {
                unconfirmedAliases[label] = anchor.key
            }
        }
        repairedTurns = TargetedSortformerRepair.remappingSpeakers(
            in: repairedTurns,
            aliases: unconfirmedAliases,
            anchorEmbeddings: originalBaselineEmbeddings
        )
        repairedTurns = TargetedSortformerRepair.restoringBaselineIdentityEvidence(
            in: repairedTurns,
            from: baseline.turns
        )

        let plannedTargetCount = windows.reduce(0) { $0 + $1.targets.count }
        logger.info(
            "[TargetedSortformer] repaired \(acceptedTargetCount)/\(plannedTargetCount) planned "
                + "targets from \(targetSegments.count) utterances "
                + "(\(mixedTargetCount) contained multiple voices) across "
                + "\(windows.count) context windows; retained "
                + "\(repairLabels.count - unconfirmedAliases.count) repeated new voices and "
                + "anchored \(unconfirmedAliases.count) short acoustic slots"
        )
        return SpeakerDiarizationRun(
            turns: repairedTurns,
            wallClockSeconds: baseline.wallClockSeconds
                + Date().timeIntervalSince(repairStartedAt),
            stageTimings: baseline.stageTimings
        )
    }

    // MARK: - Private Methods

    struct RepairVoiceProfile {
        var embedding: [Float]
        var observations: Int
    }

    /// FluidAudio also reads the very generic `REGISTRY_URL` environment variable. That name is
    /// commonly set to a Docker/ECR registry (and may not even be an HTTP URL), which can silently
    /// redirect or break every Hugging Face model download. AlmRecorder deliberately owns a
    /// narrower override and otherwise uses the public FluidInference registry.
    static func fluidAudioModelRegistryBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        guard let override = environment["ALMREC_MODEL_REGISTRY_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty,
            let components = URLComponents(string: override),
            let scheme = components.scheme?.lowercased(),
            (scheme == "https" || scheme == "http"),
            components.host != nil
        else {
            return "https://huggingface.co"
        }
        return override.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func configureFluidAudioModelRegistry(logger: VoxtralLogger) {
        let baseURL = fluidAudioModelRegistryBaseURL()
        if ProcessInfo.processInfo.environment["REGISTRY_URL"] != nil,
            ProcessInfo.processInfo.environment["ALMREC_MODEL_REGISTRY_URL"] == nil
        {
            logger.info(
                "[FluidAudioEmbedding] Ignoring unrelated REGISTRY_URL; "
                    + "model downloads use \(baseURL)"
            )
        }
        ModelRegistry.baseURL = baseURL
    }

    private func ensureTargetedSortformer() async throws -> OfflineSortformerDiarizer {
        if let targetedSortformer { return targetedSortformer }

        var timeline = DiarizerTimelineConfig.sortformerDefault
        timeline.onsetThreshold = 0.64
        timeline.offsetThreshold = 0.74
        timeline.onsetPadSeconds = 0.08
        timeline.minDurationOn = 0.16
        timeline.minDurationOff = 0.16
        let sortformer = OfflineSortformerDiarizer(
            config: .offlineV2_1,
            timelineConfig: timeline
        )
        logger.info("[TargetedSortformer] Loading offline CoreML model")
        try await sortformer.initializeFromHuggingFace()
        targetedSortformer = sortformer
        return sortformer
    }

    static func mapSortformerSlots(
        _ slots: Set<Int>,
        localTurns: [TargetedSortformerRepair.LocalTurn],
        targets: [TargetedSortformerRepair.Target],
        baseline: [DiarizationTurn],
        embeddings: [Int: [Float]],
        profiles: inout [String: RepairVoiceProfile],
        nextRepairSpeaker: inout Int,
        minimumVoiceSimilarity: Float,
        minimumVoiceMargin: Float
    ) -> [Int: String] {
        let targetRanges = targets.map(\.range)
        let slotDurations = Dictionary(
            uniqueKeysWithValues: slots.map { slot in
                let duration = localTurns
                    .filter { turn in
                        turn.speakerIndex == slot
                            && targetRanges.contains(where: { range in
                                min(range.upperBound, turn.end)
                                    > max(range.lowerBound, turn.start)
                            })
                    }
                    .reduce(0.0) { partial, turn in
                        partial + targetRanges.reduce(0.0) { rangeTotal, range in
                            rangeTotal + max(
                                0,
                                min(range.upperBound, turn.end)
                                    - max(range.lowerBound, turn.start)
                            )
                        }
                    }
                return (slot, duration)
            }
        )

        var result: [Int: String] = [:]
        var usedLabels: Set<String> = []
        for slot in slots.sorted(by: {
            let left = slotDurations[$0] ?? 0
            let right = slotDurations[$1] ?? 0
            return left != right ? left > right : $0 < $1
        }) {
            let embedding = embeddings[slot]
            let available = profiles.filter { !usedLabels.contains($0.key) }
            let ranked = available.compactMap { label, profile -> (String, Float)? in
                guard let embedding,
                      embedding.count == profile.embedding.count else { return nil }
                return (label, SpeakerUnifier.cosine(embedding, profile.embedding))
            }.sorted {
                $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0
            }

            // Calculate temporal evidence before filtering used labels. If two Sortformer slots
            // both live inside one VBx cluster, only the dominant slot may inherit that cluster;
            // the second must not quietly fall through to an unrelated label with tiny overlap.
            var temporal: [(String, TimeInterval)] = []
            for (label, turns) in Dictionary(grouping: baseline, by: \.speaker) {
                var overlap: TimeInterval = 0
                for local in localTurns where local.speakerIndex == slot {
                    for turn in turns {
                        overlap += max(
                            0,
                            min(turn.end, local.end) - max(turn.start, local.start)
                        )
                    }
                }
                temporal.append((label, overlap))
            }
            temporal.sort {
                $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0
            }
            let temporalTotal = temporal.reduce(0.0) { $0 + $1.1 }
            let bestTemporal = temporal.first
            let temporalShare = bestTemporal.map {
                $0.1 / max(0.0001, temporalTotal)
            } ?? 0

            let bestRanked = ranked.first
            let rankedMargin = bestRanked.map {
                $0.1 - (ranked.dropFirst().first?.1 ?? -1)
            } ?? 0
            var label: String
            if let best = bestTemporal,
               !usedLabels.contains(best.0),
               best.1 >= 0.24,
               temporalShare >= 0.55 {
                // Sortformer is repairing boundaries, not discarding strong VBx identity
                // evidence. A single material slot should therefore keep the local VBx label
                // even when its short-window embedding is noisy.
                label = best.0
            } else if let best = bestRanked,
               best.1 >= minimumVoiceSimilarity,
               rankedMargin >= minimumVoiceMargin {
                label = best.0
            } else {
                repeat {
                    label = "SF\(nextRepairSpeaker)"
                    nextRepairSpeaker += 1
                } while profiles[label] != nil || usedLabels.contains(label)
            }

            result[slot] = label
            usedLabels.insert(label)
            if let embedding {
                if var profile = profiles[label],
                   profile.observations > 0,
                   profile.embedding.count == embedding.count {
                    profile.embedding = Self.normalizedAverage(
                        profile.embedding,
                        count: profile.observations,
                        with: embedding
                    )
                    profile.observations += 1
                    profiles[label] = profile
                } else {
                    profiles[label] = RepairVoiceProfile(
                        embedding: VoiceMath.normalized(embedding),
                        observations: 1
                    )
                }
            }
        }
        return result
    }

    private static func normalizedAverage(
        _ existing: [Float],
        count: Int,
        with incoming: [Float]
    ) -> [Float] {
        guard existing.count == incoming.count, !existing.isEmpty else {
            return VoiceMath.normalized(incoming)
        }
        let oldWeight = Float(max(1, count))
        return VoiceMath.normalized(
            zip(existing, incoming).map {
                ($0 * oldWeight + $1) / (oldWeight + 1)
            }
        )
    }

    private static func samples(
        from audio: [Float],
        sampleRate: Int,
        ranges: [Range<TimeInterval>],
        maximumCount: Int
    ) -> [Float] {
        guard sampleRate > 0, maximumCount > 0 else { return [] }
        var result: [Float] = []
        result.reserveCapacity(min(maximumCount, audio.count))
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let start = max(0, min(audio.count, Int(range.lowerBound * Double(sampleRate))))
            let end = max(start, min(audio.count, Int(range.upperBound * Double(sampleRate))))
            guard end > start else { continue }
            let remaining = maximumCount - result.count
            guard remaining > 0 else { break }
            result.append(contentsOf: audio[start..<min(end, start + remaining)])
        }
        return result
    }

    private func ensureLegacyDiarizer(clusteringThreshold: Float) async throws {
        if diarizer != nil { return }
        let downloadedModels = try await DiarizerModels.downloadIfNeeded()
        let manager = DiarizerManager(config: DiarizerConfig(
            clusteringThreshold: clusteringThreshold
        ))
        manager.initialize(models: downloadedModels)
        diarizer = manager
    }
    
    private func loadAudio(from url: URL) async throws -> (samples: [Float], duration: TimeInterval) {
        logger.debug("[FluidAudioEmbedding] Loading audio from: \(url.path)")
        let asset = AVAsset(url: url)
        
        // Load tracks asynchronously
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            logger.error("[FluidAudioEmbedding] No audio track found in file: \(url.path)")
            throw EmbeddingError.audioLoadFailed("No audio track found")
        }
        
        // Get duration asynchronously
        let durationTime = try await asset.load(.duration)
        let duration = CMTimeGetSeconds(durationTime)
        
        // Read audio samples
        guard let reader = try? AVAssetReader(asset: asset) else {
            logger.error("[FluidAudioEmbedding] Cannot create asset reader for: \(url.path)")
            throw EmbeddingError.audioLoadFailed("Cannot create asset reader")
        }
        
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: outputSettings)
        reader.add(output)
        reader.startReading()
        
        var samples: [Float] = []
        
        while reader.status == .reading {
            if let sampleBuffer = output.copyNextSampleBuffer(),
               let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                
                let length = CMBlockBufferGetDataLength(blockBuffer)
                let sampleCount = length / MemoryLayout<Float>.size
                
                var dataPointer: UnsafeMutablePointer<Int8>?
                CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: nil, dataPointerOut: &dataPointer)
                
                if let dataPointer = dataPointer {
                    let floatPointer = dataPointer.withMemoryRebound(to: Float.self, capacity: sampleCount) {
                        return $0
                    }
                    samples.append(contentsOf: Array(UnsafeBufferPointer(start: floatPointer, count: sampleCount)))
                }
            }
        }
        
        if reader.status == .failed {
            throw EmbeddingError.audioLoadFailed(reader.error?.localizedDescription ?? "Unknown error")
        }
        
        logger.info("[FluidAudioEmbedding] Loaded \(samples.count) samples (\(duration)s)")
        return (samples, duration)
    }
    
    private static func turns(from result: DiarizationResult) -> [DiarizationTurn] {
        var turns = result.segments.map { segment in
            DiarizationTurn(
                speaker: segment.speakerId,
                start: TimeInterval(segment.startTimeSeconds),
                end: TimeInterval(segment.endTimeSeconds),
                embedding: segment.embedding.isEmpty
                    ? (result.speakerDatabase?[segment.speakerId] ?? [])
                    : segment.embedding,
                qualityScore: segment.qualityScore
            )
        }
        guard let chunks = result.chunkEmbeddings, !chunks.isEmpty else { return turns }

        let averageQuality = Dictionary(grouping: result.segments, by: \.speakerId)
            .mapValues { segments in
                segments.reduce(Float.zero) { $0 + $1.qualityScore }
                    / Float(max(1, segments.count))
            }
        for (speaker, speakerChunks) in Dictionary(grouping: chunks, by: \.speakerId) {
            guard let firstIndex = turns.firstIndex(where: { $0.speaker == speaker }) else {
                continue
            }
            turns[firstIndex].identityEmbeddingSamples = speakerChunks.map {
                SpeakerIdentityEmbeddingSample(
                    embedding: $0.embedding256,
                    start: $0.startTimeSeconds,
                    end: $0.endTimeSeconds,
                    qualityScore: averageQuality[speaker] ?? 1
                )
            }
        }
        return turns
    }

    private static func stageTimings(_ timings: PipelineTimings) -> SpeakerDiarizationStageTimings {
        SpeakerDiarizationStageTimings(
            audioLoadingSeconds: timings.audioLoadingSeconds,
            segmentationSeconds: timings.segmentationSeconds,
            embeddingSeconds: timings.embeddingExtractionSeconds,
            clusteringSeconds: timings.speakerClusteringSeconds,
            postProcessingSeconds: timings.postProcessingSeconds
        )
    }

    /// Extract real embeddings using FluidAudio's internal models
    /// Returns 256-dimensional WeSpeaker embeddings
    private func extractRealEmbeddings(from audioSamples: [Float]) async throws -> [Float] {
        guard let diarizer = diarizer else {
            throw EmbeddingError.initializationFailed("Diarizer not initialized")
        }
        
        // Use the embedding extractor directly instead of full diarization
        guard let embeddingExtractor = diarizer.embeddingExtractor else {
            throw EmbeddingError.initializationFailed("Embedding extractor not available")
        }
        
        // Model expects exactly 589 frames (94,240 samples at 160 samples/frame)
        let frameShift = 160
        let expectedFrames = 589
        let expectedSamples = expectedFrames * frameShift // 94,240 samples = 5.89 seconds at 16kHz
        
        // Prepare audio samples - pad with repetition or truncate
        var processedSamples: [Float]
        
        if audioSamples.count < expectedSamples {
            // Pad by repeating the audio cyclically
            processedSamples = [Float](repeating: 0, count: expectedSamples)
            var idx = 0
            while idx < expectedSamples {
                let copyCount = min(audioSamples.count, expectedSamples - idx)
                let sourceRange = 0..<copyCount
                for i in sourceRange {
                    processedSamples[idx + i] = audioSamples[i % audioSamples.count]
                }
                idx += copyCount
            }
            logger.info("[FluidAudioEmbedding] Padded audio from \(audioSamples.count) to \(expectedSamples) samples by repetition")
        } else if audioSamples.count > expectedSamples {
            // Truncate to the expected size (take middle portion for better representation)
            let startIdx = (audioSamples.count - expectedSamples) / 2
            processedSamples = Array(audioSamples[startIdx..<(startIdx + expectedSamples)])
            logger.info("[FluidAudioEmbedding] Truncated audio from \(audioSamples.count) to \(expectedSamples) samples")
        } else {
            // Perfect size
            processedSamples = audioSamples
            logger.info("[FluidAudioEmbedding] Audio already at expected size: \(expectedSamples) samples")
        }
        
        // Create a mask for exactly 589 frames (all 1s = single speaker)
        let mask = [Float](repeating: 1.0, count: expectedFrames)
        
        logger.info("[FluidAudioEmbedding] Extracting embedding with fixed size: \(expectedFrames) frames")
        
        do {
            // Extract embeddings using the model directly
            // Pass a single mask for the entire audio segment
            let embeddings = try embeddingExtractor.getEmbeddings(
                audio: processedSamples,
                masks: [mask],  // Single speaker mask with exactly 589 frames
                minActivityThreshold: 0.0  // Don't filter, we know there's speech
            )
            
            // We should get exactly one embedding back
            if let embedding = embeddings.first, embedding.count == 256 {
                // Check if it's a valid embedding (not all zeros)
                let magnitude = sqrt(embedding.map { $0 * $0 }.reduce(0, +))
                
                if magnitude > 0.1 {
                    logger.info("[FluidAudioEmbedding] Successfully extracted embedding (magnitude: \(magnitude))")
                    
                    // Normalize the embedding
                    var normalizedEmbedding = embedding
                    var norm: Float = 0
                    vDSP_svesq(normalizedEmbedding, 1, &norm, vDSP_Length(256))
                    if norm > 0 {
                        var scale = 1.0 / sqrt(norm)
                        vDSP_vsmul(normalizedEmbedding, 1, &scale, &normalizedEmbedding, 1, vDSP_Length(256))
                    }
                    
                    return normalizedEmbedding
                } else {
                    logger.warning("[FluidAudioEmbedding] Embedding magnitude too low (\(magnitude)), may be silence")
                }
            }
            
            throw EmbeddingError.embeddingExtractionFailed("Failed to extract valid embedding")
            
        } catch {
            logger.error("[FluidAudioEmbedding] Direct embedding extraction failed: \(error)")
            
            // Fallback to full diarization if direct extraction fails
            logger.info("[FluidAudioEmbedding] Falling back to full diarization")
            
            // Use original samples for diarization (it handles sizing internally)
            let result = try diarizer.performCompleteDiarization(
                audioSamples,
                sampleRate: Int(sampleRate)
            )
            
            if let longestSegment = result.segments.max(by: { $0.durationSeconds < $1.durationSeconds }) {
                logger.info("[FluidAudioEmbedding] Using embedding from diarization (speaker: \(longestSegment.speakerId), duration: \(longestSegment.durationSeconds)s)")
                return longestSegment.embedding
            }
            
            throw EmbeddingError.embeddingExtractionFailed("No speaker segments found in fallback")
        }
    }
}

// MARK: - Compatibility Layer

extension FluidAudioEmbeddingService {

    /// Extract embedding from a time-bounded segment of audio.
    /// If startTime/endTime are provided, slices the audio first using AVAssetExportSession.
    func extractEmbedding(
        from audioURL: URL,
        startTime: TimeInterval? = nil,
        endTime: TimeInterval? = nil
    ) async throws -> SpeakerEmbedding {
        guard let start = startTime, let end = endTime, end > start else {
            return try await extractEmbedding(from: audioURL)
        }

        // Slice audio to the requested time range
        let asset = AVAsset(url: audioURL)
        let timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 44100),
            end: CMTime(seconds: end, preferredTimescale: 44100)
        )

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            // Fallback to full audio if export session can't be created
            return try await extractEmbedding(from: audioURL)
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        exportSession.outputURL = tempURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = timeRange

        await exportSession.export()

        guard exportSession.status == .completed else {
            // Fallback to full audio on export failure
            return try await extractEmbedding(from: audioURL)
        }

        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try await extractEmbedding(from: tempURL)
    }
}
