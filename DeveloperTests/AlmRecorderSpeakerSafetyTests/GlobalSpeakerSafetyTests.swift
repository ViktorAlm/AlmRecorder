import XCTest
@testable import AlmRecorder

final class GlobalSpeakerSafetyTests: XCTestCase {
    private func vector(_ degrees: Double) -> [Float] {
        let radians = degrees * .pi / 180
        return [Float(cos(radians)), Float(sin(radians))]
    }

    private func node(
        _ id: String,
        recording: Int64,
        degrees: Double,
        spans: [SpeakerIdentityTimeSpan] = []
    ) -> GlobalSpeakerBenchmarkNode {
        GlobalSpeakerBenchmarkNode(
            id: id,
            recordingKey: "recording:\(recording)",
            recordingId: recording,
            embedding: vector(degrees),
            spans: spans,
            reliableForIdentity: true,
            goldSpeakerKey: nil,
            goldPurity: 0
        )
    }

    func testRepeatedCooccurrenceKeepsTwoRecurringPeopleApart() {
        let nodes = [
            node("a1", recording: 1, degrees: 0),
            node("a2", recording: 2, degrees: 5),
            node("b1", recording: 1, degrees: 65),
            node("b2", recording: 2, degrees: 70),
        ]
        let result = GlobalSpeakerEvidenceGraph.cluster(
            nodes,
            configuration: .init(
                linkage: .constrainedEvidence,
                threshold: 0.50,
                supportSlack: 0.20
            )
        )
        XCTAssertEqual(result.assignments["a1"], result.assignments["a2"])
        XCTAssertEqual(result.assignments["b1"], result.assignments["b2"])
        XCTAssertNotEqual(result.assignments["a1"], result.assignments["b1"])
    }

    func testCannotLinkOverridesIdenticalAcoustics() {
        let nodes = [
            node("left", recording: 1, degrees: 0),
            node("right", recording: 2, degrees: 0),
        ]
        let result = GlobalSpeakerReconciler.reconcile(
            nodes: nodes,
            model: .conservativeFallback,
            constraints: [
                .init("left", "right", kind: .cannotLink),
            ]
        )
        XCTAssertNotEqual(result.assignments["left"], result.assignments["right"])
    }

    func testDifferentTrustedPeopleNeverMerge() {
        let nodes = [
            node("left", recording: 1, degrees: 0),
            node("right", recording: 2, degrees: 0),
        ]
        let result = GlobalSpeakerReconciler.reconcile(
            nodes: nodes,
            model: .conservativeFallback,
            trustedAnchors: [
                "left": "person-a",
                "right": "person-b",
            ]
        )
        XCTAssertNotEqual(result.assignments["left"], result.assignments["right"])
    }

    func testPairPartitionIsRecordingBasedAndStable() {
        XCTAssertEqual(SpeakerPairGoldStore.roleForPair(1, 2), .development)
        XCTAssertEqual(SpeakerPairGoldStore.roleForPair(5, 2), .heldOut)
        XCTAssertEqual(SpeakerPairGoldStore.roleForPair(2, 10), .heldOut)
        XCTAssertEqual(
            SpeakerPairGoldStore.roleForPair(5, 2),
            SpeakerPairGoldStore.roleForPair(2, 5)
        )
    }

    func testGlobalApplyGateRequiresRepresentativeAcousticCoverage() {
        XCTAssertNotNil(
            GlobalSpeakerLibraryReconciliation.acousticEvidenceBlocker(
                totalClusterCount: 100,
                acousticEvidenceNodeCount: 89
            )
        )
        XCTAssertNil(
            GlobalSpeakerLibraryReconciliation.acousticEvidenceBlocker(
                totalClusterCount: 100,
                acousticEvidenceNodeCount: 90
            )
        )
    }

    func testLegacyTimelineBackfillAcceptsOneDominantFreshVoice() {
        let targets = [
            SpeakerAcousticEvidenceTarget(
                clusterID: 7,
                spans: [.init(start: 0, end: 10)]
            ),
        ]
        let evidence = [
            SpeakerIdentityCluster(
                label: "fresh-a",
                embedding: [1],
                spans: [.init(start: 0, end: 9)]
            ),
            SpeakerIdentityCluster(
                label: "fresh-b",
                embedding: [1],
                spans: [.init(start: 9, end: 10)]
            ),
        ]
        let matches = SpeakerAcousticEvidenceMatcher.matches(
            targets: targets,
            evidence: evidence
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.clusterID, 7)
        XCTAssertEqual(matches.first?.evidenceIndex, 0)
    }

    func testLegacyTimelineBackfillRejectsMixedVoiceEvidence() {
        let targets = [
            SpeakerAcousticEvidenceTarget(
                clusterID: 8,
                spans: [.init(start: 0, end: 10)]
            ),
        ]
        let evidence = [
            SpeakerIdentityCluster(
                label: "fresh-a",
                embedding: [1],
                spans: [.init(start: 0, end: 5)]
            ),
            SpeakerIdentityCluster(
                label: "fresh-b",
                embedding: [1],
                spans: [.init(start: 5, end: 10)]
            ),
        ]
        XCTAssertTrue(
            SpeakerAcousticEvidenceMatcher.matches(
                targets: targets,
                evidence: evidence
            ).isEmpty
        )
    }
}
