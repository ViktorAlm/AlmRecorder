import Foundation

struct NightlyQualityCandidateSegment: Codable, Equatable {
    let utteranceID: Int64?
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let speakerUUID: String?
    let speakerLabel: String?
    let userProtected: Bool
    /// ASR text before a user/verifier correction. This lets private gold evaluate the actual
    /// engine output while `text` remains the current protected reference used for safe commits.
    var originalASRText: String? = nil
    var confidence: String? = nil
    var source: String? = nil
    var supportingUtteranceIDs: [Int64]? = nil
    var alignmentMethod: String? = nil
}

struct NightlyQualityCandidateProvenance: Codable, Equatable {
    enum Certainty: String, Codable {
        case exact
        case inferred
        case unknown
    }

    let role: String
    let engineIdentifier: String
    let modelIdentifier: String
    let modelRevision: String?
    let runtimeRevision: String?
    /// JSON snapshot rather than a display string so benchmark runs remain reproducible.
    let settingsJSON: String?
    let sourceRevisionDate: Date?
    let certainty: Certainty
}

struct NightlyQualityCandidate: Codable, Equatable {
    enum Engine: String, Codable {
        case unknown
        case whisper
        case vibeVoice
        case gemma
        case fused
    }

    let engine: Engine
    let model: String
    let createdAt: Date
    let segments: [NightlyQualityCandidateSegment]
    var provenance: NightlyQualityCandidateProvenance? = nil
}

struct NightlyQualityDecision: Codable, Equatable {
    let utteranceID: Int64
    let originalText: String
    let finalText: String
    let confidence: String
    let source: String
    let estimatedInputTokens: Int
}

struct NightlyQualityCandidateMetrics: Codable, Equatable {
    let candidate: String
    let referenceSegmentCount: Int
    let wordErrors: Int
    let referenceWordCount: Int
    let characterErrors: Int
    let referenceCharacterCount: Int
    var matchedBoundaries: Int? = nil
    var referenceBoundaryCount: Int? = nil
    var candidateBoundaryCount: Int? = nil

    var wordErrorRate: Double? {
        referenceWordCount > 0 ? Double(wordErrors) / Double(referenceWordCount) : nil
    }

    var characterErrorRate: Double? {
        referenceCharacterCount > 0
            ? Double(characterErrors) / Double(referenceCharacterCount)
            : nil
    }

    var boundaryF1: Double? {
        guard let matchedBoundaries,
              let referenceBoundaryCount,
              let candidateBoundaryCount,
              referenceBoundaryCount > 0,
              candidateBoundaryCount > 0 else { return nil }
        let precision = Double(matchedBoundaries) / Double(candidateBoundaryCount)
        let recall = Double(matchedBoundaries) / Double(referenceBoundaryCount)
        return precision + recall > 0
            ? 2 * precision * recall / (precision + recall)
            : 0
    }
}

struct NightlyQualityBenchmarkReport: Codable, Equatable {
    let createdAt: Date
    let protectedReferenceSegmentCount: Int
    let metrics: [NightlyQualityCandidateMetrics]
}

struct NightlyQualityPostProcessingRequirements: Codable, Equatable {
    let requiresAcousticAlignment: Bool
    let requiresLocalDiarization: Bool
    let requiresGlobalSpeakerReconciliation: Bool
    let reasons: [String]
}

struct NightlyQualityTraceTurn: Codable, Equatable, Identifiable {
    let id: Int
    let position: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let speaker: String?
    let vibeVoice: String
    let whisper: String?
    let foregroundRaw: String?
    let foregroundClean: String?
    let previousConsensus: String?
    let whisperSelectable: Bool?
}

/// Exact local-only audit trail for the text model. Prompts can contain private transcript text,
/// so traces live only beside the private nightly artifact in Application Support.
struct NightlyQualityLLMTrace: Codable, Equatable, Identifiable {
    let id: UUID
    let batchIndex: Int
    let attempt: Int
    let targetIDs: [Int]
    let prompt: String
    let response: String
    let parsedSuccessfully: Bool
    let createdAt: Date
    var strategy: ConsensusRepairStrategy? = nil
    var instructionSummary: String? = nil
    var target: NightlyQualityTraceTurn? = nil
    var contextBefore: [NightlyQualityTraceTurn]? = nil
    var contextAfter: [NightlyQualityTraceTurn]? = nil
    var evidenceAccepted: Bool? = nil
    var evidenceTrigramCoverage: Double? = nil
    var evidenceBigramCoverage: Double? = nil
    var resolutionSource: String? = nil
    var audioClipRanges: [NightlyQualityAudioClipTrace]? = nil
    var audioGrounded: Bool? = nil

    init(
        batchIndex: Int,
        attempt: Int,
        targetIDs: [Int],
        prompt: String,
        response: String,
        parsedSuccessfully: Bool,
        strategy: ConsensusRepairStrategy? = nil,
        instructionSummary: String? = nil,
        target: NightlyQualityTraceTurn? = nil,
        contextBefore: [NightlyQualityTraceTurn]? = nil,
        contextAfter: [NightlyQualityTraceTurn]? = nil,
        evidenceAccepted: Bool? = nil,
        evidenceTrigramCoverage: Double? = nil,
        evidenceBigramCoverage: Double? = nil,
        resolutionSource: String? = nil,
        audioClipRanges: [NightlyQualityAudioClipTrace]? = nil,
        audioGrounded: Bool? = nil
    ) {
        self.id = UUID()
        self.batchIndex = batchIndex
        self.attempt = attempt
        self.targetIDs = targetIDs
        self.prompt = prompt
        self.response = response
        self.parsedSuccessfully = parsedSuccessfully
        self.createdAt = Date()
        self.strategy = strategy
        self.instructionSummary = instructionSummary
        self.target = target
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.evidenceAccepted = evidenceAccepted
        self.evidenceTrigramCoverage = evidenceTrigramCoverage
        self.evidenceBigramCoverage = evidenceBigramCoverage
        self.resolutionSource = resolutionSource
        self.audioClipRanges = audioClipRanges
        self.audioGrounded = audioGrounded
    }
}

struct NightlyQualityAudioClipTrace: Codable, Equatable, Identifiable {
    var id: String { "\(startTime)-\(endTime)" }
    let startTime: TimeInterval
    let endTime: TimeInterval
    let source: String
}

struct NightlyQualityConsensusVariant: Codable, Equatable, Identifiable {
    var id: String { strategy.rawValue }

    let strategy: ConsensusRepairStrategy
    var candidate: NightlyQualityCandidate
    var decisions: [NightlyQualityDecision]
    var traces: [NightlyQualityLLMTrace]
    var cumulativeInputTokens: Int
    var peakRAMBytes: UInt64?
    var completedAt: Date?
}

struct NightlyQualityArtifact: Codable, Equatable {
    /// v16 adds actual audio grounding and exact clip-range provenance to consensus traces.
    static let schemaVersion = 16

    let schemaVersion: Int
    let recordingID: Int64
    let audioFingerprint: String
    let createdAt: Date
    var updatedAt: Date
    /// Historical name retained for artifact compatibility. This is the committed foreground
    /// snapshot and must never be assumed to be Whisper without exact recording provenance.
    var whisper: NightlyQualityCandidate
    var whisperCandidate: NightlyQualityCandidate? = nil
    var vibeVoice: NightlyQualityCandidate?
    var blindGemma: NightlyQualityCandidate? = nil
    var fused: NightlyQualityCandidate? = nil
    var gemmaDecisions: [NightlyQualityDecision]
    var benchmarkReport: NightlyQualityBenchmarkReport? = nil
    var requiresSpeakerReprocessing: Bool? = nil
    var postProcessingRequirements: NightlyQualityPostProcessingRequirements? = nil
    var cumulativeInputTokens: Int
    var peakRAMBytes: UInt64?
    var gemmaTextTraces: [NightlyQualityLLMTrace]? = nil
    var gemmaCompletedTurns: Int? = nil
    var gemmaTotalTurns: Int? = nil
    var consensusVariants: [NightlyQualityConsensusVariant]? = nil
    var requestedConsensusStrategies: [ConsensusRepairStrategy]? = nil
    var completedAt: Date?

    init(
        recordingID: Int64,
        audioFingerprint: String,
        whisper: NightlyQualityCandidate
    ) {
        self.schemaVersion = Self.schemaVersion
        self.recordingID = recordingID
        self.audioFingerprint = audioFingerprint
        self.createdAt = Date()
        self.updatedAt = Date()
        self.whisper = whisper
        self.whisperCandidate = nil
        self.vibeVoice = nil
        self.blindGemma = nil
        self.fused = nil
        self.gemmaDecisions = []
        self.benchmarkReport = nil
        self.requiresSpeakerReprocessing = nil
        self.postProcessingRequirements = nil
        self.cumulativeInputTokens = 0
        self.peakRAMBytes = nil
        self.gemmaTextTraces = nil
        self.gemmaCompletedTurns = nil
        self.gemmaTotalTurns = nil
        self.consensusVariants = nil
        self.requestedConsensusStrategies = nil
        self.completedAt = nil
    }

    /// Clears exactly the selected candidate and every downstream product that could otherwise
    /// be mistaken for output derived from the fresh run.
    mutating func invalidateForRerun(
        _ scope: NightlyQualityRerunScope,
        at date: Date = Date()
    ) {
        switch scope {
        case .whisper:
            whisperCandidate = nil
        case .vibeVoice:
            vibeVoice = nil
        case .consensus:
            break
        case .allCandidates:
            whisperCandidate = nil
            vibeVoice = nil
        }
        blindGemma = nil
        fused = nil
        gemmaDecisions = []
        benchmarkReport = nil
        requiresSpeakerReprocessing = nil
        postProcessingRequirements = nil
        gemmaTextTraces = nil
        gemmaCompletedTurns = nil
        gemmaTotalTurns = nil
        if scope != .consensus {
            consensusVariants = nil
        }
        requestedConsensusStrategies = nil
        cumulativeInputTokens = 0
        completedAt = nil
        updatedAt = date
    }
}

/// Candidate timestamps are useful evidence, not ground truth. Segments with foreground support
/// are deterministically anchored to known utterance ranges. Unsupported additions remain marked
/// approximate and must go through acoustic alignment before they can become live rows.
enum NightlyFusionTimelineAligner {
    static func align(
        _ fused: [NightlyQualityCandidateSegment],
        to baseline: [NightlyQualityCandidateSegment]
    ) -> [NightlyQualityCandidateSegment] {
        let baselineByID = Dictionary(
            uniqueKeysWithValues: baseline.compactMap { segment in
                segment.utteranceID.map { ($0, segment) }
            }
        )
        var aligned = fused.map { segment -> NightlyQualityCandidateSegment in
            var copy = segment
            guard let ids = segment.supportingUtteranceIDs, !ids.isEmpty else {
                copy.alignmentMethod = "gemma_approximate"
                return copy
            }
            let anchors = ids.compactMap { baselineByID[$0] }
            guard anchors.count == ids.count,
                  let start = anchors.map(\.startTime).min(),
                  let end = anchors.map(\.endTime).max(),
                  end > start else {
                copy.alignmentMethod = "gemma_approximate"
                return copy
            }
            copy = replacingTimes(copy, start: start, end: end)
            copy.alignmentMethod = ids.count == 1
                ? "foreground_anchor"
                : "foreground_anchor_union"
            return copy
        }

        // When fusion split one foreground utterance, partition that known interval by output word
        // mass so the proposal has non-overlapping, monotonic review clips.
        let splitGroups = Dictionary(grouping: aligned.indices.filter { index in
            aligned[index].supportingUtteranceIDs?.count == 1
        }) { index in
            aligned[index].supportingUtteranceIDs?.first ?? -1
        }
        for (id, indices) in splitGroups where indices.count > 1 {
            guard let anchor = baselineByID[id], anchor.endTime > anchor.startTime else { continue }
            let ordered = indices.sorted {
                fused[$0].startTime != fused[$1].startTime
                    ? fused[$0].startTime < fused[$1].startTime
                    : $0 < $1
            }
            let weights = ordered.map {
                max(1, fused[$0].text.split(whereSeparator: \.isWhitespace).count)
            }
            let totalWeight = max(1, weights.reduce(0, +))
            var cursor = anchor.startTime
            for (offset, index) in ordered.enumerated() {
                let end = offset == ordered.count - 1
                    ? anchor.endTime
                    : cursor + (anchor.endTime - anchor.startTime)
                        * Double(weights[offset]) / Double(totalWeight)
                aligned[index] = replacingTimes(aligned[index], start: cursor, end: end)
                aligned[index].alignmentMethod = "foreground_anchor_partition"
                cursor = end
            }
        }
        return aligned
    }

    private static func replacingTimes(
        _ segment: NightlyQualityCandidateSegment,
        start: TimeInterval,
        end: TimeInterval
    ) -> NightlyQualityCandidateSegment {
        NightlyQualityCandidateSegment(
            utteranceID: segment.utteranceID,
            startTime: start,
            endTime: end,
            text: segment.text,
            speakerUUID: segment.speakerUUID,
            speakerLabel: segment.speakerLabel,
            userProtected: segment.userProtected,
            originalASRText: segment.originalASRText,
            confidence: segment.confidence,
            source: segment.source,
            supportingUtteranceIDs: segment.supportingUtteranceIDs,
            alignmentMethod: segment.alignmentMethod
        )
    }
}

enum NightlyQualityBenchmark {
    static func evaluate(_ artifact: NightlyQualityArtifact) -> NightlyQualityBenchmarkReport {
        let references = artifact.whisper.segments.filter(\.userProtected)
        var candidates: [(String, NightlyQualityCandidate?)] = [
            ("foreground_asr", artifact.whisper),
            ("whisper", artifact.whisperCandidate),
            ("vibevoice", artifact.vibeVoice),
            ("blind_gemma", artifact.blindGemma),
            ("consensus", artifact.fused)
        ]
        candidates.append(contentsOf: (artifact.consensusVariants ?? []).map {
            ("consensus_\($0.strategy.rawValue)", Optional($0.candidate))
        })
        let metrics = candidates.compactMap { name, candidate -> NightlyQualityCandidateMetrics? in
            guard let candidate else { return nil }
            var wordErrors = 0
            var wordCount = 0
            var characterErrors = 0
            var characterCount = 0
            for reference in references {
                let gold = reference.text
                let hypothesis: String
                if name == "foreground_asr" {
                    hypothesis = reference.originalASRText ?? reference.text
                } else {
                    hypothesis = candidate.segments
                        .filter {
                            $0.endTime > reference.startTime
                                && $0.startTime < reference.endTime
                        }
                        .sorted { $0.startTime < $1.startTime }
                        .map(\.text)
                        .joined(separator: " ")
                }
                let goldWords = normalizedWords(gold)
                let candidateWords = normalizedWords(hypothesis)
                wordErrors += editDistance(goldWords, candidateWords)
                wordCount += goldWords.count

                let goldCharacters = Array(normalizedCharacters(gold))
                let candidateCharacters = Array(normalizedCharacters(hypothesis))
                characterErrors += editDistance(goldCharacters, candidateCharacters)
                characterCount += goldCharacters.count
            }
            let boundary = boundaryCounts(
                references: references,
                candidate: name == "foreground_asr" ? artifact.whisper : candidate
            )
            return NightlyQualityCandidateMetrics(
                candidate: name,
                referenceSegmentCount: references.count,
                wordErrors: wordErrors,
                referenceWordCount: wordCount,
                characterErrors: characterErrors,
                referenceCharacterCount: characterCount,
                matchedBoundaries: boundary.matched,
                referenceBoundaryCount: boundary.reference,
                candidateBoundaryCount: boundary.candidate
            )
        }
        return NightlyQualityBenchmarkReport(
            createdAt: Date(),
            protectedReferenceSegmentCount: references.count,
            metrics: metrics
        )
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private static func normalizedCharacters(_ text: String) -> String {
        normalizedWords(text).joined(separator: " ")
    }

    private static func boundaryCounts(
        references: [NightlyQualityCandidateSegment],
        candidate: NightlyQualityCandidate
    ) -> (matched: Int, reference: Int, candidate: Int) {
        guard !references.isEmpty else { return (0, 0, 0) }
        let referenceEnds = references.map(\.endTime).sorted()
        var candidateEnds = candidate.segments
            .filter { segment in
                references.contains {
                    segment.endTime > $0.startTime && segment.startTime < $0.endTime
                }
            }
            .map(\.endTime)
            .sorted()
        var matched = 0
        for referenceEnd in referenceEnds {
            guard let best = candidateEnds.indices.min(by: {
                abs(candidateEnds[$0] - referenceEnd)
                    < abs(candidateEnds[$1] - referenceEnd)
            }), abs(candidateEnds[best] - referenceEnd) <= 0.75 else {
                continue
            }
            matched += 1
            candidateEnds.remove(at: best)
        }
        return (
            matched,
            referenceEnds.count,
            candidate.segments.filter { segment in
                references.contains {
                    segment.endTime > $0.startTime && segment.startTime < $0.endTime
                }
            }.count
        )
    }

    private static func editDistance<Element: Equatable>(
        _ reference: [Element],
        _ hypothesis: [Element]
    ) -> Int {
        if reference.isEmpty { return hypothesis.count }
        if hypothesis.isEmpty { return reference.count }
        var previous = Array(0...hypothesis.count)
        for (referenceIndex, referenceValue) in reference.enumerated() {
            var current = [referenceIndex + 1]
            current.reserveCapacity(hypothesis.count + 1)
            for (hypothesisIndex, hypothesisValue) in hypothesis.enumerated() {
                current.append(min(
                    current[hypothesisIndex] + 1,
                    previous[hypothesisIndex + 1] + 1,
                    previous[hypothesisIndex]
                        + (referenceValue == hypothesisValue ? 0 : 1)
                ))
            }
            previous = current
        }
        return previous[hypothesis.count]
    }
}

/// Production candidates are private user data. They live under Application Support, never in the
/// repository, and are written atomically so a crash cannot leave a half-decodable artifact.
struct NightlyQualityArtifactStore {
    static let shared = NightlyQualityArtifactStore()

    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            self.directory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            .appendingPathComponent("AlmRecorder/NightlyQuality", isDirectory: true)
        }
    }

    func artifactURL(recordingID: Int64) -> URL {
        directory.appendingPathComponent("\(recordingID).json")
    }

    func load(recordingID: Int64) -> NightlyQualityArtifact? {
        guard let data = try? Data(contentsOf: artifactURL(recordingID: recordingID)) else {
            return nil
        }
        return try? JSONDecoder().decode(NightlyQualityArtifact.self, from: data)
    }

    /// Current-schema artifacts with durable work that did not reach completion. Enumeration is
    /// intentionally filename-independent: a corrupt or manually copied file is ignored, while a
    /// valid artifact's embedded recording ID remains authoritative.
    func resumableRecordingIDs() -> Set<Int64> {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return Set(urls.compactMap { url -> Int64? in
            guard url.pathExtension.lowercased() == "json",
                  let data = try? Data(contentsOf: url),
                  let artifact = try? JSONDecoder().decode(
                      NightlyQualityArtifact.self,
                      from: data
                  ),
                  artifact.schemaVersion == NightlyQualityArtifact.schemaVersion,
                  artifact.completedAt == nil,
                  artifact.hasDurableCheckpoint else { return nil }
            return artifact.recordingID
        })
    }

    func save(_ artifact: NightlyQualityArtifact) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(artifact)
        let destination = artifactURL(recordingID: artifact.recordingID)
        let temporary = directory.appendingPathComponent(
            ".\(artifact.recordingID)-\(UUID().uuidString).tmp"
        )
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(
                destination,
                withItemAt: temporary
            )
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    static func audioFingerprint(path: String, duration: TimeInterval) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size):\(Int64(modified)):\(Int64(duration * 1_000))"
    }

    /// The refinement input changes when either the audio changes or foreground ASR commits a
    /// new transcript for the same immutable audio file. Manual text edits do not change
    /// `transcribedAt`, so they stay protected instead of causing an automatic rerun.
    static func inputFingerprint(
        path: String,
        duration: TimeInterval,
        transcribedAt: Date?
    ) -> String {
        let audio = audioFingerprint(path: path, duration: duration)
        let transcriptRevision = Int64(
            (transcribedAt?.timeIntervalSince1970 ?? 0) * 1_000
        )
        return "\(audio):\(transcriptRevision)"
    }

    func isCompleted(recordingID: Int64, fingerprint: String) -> Bool {
        guard let artifact = load(recordingID: recordingID) else { return false }
        return artifact.schemaVersion == NightlyQualityArtifact.schemaVersion
            && artifact.audioFingerprint == fingerprint
            && artifact.completedAt != nil
    }

    /// Completion is only reusable while both immutable audio/ASR provenance and the editable
    /// foreground reference still match. User corrections therefore become fresh private gold
    /// automatically instead of leaving an apparently complete artifact with stale references.
    func isCompleted(
        recordingID: Int64,
        fingerprint: String,
        foregroundSegments: [NightlyQualityCandidateSegment]
    ) -> Bool {
        guard let artifact = load(recordingID: recordingID) else { return false }
        return artifact.schemaVersion == NightlyQualityArtifact.schemaVersion
            && artifact.audioFingerprint == fingerprint
            && artifact.whisper.segments == foregroundSegments
            && artifact.completedAt != nil
    }

    /// A rollout or scope change must not abandon expensive model output already saved for the
    /// same immutable audio and foreground transcript. Stale schema/audio/text artifacts remain
    /// private history but never re-enter the automatic queue.
    func isResumable(
        recordingID: Int64,
        fingerprint: String,
        foregroundSegments: [NightlyQualityCandidateSegment]
    ) -> Bool {
        guard let artifact = load(recordingID: recordingID) else { return false }
        return artifact.schemaVersion == NightlyQualityArtifact.schemaVersion
            && artifact.audioFingerprint == fingerprint
            && artifact.whisper.segments == foregroundSegments
            && artifact.completedAt == nil
            && artifact.hasDurableCheckpoint
    }
}

private extension NightlyQualityArtifact {
    /// The committed VibeVoice structure anchor alone is a meaningful checkpoint: recreating the
    /// plan must resume with independent Whisper rather than silently dropping the enrolled call.
    var hasDurableCheckpoint: Bool {
        whisperCandidate != nil
            || vibeVoice != nil
            || blindGemma != nil
            || fused != nil
            || !gemmaDecisions.isEmpty
            || !(gemmaTextTraces ?? []).isEmpty
            || (gemmaCompletedTurns ?? 0) > 0
            || !(consensusVariants ?? []).isEmpty
    }
}
