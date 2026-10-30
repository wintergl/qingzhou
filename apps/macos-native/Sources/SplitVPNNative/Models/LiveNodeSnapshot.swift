import Foundation

struct LiveNodeSnapshot: Decodable {
    var nodes: [VPNNode]?
    var groups: [NodeGroupState]?
    var error: String?
    var viewRevision: UInt64?
    var settings: VPNSettings?
    var subscription: SubscriptionRecord?
}
struct CurrentExitRiskUpdate: Decodable {
    var result: NodeRisk?
    var viewRevision: UInt64?
}
