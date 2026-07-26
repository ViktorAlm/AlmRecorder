import Foundation
import AlmRecorderEvaluationKit

struct VibeVoiceGoldBenchmarkConfiguration: Codable, Equatable, Hashable, Identifiable {
    let quantization: VibeVoiceQuantization
    let speakerMode: VibeVoiceSpeakerMode
    let modelRevision: String
    let runtimeRevision: String

    var id: String {
        "\(quantization.rawValue)-\(speakerMode.rawValue)-\(modelRevision)-\(runtimeRevision)"
    }

    var displayName: String {
        "\(quantization.displayName) · \(speakerMode.displayName)"
    }

    static func current(
        quantization: VibeVoiceQuantization,
        speakerMode: VibeVoiceSpeakerMode
    ) -> Self {
        Self(
            quantization: quantization,
            speakerMode: speakerMode,
            modelRevision: VibeVoiceConfiguration.modelRevision(for: quantization),
            runtimeRevision: VibeVoiceConfiguration.mlxAudioRevision
        )
    }
}

struct VibeVoiceGoldMetrics: Codable, Equatable {
    let recordingCount: Int
    let evaluatedReferenceWords: Int
    let evaluatedReferenceCharacters: Int
    let wordErrorRate: Double?
    let characterErrorRate: Double?
    let wordDiarizationErrorRate: Double?
    let speakerCountMeanAbsoluteError: Double
    let mixedSpeakerTranscriptSegmentRate: Double?
    let transcriptSegmentCount: Int
    let wallClockSeconds: TimeInterval
    let modelProcessingSeconds: TimeInterval?
    let peakMemoryGB: Double?
    let audioSeconds: TimeInterval
    let realTimeFactor: Double?
}

struct VibeVoiceGoldTranscriptLine: Codable, Equatable, Identifiable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let speaker: String?
    let text: String

    var id: String {
        "\(startTime)-\(endTime)-\(speaker ?? "")-\(text)"
    }
}

struct VibeVoiceGoldCallResult: Codable, Equatable, Identifiable {
    let recordingID: Int64?
    let title: String
    let duration: TimeInterval
    let savedTranscript: [VibeVoiceGoldTranscriptLine]
    let predictedTranscript: [VibeVoiceGoldTranscriptLine]

    var id: String {
        recordingID.map(String.init) ?? "\(title)-\(duration)"
    }
}

struct VibeVoiceGoldBenchmarkReport: Codable, Equatable, Identifiable {
    let configuration: VibeVoiceGoldBenchmarkConfiguration
    let metrics: VibeVoiceGoldMetrics
    let callResults: [VibeVoiceGoldCallResult]?

    var id: String { configuration.id }
}

struct VibeVoiceGoldBenchmarkFailure: Codable, Equatable, Identifiable {
    let configuration: VibeVoiceGoldBenchmarkConfiguration
    let message: String

    var id: String { configuration.id }
}

struct VibeVoiceGoldBenchmarkBundle: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: Date
    let goldRevision: String
    let recordingIDs: [Int64]?
    let reports: [VibeVoiceGoldBenchmarkReport]
    let failures: [VibeVoiceGoldBenchmarkFailure]
}

struct VibeVoiceGoldBenchmarkProgress: Equatable, Sendable {
    let configurationName: String
    let configurationIndex: Int
    let configurationCount: Int
    let recordingIndex: Int
    let recordingCount: Int

    var fraction: Double {
        guard configurationCount > 0 else { return 0 }
        let completedConfigurations = Double(configurationIndex) / Double(configurationCount)
        let withinConfiguration = recordingCount > 0
            ? Double(recordingIndex) / Double(recordingCount * configurationCount)
            : 0
        return min(1, completedConfigurations + withinConfiguration)
    }

    var message: String {
        "\(configurationName) · conversation \(min(recordingIndex + 1, recordingCount)) of \(recordingCount)"
    }
}

enum VibeVoiceGoldBenchmarkStore {
    private static func store() throws
        -> JSONEvaluationArtifactStore<VibeVoiceGoldBenchmarkBundle> {
        try JSONEvaluationArtifactStore(
            workspace: EvaluationWorkspace.current(),
            fileName: "vibevoice-gold-benchmark.json"
        )
    }

    static func load() -> VibeVoiceGoldBenchmarkBundle? {
        try? store().load()
    }

    static func save(_ bundle: VibeVoiceGoldBenchmarkBundle) throws {
        try store().save(bundle)
    }
}

@MainActor
enum VibeVoiceGoldBenchmarkRunner {
    private struct ErrorCounts {
        var wordEdits = 0
        var referenceWords = 0
        var characterEdits = 0
        var referenceCharacters = 0
    }

    static func run(
        dataset: SpeakerEvaluationDataset,
        configurations: [VibeVoiceGoldBenchmarkConfiguration],
        speakerResolver: SpeakerNameResolver,
        progress: @escaping @MainActor (VibeVoiceGoldBenchmarkProgress) -> Void
    ) async -> VibeVoiceGoldBenchmarkBundle {
        _ = FileAccessManager.shared.getVoiceMemosURL()
        var reports: [VibeVoiceGoldBenchmarkReport] = []
        var failures: [VibeVoiceGoldBenchmarkFailure] = []

        for (configurationIndex, configuration) in configurations.enumerated() {
            do {
                let report = try await runConfiguration(
                    dataset: dataset,
                    configuration: configuration,
                    configurationIndex: configurationIndex,
                    configurationCount: configurations.count,
                    speakerResolver: speakerResolver,
                    progress: progress
                )
                reports.append(report)
            } catch is CancellationError {
                break
            } catch {
                failures.append(VibeVoiceGoldBenchmarkFailure(
                    configuration: configuration,
                    message: error.localizedDescription
                ))
            }
        }

        return VibeVoiceGoldBenchmarkBundle(
            schemaVersion: 1,
            generatedAt: Date(),
            goldRevision: dataset.goldRevision,
            recordingIDs: dataset.recordings.compactMap(\.recording.id),
            reports: reports,
            failures: failures
        )
    }

    private static func runConfiguration(
        dataset: SpeakerEvaluationDataset,
        configuration: VibeVoiceGoldBenchmarkConfiguration,
        configurationIndex: Int,
        configurationCount: Int,
        speakerResolver: SpeakerNameResolver,
        progress: @escaping @MainActor (VibeVoiceGoldBenchmarkProgress) -> Void
    ) async throws -> VibeVoiceGoldBenchmarkReport {
        guard !dataset.recordings.isEmpty else {
            throw VibeVoiceBenchmarkError.noGoldRecordings
        }
        guard VibeVoiceModelManager.shared.isModelDownloaded(configuration.quantization) else {
            throw VibeVoiceBenchmarkError.modelNotDownloaded(configuration.quantization.displayName)
        }

        let service = VibeVoiceService()
        try await service.validateRuntime()
        let speakerConfiguration = SpeakerPipelineSettings.shared.activeConfiguration
        var errorCounts = ErrorCounts()
        var predictedSegments: [SpeakerEvaluationSegment] = []
        var referenceSegments: [SpeakerEvaluationSegment] = []
        var countError = 0.0
        var audioSeconds = 0.0
        var modelProcessingSeconds = 0.0
        var peakMemoryGB: Double?
        var callResults: [VibeVoiceGoldCallResult] = []
        let startedAt = Date()

        for (recordingIndex, item) in dataset.recordings.enumerated() {
            try Task.checkCancellation()
            progress(VibeVoiceGoldBenchmarkProgress(
                configurationName: configuration.displayName,
                configurationIndex: configurationIndex,
                configurationCount: configurationCount,
                recordingIndex: recordingIndex,
                recordingCount: dataset.recordings.count
            ))
            guard let path = item.recording.filePath, !path.isEmpty,
                  FileManager.default.fileExists(atPath: path) else {
                throw VibeVoiceBenchmarkError.missingAudio(item.recording.title)
            }

            let selection = TranscriptionEngineSelection(
                backend: .vibeVoice,
                whisperVariantIdentifier: nil,
                llmEngine: nil,
                llmModelKey: nil,
                vibeVoiceQuantization: configuration.quantization,
                vibeVoiceSpeakerMode: configuration.speakerMode,
                vibeVoiceModelRevision: configuration.modelRevision,
                vibeVoiceRuntimeRevision: configuration.runtimeRevision,
                vibeVoiceContext: nil
            )
            _ = try await service.transcribe(
                audioFile: path,
                selection: selection,
                runSettings: RunSettings.defaultSettings,
                speakerConfiguration: speakerConfiguration
            )
            guard let result = service.lastTranscriptionResult else {
                throw VibeVoiceBenchmarkError.noResult(item.recording.title)
            }
            modelProcessingSeconds += service.lastModelProcessingSeconds ?? 0
            if let peak = service.lastPeakMemoryGB {
                peakMemoryGB = max(peakMemoryGB ?? 0, peak)
            }

            let referenceText = item.reference
                .sorted { $0.startTime < $1.startTime }
                .compactMap(\.text)
                .joined(separator: " ")
            let predictedText = result.chunks
                .sorted { $0.startTime < $1.startTime }
                .map(\.text)
                .joined(separator: " ")
            addTextErrors(reference: referenceText, predicted: predictedText, to: &errorCounts)
            callResults.append(VibeVoiceGoldCallResult(
                recordingID: item.recording.id,
                title: item.recording.title,
                duration: item.recording.duration ?? result.totalDuration,
                savedTranscript: item.reference
                    .sorted { $0.startTime < $1.startTime }
                    .compactMap { segment in
                        guard let text = segment.text?.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ), !text.isEmpty else {
                            return nil
                        }
                        return VibeVoiceGoldTranscriptLine(
                            startTime: segment.startTime,
                            endTime: segment.endTime,
                            speaker: displayName(
                                forReferenceSpeaker: segment.speakerKey,
                                resolver: speakerResolver
                            ),
                            text: text
                        )
                    },
                predictedTranscript: result.chunks
                    .sorted { $0.startTime < $1.startTime }
                    .compactMap { chunk in
                        let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return nil }
                        return VibeVoiceGoldTranscriptLine(
                            startTime: chunk.startTime,
                            endTime: chunk.endTime,
                            speaker: speakerResolver.displayName(
                                speakerUuid: chunk.speakerUUID,
                                localLabel: chunk.speaker
                            ),
                            text: text
                        )
                    }
            ))

            let referenceSpeakerCount = Set(item.reference.compactMap(\.speakerKey)).count
            let predictedSpeakerCount = Set(result.chunks.compactMap(\.speaker)).count
            countError += Double(abs(referenceSpeakerCount - predictedSpeakerCount))
            audioSeconds += item.recording.duration ?? result.totalDuration
            referenceSegments.append(contentsOf: item.reference)
            predictedSegments.append(contentsOf: result.chunks.compactMap { chunk in
                guard let localSpeaker = chunk.speaker else { return nil }
                return SpeakerEvaluationSegment(
                    recordingKey: item.recordingKey,
                    speakerKey: "\(item.recordingKey):\(localSpeaker)",
                    startTime: chunk.startTime,
                    endTime: chunk.endTime,
                    text: chunk.text,
                    timingIsGold: false
                )
            })
        }

        let speakerMetrics = SpeakerPipelineEvaluator.evaluate(
            reference: referenceSegments,
            predicted: predictedSegments
        )
        let elapsed = Date().timeIntervalSince(startedAt)
        let metrics = VibeVoiceGoldMetrics(
            recordingCount: dataset.recordings.count,
            evaluatedReferenceWords: errorCounts.referenceWords,
            evaluatedReferenceCharacters: errorCounts.referenceCharacters,
            wordErrorRate: rate(errorCounts.wordEdits, errorCounts.referenceWords),
            characterErrorRate: rate(
                errorCounts.characterEdits,
                errorCounts.referenceCharacters
            ),
            wordDiarizationErrorRate: speakerMetrics.wordDiarizationErrorRate,
            speakerCountMeanAbsoluteError: countError
                / Double(max(1, dataset.recordings.count)),
            mixedSpeakerTranscriptSegmentRate: speakerMetrics.mixedSpeakerTranscriptSegmentRate,
            transcriptSegmentCount: predictedSegments.count,
            wallClockSeconds: elapsed,
            modelProcessingSeconds: modelProcessingSeconds > 0
                ? modelProcessingSeconds
                : nil,
            peakMemoryGB: peakMemoryGB,
            audioSeconds: audioSeconds,
            realTimeFactor: audioSeconds > 0 ? elapsed / audioSeconds : nil
        )
        return VibeVoiceGoldBenchmarkReport(
            configuration: configuration,
            metrics: metrics,
            callResults: callResults
        )
    }

    private static func displayName(
        forReferenceSpeaker speakerKey: String?,
        resolver: SpeakerNameResolver
    ) -> String? {
        guard let speakerKey, !speakerKey.isEmpty else { return nil }
        if speakerKey.hasPrefix("local:") {
            return speakerKey.split(separator: ":").last.map(String.init)
        }
        return resolver.displayName(forUuid: speakerKey)
    }

    private static func addTextErrors(
        reference: String,
        predicted: String,
        to counts: inout ErrorCounts
    ) {
        let referenceWords = normalizedWords(reference)
        let predictedWords = normalizedWords(predicted)
        counts.wordEdits += editDistance(referenceWords, predictedWords)
        counts.referenceWords += referenceWords.count

        let referenceCharacters = Array(referenceWords.joined())
        let predictedCharacters = Array(predictedWords.joined())
        counts.characterEdits += editDistance(referenceCharacters, predictedCharacters)
        counts.referenceCharacters += referenceCharacters.count
    }

    private static func normalizedWords(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive], locale: .current)
        let separator = UnicodeScalar(" ")
        var normalized = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            normalized.append(
                CharacterSet.alphanumerics.contains(scalar) ? scalar : separator
            )
        }
        return String(normalized)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private static func editDistance<Element: Equatable>(
        _ left: [Element],
        _ right: [Element]
    ) -> Int {
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }
        var previous = Array(0...right.count)
        for (leftIndex, leftElement) in left.enumerated() {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = leftIndex + 1
            for (rightIndex, rightElement) in right.enumerated() {
                current[rightIndex + 1] = min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftElement == rightElement ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[right.count]
    }

    private static func rate(_ numerator: Int, _ denominator: Int) -> Double? {
        denominator > 0 ? Double(numerator) / Double(denominator) : nil
    }

    private enum VibeVoiceBenchmarkError: LocalizedError {
        case noGoldRecordings
        case modelNotDownloaded(String)
        case missingAudio(String)
        case noResult(String)

        var errorDescription: String? {
            switch self {
            case .noGoldRecordings:
                return "No confirmed Speaker gold conversations are available."
            case .modelNotDownloaded(let name):
                return "\(name) is not downloaded."
            case .missingAudio(let title):
                return "Audio is unavailable for “\(title)”."
            case .noResult(let title):
                return "VibeVoice returned no structured result for “\(title)”."
            }
        }
    }
}
