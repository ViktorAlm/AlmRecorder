import Foundation
import XCTest
@testable import AlmRecorder

final class VibeVoiceRecoverySafetyTests: XCTestCase {
    func testHelperRecoveryTelemetrySurvivesTheSwiftContract() throws {
        let data = Data("""
        {
          "schema_version": 1,
          "generation_tokens": 8192,
          "output_recovered": true,
          "output_likely_truncated": false,
          "segments": [
            {"start":0,"end":2,"speaker":"7","text":"recovered"}
          ]
        }
        """.utf8)

        let output = try VibeVoiceOutputParser.parse(data, duration: 2)

        XCTAssertEqual(output.chunks.map(\.text), ["recovered"])
        XCTAssertEqual(output.generationTokens, 8192)
        XCTAssertTrue(output.outputRecovered)
        XCTAssertFalse(output.outputLikelyTruncated)
    }

    func testMalformedOutputRecoveryIsBoundedAndGetsSmaller() throws {
        XCTAssertEqual(
            VibeVoiceService.recoveryChunkDuration(
                audioDuration: 15 * 60,
                recoveryDepth: 0
            ),
            5 * 60
        )
        XCTAssertEqual(
            VibeVoiceService.recoveryChunkDuration(
                audioDuration: 5 * 60,
                recoveryDepth: 1
            ),
            100
        )
        XCTAssertEqual(
            try XCTUnwrap(VibeVoiceService.recoveryChunkDuration(
                audioDuration: 100,
                recoveryDepth: 2
            )),
            100.0 / 3.0,
            accuracy: 0.001
        )
        XCTAssertNil(VibeVoiceService.recoveryChunkDuration(
            audioDuration: 100,
            recoveryDepth: 3
        ))
        XCTAssertTrue(
            VibeVoiceService.shouldRetryTerminalWindow(recoveryDepth: 3, attempt: 0)
        )
        XCTAssertFalse(
            VibeVoiceService.shouldRetryTerminalWindow(recoveryDepth: 3, attempt: 1)
        )
    }

    func testOnlyOutputShapeFailuresTriggerRecovery() {
        XCTAssertTrue(VibeVoiceService.isRecoverableOutputError(
            TranscriptionError.processFailed(
                "ALMREC_VIBEVOICE_RECOVERABLE_OUTPUT complete_json=False"
            )
        ))
        XCTAssertFalse(VibeVoiceService.isRecoverableOutputError(
            TranscriptionError.processFailed("ffmpeg not found")
        ))
        XCTAssertFalse(VibeVoiceService.isRecoverableOutputError(
            TranscriptionError.gpuOutOfMemory("metal allocation failed")
        ))
    }

    func testVibeVoiceResumeUsesOnlyAContiguousBackendTaggedPrefix() {
        var checkpoint = TranscriptionCheckpoint.empty
        checkpoint.backend = .vibeVoice
        checkpoint.processedChunks = [0, 1, 3]
        checkpoint.chunkTranscripts = [
            0: [.init(text: "zero", startTime: 0, endTime: 1, speaker: "A", speakerUUID: nil)],
            1: [.init(text: "one", startTime: 1, endTime: 2, speaker: "A", speakerUUID: nil)],
            3: [.init(text: "three", startTime: 3, endTime: 4, speaker: "B", speakerUUID: nil)],
        ]

        XCTAssertEqual(
            VibeVoiceService.restorableWindowIndices(
                checkpoint: checkpoint,
                windowCount: 5
            ),
            [0, 1]
        )

        checkpoint.backend = .whisper
        XCTAssertTrue(VibeVoiceService.restorableWindowIndices(
            checkpoint: checkpoint,
            windowCount: 5
        ).isEmpty)
    }

    func testCheckpointRoundTripPreservesNativeSpeakerProvenance() throws {
        let original = TranscriptionChunk(
            text: "checkpointed",
            startTime: 12,
            endTime: 14,
            speaker: "VibeVoice Speaker 2",
            speakerUUID: nil,
            nativeSpeakerLabel: "VibeVoice Speaker 2",
            confidence: nil
        )
        var checkpoint = TranscriptionCheckpoint.empty
        checkpoint.backend = .vibeVoice
        checkpoint.processedChunks = [0]
        checkpoint.chunkTranscripts[0] = [.init(chunk: original)]
        checkpoint.chunkOffsets[0] = 15 * 60
        checkpoint.vibeVoiceRecoveryDepths = [1: 2]

        let decoded = try JSONDecoder().decode(
            TranscriptionCheckpoint.self,
            from: JSONEncoder().encode(checkpoint)
        )
        let restored = try XCTUnwrap(decoded.chunkTranscripts[0]?.first?.transcriptionChunk)

        XCTAssertEqual(decoded.backend, .vibeVoice)
        XCTAssertEqual(decoded.vibeVoiceRecoveryDepths, [1: 2])
        XCTAssertEqual(restored.text, original.text)
        XCTAssertEqual(restored.startTime, original.startTime)
        XCTAssertEqual(restored.endTime, original.endTime)
        XCTAssertEqual(restored.speaker, original.speaker)
        XCTAssertEqual(restored.nativeSpeakerLabel, original.nativeSpeakerLabel)
    }

    func testLegacyWhisperCheckpointStillDecodesWithoutBackendTag() throws {
        let legacy = Data("""
        {
          "processedChunks":[0],
          "chunkTranscripts":{"0":[{
            "text":"legacy","startTime":0,"endTime":1,
            "speaker":null,"speakerUUID":null
          }]},
          "chunkOffsets":{"0":1},
          "lastProcessedTime":0
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(TranscriptionCheckpoint.self, from: legacy)

        XCTAssertNil(decoded.backend)
        XCTAssertNil(decoded.vibeVoiceRecoveryDepths)
        XCTAssertNil(decoded.chunkTranscripts[0]?.first?.nativeSpeakerLabel)
        XCTAssertEqual(decoded.chunkTranscripts[0]?.first?.text, "legacy")
        XCTAssertNotNil(TranscriptionCheckpointRouting.reusable(decoded, for: .whisper))
        XCTAssertNil(TranscriptionCheckpointRouting.reusable(decoded, for: .vibeVoice))
    }

    func testBackendTaggedCheckpointsCannotCrossEngines() {
        var vibeVoice = TranscriptionCheckpoint.empty
        vibeVoice.backend = .vibeVoice
        var whisper = TranscriptionCheckpoint.empty
        whisper.backend = .whisper

        XCTAssertNotNil(TranscriptionCheckpointRouting.reusable(vibeVoice, for: .vibeVoice))
        XCTAssertNil(TranscriptionCheckpointRouting.reusable(vibeVoice, for: .whisper))
        XCTAssertNotNil(TranscriptionCheckpointRouting.reusable(whisper, for: .whisper))
        XCTAssertNil(TranscriptionCheckpointRouting.reusable(whisper, for: .vibeVoice))
    }

    func testWhisperTerminalFallbackPreservesTimingAndMarksProvenance() throws {
        var source = TranscriptionChunk(
            text: "recovered words",
            startTime: 1.25,
            endTime: 4.5,
            speaker: "Speaker 2",
            speakerUUID: "must-not-cross-recordings",
            nativeSpeakerLabel: "local-2",
            confidence: 0.91
        )
        source.voiceEmbedding = [0.1, 0.2]
        source.voiceEmbeddingQuality = 0.8

        let mapped = try XCTUnwrap(VibeVoiceService.offsetWhisperFallbackChunks(
            [source],
            offset: 900,
            duration: 33
        ).first)

        XCTAssertEqual(mapped.text, "recovered words")
        XCTAssertEqual(mapped.startTime, 901.25, accuracy: 0.001)
        XCTAssertEqual(mapped.endTime, 904.5, accuracy: 0.001)
        XCTAssertEqual(mapped.speaker, "Whisper fallback local-2")
        XCTAssertEqual(mapped.nativeSpeakerLabel, "Whisper fallback local-2")
        XCTAssertNil(mapped.speakerUUID)
        XCTAssertEqual(mapped.voiceEmbedding ?? [], [0.1, 0.2])
        XCTAssertEqual(mapped.voiceEmbeddingQuality, 0.8)
    }
}
