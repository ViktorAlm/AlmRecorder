import Foundation
import XCTest
@testable import AlmRecorder

final class AudioImportPolicyTests: XCTestCase {
    func testSupportedAudioExtensionsAreCaseInsensitive() {
        for name in [
            "call.wav", "call.WAV", "call.mp3", "call.m4a", "call.aif", "call.aiff",
            "call.flac", "call.ogg", "call.opus", "call.qta",
        ] {
            XCTAssertTrue(AudioImportPolicy.supports(URL(fileURLWithPath: "/tmp/\(name)")))
        }
    }

    func testUnsupportedAndRemoteURLsAreRejected() {
        XCTAssertFalse(AudioImportPolicy.supports(URL(fileURLWithPath: "/tmp/transcript.txt")))
        XCTAssertFalse(AudioImportPolicy.supports(URL(string: "https://example.test/audio.wav")!))
    }
}
