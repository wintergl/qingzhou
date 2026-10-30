import XCTest
@testable import SplitVPNNative

final class CompatibilityRulesTests: XCTestCase {
    func testOldSnapshotsRemainReadableAndNewDirectChoiceSurvivesRoundTrip() throws {
        let old = Data(#"{"mailMasterProxy8081":false,"wechatImageSendFallback":true}"#.utf8)
        var rules = try JSONDecoder().decode(CompatibilityRules.self, from: old)
        XCTAssertNil(rules.mailMasterDirect)
        XCTAssertFalse(rules.mailMasterProxy8081)
        for choice in [true, false] {
            rules.mailMasterDirect = choice
            let restored = try JSONDecoder().decode(CompatibilityRules.self, from: JSONEncoder().encode(rules))
            XCTAssertEqual(restored.mailMasterDirect, choice)
            XCTAssertFalse(restored.mailMasterProxy8081)
            XCTAssertTrue(restored.wechatImageSendFallback)
        }
    }
}
