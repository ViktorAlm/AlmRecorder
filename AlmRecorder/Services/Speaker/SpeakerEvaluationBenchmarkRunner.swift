import Foundation
import AlmRecorderEvaluationKit

struct SpeakerEvaluationBenchmarkFailure: Codable, Equatable, Identifiable {
    let profile: SpeakerPipelineProfile
    let message: String

    var id: String { profile.rawValue }
}

struct SpeakerEvaluationBenchmarkBundle: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: Date
    let goldRevision: String
    let reports: [SpeakerPipelineBenchmarkReport]
    let failures: [SpeakerEvaluationBenchmarkFailure]
    let pairGoldBenchmark: SpeakerPairGoldBenchmarkReport?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generatedAt
        case goldRevision
        case reports
        case failures
        case pairGoldBenchmark
    }

    init(
        schemaVersion: Int,
        generatedAt: Date,
        goldRevision: String,
        reports: [SpeakerPipelineBenchmarkReport],
        failures: [SpeakerEvaluationBenchmarkFailure],
        pairGoldBenchmark: SpeakerPairGoldBenchmarkReport?
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.goldRevision = goldRevision
        self.reports = reports
        self.failures = failures
        self.pairGoldBenchmark = pairGoldBenchmark
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        generatedAt = try values.decode(Date.self, forKey: .generatedAt)
        goldRevision = try values.decode(String.self, forKey: .goldRevision)
        reports = try values.decode([SpeakerPipelineBenchmarkReport].self, forKey: .reports)
        failures = try values.decode(
            [SpeakerEvaluationBenchmarkFailure].self,
            forKey: .failures
        )
        pairGoldBenchmark = try values.decodeIfPresent(
            SpeakerPairGoldBenchmarkReport.self,
            forKey: .pairGoldBenchmark
        )
    }
}

struct SpeakerEvaluationBenchmarkProgress: Equatable, Sendable {
    let profileName: String
    let profileIndex: Int
    let profileCount: Int
    let recordingIndex: Int
    let recordingCount: Int

    var fraction: Double {
        guard profileCount > 0 else { return 0 }
        let profileBase = Double(profileIndex) / Double(profileCount)
        let withinProfile = recordingCount > 0
            ? Double(recordingIndex) / Double(recordingCount * profileCount)
            : 0
        return min(1, profileBase + withinProfile)
    }

    var message: String {
        if recordingCount == 0 {
            return "Preparing \(profileName)…"
        }
        return "\(profileName) · conversation \(min(recordingIndex + 1, recordingCount)) of \(recordingCount)"
    }
}

enum SpeakerEvaluationBenchmarkStore {
    private static func store() throws
        -> JSONEvaluationArtifactStore<SpeakerEvaluationBenchmarkBundle> {
        try JSONEvaluationArtifactStore(
            workspace: EvaluationWorkspace.current(),
            fileName: "speaker-pipeline-benchmark.json"
        )
    }

    static func load() -> SpeakerEvaluationBenchmarkBundle? {
        try? store().load()
    }

    static func save(_ bundle: SpeakerEvaluationBenchmarkBundle) throws {
        try store().save(bundle)
    }
}

enum SpeakerEvaluationBenchmarkRunner {
    private struct KnownVoice {
        let uuid: String
        var embedding: [Float]
        var observations: Int
        var prototypes: [[Float]]
        var occurrences: [GlobalSpeakerIdentityStore.LocalOccurrence]
        var referenceSecondsBySpeaker: [String: TimeInterval]
    }

    static func run(
        dataset: SpeakerEvaluationDataset,
        profiles: [SpeakerPipelineProfile],
        pairGoldBenchmark: SpeakerPairGoldBenchmarkReport?,
        calibrationBackend: GlobalSpeakerCalibrationBackend?,
        progress: @escaping @MainActor (SpeakerEvaluationBenchmarkProgress) -> Void
    ) async -> SpeakerEvaluationBenchmarkBundle {
        // Restoring this bookmark is what lets the app evaluate Voice Memos in place. Imported and
        // app-managed recordings need no special handling.
        _ = FileAccessManager.shared.getVoiceMemosURL()

        var reports: [SpeakerPipelineBenchmarkReport] = []
        var failures: [SpeakerEvaluationBenchmarkFailure] = []

        for (profileIndex, profile) in profiles.enumerated() {
            let configuration = SpeakerPipelineSettings.configuration(for: profile)
            await progress(SpeakerEvaluationBenchmarkProgress(
                profileName: profile.displayName,
                profileIndex: profileIndex,
                profileCount: profiles.count,
                recordingIndex: 0,
                recordingCount: dataset.recordings.count
            ))
            do {
                let report = try await runProfile(
                    dataset: dataset,
                    profile: profile,
                    configuration: configuration,
                    profileIndex: profileIndex,
                    profileCount: profiles.count,
                    calibrationBackend: calibrationBackend,
                    progress: progress
                )
                reports.append(report)
            } catch {
                failures.append(SpeakerEvaluationBenchmarkFailure(
                    profile: profile,
                    message: error.localizedDescription
                ))
            }
        }

        return SpeakerEvaluationBenchmarkBundle(
            schemaVersion: 1,
            generatedAt: Date(),
            goldRevision: dataset.goldRevision,
            reports: reports,
            failures: failures,
            pairGoldBenchmark: pairGoldBenchmark
        )
    }

    private static func runProfile(
        dataset: SpeakerEvaluationDataset,
        profile: SpeakerPipelineProfile,
        configuration: SpeakerPipelineConfiguration,
        profileIndex: Int,
        profileCount: Int,
        calibrationBackend: GlobalSpeakerCalibrationBackend?,
        progress: @escaping @MainActor (SpeakerEvaluationBenchmarkProgress) -> Void
    ) async throws -> SpeakerPipelineBenchmarkReport {
        guard !dataset.recordings.isEmpty else {
            throw BenchmarkError.noGoldRecordings
        }

        let service = try await FluidAudioEmbeddingService(configuration: configuration)
        var known: [KnownVoice] = []
        var diarizationPredictions: [SpeakerEvaluationSegment] = []
        var attributedPredictions: [SpeakerEvaluationSegment] = []
        var localIdentityPredictions: [SpeakerEvaluationSegment] = []
        var segmentationPredictions = Dictionary(
            uniqueKeysWithValues: SpeakerUtteranceSegmentation.allCases.map {
                ($0, [SpeakerEvaluationSegment]())
            }
        )
        var globalBenchmarkNodes: [GlobalSpeakerBenchmarkNode] = []
        var sequentialAssignments: [String: String] = [:]
        var elapsed: TimeInterval = 0
        var audioSeconds: TimeInterval = 0
        var aggregateStageTimings: SpeakerDiarizationStageTimings?
        var nextIdentity = 1
        var processingErrors: [String] = []
        var identityDecisions: [SpeakerIdentityBenchmarkDecision] = []
        var globalAliases: [String: String] = [:]

        for (recordingIndex, item) in dataset.recordings.enumerated() {
            try Task.checkCancellation()
            await progress(SpeakerEvaluationBenchmarkProgress(
                profileName: profile.displayName,
                profileIndex: profileIndex,
                profileCount: profileCount,
                recordingIndex: recordingIndex,
                recordingCount: dataset.recordings.count
            ))
            guard let path = item.recording.filePath, !path.isEmpty else {
                processingErrors.append("\(item.recording.title): missing audio path")
                continue
            }
            do {
                let audioURL = URL(fileURLWithPath: path)
                var run = try await service.diarizeDetailed(
                    audioURL,
                    configuration: configuration
                )
                if configuration.diarizationBackend == .offlineVBxTargetedSortformer {
                    let targets = item.reference.map {
                        WhisperTimedSegment(
                            text: $0.text ?? "",
                            startTime: $0.startTime,
                            endTime: $0.endTime,
                            tokenStats: nil
                        )
                    }
                    run = try await service.repairWithTargetedSortformer(
                        audioURL,
                        baseline: run,
                        targetSegments: targets,
                        configuration: configuration
                    )
                }
                elapsed += run.wallClockSeconds
                aggregateStageTimings = adding(aggregateStageTimings, run.stageTimings)
                audioSeconds += item.recording.duration ?? (run.turns.map(\.end).max() ?? 0)

                let centroids = SpeakerAlignment.identityClusters(
                    from: run.turns,
                    policy: configuration.centroidPolicy
                )
                let unifier = SpeakerUnifier(
                    matchThreshold: configuration.identitySimilarityThreshold,
                    strategy: configuration.identityMatcher,
                    ambiguityMargin: configuration.identityAmbiguityMargin
                )
                let existingEvidence = known.map {
                    SpeakerIdentityProfileEvidence(
                        uuid: $0.uuid,
                        meanEmbedding: $0.embedding,
                        prototypes: $0.prototypes
                    )
                }
                let matches = unifier.assign(
                    newClusters: centroids,
                    existing: existingEvidence
                )
                let referenceEvidence = centroids.map {
                    dominantReferenceEvidence(
                        for: $0,
                        turns: run.turns,
                        reference: item.reference
                    )
                }
                let recordingId = item.recording.id ?? Int64(recordingIndex + 1)

                var localToGlobal: [String: String] = [:]
                var localNodeIDs: [String: String] = [:]
                for index in centroids.indices {
                    let ranked = unifier.rankedProfileScores(
                        for: centroids[index],
                        existing: existingEvidence
                    )
                    let winner = ranked.first
                    let runnerUp = ranked.dropFirst().first
                    let evidence = referenceEvidence[index]
                    let assignedUUID: String
                    let reusedExisting: Bool
                    let priorReferenceSpeakers: [String]
                    switch matches[index] {
                    case .existing(let uuid):
                        assignedUUID = uuid
                        reusedExisting = true
                        priorReferenceSpeakers = known
                            .first(where: { $0.uuid == uuid })?
                            .referenceSecondsBySpeaker
                            .sorted {
                                if $0.value != $1.value { return $0.value > $1.value }
                                return $0.key < $1.key
                            }
                            .map(\.key) ?? []
                        localToGlobal[centroids[index].label] = uuid
                        if configuration.updateCentroidsAfterIngest,
                           let knownIndex = known.firstIndex(where: { $0.uuid == uuid }) {
                            known[knownIndex].embedding = normalizedAverage(
                                known[knownIndex].embedding,
                                count: known[knownIndex].observations,
                                with: centroids[index].embedding
                            )
                            known[knownIndex].observations += 1
                            known[knownIndex].prototypes.append(centroids[index].embedding)
                            known[knownIndex].occurrences.append(
                                .init(
                                    clusterId: Int64(recordingIndex * 10_000 + index + 1),
                                    recordingId: recordingId,
                                    spans: centroids[index].spans
                                )
                            )
                            mergeReferenceEvidence(
                                evidence.secondsBySpeaker,
                                into: &known[knownIndex].referenceSecondsBySpeaker
                            )
                        }
                    case .new:
                        let uuid = "predicted-\(nextIdentity)"
                        nextIdentity += 1
                        assignedUUID = uuid
                        reusedExisting = false
                        priorReferenceSpeakers = []
                        localToGlobal[centroids[index].label] = uuid
                        if centroids[index].isReliableForGlobalIdentity {
                            known.append(KnownVoice(
                                uuid: uuid,
                                embedding: centroids[index].embedding,
                                observations: 1,
                                prototypes: [centroids[index].embedding],
                                occurrences: [
                                    .init(
                                        clusterId: Int64(recordingIndex * 10_000 + index + 1),
                                        recordingId: recordingId,
                                        spans: centroids[index].spans
                                    )
                                ],
                                referenceSecondsBySpeaker: evidence.secondsBySpeaker
                            ))
                        }
                    }
                    let nodeID = "\(item.recordingKey):\(centroids[index].label)"
                    localNodeIDs[centroids[index].label] = nodeID
                    sequentialAssignments[nodeID] = assignedUUID
                    let totalReferenceSeconds = evidence.secondsBySpeaker.values.reduce(0, +)
                    globalBenchmarkNodes.append(
                        GlobalSpeakerBenchmarkNode(
                            id: nodeID,
                            recordingKey: item.recordingKey,
                            recordingId: recordingId,
                            embedding: centroids[index].embedding,
                            spans: centroids[index].spans,
                            reliableForIdentity: centroids[index].isReliableForGlobalIdentity,
                            goldSpeakerKey: evidence.dominantSpeaker,
                            goldPurity: totalReferenceSeconds > 0
                                ? evidence.dominantSeconds / totalReferenceSeconds
                                : 0
                        )
                    )
                    identityDecisions.append(SpeakerIdentityBenchmarkDecision(
                        recordingKey: item.recordingKey,
                        recordingTitle: item.recording.title,
                        localLabel: centroids[index].label,
                        referenceSpeakerKey: evidence.dominantSpeaker,
                        referenceOverlapSeconds: evidence.dominantSeconds,
                        assignedPredictedUUID: assignedUUID,
                        reusedExistingIdentity: reusedExisting,
                        winnerUUID: winner?.uuid,
                        winnerScore: winner?.value,
                        runnerUpScore: runnerUp?.value,
                        bestPrototypeScore: winner?.bestPrototype,
                        supportingPrototypeCount: winner?.supportingPrototypeCount,
                        priorReferenceSpeakers: priorReferenceSpeakers,
                        clusterCohesion: centroids[index].cohesion,
                        clusterConfidence: centroids[index].confidence,
                        clusterEmbeddingTurnCount: centroids[index].embeddingTurnCount,
                        clusterDurationSeconds: centroids[index].duration,
                        eligibleForGlobalIdentity: centroids[index].isReliableForGlobalIdentity,
                        mixtureSplitGain: centroids[index].mixtureSplitGain,
                        mixtureCentroidSimilarity: centroids[index].mixtureCentroidSimilarity
                    ))
                }

                if configuration.identityMatcher == .prototypeConsensus {
                    consolidateKnownVoices(
                        &known,
                        aliases: &globalAliases,
                        configuration: configuration
                    )
                    for label in localToGlobal.keys {
                        if let uuid = localToGlobal[label] {
                            localToGlobal[label] = canonicalUUID(uuid, aliases: globalAliases)
                        }
                    }
                }

                let rawPrediction = run.turns.map { turn in
                    SpeakerEvaluationSegment(
                        recordingKey: item.recordingKey,
                        speakerKey: "local:\(item.recordingKey):\(turn.speaker)",
                        startTime: turn.start,
                        endTime: turn.end,
                        text: nil,
                        timingIsGold: false
                    )
                }
                diarizationPredictions.append(contentsOf: rawPrediction)

                if configuration.transcriptionSegmentation == .whisperTimedSegments {
                    let oracleASR = item.reference.map {
                        WhisperTimedSegment(
                            text: $0.text ?? "",
                            startTime: $0.startTime,
                            endTime: $0.endTime,
                            tokenStats: nil
                        )
                    }
                    for mode in SpeakerUtteranceSegmentation.allCases {
                        let prediction = SpeakerAlignment.align(
                            oracleASR,
                            to: run.turns,
                            strategy: configuration.alignmentStrategy,
                            utteranceSegmentation: mode
                        ).map { segment in
                            SpeakerEvaluationSegment(
                                recordingKey: item.recordingKey,
                                speakerKey: segment.speaker.flatMap { localToGlobal[$0] },
                                startTime: segment.startTime,
                                endTime: segment.endTime,
                                text: segment.text,
                                timingIsGold: false
                            )
                        }
                        segmentationPredictions[mode, default: []].append(
                            contentsOf: prediction
                        )
                        if mode == configuration.effectiveUtteranceSegmentation {
                            attributedPredictions.append(contentsOf: prediction)
                        }
                    }
                    localIdentityPredictions.append(contentsOf: SpeakerAlignment.align(
                        oracleASR,
                        to: run.turns,
                        strategy: configuration.alignmentStrategy,
                        utteranceSegmentation: configuration.effectiveUtteranceSegmentation
                    ).map { segment in
                        SpeakerEvaluationSegment(
                            recordingKey: item.recordingKey,
                            speakerKey: segment.speaker.flatMap { localNodeIDs[$0] },
                            startTime: segment.startTime,
                            endTime: segment.endTime,
                            text: segment.text,
                            timingIsGold: false
                        )
                    })
                } else {
                    attributedPredictions.append(contentsOf: rawPrediction)
                    localIdentityPredictions.append(contentsOf: rawPrediction.map {
                        SpeakerEvaluationSegment(
                            recordingKey: $0.recordingKey,
                            speakerKey: $0.speakerKey.flatMap { key in
                                let localLabel = key.split(separator: ":").last.map(String.init)
                                return localLabel.flatMap { localNodeIDs[$0] }
                            },
                            startTime: $0.startTime,
                            endTime: $0.endTime,
                            text: $0.text,
                            timingIsGold: false
                        )
                    })
                }
            } catch {
                processingErrors.append("\(item.recording.title): \(error.localizedDescription)")
            }
        }

        let completedRecordingKeys = Set(diarizationPredictions.map(\.recordingKey))
        guard !completedRecordingKeys.isEmpty else {
            throw BenchmarkError.noAudioProcessed(processingErrors.first ?? "No readable audio")
        }

        let canonicalAttributed = remap(
            attributedPredictions,
            through: resolvedAliases(globalAliases)
        )
        let personas = VoicePersonaGrouper.group(
            known.map { (uuid: $0.uuid, centroid: $0.embedding) },
            threshold: configuration.personaSimilarityThreshold,
            linkage: configuration.personaLinkage
        )
        let personaMap = VoicePersonaGrouper.representativeMap(personas)
        let sequentialIdentityPredictions = remap(canonicalAttributed, through: personaMap)
        let resolvedSequentialAssignments: [String: String] = Dictionary(
            uniqueKeysWithValues: sequentialAssignments.map { nodeID, uuid in
                let canonical = canonicalUUID(uuid, aliases: globalAliases)
                return (nodeID, personaMap[canonical] ?? canonical)
            }
        )
        let selectedAssignments: [String: String]
        let selectedIdentityPredictions: [SpeakerEvaluationSegment]
        let selectedGlobalMethod: String
        if SpeakerPipelineSettings.shared.continuousReconciliationEnabled,
           let calibrationBackend,
           calibrationBackend.model.isLearned {
            let reconciled = GlobalSpeakerReconciler.reconcile(
                nodes: globalBenchmarkNodes,
                model: calibrationBackend.model,
                cohortEmbeddings: calibrationBackend.cohortEmbeddings,
                configuration: .init(
                    mergeProbability: calibrationBackend.mergeProbability
                )
            )
            selectedAssignments = reconciled.assignments
            selectedIdentityPredictions = remap(
                localIdentityPredictions,
                through: reconciled.assignments
            )
            selectedGlobalMethod = "production-calibrated-constrained"
        } else if configuration.identityMatcher == .evidenceGraph {
            let graph = GlobalSpeakerEvidenceGraph.cluster(
                globalBenchmarkNodes,
                configuration: .init(
                    linkage: .constrainedEvidence,
                    threshold: configuration.identitySimilarityThreshold
                )
            )
            selectedAssignments = graph.assignments
            selectedIdentityPredictions = remap(
                localIdentityPredictions,
                through: graph.assignments
            )
            selectedGlobalMethod = "constrained-evidence-graph"
        } else {
            selectedAssignments = resolvedSequentialAssignments
            selectedIdentityPredictions = sequentialIdentityPredictions
            selectedGlobalMethod = "sequential-\(configuration.identityMatcher.rawValue)"
        }
        let reference = dataset.recordings
            .filter { completedRecordingKeys.contains($0.recordingKey) }
            .flatMap(\.reference)
        let metrics = SpeakerPipelineEvaluator.evaluate(
            reference: reference,
            predicted: diarizationPredictions,
            speakerAttributedPredicted: canonicalAttributed,
            identityPredicted: selectedIdentityPredictions
        )
        let transcriptSegmentationCandidates: [SpeakerTranscriptSegmentationCandidateReport]?
        if configuration.transcriptionSegmentation == .whisperTimedSegments {
            transcriptSegmentationCandidates = SpeakerUtteranceSegmentation.allCases.map { mode in
                let attributed = remap(
                    segmentationPredictions[mode] ?? [],
                    through: resolvedAliases(globalAliases)
                )
                return SpeakerTranscriptSegmentationCandidateReport(
                    mode: mode,
                    metrics: SpeakerPipelineEvaluator.evaluate(
                        reference: reference,
                        predicted: diarizationPredictions,
                        speakerAttributedPredicted: attributed,
                        identityPredicted: remap(attributed, through: personaMap)
                    )
                )
            }
        } else {
            transcriptSegmentationCandidates = nil
        }
        let globalCandidates = makeGlobalIdentityCandidateReports(
            nodes: globalBenchmarkNodes,
            reference: reference,
            rawDiarization: diarizationPredictions,
            localIdentityPredictions: localIdentityPredictions,
            selectedAssignments: selectedAssignments,
            selectedMethod: selectedGlobalMethod,
            selectedEndToEndMetrics: metrics,
            calibrationBackend: calibrationBackend
        )
        var report = SpeakerPipelineBenchmarkReport(
            runName: profile.rawValue,
            profile: profile,
            configuration: configuration,
            metrics: metrics,
            requestedRecordingCount: dataset.recordings.count,
            processedRecordingCount: completedRecordingKeys.count,
            skippedRecordingCount: dataset.recordings.count - completedRecordingKeys.count,
            wallClockSeconds: elapsed,
            audioSeconds: audioSeconds,
            realTimeFactor: audioSeconds > 0 ? elapsed / audioSeconds : nil,
            diarizationStageSeconds: aggregateStageTimings,
            generatedAt: Date(),
            identityDecisions: identityDecisions,
            globalIdentityCandidates: globalCandidates
        )
        report.transcriptSegmentationCandidates = transcriptSegmentationCandidates
        return report
    }

    private static func makeGlobalIdentityCandidateReports(
        nodes: [GlobalSpeakerBenchmarkNode],
        reference: [SpeakerEvaluationSegment],
        rawDiarization: [SpeakerEvaluationSegment],
        localIdentityPredictions: [SpeakerEvaluationSegment],
        selectedAssignments: [String: String],
        selectedMethod: String,
        selectedEndToEndMetrics: SpeakerPipelineMetrics,
        calibrationBackend: GlobalSpeakerCalibrationBackend?
    ) -> [GlobalSpeakerIdentityCandidateReport] {
        guard !nodes.isEmpty else { return [] }

        func report(
            id: String,
            name: String,
            method: String,
            threshold: Float?,
            assignments: [String: String],
            endToEnd: SpeakerPipelineMetrics? = nil
        ) -> GlobalSpeakerIdentityCandidateReport {
            let endMetrics = endToEnd ?? SpeakerPipelineEvaluator.evaluate(
                reference: reference,
                predicted: rawDiarization,
                speakerAttributedPredicted: localIdentityPredictions,
                identityPredicted: remap(localIdentityPredictions, through: assignments)
            )
            return GlobalSpeakerIdentityCandidateReport(
                id: id,
                name: name,
                method: method,
                threshold: threshold,
                metrics: GlobalSpeakerGoldScorer.evaluate(
                    nodes: nodes,
                    assignments: assignments
                ),
                endToEndPairPrecision: endMetrics.identityPairPrecision,
                endToEndPairRecall: endMetrics.identityPairRecall,
                endToEndPairF1: endMetrics.identityPairF1,
                endToEndFalseMergePairs: endMetrics.falseMergePairs,
                endToEndFalseSplitPairs: endMetrics.falseSplitPairs
            )
        }

        var result = [
            report(
                id: "production-sequential",
                name: "Current production",
                method: selectedMethod,
                threshold: nil,
                assignments: selectedAssignments,
                endToEnd: selectedEndToEndMetrics
            ),
            report(
                id: "isolated",
                name: "Never merge",
                method: "isolated-control",
                threshold: nil,
                assignments: Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.id) })
            ),
        ]

        let configurations: [(String, String, GlobalSpeakerEvidenceGraph.Configuration)] = [
            (
                "single-050",
                "Single-link control",
                .init(linkage: .single, threshold: 0.50)
            ),
            (
                "complete-042",
                "Complete-link control",
                .init(linkage: .complete, threshold: 0.42)
            ),
            (
                "evidence-042",
                "Evidence graph · recall",
                .init(linkage: .constrainedEvidence, threshold: 0.42)
            ),
            (
                "evidence-046",
                "Evidence graph · balanced",
                .init(linkage: .constrainedEvidence, threshold: 0.46)
            ),
            (
                "evidence-050",
                "Evidence graph · conservative",
                .init(linkage: .constrainedEvidence, threshold: 0.50)
            ),
            (
                "evidence-054",
                "Evidence graph · strict",
                .init(linkage: .constrainedEvidence, threshold: 0.54)
            ),
        ]
        for (id, name, graphConfiguration) in configurations {
            let graph = GlobalSpeakerEvidenceGraph.cluster(
                nodes,
                configuration: graphConfiguration
            )
            result.append(
                report(
                    id: id,
                    name: name,
                    method: graphConfiguration.linkage.rawValue,
                    threshold: graphConfiguration.threshold,
                    assignments: graph.assignments
                )
            )
        }
        if let backend = calibrationBackend {
            var calibratedConfigurations: [(String, String, Double)] = [
                (
                    "calibrated-production",
                    "Calibrated reconciler · learned operating point",
                    backend.mergeProbability
                ),
                ("calibrated-078", "Calibrated reconciler · recall", 0.78),
                ("calibrated-088", "Calibrated reconciler · balanced", 0.88),
                ("calibrated-094", "Calibrated reconciler · strict", 0.94),
            ]
            var seenThresholds = Set<Double>()
            calibratedConfigurations = calibratedConfigurations.filter {
                seenThresholds.insert(($0.2 * 1_000).rounded() / 1_000).inserted
            }
            for (id, name, threshold) in calibratedConfigurations {
                let reconciled = GlobalSpeakerReconciler.reconcile(
                    nodes: nodes,
                    model: backend.model,
                    cohortEmbeddings: backend.cohortEmbeddings,
                    configuration: .init(mergeProbability: threshold)
                )
                result.append(
                    report(
                        id: id,
                        name: name,
                        method: backend.model.isLearned
                            ? "gold-calibrated-constrained"
                            : "fallback-constrained",
                        threshold: Float(threshold),
                        assignments: reconciled.assignments
                    )
                )
            }
        }
        return result
    }

    private static func dominantReferenceEvidence(
        for cluster: SpeakerIdentityCluster,
        turns: [DiarizationTurn],
        reference: [SpeakerEvaluationSegment]
    ) -> (
        dominantSpeaker: String?,
        dominantSeconds: TimeInterval,
        secondsBySpeaker: [String: TimeInterval]
    ) {
        let clusterTurns = turns.filter { $0.speaker == cluster.label }
        var secondsBySpeaker: [String: TimeInterval] = [:]
        for turn in clusterTurns {
            for segment in reference {
                guard let speaker = segment.speakerKey else { continue }
                let overlap = max(0, min(turn.end, segment.endTime) - max(turn.start, segment.startTime))
                if overlap > 0 { secondsBySpeaker[speaker, default: 0] += overlap }
            }
        }
        let dominant = secondsBySpeaker.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }.first
        return (dominant?.key, dominant?.value ?? 0, secondsBySpeaker)
    }

    private static func mergeReferenceEvidence(
        _ source: [String: TimeInterval],
        into target: inout [String: TimeInterval]
    ) {
        for (speaker, seconds) in source {
            target[speaker, default: 0] += seconds
        }
    }

    private static func consolidateKnownVoices(
        _ known: inout [KnownVoice],
        aliases: inout [String: String],
        configuration: SpeakerPipelineConfiguration
    ) {
        let candidates = known.map { voice in
            GlobalSpeakerConsolidator.Candidate(
                uuid: voice.uuid,
                name: nil,
                nameSource: nil,
                meanEmbedding: voice.embedding,
                prototypes: voice.prototypes,
                recordingIds: Set(voice.occurrences.map(\.recordingId)),
                occurrences: voice.occurrences
            )
        }
        let threshold = max(0.79, configuration.identitySimilarityThreshold + 0.08)
        let decisions = candidates
            .filter { $0.prototypes.count <= 2 }
            .compactMap {
                GlobalSpeakerConsolidator.decision(
                    source: $0,
                    candidates: candidates,
                    threshold: threshold,
                    ambiguityMargin: configuration.identityAmbiguityMargin
                )
            }
            .prefix(24)

        for decision in decisions {
            guard let sourceIndex = known.firstIndex(where: {
                $0.uuid == decision.sourceUUID
            }), let targetIndex = known.firstIndex(where: {
                $0.uuid == decision.targetUUID
            }), sourceIndex != targetIndex else { continue }
            let source = known[sourceIndex]
            known[targetIndex].prototypes.append(contentsOf: source.prototypes)
            known[targetIndex].occurrences.append(contentsOf: source.occurrences)
            known[targetIndex].observations += source.observations
            mergeReferenceEvidence(
                source.referenceSecondsBySpeaker,
                into: &known[targetIndex].referenceSecondsBySpeaker
            )
            known[targetIndex].embedding =
                VoiceMath.meanNormalized(known[targetIndex].prototypes)
                ?? known[targetIndex].embedding
            aliases[source.uuid] = known[targetIndex].uuid
            let inheritedAliases = aliases.compactMap { alias, target in
                target == source.uuid ? alias : nil
            }
            for alias in inheritedAliases {
                aliases[alias] = known[targetIndex].uuid
            }
            known.remove(at: sourceIndex)
        }
    }

    private static func canonicalUUID(
        _ uuid: String,
        aliases: [String: String]
    ) -> String {
        var current = uuid
        var visited = Set<String>()
        while visited.insert(current).inserted, let next = aliases[current] {
            current = next
        }
        return current
    }

    private static func resolvedAliases(_ aliases: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: aliases.keys.map {
            ($0, canonicalUUID($0, aliases: aliases))
        })
    }

    private static func remap(
        _ segments: [SpeakerEvaluationSegment],
        through map: [String: String]
    ) -> [SpeakerEvaluationSegment] {
        segments.map {
            SpeakerEvaluationSegment(
                recordingKey: $0.recordingKey,
                speakerKey: $0.speakerKey.flatMap { map[$0] ?? $0 },
                startTime: $0.startTime,
                endTime: $0.endTime,
                text: $0.text,
                timingIsGold: $0.timingIsGold
            )
        }
    }

    private static func normalizedAverage(
        _ existing: [Float],
        count: Int,
        with next: [Float]
    ) -> [Float] {
        guard existing.count == next.count, !existing.isEmpty else { return next }
        var result = zip(existing, next).map {
            (($0 * Float(count)) + $1) / Float(count + 1)
        }
        let norm = sqrt(result.reduce(Float.zero) { $0 + $1 * $1 })
        if norm > 0 {
            for index in result.indices { result[index] /= norm }
        }
        return result
    }

    private static func adding(
        _ lhs: SpeakerDiarizationStageTimings?,
        _ rhs: SpeakerDiarizationStageTimings?
    ) -> SpeakerDiarizationStageTimings? {
        guard let rhs else { return lhs }
        guard let lhs else { return rhs }
        return SpeakerDiarizationStageTimings(
            audioLoadingSeconds: lhs.audioLoadingSeconds + rhs.audioLoadingSeconds,
            segmentationSeconds: lhs.segmentationSeconds + rhs.segmentationSeconds,
            embeddingSeconds: lhs.embeddingSeconds + rhs.embeddingSeconds,
            clusteringSeconds: lhs.clusteringSeconds + rhs.clusteringSeconds,
            postProcessingSeconds: lhs.postProcessingSeconds + rhs.postProcessingSeconds
        )
    }

    private enum BenchmarkError: LocalizedError {
        case noGoldRecordings
        case noAudioProcessed(String)

        var errorDescription: String? {
            switch self {
            case .noGoldRecordings:
                return "Confirm at least one conversation as Speaker gold first."
            case .noAudioProcessed(let detail):
                return "No gold audio could be evaluated. \(detail)"
            }
        }
    }
}
