import Foundation
import SplitVpnCore

struct CoreError: LocalizedError {
    var code: String
    var message: String

    var errorDescription: String? { message }
}

/// Bridge to the shared Rust core (`packages/vpn-core`, `qz_core.h`). The core
/// owns subscriptions, node parsing and sing-box config generation under its
/// own data directory; Swift keeps UI mirrors in `AppGroupStore`.
final class CoreClient {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    /// Runs one `{channel, payload}` request off the main thread and returns `data`.
    func call(_ channel: String, _ payload: [String: Any] = [:]) async throws -> Any {
        let body = try MobileCoreBridge.request(channel: channel, payload: payload)
        let request = String(decoding: body, as: UTF8.self)
        let root = rootURL.path
        let reply = await Task.detached(priority: .userInitiated) {
            Self.invoke(root: root, request: request)
        }.value
        return try Self.decode(reply)
    }

    func object(_ channel: String, _ payload: [String: Any] = [:]) async throws -> [String: Any] {
        guard let value = try await call(channel, payload) as? [String: Any] else {
            throw CoreError(code: "CORE_BAD_REPLY", message: "核心返回格式无效：\(channel)")
        }
        return value
    }

    // MARK: - Subscription mirrors

    func subscriptionStatus() async throws -> [String: Any] {
        try await object("subscription:get-status")
    }

    /// Saves the single iPhone subscription URL into the first core entry and returns its id.
    @discardableResult
    func saveSubscription(url: String) async throws -> String {
        var payload: [String: Any] = ["url": url]
        if let id = Self.firstEntry(try await subscriptionStatus())?["id"] as? String {
            payload["id"] = id
        }
        let record = try await object("subscription:save", payload)
        guard let id = Self.firstEntry(record)?["id"] as? String else {
            throw CoreError(code: "CORE_BAD_REPLY", message: "订阅保存后没有返回订阅 ID")
        }
        return id
    }

    func nodes() async throws -> [ProviderNode] {
        let list = try await call("nodes:list") as? [[String: Any]] ?? []
        return list.compactMap { node in
            guard let name = node["name"] as? String else {
                return nil
            }
            return ProviderNode(
                name: name,
                type: node["type"] as? String ?? "-",
                server: node["server"] as? String ?? "",
                port: node["port"] as? Int,
                rawURI: nil,
                metadata: (node["runtimeUdpSupported"] as? Bool).map { ["udp": String($0)] },
                identityKey: node["identityKey"] as? String,
                subscriptionId: node["subscriptionId"] as? String,
                subscriptionName: node["subscriptionName"] as? String,
                identityAmbiguous: node["identityAmbiguous"] as? Bool,
                iosSupported: node["iosSupported"] as? Bool
            )
        }
    }

    static func subscriptionRecord(from status: [String: Any]) -> SubscriptionRecord {
        SubscriptionRecord(
            url: status["url"] as? String ?? "",
            updatedAt: (status["updatedAt"] as? String).flatMap(parseDate),
            nodeCount: status["nodeCount"] as? Int ?? 0,
            status: status["status"] as? String ?? "empty",
            lastError: status["lastError"] as? String ?? ""
        )
    }

    static func firstEntry(_ record: [String: Any]) -> [String: Any]? {
        (record["entries"] as? [[String: Any]])?.first
    }

    // MARK: - sing-box

    /// Pushes the iPhone routing settings into the core, then generates the
    /// sing-box document the packet tunnel runs.
    func generateTunnelConfig(
        settings: AppSettings,
        domains: VpnDomainList,
        geoRoutingResources: GeoRoutingResources?
    ) async throws -> GeneratedTunnelConfig {
        let preferences = try await object("settings:patch", [
            "selectedProxy": settings.selectedProxy,
            "unknownTraffic": settings.unknownTrafficPolicy,
            "vpnDomainRules": domains.domains
        ])

        var payload: [String: Any] = [
            "mtu": settings.packetTunnelMTU,
            "domainResolver": settings.proxyServerDomainResolver
        ]
        if !((preferences["staticExit"] as? [String: Any])?["server"] as? String ?? "").isEmpty,
           let credential = try MobileSecretVault.load("static-exit") {
            payload["exitCredential"] = try JSONSerialization.jsonObject(with: credential)
        }
        if let geo = geoRoutingResources, geo.isAvailable {
            payload["geo"] = [
                "geositeCn": geo.geositeCNPath,
                "geoipCn": geo.geoipCNPath,
                "geositeNonCn": geo.geositeNonCNPath
            ]
        }
        let generated = try await object("singbox:generate", payload)
        guard let config = generated["config"] as? String,
              let summary = generated["summary"] as? [String: Any] else {
            throw CoreError(code: "CORE_BAD_REPLY", message: "核心没有返回 sing-box 配置")
        }
        return GeneratedTunnelConfig(
            selectedProxy: summary["selectedProxy"] as? String ?? settings.selectedProxy,
            providerNodeCount: summary["providerNodeCount"] as? Int ?? 0,
            convertedOutboundCount: summary["convertedOutboundCount"] as? Int,
            unsupportedNodeCount: summary["unsupportedNodeCount"] as? Int,
            selectedOutboundTag: summary["selectedOutboundTag"] as? String,
            selectedProxyStatus: summary["selectedProxyStatus"] as? String,
            selectedProxyMessage: summary["selectedProxyMessage"] as? String,
            unknownTrafficPolicy: summary["unknownTrafficPolicy"] as? String ?? settings.unknownTrafficPolicy,
            packetTunnelMTU: summary["packetTunnelMTU"] as? Int,
            vpnDomains: domains.domains,
            generatedAt: Date(),
            yaml: "",
            singBoxJSON: config,
            runtimeRevision: summary["runtimeRevision"] as? String
        )
    }

    /// The iPhone domain list stores bare suffixes; the core expects Mihomo rule lines.
    static func vpnDomainRule(_ domain: String) -> String {
        domain.contains(",") ? domain : "DOMAIN-SUFFIX,\(domain)"
    }

    // MARK: - FFI

    private static func invoke(root: String, request: String) -> String {
        MobileCoreBridge.invoke(root: root, request: request)
    }

    private static func decode(_ reply: String) throws -> Any {
        guard let object = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any] else {
            throw CoreError(code: "CORE_BAD_REPLY", message: "核心返回格式无效")
        }
        if object["ok"] as? Bool == true {
            return object["data"] ?? NSNull()
        }
        let error = object["error"] as? [String: Any]
        throw CoreError(
            code: error?["code"] as? String ?? "CORE_OPERATION_FAILED",
            message: error?["message"] as? String ?? "核心调用失败"
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
