import Foundation

struct DirectIPv4Route: Codable, Equatable, Identifiable {
    var id: String { cidr }
    var cidr: String
    var destinationAddress: String
    var subnetMask: String
    var label: String
}

enum DefaultRules {
    static let vpnDomains = [
        "openai.com",
        "chatgpt.com",
        "ct.sendgrid.net",
        "intercom.io",
        "intercomcdn.com",
        "oaistatic.com",
        "oaiusercontent.com",
        "oaistatsig.com",
        "auth0.openai.com",
        "cdn.openaimerge.com",
        "workos.com",
        "challenges.cloudflare.com",
        "humb.apple.com",
        "workoscdn.com",
        "js.stripe.com",
        "o207216.ingest.sentry.io",
        "o33249.ingest.sentry.io",
        "rum.browser-intake-datadoghq.com",
        "workos.imgix.net",
        "google.com",
        "gstatic.com",
        "googleapis.com",
        "googleusercontent.com",
        "youtube.com",
        "youtube-nocookie.com",
        "youtu.be",
        "yt.be",
        "ytimg.com",
        "googlevideo.com",
        "ggpht.com",
        "gvt1.com",
        "gvt2.com",
        "gvt3.com",
        "gvt4.com"
    ]

    static let directDomainSuffixes = [
        "cn",
        "com.cn",
        "net.cn",
        "org.cn",
        "gov.cn",
        "edu.cn",
        "baidu.com",
        "bdstatic.com",
        "shifen.com",
        "qq.com",
        "tencent.com",
        "weixin.qq.com",
        "weixinbridge.com",
        "alibaba.com",
        "alicdn.com",
        "aliyun.com",
        "taobao.com",
        "tmall.com",
        "jd.com",
        "360buyimg.com",
        "bytedance.com",
        "douyin.com",
        "byteimg.com",
        "snssdk.com",
        "toutiao.com",
        "autonavi.com",
        "amap.com",
        "gaode.com",
        "xiaomi.com",
        "mi.com",
        "huawei.com",
        "hicloud.com",
        "meituan.com",
        "dianping.com",
        "bilibili.com",
        "biliapi.net",
        "163.com",
        "126.net",
        "sina.com.cn",
        "sinaimg.cn",
        "weibo.com",
        "douban.com",
        "zhihu.com",
        "xiaohongshu.com",
        "pinduoduo.com",
        "pddpic.com",
        "alipay.com",
        "alipayobjects.com",
        "apple.com.cn",
        "icloud.com.cn",
        "aaplimg.com"
    ]

    static let directIPv4Routes = [
        DirectIPv4Route(cidr: "0.0.0.0/8", destinationAddress: "0.0.0.0", subnetMask: "255.0.0.0", label: "Current network"),
        DirectIPv4Route(cidr: "10.0.0.0/8", destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0", label: "Private LAN"),
        DirectIPv4Route(cidr: "100.64.0.0/10", destinationAddress: "100.64.0.0", subnetMask: "255.192.0.0", label: "Tailscale / CGNAT"),
        DirectIPv4Route(cidr: "127.0.0.0/8", destinationAddress: "127.0.0.0", subnetMask: "255.0.0.0", label: "Loopback"),
        DirectIPv4Route(cidr: "169.254.0.0/16", destinationAddress: "169.254.0.0", subnetMask: "255.255.0.0", label: "Link-local"),
        DirectIPv4Route(cidr: "172.16.0.0/12", destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0", label: "Private LAN"),
        DirectIPv4Route(cidr: "192.168.0.0/16", destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0", label: "Private LAN"),
        DirectIPv4Route(cidr: "224.0.0.0/4", destinationAddress: "224.0.0.0", subnetMask: "240.0.0.0", label: "Multicast"),
        DirectIPv4Route(cidr: "240.0.0.0/4", destinationAddress: "240.0.0.0", subnetMask: "240.0.0.0", label: "Reserved")
    ]

    static var directCidrs: [String] {
        directIPv4Routes.map(\.cidr)
    }

    static var networkExtensionExcludedIPv4Routes: [DirectIPv4Route] {
        directIPv4Routes.filter { route in
            route.cidr != "127.0.0.0/8"
        }
    }

    static let directRuleSummary = [
        "局域网 / 保留地址直连",
        "Tailscale 100.64.0.0/10 直连",
        "VPN 域名列表走代理",
        "CN 规则集直连",
        "Geo 非 CN 规则走代理",
        "未匹配流量默认直连"
    ]

    static func routeDecision(
        for input: String,
        vpnDomains: [String],
        unknownTrafficPolicy: String
    ) -> RouteDecision {
        let normalizedTarget = normalizedRouteTarget(input)

        guard !normalizedTarget.isEmpty else {
            return RouteDecision(
                input: input,
                normalizedTarget: "-",
                outbound: "direct",
                matchedRule: "invalid",
                detail: "输入为空或无法解析，运行时会按未匹配流量处理"
            )
        }

        if let matchedDomain = matchingDomainSuffix(normalizedTarget, suffixes: normalizeDomainSuffixes(vpnDomains)) {
            return RouteDecision(
                input: input,
                normalizedTarget: normalizedTarget,
                outbound: "proxy",
                matchedRule: "VPN 域名：\(matchedDomain)",
                detail: "命中 VPN 域名列表，预计走所选节点"
            )
        }

        if let matchedDomain = matchingDomainSuffix(normalizedTarget, suffixes: directDomainSuffixes) {
            return RouteDecision(
                input: input,
                normalizedTarget: normalizedTarget,
                outbound: "direct",
                matchedRule: "国内直连域名：\(matchedDomain)",
                detail: "命中内置直连域名，预计直连"
            )
        }

        if let matchedCIDR = matchingDirectCIDR(normalizedTarget) {
            return RouteDecision(
                input: input,
                normalizedTarget: normalizedTarget,
                outbound: "direct",
                matchedRule: "系统直连网段：\(matchedCIDR)",
                detail: "命中 NetworkExtension 排除网段或 sing-box 直连网段"
            )
        }

        let usesProxy = unknownTrafficPolicy == "vpn"
        return RouteDecision(
            input: input,
            normalizedTarget: normalizedTarget,
            outbound: usesProxy ? "proxy" : "direct",
            matchedRule: "未匹配默认策略",
            detail: usesProxy ? "未匹配流量当前会走代理" : "未命中本地静态规则；运行时若命中 Geo 非 CN 规则仍会走代理，否则直连"
        )
    }

    static func normalizedRouteTarget(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else {
            return ""
        }

        if let url = URL(string: value), let host = url.host {
            value = host
        } else {
            if let schemeRange = value.range(of: "://") {
                value.removeSubrange(value.startIndex..<schemeRange.upperBound)
            }
            if let slashIndex = value.firstIndex(of: "/") {
                value = String(value[..<slashIndex])
            }
            if let questionIndex = value.firstIndex(of: "?") {
                value = String(value[..<questionIndex])
            }
            if let hashIndex = value.firstIndex(of: "#") {
                value = String(value[..<hashIndex])
            }
            if value.first != "[", let colonIndex = value.lastIndex(of: ":") {
                let suffix = value[value.index(after: colonIndex)...]
                if suffix.allSatisfy(\.isNumber) {
                    value = String(value[..<colonIndex])
                }
            }
        }

        return value.trimmingCharacters(in: CharacterSet(charactersIn: "[] ."))
    }

    private static func normalizeDomainSuffixes(_ values: [String]) -> [String] {
        values
            .map { normalizedRouteTarget($0) }
            .filter { !$0.isEmpty }
    }

    private static func matchingDomainSuffix(_ target: String, suffixes: [String]) -> String? {
        suffixes.first { suffix in
            target == suffix || target.hasSuffix(".\(suffix)")
        }
    }

    private static func matchingDirectCIDR(_ target: String) -> String? {
        guard let ip = ipv4Value(target) else {
            return nil
        }
        return directCidrs.first { cidr in
            guard let (network, prefixLength) = parseIPv4CIDR(cidr) else {
                return false
            }
            let mask = prefixLength == 0 ? UInt32(0) : UInt32.max << UInt32(32 - prefixLength)
            return (ip & mask) == (network & mask)
        }
    }

    private static func parseIPv4CIDR(_ value: String) -> (UInt32, Int)? {
        let parts = value.split(separator: "/")
        guard parts.count == 2,
              let ip = ipv4Value(String(parts[0])),
              let prefixLength = Int(parts[1]),
              (0...32).contains(prefixLength) else {
            return nil
        }
        return (ip, prefixLength)
    }

    private static func ipv4Value(_ value: String) -> UInt32? {
        let parts = value.split(separator: ".")
        guard parts.count == 4 else {
            return nil
        }
        var result = UInt32(0)
        for part in parts {
            guard let octet = UInt32(part), octet <= 255 else {
                return nil
            }
            result = (result << 8) | octet
        }
        return result
    }
}
