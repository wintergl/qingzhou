import AppKit
import Combine
import Foundation

@MainActor
final class VPNStore: ObservableObject {
    @Published var page: VPNPage? = .overview
    @Published private(set) var status: VPNStatus?
    @Published private(set) var statusKnown = false
    @Published private(set) var connectionOperation: ConnectionOperation?
    @Published private(set) var terminating = false
    @Published private(set) var nodes: [VPNNode] = []
    @Published private(set) var groups: [NodeGroupState] = []
    @Published private(set) var risks: [NodeRisk] = []
    @Published private(set) var traffic: TrafficMonitor?
    @Published private(set) var legacyOwnerRunning = false
    @Published private(set) var previewOnly = true
    @Published private(set) var ownsRuntime = false
    @Published private(set) var companyRouting: CompanyRoutingState?
    @Published private(set) var refreshing = false
    @Published private(set) var busy: String?
    @Published var message: String?
    @Published var error: String?
    @Published private(set) var connectivity: ConnectivityCheck?
    @Published private(set) var diagnostics: DiagnosticSchedule?
    @Published private(set) var speedBatchRunning = false
    @Published private(set) var speedProgress: NodeSpeedProgress?
    @Published private(set) var speedTestingNode: String?
    @Published private(set) var websites: WebsiteTests?
    @Published private(set) var batchMessage: String?
    @Published private(set) var riskBatchRunning = false
    @Published private(set) var riskProgress: RiskBatchProgress?
    @Published private(set) var riskBatchNote: String?
    @Published private(set) var riskKeyConfigured = false
    @Published var riskKeyMessage: String?
    @Published private(set) var loginItemState: LoginItemState = .disabled
    @Published private(set) var activity = DesktopActivity()
    let core: CoreService
    private let loginItems: any LoginItemService
    var onCompanyRouting: ((CompanyRoutingState) -> Void)?
    private var operationGeneration: UInt64 = 0
    private var started = false
    private var startupConnectionRequested = false
    private var startup: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    private var pollingInterval: Duration?
    private var refreshingTraffic = false
    private var operation: Task<Void, Never>?
    private var coreObservation: AnyCancellable?
    private var networkChanges: NativeNetworkChangeService?
    private var activityChanges: NativeActivityService?
    private var networkEventsEnabled = false
    private let riskKeyVault: any CompanyCredentialVault
    private let riskKeyOrigin = "https://api.ipdata.co"
    init(preview: Bootstrap? = nil, core: CoreService? = nil, loginItems: (any LoginItemService)? = nil,
         riskKeyVault: (any CompanyCredentialVault)? = nil) {
        self.core = core ?? CoreService()
        self.loginItems = loginItems ?? NativeLoginItemService()
        self.riskKeyVault = riskKeyVault ?? KeychainCompanyCredentialVault(service: "dev.split-vpn.risk-api-key")
        if let preview {
            started = true; statusKnown = true; status = preview.status; nodes = preview.nodes; groups = preview.groups; risks = preview.risks
            traffic = preview.traffic; previewOnly = true; companyRouting = preview.companyRouting
            if let diagnostics = preview.diagnostics { applyDiagnostics(diagnostics) }
            if let loginItems { loginItemState = loginItems.state() }
        }
        coreObservation = self.core.$availability.sink { [weak self] availability in
            switch availability {
            case .unavailable, .closed: self?.statusKnown = false; self?.startPolling()
            default: break
            }
        }
    }

    var running: Bool { status?.mihomo.state == "running" }
    var selectedProxy: String { status?.settings.selectedProxy ?? "尚未读取" }
    var displaySelectedProxy: String { groups.first { $0.runtimeName == selectedProxy }?.group.name ?? selectedProxy }
    var favoriteNames: Set<String> { Set(status?.settings.favoriteNodeNames ?? []) }
    var providerNodes: [VPNNode] { nodes.filter(\.isProvider) }
    var currentRisk: NodeRisk? { risks.first { $0.nodeName == selectedProxy } }
    var canMutate: Bool { !previewOnly && !terminating && busy == nil && connectionOperation != .disconnecting && statusKnown && status != nil }
    var connectionRequested: Bool {
        running || connectionOperation == .connecting || status?.mihomo.networkRecovery?.active == true
    }
    var canDisconnect: Bool {
        !previewOnly && !terminating && statusKnown && !connectionProtected
            && connectionRequested && connectionOperation != .disconnecting
    }
    var canControlConnection: Bool { canDisconnect || canMutate }
    var connectionProtected: Bool { legacyOwnerRunning && running && !ownsRuntime }

    func startOnce() {
        guard !started else { return }; started = true
        startNetworkChanges()
        startActivityChanges()
        refreshLoginItem()
        core.onEvent = { [weak self] event, value in
            guard let self else { return }
            if event == "diagnostics:updated", let value, let state = try? JSONDecoder().decode(DiagnosticSchedule.self, from: value.encoded) {
                self.applyDiagnostics(state); return
            }
            if event == "nodes:speed-progress", let value, let progress = try? JSONDecoder().decode(NodeSpeedProgress.self, from: value.encoded) {
                self.speedProgress = progress; self.speedBatchRunning = !progress.finished
                self.speedTestingNode = progress.phase == "testing" ? progress.nodeName : nil
                if let result = progress.result, let index = self.nodes.firstIndex(where: { $0.name == result.nodeName && $0.identityAmbiguous != true }) {
                    self.nodes[index].delay = result.medianDelayMs.flatMap { $0 > 0 ? $0 : nil }
                    self.nodes[index].available = result.status == "available" || result.status == "unstable"
                    self.nodes[index].latencyStatus = result.status
                    self.nodes[index].latencyCheckedAt = result.testedAt
                    self.nodes[index].latencySource = "manual"
                    self.nodes[index].latencyFailure = result.failureReason
                }
                if progress.finished { self.speedTestingNode = nil; Task { await self.refresh() } }
                return
            }
            if event == "vpn:status", let value,
               let state = try? JSONDecoder().decode(CoreStatus.self, from: value.encoded) {
                self.status?.mihomo = state
                self.statusKnown = self.status != nil
                if state.networkRecovery?.ready == false { self.connectivity = nil; self.websites = nil }
                self.startPolling()
                return
            }
            if event == "company:routing-state", let value,
               let state = try? JSONDecoder().decode(CompanyRoutingState.self, from: value.encoded) {
                self.companyRouting = state; self.onCompanyRouting?(state)
            }
            if event == "nodes:risk-progress", let value,
               let progress = try? JSONDecoder().decode(RiskBatchProgress.self, from: value.encoded) {
                self.riskProgress = progress; self.riskBatchRunning = !progress.finished
                if let result = progress.result {
                    if let index = self.risks.firstIndex(where: { $0.nodeName == result.nodeName }) { self.risks[index] = result }
                    else { self.risks.append(result) }
                }
                if progress.finished {
                    if let error = progress.error { self.error = error }
                    Task { await self.refresh() }
                }
                return
            }
            if event.contains("progress"), case .object(let fields) = value {
                let checked = fields["checked"] ?? fields["completed"]
                let total = fields["total"]
                func number(_ value: JSONValue?) -> Int { if case .number(let n) = value { return Int(n) }; return 0 }
                self.batchMessage = "检测进度 \(number(checked)) / \(number(total))"
                if case .bool(true) = fields["finished"] {
                    self.batchMessage = "检测已完成"
                    Task { await self.refresh() }
                }
            }
        }
        startup = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            guard !Task.isCancelled else { return }
            self.repairLegacyLoginItem()
            await self.connectOnStartup()
            guard !Task.isCancelled else { return }
            await self.restoreRiskKey()
        }
        startPolling()
    }
    func refresh() async {
        guard !terminating else { return }
        do { try await refreshSnapshot() }
        catch is CancellationError { return }
        catch { statusKnown = false; self.error = error.localizedDescription }
    }
    private func refreshSnapshot(timeout: Duration? = nil) async throws {
        while refreshing { try await Task.sleep(for: .milliseconds(20)) }
        refreshing = true
        defer { refreshing = false }
        let generation = operationGeneration
        let data: Bootstrap = try await core.request("native:bootstrap", timeout: timeout)
        guard generation == operationGeneration else { throw CancellationError() }
        guard core.availability != .closed else { throw CoreService.CoreError.message("VPN 服务已关闭。") }
        statusKnown = true
        status = data.status; nodes = data.nodes; risks = data.risks
        if data.status.mihomo.networkRecovery?.ready == false { connectivity = nil; websites = nil }
        let states = Dictionary(uniqueKeysWithValues: data.groups.map { ($0.id, $0) })
        groups = data.status.settings.nodeGroups.map { group in
            if let state = states[group.id] { return state }
            // Subscription groups are retained in the saved schema but the
            // desktop runtime API only returns custom groups. Show both.
            let subscriptionID = group.id.hasPrefix("subscription:") ? String(group.id.dropFirst("subscription:".count)) : nil
            let members = group.nodeNames.map { name -> GroupMemberState in
                let node = data.nodes.first { $0.name == name && (subscriptionID == nil || $0.subscriptionId == subscriptionID) }
                return GroupMemberState(identityKey: node?.identityKey, lastKnownName: name,
                                        issue: node == nil ? "节点已移除或订阅停用" : nil,
                                        available: node?.available, delay: node?.delay, current: node?.selected ?? false)
            }
            return NodeGroupState(group: group, runtimeName: "", selected: false, applied: false,
                                  currentMember: members.first(where: \.current)?.lastKnownName, members: members,
                                  availableCount: members.filter { $0.available == true }.count,
                                  failedCount: members.filter { $0.available == false }.count,
                                  untestedCount: members.filter { $0.available == nil }.count)
        }
        traffic = data.traffic; previewOnly = data.previewOnly
        if let diagnostics = data.diagnostics { applyDiagnostics(diagnostics) }
        ownsRuntime = data.ownsRuntime; companyRouting = data.companyRouting
        onCompanyRouting?(data.companyRouting)
        legacyOwnerRunning = data.legacyOwnerRunning
        refreshLoginItem()
        startPolling()
    }
    private func applyDiagnostics(_ state: DiagnosticSchedule) {
        diagnostics = state
        connectivity = state.connectivity.result.flatMap { try? JSONDecoder().decode(ConnectivityCheck.self, from: $0.encoded) }
        websites = state.websites.result.flatMap { try? JSONDecoder().decode(WebsiteTests.self, from: $0.encoded) }
    }
    func startNodeSpeed(_ requested: [VPNNode]) {
        guard canMutate, running, !speedBatchRunning else { return }
        let names = requested.filter { $0.isProvider && $0.identityAmbiguous != true }.map(\.name)
        guard !names.isEmpty else { return }
        speedBatchRunning = true; speedProgress = nil; speedTestingNode = nil
        Task {
            do { _ = try await core.requestValue("nodes:start-speed-batch", payload: ["nodeNames": names]) }
            catch { speedBatchRunning = false; self.error = error.localizedDescription }
        }
    }
    func cancelNodeSpeed() {
        guard speedBatchRunning, !terminating else { return }
        Task { do { _ = try await core.requestValue("nodes:cancel-speed-batch") } catch { self.error = error.localizedDescription } }
    }
    func refreshTraffic() async {
        guard !terminating, !refreshingTraffic else { return }
        refreshingTraffic = true
        defer { refreshingTraffic = false }
        if let result: TrafficMonitor = try? await core.request("traffic:get-monitor"), !Task.isCancelled { traffic = result }
    }
    private struct StartupConnection: Decodable {
        var startupOutcome: String
        var mihomo: CoreStatus
    }
    private func connectOnStartup() async {
        guard !startupConnectionRequested, !Task.isCancelled, canMutate else { return }
        startupConnectionRequested = true
        busy = running ? "读取连接状态" : "自动连接 VPN"
        connectionOperation = running ? nil : .connecting
        let generation = operationGeneration
        defer { if generation == operationGeneration { busy = nil; connectionOperation = nil } }
        do {
            let result: StartupConnection = try await core.request("native:startup-connect")
            guard !Task.isCancelled else { return }
            status?.mihomo = result.mihomo
            await refresh()
            guard generation == operationGeneration, !Task.isCancelled else { return }
            if result.startupOutcome == "connected" { message = "已自动连接 VPN。" }
            else if result.startupOutcome == "waiting-network" { message = "网络尚未就绪，就绪后将自动连接 VPN。" }
            else if result.startupOutcome == "helper-update-required" { message = "请先更新连接服务，再连接 VPN。" }
        } catch {
            if !Task.isCancelled { self.error = "自动连接未完成：\(error.localizedDescription)" }
        }
    }
    func refreshLoginItem() {
        guard !previewOnly else { return }
        loginItemState = loginItems.state()
    }
    private func repairLegacyLoginItem() {
        guard canMutate else { return }
        do { loginItemState = try loginItems.repairLegacyRegistration() }
        catch {
            loginItemState = loginItems.state()
            self.error = "登录启动未完成：\(error.localizedDescription)"
        }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        guard !previewOnly, !terminating, busy == nil else { return }
        busy = "保存启动设置"; error = nil; message = nil
        defer { busy = nil }
        do {
            loginItemState = try loginItems.setEnabled(enabled)
            message = loginItemState == .requiresApproval ? loginItemState.detail : enabled ? "已设置登录后启动轻舟。" : "已关闭登录后启动。"
        } catch {
            loginItemState = loginItems.state()
            self.error = error.localizedDescription
        }
    }
    func openLoginItemSettings() { loginItems.openSystemSettings() }
    private func startNetworkChanges() {
        guard core.usesSystemRuntime, networkChanges == nil else { return }
        let changes = NativeNetworkChangeService()
        networkEventsEnabled = changes.start { [weak self] available in self?.networkChanged(available: available) }
        networkChanges = changes
    }
    func networkChanged(available: Bool?) {
        guard !terminating, !connectionProtected, statusKnown else { return }
        // Forward even after a failed recovery. The core owns reconnect intent
        // and ignores late notifications after an explicit disconnect.
        connectivity = nil; websites = nil
        let payload: [String: Any] = available.map { ["available": $0] } ?? [:]
        Task { [weak self] in
            guard let self, !self.terminating else { return }
            _ = try? await self.core.requestValue("native:network-changed", payload: payload)
        }
    }
    private func startActivityChanges() {
        guard core.usesSystemRuntime, activityChanges == nil else { return }
        let changes = NativeActivityService()
        changes.start { [weak self] activity in self?.setActivity(activity, forceReport: true) }
        activityChanges = changes
    }
    func setActivity(_ value: DesktopActivity, forceReport: Bool = false) {
        let previous = activity
        if value != previous { activity = value }
        startPolling()
        if !value.sleeping, value.visible, !previous.visible, running {
            Task { [weak self] in await self?.refreshTraffic() }
        }
        if forceReport || value.sleeping != previous.sleeping || value.lowPower != previous.lowPower || value.visible != previous.visible {
            let payload: [String: Any] = ["sleeping": value.sleeping, "lowPower": value.lowPower, "networkEvents": networkEventsEnabled, "visible": value.visible]
            Task { [weak self] in
                guard let self, !self.terminating else { return }
                _ = try? await self.core.requestValue("native:runtime-environment", payload: payload)
            }
        }
    }
    func updateConnectionService() {
        guard canMutate, connectionServiceUpdateRequired else { return }
        action("更新连接服务", channel: "native:upgrade-helper")
    }
    func disconnectNow() async throws {
        guard canDisconnect else { return }
        operationGeneration &+= 1
        startup?.cancel(); operation?.cancel()
        connectionOperation = .disconnecting; busy = "断开 VPN"
        connectivity = nil; websites = nil; error = nil; message = nil
        defer { connectionOperation = nil; busy = nil }
        do {
            let stopped: CoreStatus = try await core.request("vpn:stop", timeout: .seconds(45))
            guard stopped.state == "stopped", stopped.pid == nil else {
                throw CoreService.CoreError.message("VPN 断开尚未确认，请刷新状态后重试。")
            }
            status?.mihomo = stopped; statusKnown = status != nil
            message = "VPN 已断开。"
        } catch { self.error = error.localizedDescription; throw error }
    }
    func action(_ title: String, channel: String, payload: [String: Any] = [:]) {
        if channel == "vpn:stop", canDisconnect {
            Task { try? await disconnectNow() }; return
        }
        guard canMutate else { error = "服务尚未就绪或已有操作正在进行，请稍后重试。"; return }
        guard busy == nil else { return }
        busy = title; error = nil; message = nil
        connectionOperation = channel == "vpn:start" ? .connecting : channel == "vpn:stop" ? .disconnecting : nil
        let generation = operationGeneration
        operation = Task {
            defer { if generation == operationGeneration { busy = nil; connectionOperation = nil } }
            do {
                let result = try await core.requestValue(channel, payload: payload)
                guard generation == operationGeneration, !Task.isCancelled else { return }
                if case .object(let fields) = result, case .bool(false) = fields["controllerOk"] {
                    let detail = fields["controllerError"].flatMap { if case .string(let message) = $0 { return message }; return nil }
                    throw CoreService.CoreError.message(detail ?? "内核连接验证失败。")
                }
                try await refreshSnapshot()
                guard generation == operationGeneration, !Task.isCancelled else { return }
                message = "\(title)完成"
            }
            catch { if generation == operationGeneration { self.error = error.localizedDescription } }
        }
    }
    func saveRoutingRule(_ draft: RoutingRuleDraft) async throws {
        guard canMutate else { throw CoreService.CoreError.message("服务尚未就绪或已有操作正在进行，请稍后重试。") }
        busy = "保存分流规则"; error = nil; message = nil
        defer { busy = nil }
        _ = try await core.requestValue(draft.original == nil ? "routing:add-rule" : "routing:edit-rule", payload: draft.payload)
        try await refreshSnapshot()
        message = "分流规则已保存"
    }
    func connectOrVerify() {
        if canDisconnect { Task { try? await disconnectNow() }; return }
        guard canMutate else { return }
        if !running && selectedProxy != "DIRECT" && !providerNodes.contains(where: { $0.name == selectedProxy && $0.identityAmbiguous != true }) {
            page = .nodes; message = "请选择一个具体节点后连接 VPN。"; return
        }
        if connectionProtected { checkConnectivity() }
        else { action(running ? "断开 VPN" : "连接 VPN", channel: running ? "vpn:stop" : "vpn:start") }
    }
    func select(_ node: VPNNode) {
        if let identity = node.identityKey { action("切换出口", channel: "nodes:select-v2", payload: ["identityKey": identity]) }
        else if node.name == "DIRECT" { action("切换出口", channel: "nodes:select", payload: ["nodeName": node.name]) }
    }
    func toggleFavorite(_ node: VPNNode) {
        action("保存收藏", channel: "native:favorite", payload: ["name": node.name])
    }
    func saveGroups(_ groups: [NodeGroup]) { action("保存节点组", channel: "node-groups:save", payload: ["nodeGroups": Self.jsonObjects(groups)]) }
    func checkAllRisks() {
        guard canMutate, running, !riskBatchRunning else { return }
        let usable = providerNodes.filter { $0.identityAmbiguous != true }
        let skipped = providerNodes.count - usable.count
        guard !usable.isEmpty else { error = "没有可检测的订阅节点。"; return }
        riskBatchRunning = true; riskProgress = nil
        riskBatchNote = skipped > 0 ? "\(skipped) 个同名冲突节点无法区分出口，已跳过。" : nil
        Task {
            do {
                _ = try await core.requestValue("nodes:start-risk-batch", payload: ["nodeNames": usable.map(\.name), "forceRefresh": true])
            } catch { riskBatchRunning = false; self.error = error.localizedDescription }
        }
    }
    private func restoreRiskKey() async {
        do {
            if let saved = try await riskKeyVault.load(origin: riskKeyOrigin) {
                guard !Task.isCancelled, !terminating else { return }
                _ = try await core.requestValue("native:risk-key", payload: ["apiKey": saved.password])
                riskKeyConfigured = true
            }
        } catch { riskKeyMessage = error.localizedDescription }
    }
    func saveRiskKey(_ value: String) async -> Bool {
        guard !terminating else { return false }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty && key.count <= 512 && !riskBatchRunning else { riskKeyMessage = "请输入有效的 ipdata 密钥，检测期间不能修改。"; return false }
        do {
            try await riskKeyVault.save(CompanyCredentials(origin: riskKeyOrigin, domain: "api-key", username: "ipdata", password: key))
            guard !terminating else { return false }
            _ = try await core.requestValue("native:risk-key", payload: ["apiKey": key])
            if !(status?.settings.vpnDomainRules ?? []).contains(where: { rule in
                let normalized = rule.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized == "domain-suffix,ipdata.co" || normalized == "domain,api.ipdata.co" || normalized == "domain-suffix,api.ipdata.co"
            }) {
                _ = try await core.requestValue("routing:add-rule", payload: ["rule": "DOMAIN-SUFFIX,ipdata.co"])
                await refresh()
            }
            riskKeyConfigured = true; riskKeyMessage = "原生版风险密钥已保存到钥匙串。"; return true
        } catch { riskKeyMessage = error.localizedDescription; return false }
    }
    func clearRiskKey() async -> Bool {
        guard !terminating, !riskBatchRunning else { return false }
        do {
            try await riskKeyVault.remove(origin: riskKeyOrigin)
            guard !terminating else { return false }
            _ = try await core.requestValue("native:risk-key", payload: ["apiKey": ""])
            riskKeyConfigured = false; riskKeyMessage = "已移除原生版风险密钥，原版设置保留。"; return true
        } catch { riskKeyMessage = error.localizedDescription; return false }
    }
    func cancelRiskBatch() {
        guard !terminating else { return }
        Task { do { _ = try await core.requestValue("nodes:cancel-risk-batch") } catch { self.error = error.localizedDescription } }
    }
    func checkConnectivity() {
        guard busy == nil, !terminating, diagnostics?.connectivity.running != true else { return }
        busy = "检测连通性"; error = nil
        let generation = operationGeneration
        operation = Task {
            defer { if generation == operationGeneration { busy = nil } }
            do {
                let result: ConnectivityCheck = try await core.request("connectivity:check")
                guard generation == operationGeneration, !Task.isCancelled else { return }
                connectivity = result; await refresh()
            } catch { if generation == operationGeneration { self.error = error.localizedDescription } }
        }
    }
    func testWebsites() {
        guard busy == nil, !terminating, diagnostics?.websites.running != true else { return }
        busy = "检测站点"; error = nil
        let generation = operationGeneration
        operation = Task {
            defer { if generation == operationGeneration { busy = nil } }
            do {
                let result: WebsiteTests = try await core.request("connectivity:test-website-speeds")
                guard generation == operationGeneration, !Task.isCancelled else { return }
                websites = result
            } catch { if generation == operationGeneration { self.error = error.localizedDescription } }
        }
    }
    /// Menu and popover requests re-read the actual state before choosing an action.
    func toggleConnection() async throws {
        if canDisconnect { try await disconnectNow(); return }
        guard !terminating, busy == nil else { return }
        busy = "读取连接状态"; error = nil; message = nil
        connectionOperation = running ? .disconnecting : .connecting
        let generation = operationGeneration
        defer { if generation == operationGeneration { busy = nil; connectionOperation = nil } }
        do {
            try await refreshSnapshot()
            guard generation == operationGeneration, !Task.isCancelled else { return }
            guard !terminating, !previewOnly else { return }
            guard !connectionProtected else { throw CoreService.CoreError.message("当前连接由原版维护，请在原版控制连接。") }
            guard status?.mihomo.mode != "subscription-probe" else { throw CoreService.CoreError.message("订阅检测进行中，请等待检测结束。") }
            if !running && selectedProxy != "DIRECT" && !providerNodes.contains(where: { $0.name == selectedProxy && $0.identityAmbiguous != true }) {
                page = .nodes
                throw CoreService.CoreError.message("请选择一个具体节点后连接 VPN。")
            }
            connectionOperation = running ? .disconnecting : .connecting
            busy = running ? "断开 VPN" : "连接 VPN"
            let result = try await core.requestValue(running ? "vpn:stop" : "vpn:start")
            guard generation == operationGeneration, !Task.isCancelled else { return }
            if case .object(let fields) = result, case .bool(false) = fields["controllerOk"] {
                throw CoreService.CoreError.message("内核连接验证失败。")
            }
            try await refreshSnapshot()
            guard generation == operationGeneration, !Task.isCancelled else { return }
            message = running ? "VPN 已连接。" : "VPN 已断开。"
        } catch {
            guard generation == operationGeneration else { return }
            self.error = error.localizedDescription
            if case .unavailable = core.availability { statusKnown = false }
            throw error
        }
    }
    func beginTermination() {
        terminating = true
        networkChanges?.stop(); networkChanges = nil
        activityChanges?.stop(); activityChanges = nil
        startup?.cancel(); polling?.cancel()
    }
    func waitForOperations() async {
        await startup?.value
        guard !Task.isCancelled else { return }
        await operation?.value
        guard !Task.isCancelled else { return }
        await core.waitForPendingRequests()
    }
    func disconnectForTermination() async throws {
        try await refreshSnapshot(timeout: .seconds(45))
        guard !previewOnly else { return }
        if connectionProtected { return }
        connectionOperation = .disconnecting
        defer { connectionOperation = nil }
        // Also clears a core's pending automatic reconnect when no engine is running.
        let stopped: CoreStatus = try await core.request("vpn:stop", timeout: .seconds(45))
        guard stopped.state == "stopped", stopped.pid == nil else {
            throw CoreService.CoreError.message("VPN 断开尚未确认，应用继续运行。")
        }
        status?.mihomo = stopped; statusKnown = true
    }
    func resumeAfterTerminationFailure() {
        terminating = false
        startNetworkChanges()
        startActivityChanges()
        startPolling()
    }
    private func startPolling() {
        let interval = started && !terminating && core.availability != .closed
            ? activity.pollingInterval(statusKnown: statusKnown, running: running) : nil
        guard interval != pollingInterval || (interval != nil && polling == nil) else { return }
        polling?.cancel(); polling = nil; pollingInterval = interval
        guard let interval else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval, tolerance: .milliseconds(500)) }
                catch { return }
                guard let self, !Task.isCancelled else { return }
                if self.busy == nil {
                    if self.statusKnown { await self.refreshTraffic() }
                    else { await self.refresh() }
                }
            }
        }
    }
    func close() {
        started = false
        networkChanges?.stop(); networkChanges = nil
        activityChanges?.stop(); activityChanges = nil
        startup?.cancel(); polling?.cancel(); polling = nil; pollingInterval = nil
        core.close()
    }
    static func jsonObjects<T: Encodable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value), let result = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return result
    }
}
