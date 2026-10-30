import XCTest
@testable import SplitVPNNative

final class ChainSubscriptionScopeTests: XCTestCase {
    private var nodes: [VPNNode] {
        [VPNNode(name: "示例 A", type: "http", selected: false, identityKey: "a", subscriptionId: "one"),
         VPNNode(name: "示例 B", type: "http", selected: false, identityKey: "b", subscriptionId: "two"),
         VPNNode(name: "冲突节点", type: "http", selected: false, identityKey: "c", subscriptionId: "one", identityAmbiguous: true)]
    }
    func test_scope_only_shows_eligible_nodes_from_selected_subscription() {
        let scope = ChainSubscriptionScope(subscriptionID: "one", nodes: nodes)
        XCTAssertEqual(scope.candidates.map(\.id), ["a"])
        XCTAssertTrue(scope.contains("a")); XCTAssertFalse(scope.contains("b")); XCTAssertFalse(scope.contains("c"))
        XCTAssertEqual(ChainSubscriptionScope(subscriptionID: "", nodes: nodes).candidates.count, 2)
    }
    func test_full_subscription_retest_preserves_other_results_using_core_scope() {
        let scope = ChainSubscriptionScope(subscriptionID: "one", nodes: nodes)
        let payload = scope.payload(mode: "full")
        XCTAssertEqual(payload["mode"] as? String, "accumulate")
        XCTAssertEqual(payload["subscriptionId"] as? String, "one")
        XCTAssertEqual(payload["forceRetest"] as? Bool, true)
        XCTAssertNil(payload["identityKeys"])
        XCTAssertNil(scope.payload(mode: "continuous")["forceRetest"])
        XCTAssertEqual(ChainSubscriptionScope(subscriptionID: "", nodes: nodes).payload(mode: "full")["mode"] as? String, "full")
    }
}
