import Foundation
import NetworkExtension

@MainActor
final class SplitVpnAppState: ObservableObject {
    @Published var subscription: SubscriptionRecord = .empty
    @Published var settings: AppSettings = .defaults
    @Published var domains: VpnDomainList = .defaults
    @Published var runtimeStatus: RuntimeStatus = .disconnected
    @Published var diagnosticsSettings: DiagnosticsSettings = .standard
    @Published var nodes: [ProviderNode] = []
    @Published var logs: [LogEntry] = []
    @Published var generatedConfigReady = false
    @Published var convertedOutboundCount = 0
    @Published var unsupportedNodeCount = 0
    @Published var selectedOutboundTag = "-"
    @Published var selectedProxyStatus = "-"
    @Published var selectedProxyMessage = "-"
    @Published var packetTunnelCoreMode = SplitVpnConstants.packetTunnelCoreMode
    @Published var readinessItems: [ReadinessItem] = []
    @Published var usesAppGroupContainer = false
    @Published var ruleSetLibrary: RuleSetLibraryRecord = .empty
    @Published var isRuleSetUpdating = false
    @Published var isBusy = false
    @Published var notice: String?

    private let store: AppGroupStore
    private let core: CoreClient
    private let subscriptionService: SubscriptionService
    private let ruleSetUpdateService: RuleSetUpdateService
    private let vpnManager: SplitVpnVPNManager

    var isTunnelRunning: Bool {
        switch runtimeStatus.state {
        case .connected, .connecting, .disconnecting:
            return true
        case .disconnected, .error:
            return false
        }
    }

    init(
        store: AppGroupStore = .shared,
        subscriptionService: SubscriptionService = SubscriptionService(),
        ruleSetUpdateService: RuleSetUpdateService? = nil,
        vpnManager: SplitVpnVPNManager = SplitVpnVPNManager(),
        core: CoreClient? = nil
    ) {
        self.store = store
        self.core = core ?? CoreClient(rootURL: store.url("core"))
        self.subscriptionService = subscriptionService
        self.ruleSetUpdateService = ruleSetUpdateService ?? RuleSetUpdateService(store: store)
        self.vpnManager = vpnManager
        refreshFromDisk()
    }

    func bootstrap() async {
        refreshFromDisk()
        do {
            try await migrateLegacySubscription()
            try await syncSubscriptionMirrors()
            try await regenerateConfig()
            refreshFromDisk()
        } catch {
            let message = Redaction.message(error.localizedDescription)
            appendLog(level: "warn", message: "Config regeneration during app bootstrap failed: \(message)")
            notice = message
        }
        await refreshVPNStatus()
        await updateRuleSets(force: false)
    }

    func refreshFromDisk() {
        subscription = store.readSubscription()
        settings = store.readSettings()
        domains = store.readDomains()
        runtimeStatus = store.readRuntimeStatus()
        diagnosticsSettings = store.readDiagnosticsSettings()
        nodes = store.readNodes()
        logs = store.readLogs().sorted { $0.createdAt > $1.createdAt }
        ruleSetLibrary = store.readRuleSetLibrary()
        let generatedConfig = store.readGeneratedConfig()
        generatedConfigReady = generatedConfig?.singBoxJSON?.isEmpty == false
        convertedOutboundCount = generatedConfig?.convertedOutboundCount ?? 0
        unsupportedNodeCount = generatedConfig?.unsupportedNodeCount ?? 0
        selectedOutboundTag = generatedConfig?.selectedOutboundTag ?? "-"
        selectedProxyStatus = generatedConfig?.selectedProxyStatus ?? "-"
        selectedProxyMessage = generatedConfig?.selectedProxyMessage ?? "-"
        readinessItems = makeReadinessItems(generatedConfig: generatedConfig)
        usesAppGroupContainer = store.isUsingAppGroupContainer
    }

    func saveSubscriptionURL(_ value: String) {
        let url = value.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await core.saveSubscription(url: url)
                try await syncSubscriptionMirrors()
                refreshFromDisk()
                appendLog(level: "info", message: "Saved subscription \(Redaction.subscriptionURL(url))")
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    func updateSubscription(url value: String? = nil) async {
        let url = (value ?? subscription.url).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            notice = "订阅 URL 不能为空"
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let id = try await core.saveSubscription(url: url)
            let result = try await subscriptionService.update(id: id, core: core)
            try await syncSubscriptionMirrors()
            guard result.ok else {
                let message = Redaction.message(result.error)
                appendLog(level: "error", message: "Subscription update failed: \(message)")
                refreshFromDisk()
                notice = message
                return
            }
            try await regenerateConfig()
            appendLog(level: "info", message: "Updated subscription \(Redaction.subscriptionURL(url)); nodes=\(store.readNodes().count)")
            refreshFromDisk()
            notice = "订阅已更新，节点 \(nodes.count) 个"
        } catch {
            let message = Redaction.message(error.localizedDescription)
            appendLog(level: "error", message: "Subscription update failed: \(message)")
            refreshFromDisk()
            notice = message
        }
    }

    func selectProxy(_ name: String) {
        settings.selectedProxy = name
        do {
            try store.saveSettings(settings)
            appendLog(level: "info", message: "Selected proxy \(name)")
            applyRoutingChange("节点已切换为 \(name)")
        } catch {
            notice = error.localizedDescription
        }
    }

    func saveDomains(from multilineText: String) {
        let next = VpnDomainList(domains: multilineText.split(whereSeparator: \.isNewline).map(String.init))
        do {
            try store.saveDomains(next)
            appendLog(level: "info", message: "Saved VPN domain list")
            applyRoutingChange("VPN 域名规则已保存")
        } catch {
            notice = error.localizedDescription
        }
    }

    func setUnknownTrafficPolicy(_ value: String) {
        settings.unknownTrafficPolicy = value
        do {
            try store.saveSettings(settings)
            applyRoutingChange("未知流量策略已更新")
        } catch {
            notice = error.localizedDescription
        }
    }

    func setPacketTunnelMTU(_ value: Int) {
        settings.packetTunnelMTU = TunnelAddressing.normalizedMTU(value)
        do {
            try store.saveSettings(settings)
            applyRoutingChange("Packet Tunnel MTU 已更新")
        } catch {
            notice = error.localizedDescription
        }
    }

    func setProxyServerDomainResolver(_ value: String) {
        settings.proxyServerDomainResolver = ProxyServerDomainResolver.normalized(value)
        do {
            try store.saveSettings(settings)
            applyRoutingChange("节点 DNS 解析器已更新")
        } catch {
            notice = error.localizedDescription
        }
    }

    func enableDeepDiagnostics() {
        do {
            let next = DiagnosticsSettings.deep()
            try store.saveDiagnosticsSettings(next)
            diagnosticsSettings = next
            noteRestartIfTunnelRunning("深度诊断已开启 10 分钟")
        } catch {
            notice = error.localizedDescription
        }
    }

    func disableDeepDiagnostics() {
        do {
            try store.saveDiagnosticsSettings(.standard)
            diagnosticsSettings = .standard
            noteRestartIfTunnelRunning("已恢复标准低功耗诊断")
        } catch {
            notice = error.localizedDescription
        }
    }

    func updateRuleSets(force: Bool = true) async {
        guard !isRuleSetUpdating else {
            return
        }

        isRuleSetUpdating = true
        defer {
            isRuleSetUpdating = false
        }

        do {
            let result = try await ruleSetUpdateService.updateIfNeeded(force: force)
            ruleSetLibrary = result.record
            if result.didUpdate {
                try await regenerateConfig()
                appendLog(level: "info", message: "Updated rule-set library bytes=\(result.record.totalBytes)")
                refreshFromDisk()
                noteRestartIfTunnelRunning("规则集已更新")
            } else if force {
                notice = "规则集已是最新"
            }
        } catch {
            let message = Redaction.message(error.localizedDescription)
            appendLog(level: "warn", message: "Rule-set update failed: \(message)")
            refreshFromDisk()
            if force {
                notice = message
            }
        }
    }

    func routeDecision(for input: String) -> RouteDecision {
        DefaultRules.routeDecision(
            for: input,
            vpnDomains: domains.domains,
            unknownTrafficPolicy: settings.unknownTrafficPolicy
        )
    }

    func connect() async {
        isBusy = true
        defer { isBusy = false }

        do {
            try await regenerateConfig()
            refreshFromDisk()
            appendLog(
                level: "info",
                message: "Connect requested selected=\(settings.selectedProxy) nodes=\(nodes.count) converted=\(convertedOutboundCount) unsupported=\(unsupportedNodeCount) selected_status=\(store.readGeneratedConfig()?.selectedProxyStatus ?? "-") configReady=\(generatedConfigReady)"
            )
            try assertReadyForPhoneTunnel()
            try await vpnManager.installOrUpdateTunnel()
            try await vpnManager.startTunnel()
            appendLog(level: "info", message: "Requested iOS VPN start")
            await refreshVPNStatus()
        } catch {
            let message = Redaction.message(error.localizedDescription)
            runtimeStatus = RuntimeStatus(
                state: .error,
                startedAt: nil,
                lastError: message,
                bytesIn: runtimeStatus.bytesIn,
                bytesOut: runtimeStatus.bytesOut
            )
            try? store.saveRuntimeStatus(runtimeStatus)
            appendLog(level: "error", message: "VPN start failed: \(message)")
            notice = message
            refreshFromDisk()
        }
    }

    func disconnect() async {
        await vpnManager.stopTunnel()
        try? store.saveRuntimeStatus(.disconnected)
        appendLog(level: "info", message: "Requested iOS VPN stop")
        await refreshVPNStatus()
        refreshFromDisk()
    }

    func refreshVPNStatus() async {
        do {
            let status = try await vpnManager.currentStatus()
            if shouldRequestExtensionStatus(status), let extensionStatus = try await vpnManager.extensionRuntimeStatus() {
                runtimeStatus = extensionStatus
                runtimeStatus.state = map(status)
            } else {
                runtimeStatus.state = map(status)
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    private func regenerateConfig() async throws {
        let geoRoutingResources = try store.installBundledGeoRoutingResources()
        let generated = try await core.generateTunnelConfig(
            settings: settings,
            domains: domains,
            geoRoutingResources: geoRoutingResources
        )
        try store.saveGeneratedConfig(generated)
    }

    private func applyRoutingChange(_ summary: String) {
        Task {
            do {
                try await regenerateConfig()
                refreshFromDisk()
                noteRestartIfTunnelRunning(summary)
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    /// Writes the core's subscription summary and node list into the App Group
    /// mirrors the UI and packet tunnel diagnostics read.
    private func syncSubscriptionMirrors() async throws {
        let status = try await core.subscriptionStatus()
        try store.saveSubscription(CoreClient.subscriptionRecord(from: status))
        try store.saveNodes(try await core.nodes())
    }

    /// Moves a URL and provider text saved before the Rust core existed into
    /// the core, so upgraded installs keep their nodes without a download.
    private func migrateLegacySubscription() async throws {
        let legacyURL = store.readSubscription().url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !legacyURL.isEmpty, CoreClient.firstEntry(try await core.subscriptionStatus()) == nil {
            try await core.saveSubscription(url: legacyURL)
            appendLog(level: "info", message: "Migrated subscription \(Redaction.subscriptionURL(legacyURL)) into core")
        }

        guard let entry = CoreClient.firstEntry(try await core.subscriptionStatus()),
              let id = entry["id"] as? String,
              (entry["nodeCount"] as? Int ?? 0) == 0,
              let legacyText = try? String(contentsOf: store.url("providers/subscription.yaml"), encoding: .utf8),
              !legacyText.isEmpty else {
            return
        }
        let plan = try await core.object("subscription:plan", ["id": id])
        let result = try await core.object(
            "subscription:accept",
            ["id": id, "token": plan["token"] ?? "", "index": 0, "status": 200, "content": legacyText]
        )
        if result["done"] as? Bool == true, result["ok"] as? Bool == true {
            appendLog(level: "info", message: "Imported legacy provider nodes into core")
        } else {
            appendLog(level: "warn", message: "Legacy provider text could not be imported into core")
        }
    }

    private func noteRestartIfTunnelRunning(_ summary: String) {
        if isTunnelRunning {
            notice = "\(summary)；当前 VPN 需要断开后重新连接才会生效"
            appendLog(level: "warn", message: "\(summary); reconnect required for active tunnel")
        } else {
            notice = summary
        }
    }

    private func assertReadyForPhoneTunnel() throws {
        let blockingItems = readinessItems.filter { item in
            item.severity == .blocking && Self.hardBlockingReadinessIDs.contains(item.id)
        }
        guard blockingItems.isEmpty else {
            let message = blockingItems.map(\.title).joined(separator: "；")
            appendLog(level: "error", message: "Phone tunnel preflight failed: \(message)")
            throw SplitVpnAppStateError.preflightFailed(message)
        }
    }

    private static let hardBlockingReadinessIDs = Set([
        "signing",
        "app-group",
        "node-conversion"
    ])

    private func makeReadinessItems(generatedConfig: GeneratedTunnelConfig?) -> [ReadinessItem] {
        [
            signingReadinessItem(),
            appGroupReadinessItem(),
            subscriptionReadinessItem(),
            nodeConversionReadinessItem(generatedConfig: generatedConfig),
            singBoxReadinessItem(generatedConfig: generatedConfig)
        ]
    }

    private func signingReadinessItem() -> ReadinessItem {
        if SplitVpnConstants.usesPlaceholderSigning {
            return ReadinessItem(
                id: "signing",
                title: "签名配置仍是占位值",
                detail: "请在 Config/Signing.local.xcconfig 设置 Team、Bundle ID 和 App Group",
                severity: .blocking
            )
        }
        return ReadinessItem(
            id: "signing",
            title: "签名标识已替换",
            detail: "Bundle ID、Extension ID 和 App Group 来自本地配置",
            severity: .ok
        )
    }

    private func appGroupReadinessItem() -> ReadinessItem {
        if store.isUsingAppGroupContainer {
            return ReadinessItem(
                id: "app-group",
                title: "App Group 可用",
                detail: "主 App 和 Extension 将使用共享容器",
                severity: .ok
            )
        }
        return ReadinessItem(
            id: "app-group",
            title: "App Group 容器不可用",
            detail: "当前退回到 App 文档目录，真机 VPN Extension 将无法共享配置",
            severity: .blocking
        )
    }

    private func subscriptionReadinessItem() -> ReadinessItem {
        if nodes.isEmpty {
            return ReadinessItem(
                id: "subscription",
                title: "还没有可用订阅节点",
                detail: "仍可先启动隧道做真机连通性测试",
                severity: .warning
            )
        }
        return ReadinessItem(
            id: "subscription",
            title: "订阅节点已加载",
            detail: "节点数量 \(nodes.count)",
            severity: .ok
        )
    }

    private func nodeConversionReadinessItem(generatedConfig: GeneratedTunnelConfig?) -> ReadinessItem {
        let converted = generatedConfig?.convertedOutboundCount ?? convertedOutboundCount
        let unsupported = generatedConfig?.unsupportedNodeCount ?? unsupportedNodeCount
        let selectedStatus = generatedConfig?.selectedProxyStatus ?? ""
        let selectedMessage = generatedConfig?.selectedProxyMessage ?? ""
        if nodes.isEmpty {
            return ReadinessItem(
                id: "node-conversion",
                title: "等待订阅节点",
                detail: "更新订阅后会生成 sing-box outbounds",
                severity: .warning
            )
        }
        if selectedStatus == "manual-unsupported" || selectedStatus == "manual-missing" {
            return ReadinessItem(
                id: "node-conversion",
                title: "当前手选节点不可用",
                detail: Redaction.message(selectedMessage),
                severity: .blocking
            )
        }
        if converted == 0 {
            return ReadinessItem(
                id: "node-conversion",
                title: "订阅节点暂不能转换",
                detail: "连接不会被阻断；将使用直连 fallback 先验证 Packet Tunnel",
                severity: .warning
            )
        }
        return ReadinessItem(
            id: "node-conversion",
            title: "节点可转换",
            detail: "已转换 \(converted)，暂不支持 \(unsupported)",
            severity: unsupported > 0 ? .warning : .ok
        )
    }

    private func singBoxReadinessItem(generatedConfig: GeneratedTunnelConfig?) -> ReadinessItem {
        if generatedConfig?.singBoxJSON?.isEmpty == false {
            return ReadinessItem(
                id: "sing-box",
                title: "sing-box 配置已生成",
                detail: "Packet Tunnel 启动时会传递 configContent",
                severity: .ok
            )
        }
        return ReadinessItem(
            id: "sing-box",
            title: "sing-box 配置未生成",
            detail: "点击连接前会尝试重新生成配置",
            severity: .warning
        )
    }

    private func appendLog(level: String, message: String) {
        store.appendLog(level: level, message: message)
        logs = store.readLogs().sorted { $0.createdAt > $1.createdAt }
    }

    private func map(_ status: NEVPNStatus) -> TunnelConnectionState {
        switch status {
        case .connected:
            return .connected
        case .connecting, .reasserting:
            return .connecting
        case .disconnecting:
            return .disconnecting
        case .disconnected, .invalid:
            return .disconnected
        @unknown default:
            return .error
        }
    }

    private func shouldRequestExtensionStatus(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connected, .connecting, .reasserting:
            return true
        case .disconnected, .disconnecting, .invalid:
            return false
        @unknown default:
            return false
        }
    }
}

enum SplitVpnAppStateError: LocalizedError {
    case preflightFailed(String)

    var errorDescription: String? {
        switch self {
        case .preflightFailed(let message):
            return "真机连接预检未通过：\(message)"
        }
    }
}
