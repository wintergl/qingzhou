import Foundation

/// UI scope only; the core validates subscription membership and owns retesting.
struct ChainSubscriptionScope {
    var subscriptionID: String
    var nodes: [VPNNode]
    var candidates: [VPNNode] { nodes.filter { $0.identityAmbiguous != true && (subscriptionID.isEmpty || $0.subscriptionId == subscriptionID) } }
    func contains(_ identity: String) -> Bool { subscriptionID.isEmpty || candidates.contains { $0.identityKey == identity } }
    func payload(mode: String) -> [String: Any] {
        guard !subscriptionID.isEmpty else { return ["mode": mode] }
        var payload: [String: Any] = ["mode": mode == "full" ? "accumulate" : mode, "subscriptionId": subscriptionID]
        if mode == "full" { payload["forceRetest"] = true }
        return payload
    }
}
