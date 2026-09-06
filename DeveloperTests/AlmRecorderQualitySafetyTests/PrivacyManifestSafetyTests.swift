import Foundation
import XCTest

final class PrivacyManifestSafetyTests: XCTestCase {
    func testManifestDeclaresRequiredReasonAPIsUsedByTheApp() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestURL = root.appendingPathComponent("AlmRecorder/PrivacyInfo.xcprivacy")
        let data = try Data(contentsOf: manifestURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
        let entries = try XCTUnwrap(
            plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]]
        )
        let pairs: [(String, Set<String>)] = entries.compactMap { entry in
            guard let category = entry["NSPrivacyAccessedAPIType"] as? String,
                  let reasons = entry["NSPrivacyAccessedAPITypeReasons"] as? [String] else {
                return nil
            }
            return (category, Set(reasons))
        }
        let reasonsByCategory = Dictionary(uniqueKeysWithValues: pairs)

        XCTAssertEqual(
            reasonsByCategory["NSPrivacyAccessedAPICategoryUserDefaults"],
            ["CA92.1"]
        )
        XCTAssertEqual(
            reasonsByCategory["NSPrivacyAccessedAPICategoryFileTimestamp"],
            ["C617.1", "3B52.1"]
        )
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
    }
}
