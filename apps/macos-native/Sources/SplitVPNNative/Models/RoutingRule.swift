import Foundation

enum RoutingOutlet: String, CaseIterable, Identifiable {
    case vpn, direct
    var id: String { rawValue }
    var title: String { self == .vpn ? "走 VPN" : "直连" }
    var detail: String { self == .vpn ? "使用当前选中的节点或节点组。" : "使用本机网络访问。" }
}

enum RoutingMatchKind: String, CaseIterable, Identifiable {
    case auto, suffix = "DOMAIN-SUFFIX", domain = "DOMAIN", keyword = "DOMAIN-KEYWORD", ip, raw
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "自动识别（推荐）"
        case .suffix: return "域名及子域名"
        case .domain: return "仅此域名"
        case .keyword: return "域名包含关键词"
        case .ip: return "IP 地址或网段"
        case .raw: return "高级规则"
        }
    }
    var example: String {
        switch self {
        case .auto: return "example.test 或 192.0.2.8"
        case .suffix: return "example.test"
        case .domain: return "api.example.test"
        case .keyword: return "example"
        case .ip: return "192.0.2.8 或 192.0.2.0/24"
        case .raw: return "DOMAIN-SUFFIX,example.test"
        }
    }
    var hint: String {
        switch self {
        case .auto: return "可填域名、IP、网段或完整网址。域名默认包含子域名，网址只取地址，路径不参与分流。"
        case .suffix: return "填写 example.test，也会匹配 api.example.test 和其他子域名。"
        case .domain: return "只匹配填写的域名，不包含它的子域名或其他域名。"
        case .keyword: return "匹配域名中包含这个词的地址，范围通常比单个域名更大。"
        case .ip: return "单个 IP 可直接填写；网段使用 / 前缀长度，例如 192.0.2.0/24。也支持 IPv6。"
        case .raw: return "保留已有 DOMAIN、DOMAIN-SUFFIX、DOMAIN-KEYWORD、IP-CIDR、IP-CIDR6 和 GEOSITE 格式。"
        }
    }
}

struct RoutingRule: Identifiable {
    var raw: String
    var outlet: RoutingOutlet
    var id: String { "\(outlet.rawValue):\(raw)" }
    var kind: String { String(raw.split(separator: ",", maxSplits: 1).first ?? "") }
    var address: String { String(raw.split(separator: ",", maxSplits: 1).last ?? "") }
    var matchTitle: String {
        if kind == "IP-CIDR" || kind == "IP-CIDR6" { return "IP 地址或网段" }
        if kind == "GEOSITE" { return "Geo 分类" }
        return RoutingMatchKind(rawValue: kind)?.title ?? "高级规则"
    }
}

struct RoutingRuleDraft: Identifiable {
    let id = UUID()
    let original: RoutingRule?
    var outlet: RoutingOutlet
    var kind: RoutingMatchKind
    var address: String
    init(original: RoutingRule? = nil) {
        self.original = original
        outlet = original?.outlet ?? .vpn
        if let original {
            kind = original.kind.hasPrefix("IP-CIDR") ? .ip : RoutingMatchKind(rawValue: original.kind) ?? .raw
            address = kind == .raw ? original.raw : original.address
        } else { kind = .auto; address = "" }
    }
    var validationID: String { "\(kind.rawValue):\(address)" }
    var payload: [String: Any] {
        var value: [String: Any] = ["rule": address, "kind": kind.rawValue, "target": outlet.rawValue]
        if let original { value["originalRule"] = original.raw; value["originalTarget"] = original.outlet.rawValue }
        return value
    }
}

struct NormalizedRoutingRule: Decodable {
    var rule: String
    var kind: String
    var value: String
    var matchTitle: String { RoutingRule(raw: rule, outlet: .vpn).matchTitle }
}

struct RoutingDiagnostic: Decodable {
    var host: String
    var matchedRules: [String]
    var policy: String
}
