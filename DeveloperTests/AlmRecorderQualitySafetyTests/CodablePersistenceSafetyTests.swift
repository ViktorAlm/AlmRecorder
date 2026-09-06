import Foundation
import XCTest
@testable import AlmRecorder

final class CodablePersistenceSafetyTests: XCTestCase {
    func testEmbeddingJobKeepsIdentityAndCreationDateAcrossPersistence() throws {
        var job = EmbeddingJob(
            recordingId: 42,
            recordingTitle: "Synthetic", // privacy:allow-synthetic
            utteranceData: [],
            priority: .high
        )
        job.id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        job.createdAt = Date(timeIntervalSince1970: 1_700_000_000)

        let decoded = try roundTrip(job, as: EmbeddingJob.self)

        XCTAssertEqual(decoded.id, job.id)
        XCTAssertEqual(decoded.createdAt, job.createdAt)
    }

    func testInsightsJobKeepsIdentityAndCreationDateAcrossPersistence() throws {
        var job = RecordingInsightsJob(
            recordingId: 7,
            recordingTitle: "Synthetic", // privacy:allow-synthetic
            force: true,
            priority: .normal
        )
        job.id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        job.createdAt = Date(timeIntervalSince1970: 1_710_000_000)

        let decoded = try roundTrip(job, as: RecordingInsightsJob.self)

        XCTAssertEqual(decoded.id, job.id)
        XCTAssertEqual(decoded.createdAt, job.createdAt)
    }

    func testTranscriptionItemKeepsIdentityAcrossPersistence() throws {
        var item = TranscriptionItem(
            fileName: "synthetic.wav",
            filePath: "/private/tmp/synthetic.wav", // privacy:allow-synthetic
            transcript: "synthetic speech", // privacy:allow-synthetic
            language: "en",
            duration: 1,
            fileSize: 128,
            createdDate: Date(timeIntervalSince1970: 1_720_000_000),
            transcribedDate: Date(timeIntervalSince1970: 1_720_000_001),
            source: .imported,
            status: .completed,
            error: nil
        )
        item.id = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!

        let decoded = try roundTrip(item, as: TranscriptionItem.self)

        XCTAssertEqual(decoded.id, item.id)
    }

    private func roundTrip<T: Codable>(_ value: T, as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }
}
