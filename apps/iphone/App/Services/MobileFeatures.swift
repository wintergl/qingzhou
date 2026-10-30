import Foundation
import Security

struct ManagedSubscription: Identifiable {
    let id: String
    let name: String
    let url: String
    let enabled: Bool
    let nodeCount: Int
    let status: String
    let lastError: String?
    let interval: Int
    init?(_ value: [String: Any]) {
        guard let id = value["id"] as? String else { return nil }
        self.id = id; name = value["name"] as? String ?? "订阅"; url = value["url"] as? String ?? ""
        enabled = value["enabled"] as? Bool ?? true; nodeCount = value["nodeCount"] as? Int ?? 0
        status = value["status"] as? String ?? "saved"; lastError = value["lastError"] as? String
        interval = value["updateIntervalMinutes"] as? Int ?? 1440
    }
}

struct ManagedNodeGroup: Identifiable {
    var raw: [String: Any]
    var id: String { raw["id"] as? String ?? "" }
    var name: String { raw["name"] as? String ?? "节点组" }
    var strategy: String { raw["strategy"] as? String ?? "manual" }
    var nodeNames: [String] { raw["nodeNames"] as? [String] ?? [] }
}


extension SplitVpnAppState {
    func restoreManagedSettings(_ previous: [String: Any]) async throws {
        let fields = ["selectedProxy", "defaultOutlet", "unknownTraffic", "geoFallback", "vpnDomainRules", "directDomainRules", "specialCompatibilityRules", "favoriteNodeNames", "nodeGroups", "ipv6", "lanDirect", "tailscaleDirect", "staticExit"]
        var patch: [String: Any] = [:]; fields.forEach { patch[$0] = previous[$0] }
        _ = try await core.call("settings:patch", patch)
        try await refreshManagedState(); try await regenerateConfig()
        if isTunnelRunning { try await applyManagedConfiguration() }
    }
    func applyManagedConfiguration() async throws {
        let generated = store.readGeneratedConfig()
        if generated?.selectedOutboundTag == "block" { throw CoreError(code: "INVALID_SELECTION", message: generated?.selectedProxyMessage ?? "所选节点不可用") }
        guard isTunnelRunning else { notice = "配置已保存"; return }
        try await vpnManager.reloadConfiguration()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            await refreshVPNStatus()
            if runtimeStatus.state == .connected && runtimeStatus.configurationRevision == store.readGeneratedConfig()?.runtimeRevision { notice = "配置已生效"; return }
            if runtimeStatus.state == .error || runtimeStatus.state == .disconnected { break }
        }
        throw CoreError(code: "APPLY_UNCONFIRMED", message: "未能确认配置已生效，请检查连接状态")
    }

    func refreshManagedState() async throws {
        if !FileManager.default.fileExists(atPath: store.url("core/settings.json").path) {
            _ = try await core.call("settings:patch", ["selectedProxy": settings.selectedProxy, "unknownTraffic": settings.unknownTrafficPolicy, "vpnDomainRules": domains.domains])
        }
        let preferences = try await core.object("settings:get")
        let record = try await core.subscriptionStatus()
        corePreferences = preferences
        subscriptions = (record["entries"] as? [[String: Any]] ?? []).compactMap(ManagedSubscription.init)
        nodeGroups = (preferences["nodeGroups"] as? [[String: Any]] ?? []).map { ManagedNodeGroup(raw: $0) }
        settings.selectedProxy = preferences["selectedProxy"] as? String ?? settings.selectedProxy
        settings.unknownTrafficPolicy = preferences["unknownTraffic"] as? String ?? settings.unknownTrafficPolicy
        domains = VpnDomainList(domains: preferences["vpnDomainRules"] as? [String] ?? domains.domains)
        try store.saveSettings(settings); try store.saveDomains(domains)
        nodes = try await core.nodes(); try store.saveNodes(nodes)
        try store.saveSubscription(CoreClient.subscriptionRecord(from: record))
    }

    @discardableResult
    func managedEdit(_ channel: String, _ payload: [String: Any], regenerate: Bool = true) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true; defer { isBusy = false }
        var previous: [String: Any]?
        do {
            previous = try await core.object("settings:get")
            _ = try await core.call(channel, payload)
            try await refreshManagedState()
            if regenerate { try await regenerateConfig(); try await applyManagedConfiguration() }
            refreshFromDisk()
            return true
        } catch is CancellationError { return false }
        catch {
            let original = Redaction.message(error.localizedDescription)
            if let previous, !channel.hasPrefix("subscription:") { do { try await restoreManagedSettings(previous) } catch { notice = "操作失败，原配置恢复尚未确认，请检查连接"; return false } }
            notice = original; return false
        }
    }

    func updateManagedSubscription(_ id: String) async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do {
            let result = try await subscriptionService.update(id: id, core: core)
            try await refreshManagedState()
            guard result.ok else { notice = Redaction.message(result.error); return }
            try await regenerateConfig(); try await applyManagedConfiguration(); refreshFromDisk()
        } catch { notice = Redaction.message(error.localizedDescription) }
    }

    func saveStaticExit(_ configuration: [String: Any], password: String) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true; defer { isBusy = false }
        var previous: Data?
        var persisted = false
        var applied = false
        let oldConfiguration = corePreferences["staticExit"] as? [String: Any] ?? ["enabled": false, "protocol": "socks5", "server": "", "port": 0, "username": "", "expectedIp": ""]
        do {
            previous = try MobileSecretVault.load("static-exit")
            let old = previous.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let endpoint = old?["configuration"] as? NSDictionary
            let same = ["protocol", "server", "port", "username"].allSatisfy { key in
                guard let a = endpoint?[key] as? NSObject, let b = configuration[key] as? NSObject else { return false }; return a == b
            }
            let secret = password.isEmpty && same ? old?["password"] as? String ?? "" : password
            let credential: [String: Any] = ["configuration": configuration, "password": secret]
            try MobileSecretVault.save("static-exit", data: JSONSerialization.data(withJSONObject: credential)); persisted = true
            _ = try await core.call("static-exit:configure", ["configuration": configuration])
            applied = true
            try await refreshManagedState(); try await regenerateConfig(); refreshFromDisk()
            try await applyManagedConfiguration()
            return true
        } catch {
            if persisted { try? MobileSecretVault.save("static-exit", data: previous) }
            if applied {
                _ = try? await core.call("static-exit:configure", ["configuration": oldConfiguration])
                try? await refreshManagedState(); try? await regenerateConfig()
            }
            notice = Redaction.message(error.localizedDescription); return false
        }
    }
}


extension SplitVpnAppState {
    var mobileContext: String { "\(runtimeStatus.state.rawValue):\(runtimeStatus.configurationRevision ?? ""):\(runtimeStatus.networkEpoch ?? "")" }
    func mobilePayload() throws -> [String: Any] {
        guard runtimeStatus.state == .connected, let revision = runtimeStatus.configurationRevision, let epoch = runtimeStatus.networkEpoch else {
            throw CoreError(code: "NOT_CONNECTED", message: "请先连接并等待配置生效")
        }
        return ["connected": true, "runtimeRevision": revision, "networkEpoch": epoch]
    }
    func mobileCall(_ channel: String, _ extra: [String: Any] = [:]) async throws -> [String: Any] {
        let context = mobileContext
        var payload = try mobilePayload()
        extra.forEach { payload[$0.key] = $0.value }
        let result = try await core.object(channel, payload)
        await refreshVPNStatus()
        guard context == mobileContext else { throw CoreError(code: "STALE", message: "连接已变化，本次结果已丢弃") }
        return result
    }
    func scheduleMobileDiagnostics() {
        let context = mobileContext
        guard context != automaticDiagnosticContext else { return }
        let invalidatedEpoch = automaticDiagnosticNetworkEpoch
        automaticDiagnosticNetworkEpoch = runtimeStatus.networkEpoch ?? ""
        automaticDiagnosticContext = context
        mobileConnectivity = [:]; mobileWebsites = []; currentExitRisk = [:]
        if runtimeStatus.state != .connected {
            Task { _ = try? await core.call("mobile:runtime:invalidate", ["expectedEpoch": invalidatedEpoch]) }
            return
        }
        guard runtimeStatus.configurationRevision != nil else { return }
        Task { await runMobileDiagnostics(context: context) }
    }
    func runMobileDiagnostics(context: String? = nil) async {
        guard !mobileDiagnosticsRunning else { return }
        let observed = context ?? mobileContext
        mobileDiagnosticsRunning = true
        defer {
            mobileDiagnosticsRunning = false
            if observed != mobileContext { automaticDiagnosticContext = ""; scheduleMobileDiagnostics() }
        }
        do {
            let target = ConnectivityProbeTarget(id: "chatgpt-system", name: "ChatGPT", url: URL(string: "https://chatgpt.com/cdn-cgi/trace")!, capturesBodyPreview: false)
            let evidence = await ConnectivityProbeService().runAll(targets: [target], roundCount: 1).first
            guard observed == mobileContext else { return }
            let code = evidence?.statusCode
            let dns: [String: Any] = ["ok": code != nil, "error": code == nil ? "系统 DNS／连接尚未取得成功响应" : NSNull()]
            let web: [String: Any] = ["ok": code.map { (200..<300).contains($0) } ?? false, "httpStatus": code as Any? ?? NSNull(), "error": code.map { (200..<300).contains($0) ? NSNull() as Any : "ChatGPT 返回 HTTP \($0)" } ?? "ChatGPT 请求失败"]
            let connectivity = try await mobileCall("mobile:diagnostics:connectivity", ["systemDns": dns, "chatgpt": web])
            let websites = try await mobileCall("mobile:diagnostics:websites")
            guard observed == mobileContext else { return }
            mobileConnectivity = connectivity["connectivity"] as? [String: Any] ?? [:]
            mobileWebsites = websites["results"] as? [[String: Any]] ?? []
        } catch { if observed == mobileContext { notice = Redaction.message(error.localizedDescription) } }
    }
    func checkCurrentExitRisk() async {
        do {
            guard let data = try MobileSecretVault.load("ipdata"), let key = String(data: data, encoding: .utf8), !key.isEmpty else { throw CoreError(code: "NO_KEY", message: "请先保存 ipdata 密钥") }
            currentExitRisk = try await mobileCall("mobile:diagnostics:risk", ["apiKey": key])
        } catch { notice = Redaction.message(error.localizedDescription) }
    }
    func updateDueSubscriptions() async {
        guard !isBusy, Date().timeIntervalSince(dueSubscriptionAttempt) > 900 else { return }
        dueSubscriptionAttempt = Date()
        #if os(iOS)
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        #endif
        do {
            let ids = try await core.call("subscription:due") as? [String] ?? []
            for id in ids { if Task.isCancelled { return }; await updateManagedSubscription(id) }
        } catch { notice = Redaction.message(error.localizedDescription) }
    }
}

extension SplitVpnAppState {
    func useMobileChain(_ identity: String) async throws -> String {
        guard !isBusy else { throw CoreError(code: "BUSY", message: "请等待当前操作结束") }
        isBusy = true; defer { isBusy = false }
        let previous = try await core.object("settings:get")
        do {
            let checked = try await mobileCall("mobile:chain:prepare-use", ["identityKey": identity])
            _ = try await mobileCall("mobile:chain:commit-use", ["ticket": checked["ticket"] ?? ""])
            try await refreshManagedState(); try await regenerateConfig(); try await applyManagedConfiguration()
            let confirmed = try await mobileCall("mobile:diagnostics:verify-exit")
            return "已确认实际出口：\(confirmed["externalIp"] as? String ?? "未知")"
        } catch {
            let original = error
            let fields = ["selectedProxy", "defaultOutlet", "staticExit"]
            var patch: [String: Any] = [:]; fields.forEach { patch[$0] = previous[$0] }
            _ = try await core.call("settings:patch", patch)
            try await refreshManagedState(); try await regenerateConfig(); try await applyManagedConfiguration()
            throw original
        }
    }
}
