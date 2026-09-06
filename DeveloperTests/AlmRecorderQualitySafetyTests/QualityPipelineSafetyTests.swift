import Foundation
import XCTest
@testable import AlmRecorder

final class QualityPipelineSafetyTests: XCTestCase {
    private func segment(text: String = "foreground") -> NightlyQualityCandidateSegment {
        NightlyQualityCandidateSegment(
            utteranceID: 11,
            startTime: 1,
            endTime: 2,
            text: text,
            speakerUUID: "person-a",
            speakerLabel: "Speaker 0",
            userProtected: false
        )
    }

    private func candidate(
        engine: NightlyQualityCandidate.Engine,
        segments: [NightlyQualityCandidateSegment]
    ) -> NightlyQualityCandidate {
        NightlyQualityCandidate(
            engine: engine,
            model: engine.rawValue,
            createdAt: Date(timeIntervalSince1970: 10),
            segments: segments
        )
    }

    func testCleanupJobIdentityAndCreationDateSurvivePersistence() throws {
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_234)
        var job = TranscriptCleanupJob(
            id: id,
            recordingId: 42,
            recordingTitle: "Synthetic call", // privacy:allow-synthetic
            mode: .auto,
            force: true,
            priority: .high,
            createdAt: createdAt
        )
        job.status = .processing
        let decoded = try JSONDecoder().decode(
            TranscriptCleanupJob.self,
            from: JSONEncoder().encode(job)
        )
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.createdAt, createdAt)
        XCTAssertEqual(decoded.status, .processing)
    }

    func testMatchingPartialArtifactIsDiscoveredAndResumable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alm-quality-safety-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NightlyQualityArtifactStore(directory: root)
        let foreground = [segment()]
        var artifact = NightlyQualityArtifact(
            recordingID: 42,
            audioFingerprint: "audio:revision",
            whisper: candidate(engine: .vibeVoice, segments: foreground)
        )
        artifact.vibeVoice = candidate(engine: .vibeVoice, segments: foreground)
        artifact.gemmaCompletedTurns = 3
        artifact.gemmaTotalTurns = 10
        try store.save(artifact)

        XCTAssertEqual(store.resumableRecordingIDs(), Set([Int64(42)]))
        XCTAssertTrue(
            store.isResumable(
                recordingID: 42,
                fingerprint: "audio:revision",
                foregroundSegments: foreground
            )
        )
        XCTAssertFalse(
            store.isResumable(
                recordingID: 42,
                fingerprint: "changed-audio",
                foregroundSegments: foreground
            )
        )
        XCTAssertFalse(
            store.isResumable(
                recordingID: 42,
                fingerprint: "audio:revision",
                foregroundSegments: [segment(text: "user changed the row")]
            )
        )
    }

    func testCompletedArtifactDoesNotReenterRecoveryQueue() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alm-quality-complete-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NightlyQualityArtifactStore(directory: root)
        let foreground = [segment()]
        var artifact = NightlyQualityArtifact(
            recordingID: 9,
            audioFingerprint: "stable",
            whisper: candidate(engine: .vibeVoice, segments: foreground)
        )
        artifact.vibeVoice = candidate(engine: .vibeVoice, segments: foreground)
        artifact.completedAt = Date()
        try store.save(artifact)

        XCTAssertTrue(store.resumableRecordingIDs().isEmpty)
        XCTAssertFalse(
            store.isResumable(
                recordingID: 9,
                fingerprint: "stable",
                foregroundSegments: foreground
            )
        )
    }

    func testNightlyProductionDefaultsAreForegroundFirstAndSpeakerSafe() {
        let configuration = NightlyQualityConfiguration()
        XCTAssertTrue(configuration.enabled)
        XCTAssertEqual(configuration.scope, .newRecordings)
        XCTAssertEqual(configuration.commitPolicy, .automaticHighConfidence)
        XCTAssertEqual(configuration.mode, .maximum)
        XCTAssertEqual(TranscriptionProductionDefaults.backend, .vibeVoice)
        XCTAssertEqual(TranscriptionProductionDefaults.vibeVoiceQuantization, .fourBit)
        XCTAssertEqual(TranscriptionProductionDefaults.vibeVoiceSpeakerMode, .fused)
    }
}
