import Foundation
import XCTest
@testable import AlmRecorder

final class DownloadIntegritySafetyTests: XCTestCase {
    func testTinyOrPartialModelCannotMasqueradeAsInstalled() {
        let declared: Int64 = 8_000_000_000

        XCTAssertFalse(
            UnifiedDownloadQueue.isAcceptableFileSize(
                1_000_001,
                declaredSize: declared
            )
        )
        XCTAssertFalse(
            UnifiedDownloadQueue.isAcceptableFileSize(
                5_599_999_999,
                declaredSize: declared
            )
        )
        XCTAssertTrue(
            UnifiedDownloadQueue.isAcceptableFileSize(
                5_600_000_000,
                declaredSize: declared
            )
        )
    }

    func testServerContentLengthWinsOverCatalogEstimate() {
        XCTAssertTrue(
            UnifiedDownloadQueue.isAcceptableFileSize(
                175_115_840,
                declaredSize: 100_000_000,
                serverExpectedBytes: 175_115_840
            )
        )
        XCTAssertFalse(
            UnifiedDownloadQueue.isAcceptableFileSize(
                175_000_000,
                declaredSize: 100_000_000,
                serverExpectedBytes: 175_115_840
            )
        )
    }

    func testRetryBackoffDoesNotImmediatelyRequeueTheFailedDownload() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(UnifiedDownloadQueue.retryIsReady(notBefore: nil, now: now))
        XCTAssertTrue(
            UnifiedDownloadQueue.retryIsReady(
                notBefore: now.addingTimeInterval(-1),
                now: now
            )
        )
        XCTAssertFalse(
            UnifiedDownloadQueue.retryIsReady(
                notBefore: now.addingTimeInterval(2),
                now: now
            )
        )
    }

    func testAudioProjectorsUseTheirRealCatalogScale() throws {
        let voxtral = try XCTUnwrap(VoxtralConfiguration.models["Q5_K_M"])
        let gemma = try XCTUnwrap(GemmaConfiguration.models["12B-Q5_K_M"])

        XCTAssertGreaterThan(Int64(voxtral.mmprojSizeGB * 1_000_000_000), 1_000_000_000)
        XCTAssertFalse(
            UnifiedDownloadQueue.isAcceptableFileSize(
                100_000_000,
                declaredSize: Int64(voxtral.mmprojSizeGB * 1_000_000_000)
            )
        )
        XCTAssertFalse(
            UnifiedDownloadQueue.isAcceptableFileSize(
                100_000_000,
                declaredSize: Int64(gemma.mmprojSizeGB * 1_000_000_000)
            )
        )
    }
}
