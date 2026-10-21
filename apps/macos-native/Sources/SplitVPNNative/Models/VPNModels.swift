import Foundation

enum VPNPage: String, CaseIterable, Identifiable {
    case overview = "总览", company = "私有网络", subscriptions = "订阅", nodes = "节点", groups = "节点组"
    case routing = "分流规则", diagnostics = "诊断与风险", traffic = "流量", logs = "日志"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .company: return "building.2.crop.circle"
        case .subscriptions: return "tray.full"
        case .nodes: return "network"
        case .groups: return "square.stack.3d.up"
        case .routing: return "arrow.triangle.branch"
        case .diagnostics: return "waveform.path.ecg"
        case .traffic: return "chart.xyaxis.line"
        case .logs: return "text.alignleft"
        }
    }
}

struct Bootstrap: Decodable {
    var status: VPNStatus
    var nodes: [VPNNode]
    var groups: [NodeGroupState]
    var risks: [NodeRisk]
    var traffic: TrafficMonitor
    var legacyOwnerRunning: Bool
    var previewOnly: Bool
    var ownsRuntime: Bool
    var companyRouting: CompanyRoutingState
    var dataDir: String
}
struct VPNStatus: Decodable {
    var appStartedAt: String
    var mihomo: CoreStatus
    var subscription: SubscriptionRecord
    var settings: VPNSettings
}
struct CoreStatus: Decodable {
    var state: String
    var mode: String?
    var pid: Int?
    var startedAt: String?
    var lastError: String?
    var networkRecovery: NetworkRecoveryStatus? = nil
}
struct NetworkRecoveryStatus: Decodable {
    var state: String
    var error: String?
    var attempts: Int?
    var helperUpdateRequired: Bool?
    var maxAttempts: Int?
    var phase: String?
    var startedAt: String?
    var history: [NetworkRecoveryRecord]?
    var ready: Bool { state == "idle" || state == "ready" }
}
struct VPNSettings: Decodable {
    var launchAtLogin: Bool
    var unknownTraffic: String
    /// Optional so cores that predate geoFallback still decode.
    var geoFallback: String?
    var tun: Bool
    var ipv6: Bool
    var lanDirect: Bool
    var tailscaleDirect: Bool
    var specialCompatibilityRules: CompatibilityRules
    var selectedProxy: String
    var vpnDomainRules: [String]
    var favoriteNodeNames: [String]
    var nodeGroups: [NodeGroup]
    /// Optional so snapshots from older cores remain readable.
    var directDomainRules: [String]? = nil
}
struct CompatibilityRules: Codable {
    var mailMasterProxy8081: Bool
    var wechatImageSendFallback: Bool
}
struct SubscriptionRecord: Decodable {
    var nodeCount: Int
    var status: String
    var lastError: String?
    var updatedAt: String?
    var entries: [Subscription]
}
struct Subscription: Codable, Identifiable {
    var id: String
    var name: String
    var url: String
    var enabled: Bool
    var updatedAt: String?
    var nodeCount: Int
    var status: String
    var lastError: String?
    var updateIntervalMinutes: Int?
    var lastAttemptAt: String?
    var displayHost: String { URL(string: url)?.host ?? "已保存的订阅" }
}
struct VPNNode: Decodable, Identifiable {
    var name: String
    var type: String
    var selected: Bool
    var delay: Double?
    var available: Bool?
    var identityKey: String?
    var subscriptionId: String?
    var subscriptionName: String?
    var identityAmbiguous: Bool?
    var location: NodeLocation?
    var id: String { identityKey ?? name }
    var isProvider: Bool { identityKey != nil }
    var latencyText: String { delay.map { "\(Int($0)) ms" } ?? "未测速" }
    var availabilityText: String { identityAmbiguous == true ? "同名冲突" : available.map { $0 ? "可连接" : "未连通" } ?? "未检测" }
}
struct NodeLocation: Decodable {
    var country: String?
    var city: String?
    var source: String
}
struct NodeGroup: Codable, Identifiable {
    var id: String
    var name: String
    var nodeNames: [String]
    var members: [NodeMember]?
    var strategy: String?
    var preferredIdentityKey: String?
    var balanceStrategy: String?
    var healthCheckURL: String?
    var strategyLabel: String {
        switch strategy ?? "manual" {
        case "auto": return "自动择优"
        case "fallback": return "故障切换"
        case "balance": return "负载均衡"
        default: return "手动选择"
        }
    }
}
struct NodeMember: Codable {
    var identityKey: String?
    var lastKnownName: String
}
struct NodeGroupState: Decodable, Identifiable {
    var group: NodeGroup
    var runtimeName: String
    var selected: Bool
    var applied: Bool
    var currentMember: String?
    var members: [GroupMemberState]
    var availableCount: Int
    var failedCount: Int
    var untestedCount: Int
    var id: String { group.id }
    var isSubscriptionGroup: Bool { group.id.hasPrefix("subscription:") }
}
struct GroupMemberState: Decodable, Identifiable {
    var identityKey: String?
    var lastKnownName: String
    var issue: String?
    var available: Bool?
    var delay: Double?
    var current: Bool
    var id: String { identityKey ?? lastKnownName }
}
struct NodeRisk: Decodable, Identifiable {
    var nodeName: String
    var ip: String?
    var riskLevel: String
    var reasons: [String]
    var checkedAt: String
    var error: String?
    var id: String { nodeName }
    var label: String {
        switch riskLevel { case "low": return "低风险"; case "medium": return "中风险"; case "high": return "高风险"; default: return "未确认" }
    }
}
struct RiskBatchProgress: Decodable {
    var id: String
    var checked: Int
    var total: Int
    var nodeName: String?
    var result: NodeRisk?
    var finished: Bool
    var cancelled: Bool
    var stoppedReason: String?
    var error: String?
}
struct TrafficMonitor: Decodable {
    var snapshot: TrafficSnapshot?
    var rates: TrafficRate
    var samples: [TrafficSample]
    var running: Bool
    var updatedAt: String?
    var error: String?
}
struct TrafficRate: Decodable { var upload: Double; var download: Double }
struct TrafficSample: Decodable { var upload: Double; var download: Double; var sampledAt: String }
struct TrafficSnapshot: Decodable {
    var uploadTotal: Double
    var downloadTotal: Double
    var connectionCount: Int
    var connections: [TrafficConnection]
}
struct TrafficConnection: Decodable, Identifiable {
    var id: String
    var host: String
    var network: String
    var type: String
    var rule: String
    var rulePayload: String
    var chains: [String]
    var upload: Double
    var download: Double
    var process: String?
    var destination: String
    var displayTarget: String { host.isEmpty ? destination : host }
}
struct ConnectivityCheck: Decodable { var connectivity: Connectivity; var nodeRisk: NodeRisk?; var nodeRiskError: String? }
struct Connectivity: Decodable {
    var domesticOk: Bool
    var foreignOk: Bool
    var externalIp: String?
    var error: String?
    var latency: ConnectivityLatency
    var proxyOk: Bool?
    var systemDns: SystemNetworkProbe?
    var chatgpt: SystemNetworkProbe?
}
struct SystemNetworkProbe: Decodable {
    var ok: Bool
    var error: String?
    var httpStatus: Int?
    var elapsedMs: Double?
}
struct ConnectivityLatency: Decodable { var domesticMs: Double?; var foreignMs: Double? }
struct WebsiteTests: Decodable { var proxyName: String; var results: [WebsiteResult] }
struct WebsiteResult: Decodable, Identifiable {
    var id: String
    var label: String
    var url: String
    var delay: Double?
    var ok: Bool
    var error: String?
}

enum JSONValue: Codable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data("null".utf8) }
    var prettyText: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
