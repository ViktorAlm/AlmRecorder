import Foundation
import XCTest
@testable import AlmRecorder

/// Opt-in, no-mock verification of the production quality pipeline.
///
/// The test source is public, but its audio fixture and installed models stay outside Git. It
/// refuses to run against the developer's normal Application Support directory and never downloads
/// a missing model or writes to the transcript database.
///
///     ALMREC_PRODUCTION_CHAIN_AUDIO=/absolute/path/to/owned-or-synthetic.wav \
///       ALMREC_PRODUCTION_CHAIN_ISOLATED_HOME=1 \
///       ALMREC_PRODUCTION_CHAIN_HOME=/private/tmp/disposable-home \
///       HOME=/private/tmp/disposable-home \
///       CFFIXED_USER_HOME=/private/tmp/disposable-home \
///       swift test --filter ProductionThreeStageLiveTests
final class ProductionThreeStageLiveTests: XCTestCase {
    private static let whisperIdentifier = "OpenAI Whisper-large-v3-q5_0"
    private static let gemmaModelKey = "12B-Q5_K_M"

    func testVibeVoiceWhisperGemmaAndCleanupUseRealProductionServices() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let audioPath = environment["ALMREC_PRODUCTION_CHAIN_AUDIO"],
              !audioPath.isEmpty else {
            throw XCTSkip(
                "Set ALMREC_PRODUCTION_CHAIN_AUDIO to run the real VibeVoice -> Whisper -> Gemma chain."
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: audioPath),
            "The live-test audio fixture does not exist."
        )

        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].standardizedFileURL.path
        let expectedHome = environment["ALMREC_PRODUCTION_CHAIN_HOME"].map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        guard environment["ALMREC_PRODUCTION_CHAIN_ISOLATED_HOME"] == "1",
              let expectedHome,
              expectedHome.hasPrefix("/tmp/") || expectedHome.hasPrefix("/private/tmp/"),
              applicationSupport.hasPrefix(expectedHome + "/") else {
            XCTFail(
                "Refusing the live chain outside a disposable home. Set HOME and "
                    + "CFFIXED_USER_HOME to a temporary directory, set "
                    + "ALMREC_PRODUCTION_CHAIN_HOME to that directory, and opt in with "
                    + "ALMREC_PRODUCTION_CHAIN_ISOLATED_HOME=1. Resolved Application Support: "
                    + applicationSupport
            )
            return
        }

        let vibeQuantization = VibeVoiceQuantization.fourBit
        let whisperVariant = try XCTUnwrap(
            WhisperModelVariant.fromIdentifier(Self.whisperIdentifier),
            "The production Whisper large-v3 q5_0 variant is not in the catalog."
        )
        let gemmaModels = GemmaModelManager()

        XCTAssertTrue(
            VibeVoiceModelManager.shared.isModelDownloaded(vibeQuantization),
            "VibeVoice 4-bit is not installed; this test never downloads models."
        )
        XCTAssertTrue(
            WhisperModelManager.shared.isModelDownloaded(whisperVariant),
            "Whisper large-v3 q5_0 is not installed; this test never downloads models."
        )
        XCTAssertTrue(
            gemmaModels.isAudioModelDownloaded(Self.gemmaModelKey),
            "Gemma 12B Q5_K_M and its audio projector are not installed; this test never downloads models."
        )

        let vibeSelection = TranscriptionEngineSelection(
            backend: .vibeVoice,
            whisperVariantIdentifier: nil,
            llmEngine: nil,
            llmModelKey: nil,
            vibeVoiceQuantization: vibeQuantization,
            vibeVoiceSpeakerMode: .fused,
            vibeVoiceModelRevision: VibeVoiceConfiguration.modelRevision(for: vibeQuantization),
            vibeVoiceRuntimeRevision: VibeVoiceConfiguration.mlxAudioRevision,
            vibeVoiceContext: nil
        )
        let vibeService = VibeVoiceService()
        _ = try await vibeService.transcribe(
            audioFile: audioPath,
            selection: vibeSelection,
            runSettings: .defaultSettings,
            speakerConfiguration: SpeakerPipelineSettings.shared.activeConfiguration
        )
        let vibeResult = try XCTUnwrap(vibeService.lastTranscriptionResult)
        XCTAssertFalse(vibeResult.chunks.isEmpty, "VibeVoice produced no timestamped turns.")
        XCTAssertTrue(vibeResult.chunks.allSatisfy {
            $0.endTime > $0.startTime && ($0.nativeSpeakerLabel ?? $0.speaker) != nil
        })

        let whisperResult = try await WhisperService.shared.transcribeWithResult(
            audioFile: audioPath,
            variant: whisperVariant,
            language: nil,
            speakerConfiguration: SpeakerPipelineSettings.shared.activeConfiguration,
            persistSpeakerIdentities: false
        )
        XCTAssertFalse(whisperResult.chunks.isEmpty, "Whisper produced no timestamped evidence.")

        let foregroundSegments = vibeResult.chunks.enumerated().map { index, chunk in
            NightlyQualityCandidateSegment(
                utteranceID: Int64(index + 1),
                startTime: chunk.startTime,
                endTime: chunk.endTime,
                text: chunk.text,
                speakerUUID: chunk.speakerUUID,
                speakerLabel: chunk.nativeSpeakerLabel ?? chunk.speaker,
                userProtected: false,
                originalASRText: chunk.text,
                confidence: chunk.confidence.map { String($0) },
                source: "vibevoice_live_foreground",
                supportingUtteranceIDs: [Int64(index + 1)],
                alignmentMethod: "vibevoice_native_turn"
            )
        }
        let foreground = NightlyQualityCandidate(
            engine: .vibeVoice,
            model: vibeSelection.displayName,
            createdAt: Date(),
            segments: foregroundSegments
        )
        let whisperCandidate = NightlyQualityCandidate(
            engine: .whisper,
            model: "Whisper - \(whisperVariant.displayName)",
            createdAt: Date(),
            segments: whisperResult.chunks.map { chunk in
                NightlyQualityCandidateSegment(
                    utteranceID: nil,
                    startTime: chunk.startTime,
                    endTime: chunk.endTime,
                    text: chunk.text,
                    speakerUUID: nil,
                    speakerLabel: chunk.nativeSpeakerLabel ?? chunk.speaker,
                    userProtected: false,
                    confidence: chunk.confidence.map { String($0) },
                    source: "whisper_live_candidate"
                )
            }
        )
        var artifact = NightlyQualityArtifact(
            recordingID: -1,
            audioFingerprint: "public-live-test",
            whisper: foreground
        )
        artifact.vibeVoice = foreground
        artifact.whisperCandidate = whisperCandidate

        let finalizer = GemmaMultimodalConsensusFinalizer(
            maximumInputTokens: 12_000,
            modelKey: Self.gemmaModelKey,
            strategy: .readableReconstruction
        )
        let gemma = try await finalizer.finalize(
            artifact: artifact,
            audioPath: audioPath,
            language: vibeResult.language
        )

        XCTAssertEqual(gemma.fusedCandidate.segments.count, foregroundSegments.count)
        XCTAssertFalse(gemma.fusedCandidate.segments.isEmpty)
        XCTAssertEqual(gemma.decisions.count, foregroundSegments.count)
        XCTAssertFalse(gemma.textTraces.isEmpty, "Gemma produced no auditable model traces.")
        XCTAssertTrue(gemma.textTraces.allSatisfy { $0.parsedSuccessfully })
        XCTAssertTrue(gemma.textTraces.allSatisfy { $0.audioGrounded == true })
        XCTAssertTrue(gemma.textTraces.allSatisfy { !($0.audioClipRanges ?? []).isEmpty })

        for (locked, final) in zip(foregroundSegments, gemma.fusedCandidate.segments) {
            XCTAssertEqual(final.startTime, locked.startTime, accuracy: 0.000_001)
            XCTAssertEqual(final.endTime, locked.endTime, accuracy: 0.000_001)
            XCTAssertEqual(final.speakerUUID, locked.speakerUUID)
            XCTAssertEqual(final.speakerLabel, locked.speakerLabel)
            XCTAssertEqual(final.supportingUtteranceIDs, locked.supportingUtteranceIDs)
            XCTAssertFalse(
                final.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty
            )
        }

        let cleanup = TranscriptSuspicionScorer.score(
            gemma.fusedCandidate.segments.map { segment in
                TranscriptSuspicionScorer.Input(
                    text: segment.text,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    speaker: segment.speakerLabel,
                    meanP: nil,
                    minP: nil,
                    lowFrac: nil
                )
            }
        )
        XCTAssertEqual(cleanup.count, gemma.fusedCandidate.segments.count)

        let acceptedRepairs = gemma.fusedCandidate.segments.filter {
            $0.source == "gemma_audio_consensus"
        }.count
        print(
            "REAL_PRODUCTION_CHAIN_OK vibe_turns=\(vibeResult.chunks.count) "
                + "whisper_turns=\(whisperResult.chunks.count) "
                + "gemma_turns=\(gemma.fusedCandidate.segments.count) "
                + "accepted_repairs=\(acceptedRepairs) cleanup_scored=\(cleanup.count)"
        )
    }
}
