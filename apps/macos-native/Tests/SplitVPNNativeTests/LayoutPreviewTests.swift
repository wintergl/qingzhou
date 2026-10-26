import AppKit
import SwiftUI
import XCTest
@testable import SplitVPNNative

final class LayoutPreviewTests: XCTestCase {
    @MainActor func testRenderPagesAndControlsWithoutNetworkServices() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let suite = "splitvpn-layout-fixture-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let destination = ProcessInfo.processInfo.environment["SPLITVPN_LAYOUT_OUTPUT"]
        guard let destination else { return }
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        let stamp = "2026-10-08T14:00:00Z"
        let emptyRoute = CompanyRoutingState(active: false, verified: false, recovering: false, recoveryCount: 0, proxyName: nil, ruleCount: 0, routes: [], lastError: nil, proof: nil, internet: nil)
        let status = VPNStatus(appStartedAt: stamp, mihomo: CoreStatus(state: "running", mode: "vpn", pid: 0, startedAt: stamp, lastError: nil),
            subscription: SubscriptionRecord(nodeCount: 117, status: "ready", updatedAt: stamp, entries: []),
            settings: VPNSettings(launchAtLogin: false, unknownTraffic: "direct", tun: true, ipv6: false, lanDirect: true, tailscaleDirect: true,
                specialCompatibilityRules: CompatibilityRules(mailMasterProxy8081: false, wechatImageSendFallback: false), selectedProxy: "日本 东京 · 示例节点", vpnDomainRules: ["DOMAIN-SUFFIX,example.test", "IP-CIDR,203.0.113.8/32"], favoriteNodeNames: ["示例节点"], nodeGroups: [], directDomainRules: ["DOMAIN,api.example.test", "IP-CIDR,192.0.2.0/24"]))
        var nodes = [VPNNode(name: "日本 东京 · 示例节点", type: "ss", selected: true, delay: 35, available: true, identityKey: "fixture-jp", subscriptionId: "fixture-sub", subscriptionName: "示例订阅", identityAmbiguous: false, location: NodeLocation(country: "日本", city: "东京", source: "name-recognized")),
                     VPNNode(name: "美国 洛杉矶 · 示例节点", type: "trojan", selected: false, delay: 150, available: true, identityKey: "fixture-us", subscriptionId: "fixture-sub", subscriptionName: "示例订阅", identityAmbiguous: false, location: NodeLocation(country: "美国", city: "洛杉矶", source: "name-recognized"))]
        let fresh = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-92))
        let later = ISO8601DateFormatter().string(from: Date().addingTimeInterval(208))
        let siteNext = ISO8601DateFormatter().string(from: Date().addingTimeInterval(808))
        nodes[0].latencyStatus = "available"; nodes[0].latencyCheckedAt = fresh; nodes[0].latencySource = "engine"
        nodes[1].latencyStatus = "available"; nodes[1].latencyCheckedAt = fresh; nodes[1].latencySource = "manual"
        for (i, name, state, delay) in [
            (2, "新加坡 · 滨海", "available", 128.0),
            (3, "美国 洛杉矶 · 西海岸", "timeout", 0.0),
            (4, "美国 洛杉矶 · 太平洋", "failed", 0.0),
            (5, "日本 大阪 · 备用线路", "stale", 76.0),
            (6, "德国 法兰克福 · 示例节点", "untested", 0.0),
            (7, "英国 伦敦 · 示例节点", "testing", 0.0)
        ] {
            var node = nodes[0]; node.name = name; node.identityKey = "fixture-\(i)"; node.selected = false
            node.latencyStatus = state; node.delay = delay > 0 ? delay : nil
            node.available = state == "available" ? true : state == "timeout" || state == "failed" ? false : nil
            node.latencyCheckedAt = state == "untested" || state == "testing" ? nil : fresh
            node.latencyFailure = state == "timeout" ? "timeout" : nil
            node.location = nil; nodes.append(node)
        }
        let risks = [NodeRisk(nodeName: nodes[0].name, ip: "203.0.113.1", riskLevel: "low", reasons: ["fixture"], checkedAt: stamp),
                     NodeRisk(nodeName: nodes[1].name, ip: "203.0.113.2", riskLevel: "medium", reasons: ["fixture"], checkedAt: stamp)]
        let group = NodeGroup(id: "fixture-group", name: "常用节点", nodeNames: nodes.map(\.name), members: nodes.map { NodeMember(identityKey: $0.identityKey, lastKnownName: $0.name) }, strategy: "manual")
        let members = nodes.map { GroupMemberState(identityKey: $0.identityKey, lastKnownName: $0.name, issue: nil, available: $0.available, delay: $0.delay, current: $0.selected) }
        let groupState = NodeGroupState(group: group, runtimeName: "fixture-group", selected: false, applied: false, currentMember: nil, members: members, availableCount: 2, failedCount: 0, untestedCount: 0)
        var populatedStatus = status
        populatedStatus.subscription.entries = [
            Subscription(id: "fixture-sub", name: "日常线路", url: "https://subscription.example.test/fixture", enabled: true, updatedAt: fresh, nodeCount: 85, status: "ready", updateIntervalMinutes: 60),
            Subscription(id: "fixture-backup", name: "备用线路", url: "https://backup.example.test/fixture", enabled: false, updatedAt: stamp, nodeCount: 32, status: "ready")
        ]
        let samples = (0..<90).map { i in TrafficSample(upload: (sin(Double(i) * 0.18) + 1.3) * 18000, download: (sin(Double(i) * 0.12) + 1.6) * 380000, sampledAt: fresh) }
        let previewTraffic = TrafficMonitor(snapshot: TrafficSnapshot(uploadTotal: 124000000, downloadTotal: 2450000000, connectionCount: 3,
            connections: [TrafficConnection(id: "fixture-connection", host: "example.test", network: "tcp", type: "TUN", rule: "DomainSuffix", rulePayload: "example.test", chains: ["日本 东京 · 示例节点"], upload: 24500, download: 1260000, process: "Safari", destination: "203.0.113.8")]),
            rates: TrafficRate(upload: 24000, download: 850000), samples: samples, running: true)
        var snapshot = Bootstrap(status: populatedStatus, nodes: nodes, groups: [groupState], risks: risks, traffic: previewTraffic, legacyOwnerRunning: false, previewOnly: true, ownsRuntime: false, companyRouting: emptyRoute, dataDir: "/fixture-only")
        let schedule = #"""
        {"automatic":true,"pausedReason":null,"connectivity":{"state":"ready","source":"automatic","checkedAt":"\#(fresh)","nextCheckAt":"\#(later)","intervalSeconds":300,"result":{"connectivity":{"domesticOk":true,"foreignOk":true,"externalIp":"203.0.113.8","latency":{"domesticMs":18,"foreignMs":183},"proxyOk":true}}},"websites":{"state":"ready","source":"automatic","checkedAt":"\#(fresh)","nextCheckAt":"\#(siteNext)","intervalSeconds":900,"result":{"proxyName":"日本 东京 · 示例节点","results":[{"id":"google","label":"Google","url":"https://www.google.com/generate_204","delay":183,"ok":true},{"id":"chatgpt","label":"ChatGPT","url":"https://chatgpt.com/cdn-cgi/trace","delay":null,"ok":false,"httpStatus":403,"failureReason":"restricted"},{"id":"claude","label":"Claude","url":"https://claude.ai","delay":612,"ok":true}]}}}
        """#
        snapshot.diagnostics = try JSONDecoder().decode(DiagnosticSchedule.self, from: Data(schedule.utf8))
        let vpn = VPNStore(preview: snapshot)
        // Use a fake transport for enabled control states; no production core,
        // account, keychain or networking service is started by this preview.
        let fake = MenuCoreModel()
        var interactive = try XCTUnwrap(JSONSerialization.jsonObject(with: fake.bootstrap().encoded) as? [String: Any])
        interactive["nodes"] = nodes.map { node in
            var row: [String: Any] = ["name": node.name, "type": node.type, "selected": node.selected, "subscriptionId": "fixture-sub", "subscriptionName": "示例订阅"]
            if let value = node.identityKey { row["identityKey"] = value }
            if let value = node.available { row["available"] = value }
            if let value = node.delay { row["delay"] = value }
            if let value = node.latencyStatus { row["latencyStatus"] = value }
            if let value = node.latencyCheckedAt { row["latencyCheckedAt"] = value }
            if let value = node.latencySource { row["latencySource"] = value }
            if let value = node.latencyFailure { row["latencyFailure"] = value }
            if let location = node.location { row["location"] = ["country":location.country ?? "", "city":location.city ?? "", "source":"name-recognized"] }
            return row
        }
        interactive["risks"] = risks.map { ["nodeName":$0.nodeName,"riskLevel":$0.riskLevel,"ip":"203.0.113.1","reasons":$0.reasons,"checkedAt":fresh] as [String: Any] }
        var interactiveStatus = interactive["status"] as! [String: Any]
        interactiveStatus["mihomo"] = ["state": "running", "mode": "vpn"]
        var interactiveSettings = interactiveStatus["settings"] as! [String: Any]
        interactiveSettings["selectedProxy"] = nodes[0].name
        interactiveStatus["settings"] = interactiveSettings; interactive["status"] = interactiveStatus
        let interactivePayload = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: interactive))
        let nodeDesignStore = VPNStore(core: CoreService { _, _ in interactivePayload }, loginItems: PreviewLoginItemService(), riskKeyVault: FixtureVault())
        await nodeDesignStore.refresh()
        defer { nodeDesignStore.close() }
        func recoveryStore(_ payload: String) throws -> VPNStore {
            var sample = snapshot
            sample.status.mihomo.networkRecovery = try JSONDecoder().decode(NetworkRecoveryStatus.self, from: Data(payload.utf8))
            sample.status.mihomo.startedAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-8280))
            return VPNStore(preview: sample)
        }
        let recovering = try recoveryStore(#"{"state":"recovering","phase":"waiting-stable","attempts":0}"#)
        let restored = try recoveryStore(#"{"state":"ready","history":[{"id":1,"startedAt":"2026-10-13T12:00:00Z","finishedAt":"2026-10-13T12:00:05Z","durationMs":5000,"reason":"network-change","outcome":"verified","attempts":0}]}"#)
        let failedRecovery = try recoveryStore(#"{"state":"failed","attempts":3,"maxAttempts":3,"error":"测试：当前网络不可用","history":[{"id":2,"startedAt":"2026-10-13T12:00:00Z","finishedAt":"2026-10-13T12:00:15Z","durationMs":15000,"reason":"network-change","outcome":"failed","attempts":3}]}"#)
        let pendingLogin = VPNStore(preview: snapshot, loginItems: PreviewLoginItemService())
        let enabledLogin = VPNStore(preview: snapshot, loginItems: PreviewLoginItemService(current: .enabled))
        let legacyLogin = VPNStore(preview: snapshot, loginItems: PreviewLoginItemService(current: .needsRepair))
        let pageFilter = ProcessInfo.processInfo.environment["SPLITVPN_LAYOUT_PAGES"]?.split(separator: ",").map(String.init)
        let probe = ProbeInfo(origin: "https://vpn.example.invalid", fingerprint: String(repeating: "AB:", count: 31) + "AB", subject: "示例接入网关", validTo: "2099-01-01T00:00:00Z", nameMatches: true, selfSigned: false, methods: [AuthMethod(loginDomain: "local", authType: "auth/psw", authName: "接入账号")])
        let loggedOut = CompanyStore(credentialVault: FixtureVault(), preferences: defaults, preview: CompanyPreview(probe: probe))
        let passwordChange = CompanyStore(credentialVault: FixtureVault(), preferences: defaults, helper: MenuHelper(), preview: CompanyPreview(probe: probe))
        passwordChange.receive(try JSONDecoder().decode(HelperEvent.self, from: Data(#"{"type":"error","stage":"login","code":"password_change_required"}"#.utf8)))
        let firstCertificate = CompanyStore(credentialVault: FixtureVault(), preferences: defaults, preview: CompanyPreview(probe: probe))
        firstCertificate.acceptProbe(probe)
        let rows = (1...25).map { ResourceRow(id: String($0), appID: String($0), name: "授权应用 \($0)", address: "192.0.2.\($0)", ports: "80,443", network: "tcp", accessModel: "vpn") }
        let proof = TunnelProof(port: 10000, target: "192.0.2.55", httpStatus: 200, elapsedMs: 35, sent: 128, received: 1024, verifiedAt: stamp, transport: "atrust-tcp")
        let systemProof = SystemBusinessProof(target: "192.0.2.55", httpStatus: 200, elapsedMs: 40, interfaceName: "fixture", sourcePort: 10001, chains: ["fixture"], corePid: 0, verifiedAt: stamp)
        let route = CompanyRoutingState(active: true, verified: true, recovering: false, recoveryCount: 0, proxyName: "fixture", ruleCount: 25, routes: ["192.0.2.0/24"], lastError: nil, proof: systemProof, internet: nil)
        let connected = CompanyStore(credentialVault: FixtureVault(), preferences: defaults, preview: CompanyPreview(probe: probe, resources: ResourceResult(rows: rows, appCount: 25, dns: [], gateways: [], fetchedAt: stamp), tunnel: proof, routing: route))
        let unverifiedRoute = CompanyRoutingState(active: true, verified: false, recovering: false, recoveryCount: 0, proxyName: "fixture", ruleCount: 25, routes: ["192.0.2.0/24"], lastError: nil, proof: nil, internet: nil)
        let ready = TunnelProof(port: 10000, target: "", httpStatus: 0, elapsedMs: 0, sent: 0, received: 0, verifiedAt: "", transport: "atrust-tcp")
        let unverified = CompanyStore(credentialVault: FixtureVault(), preferences: defaults, preview: CompanyPreview(probe: probe, resources: ResourceResult(rows: rows, appCount: 25, dns: [], gateways: [], fetchedAt: stamp), tunnel: ready, routing: unverifiedRoute))
        var subscriptionDraft = SubscriptionDraft()
        subscriptionDraft.name = "示例订阅"
        subscriptionDraft.url = "https://subscription.example.invalid/link/fixture"
        let challenge = AuthChallenge(id: "fixture-sms", kind: "sms", title: "私有网络认证", message: "输入本次验证码，完成接入账号登录。", imageBase64: nil, url: nil)
        let passwordChallenge = AuthChallenge(id: "fixture-password", kind: "password_change", title: "修改接入密码",
            message: "接入密码已到期，请修改后继续本次登录。修改后，其他已在线终端可能需要重新登录。", imageBase64: nil, url: nil,
            username: "测试账号", rules: ["密码至少 12 位。", "需同时包含大写和小写字母。", "需包含数字。", "需包含特殊字符。", "不能与最近 5 次使用的密码重复。"])
        var passwordRetry = passwordChallenge
        passwordRetry.errorMessage = "接入服务返回错误 75500405：新密码不能属于弱密码库，请重新填写。"
        passwordRetry.requireUsername = true
        var directDraft = RoutingRuleDraft(); directDraft.outlet = .direct; directDraft.address = "192.0.2.0/24"
        var vpnDraft = RoutingRuleDraft(); vpnDraft.address = "https://example.test/path"
        nodeDesignStore.page = .nodes
        for (name, view) in [("overview-recovering", AnyView(OverviewView(store: recovering, company: connected))),
                              ("overview-restored", AnyView(OverviewView(store: restored, company: connected))),
                              ("overview-recovery-failed", AnyView(OverviewView(store: failedRecovery, company: connected))),
                              ("diagnostics-recovery", AnyView(DiagnosticsView(store: restored))),
                              ("overview", AnyView(OverviewView(store: vpn, company: connected))),
                              ("overview-company-connected", AnyView(OverviewView(store: vpn, company: unverified))),
                              ("company-login", AnyView(CompanyView(store: loggedOut, vpn: vpn, initializeOnAppear: false))),
                              ("company-password-change", AnyView(CompanyView(store: passwordChange, vpn: vpn, initializeOnAppear: false))),
                              ("company-password-change-sheet", AnyView(CompanyPasswordChangeSheet(challenge: passwordChallenge, onSubmit: { _ in }, onCancel: {}).frame(maxWidth: .infinity, maxHeight: .infinity))),
                              ("company-password-change-retry", AnyView(CompanyPasswordChangeSheet(challenge: passwordRetry, onSubmit: { _ in }, onCancel: {}).frame(maxWidth: .infinity, maxHeight: .infinity))),
                              ("company-first-certificate", AnyView(CompanyView(store: firstCertificate, vpn: vpn, initializeOnAppear: false))),
                              ("company-connected", AnyView(CompanyView(store: connected, vpn: vpn, initializeOnAppear: false))),
                              ("company-verification", AnyView(CompanyVerificationSheet(store: connected, verifyOnAppear: false).frame(maxWidth: .infinity, maxHeight: .infinity))),
                              ("node-groups", AnyView(NodeGroupsView(store: vpn))),
                              ("nodes", AnyView(NodesView(store: nodeDesignStore))),
                              ("nodes-selected", AnyView(NodesView(store: nodeDesignStore, initialSelection: [nodes[3].id]))),
                              ("nodes-bottom", AnyView(NodesView(store: nodeDesignStore))),
                              ("shell-overview", AnyView(ContentView(store: vpn, company: connected))),
                              ("shell-nodes", AnyView(ContentView(store: nodeDesignStore, company: loggedOut))),
                              ("traffic", AnyView(TrafficView(store: vpn))),
                              ("logs", AnyView(LogsView(store: vpn, initializeOnAppear: false))),
                              ("subscriptions", AnyView(SubscriptionsView(store: vpn))),
                              ("subscription-editor", AnyView(SubscriptionEditor(draft: subscriptionDraft) { _, _, _ in }.frame(maxWidth: .infinity, maxHeight: .infinity))),
                              ("group-editor", AnyView(GroupEditor(group: group, nodes: nodes) { _ in }.frame(maxWidth: .infinity, maxHeight: .infinity))),
                              ("routing", AnyView(RoutingView(store: vpn))),
                              ("routing-editor-vpn", AnyView(RoutingRuleEditor(store: vpn, draft: vpnDraft, normalized: NormalizedRoutingRule(rule: "DOMAIN-SUFFIX,example.test", kind: "DOMAIN-SUFFIX", value: "example.test")).frame(maxWidth: .infinity, maxHeight: .infinity))),
                              ("routing-editor-direct", AnyView(RoutingRuleEditor(store: vpn, draft: directDraft, normalized: NormalizedRoutingRule(rule: "IP-CIDR,192.0.2.0/24", kind: "IP-CIDR", value: "192.0.2.0/24")).frame(maxWidth: .infinity, maxHeight: .infinity))),
                              ("settings", AnyView(SettingsView(store: vpn).frame(maxWidth: .infinity, maxHeight: .infinity))),
                              ("settings-login-approval", AnyView(SettingsView(store: pendingLogin).frame(maxWidth: .infinity, maxHeight: .infinity))),
                              ("settings-login-enabled", AnyView(SettingsView(store: enabledLogin).frame(maxWidth: .infinity, maxHeight: .infinity))),
                              ("settings-login-repair", AnyView(SettingsView(store: legacyLogin).frame(maxWidth: .infinity, maxHeight: .infinity))),
                              ("company-challenge", AnyView(ChallengeSheet(challenge: challenge, onSubmit: { _ in }, onCancel: {}).frame(maxWidth: .infinity, maxHeight: .infinity))),
                              ("button-states", AnyView(ButtonStylesPreview())),
                              ("diagnostics-network", AnyView(DiagnosticsView(store: vpn))),
                              ("diagnostics-risk", AnyView(DiagnosticsView(store: vpn, section: "节点风险"))),
                              ("diagnostics-subscription", AnyView(DiagnosticsView(store: vpn, section: "订阅探测")))] {
            if let pageFilter, !pageFilter.contains(name) { continue }
            let sizes = name.hasPrefix("shell-") ? [NSSize(width: 1120, height: 760), NSSize(width: 1440, height: 960)] : [NSSize(width: 840, height: 640), NSSize(width: 1040, height: 780)]
            for size in sizes {
              for scheme in [ColorScheme.light, .dark] {
                defaults.set(scheme == .dark ? "dark" : "light", forKey: "previewAppearance")
                let hosting = NSHostingView(rootView: view.background(VPNTheme.background).tint(VPNTheme.accent).foregroundStyle(VPNTheme.text).font(.system(size: 13)).controlSize(.regular).buttonStyle(VPNButtonStyle()).defaultAppStorage(defaults).preferredColorScheme(scheme))
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.isReleasedWhenClosed = false; window.contentView = hosting
                hosting.frame = NSRect(origin: .zero, size: size)
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 150_000_000)
                if name == "nodes-bottom" {
                    func tables(_ view: NSView) -> [NSTableView] {
                        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables($0) }
                    }
                    for table in tables(hosting) { if table.numberOfRows > 0 { table.scrollRowToVisible(table.numberOfRows - 1) } }
                    hosting.layoutSubtreeIfNeeded()
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                if name.hasPrefix("settings") {
                    func scrollViews(_ view: NSView) -> [NSScrollView] {
                        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews($0) }
                    }
                    let scrolls = scrollViews(hosting)
                    XCTAssertFalse(scrolls.isEmpty, "设置页应能滚动至启动区域。")
                    for scroll in scrolls {
                        if let document = scroll.documentView {
                            let y = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
                            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                            scroll.reflectScrolledClipView(scroll.contentView)
                        }
                    }
                    hosting.layoutSubtreeIfNeeded()
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: destination).appendingPathComponent("\(name)-\(Int(size.width))-\(scheme == .dark ? "dark" : "light").png"))
                XCTAssertEqual(hosting.bounds.size, size)
                window.close()
              }
            }
        }
        XCTAssertTrue(vpn.previewOnly)
        XCTAssertFalse(loggedOut.working)
        XCTAssertEqual(connected.resources?.rows.count, 25)
        XCTAssertEqual(unverified.statusText, "私有网络已连接")
    }
}

@MainActor private final class PreviewLoginItemService: LoginItemService {
    let current: LoginItemState
    init(current: LoginItemState = .requiresApproval) { self.current = current }
    func state() -> LoginItemState { current }
    func setEnabled(_ enabled: Bool) throws -> LoginItemState { .requiresApproval }
    func openSystemSettings() {}
}

private struct ButtonStylesPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "按钮样式检查", subtitle: "启用、停用和弹窗操作；所有操作均为空，不连接网络")
            ForEach([false, true], id: \.self) { disabled in
                VStack(alignment: .leading, spacing: 12) {
                    Text(disabled ? "不可用" : "可用").foregroundStyle(VPNTheme.secondary)
                    HStack {
                        Button("设为当前出口") {}.buttonStyle(VPNButtonStyle(prominent: true))
                        Button("测速选中节点") {}
                        Button("测速当前列表") {}
                        Menu("更多检测") { Button("推荐多站点测速") {} }
                    }.disabled(disabled)
                }
            }
            HStack {
                Button("取消") {}.keyboardShortcut(.cancelAction)
                Button("保存") {}.buttonStyle(VPNButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                Spacer()
                Button("删除", role: .destructive) {}
                Button("断开 VPN") {}.buttonStyle(VPNButtonStyle(prominent: true, destructive: true))
            }
            Spacer()
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
