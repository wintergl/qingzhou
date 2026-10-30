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
        {"automatic":true,"pausedReason":null,"connectivity":{"state":"ready","source":"automatic","checkedAt":"\#(fresh)","nextCheckAt":"\#(later)","intervalSeconds":300,"result":{"connectivity":{"domesticOk":true,"foreignOk":false,"externalIp":"203.0.113.8","latency":{"domesticMs":18,"foreignMs":183},"proxyOk":true,"systemDns":{"ok":true},"chatgpt":{"ok":false,"httpStatus":403,"failureReason":"restricted"}}}},"websites":{"state":"ready","source":"automatic","checkedAt":"\#(fresh)","nextCheckAt":"\#(siteNext)","intervalSeconds":900,"result":{"proxyName":"日本 东京 · 示例节点","results":[{"id":"google","label":"Google","url":"https://www.google.com/generate_204","delay":183,"ok":true},{"id":"chatgpt","label":"ChatGPT","url":"https://chatgpt.com/cdn-cgi/trace","delay":null,"ok":false,"httpStatus":403,"failureReason":"restricted"},{"id":"claude","label":"Claude","url":"https://claude.ai","delay":612,"ok":true}]}}}
        """#
        snapshot.diagnostics = try JSONDecoder().decode(DiagnosticSchedule.self, from: Data(schedule.utf8))
        snapshot.diagnostics?.websites.intervalSeconds = 900
        var currentRisk = risks[0]
        currentRisk.ip = "203.0.113.8"; currentRisk.checkedAt = fresh
        currentRisk.scope = "current-exit"; currentRisk.viaStaticExit = false
        snapshot.currentExitRisk = currentRisk
        let vpn = VPNStore(preview: snapshot)
        var updatingSnapshot = snapshot
        updatingSnapshot.diagnostics?.connectivity.state = "running"
        updatingSnapshot.diagnostics?.connectivity.startedAt = fresh
        updatingSnapshot.diagnostics?.connectivity.staleResult = true
        updatingSnapshot.diagnostics?.websites.state = "running"
        updatingSnapshot.diagnostics?.websites.startedAt = fresh
        updatingSnapshot.diagnostics?.websites.staleResult = true
        let updatingDiagnostics = VPNStore(preview: updatingSnapshot)
        var failedSnapshot = snapshot
        failedSnapshot.diagnostics?.connectivity.state = "error"
        failedSnapshot.diagnostics?.connectivity.result = nil
        failedSnapshot.diagnostics?.connectivity.error = "连接检测未完成，请检查网络后重试。"
        failedSnapshot.diagnostics?.websites.state = "error"
        failedSnapshot.diagnostics?.websites.result = nil
        failedSnapshot.diagnostics?.websites.error = "站点检测未完成，请检查当前出口后重试。"
        let failedDiagnostics = VPNStore(preview: failedSnapshot)
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
        let nodeDesignStore = VPNStore(core: CoreService { channel, _ in
            if channel == "nodes:list", case .object(let fields) = interactivePayload { return fields["nodes"] ?? .array([]) }
            return interactivePayload
        }, loginItems: PreviewLoginItemService(), riskKeyVault: FixtureVault())
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
        var chainPreview = ChainScanState(id: "fixture-scan", completed: 2, total: 2,
            results: [ChainScanRow(identityKey: "fixture-fast", nodeName: "日本 东京 · 示例机场", status: "available", latencyMs: 180, jitterMs: 22, downloadMbps: 16.82, latencySuccesses: 3, latencyAttempts: 3, downloadSuccesses: 2, downloadAttempts: 2, exitIp: "203.0.113.8", errors: [], balancedScore: 53.80675891),
                      ChainScanRow(identityKey: "fixture-slow", nodeName: "美国 西部 · 示例机场", status: "unstable", latencyMs: 350, jitterMs: 90, downloadMbps: 4.1, latencySuccesses: 2, latencyAttempts: 3, downloadSuccesses: 2, downloadAttempts: 2, exitIp: "203.0.113.8", errors: ["latency-failed"])], stale: false, recommendedIdentityKey: "fixture-fast", recommendationSummary: "本轮完整通过测试的链路中，这条综合表现排名第一，兼顾下载、响应与波动。")
        chainPreview.results[0].rank = 1; chainPreview.results[0].testedAt = fresh
        chainPreview.results[0].requiresRefresh = false
        chainPreview.results[1].testedAt = fresh; chainPreview.results[1].requiresRefresh = false
        chainPreview.leaders = ChainLeaders(balanced: "fixture-fast", download: "fixture-fast", latency: "fixture-fast")
        var comparisonPreview = chainPreview
        comparisonPreview.results = [
            ChainScanRow(identityKey: "fixture-jp", nodeName: "日本 东京 · 均衡线路", status: "available", latencyMs: 96, jitterMs: 8, downloadMbps: 48.6, latencySuccesses: 3, latencyAttempts: 3, downloadSuccesses: 2, downloadAttempts: 2, exitIp: "203.0.113.8", errors: [], balancedScore: 68.2, testedAt: fresh, requiresRefresh: false, rank: 1),
            ChainScanRow(identityKey: "fixture-us", nodeName: "美国 洛杉矶 · 高速下载", status: "available", latencyMs: 225, jitterMs: 25, downloadMbps: 92.4, latencySuccesses: 3, latencyAttempts: 3, downloadSuccesses: 2, downloadAttempts: 2, exitIp: "203.0.113.8", errors: [], balancedScore: 57.8, testedAt: fresh, requiresRefresh: false, rank: 2),
            ChainScanRow(identityKey: "compare-sg", nodeName: "新加坡 · 低延迟线路", status: "available", latencyMs: 42, jitterMs: 4, downloadMbps: 8.5, latencySuccesses: 3, latencyAttempts: 3, downloadSuccesses: 2, downloadAttempts: 2, exitIp: "203.0.113.8", errors: [], balancedScore: 56.1, testedAt: fresh, requiresRefresh: false, rank: 3),
            ChainScanRow(identityKey: "compare-old", nodeName: "香港 · 上次测量", status: "available", latencyMs: 35, jitterMs: 4, downloadMbps: 120, latencySuccesses: 3, latencyAttempts: 3, downloadSuccesses: 2, downloadAttempts: 2, exitIp: "203.0.113.8", errors: [], balancedScore: 84.3, testedAt: "2026-10-20T10:00:00Z", requiresRefresh: true, rank: 4),
            ChainScanRow(identityKey: "compare-failed", nodeName: "韩国 · 出口未通过", status: "unstable", latencyMs: 70, jitterMs: 15, downloadMbps: 34, latencySuccesses: 3, latencyAttempts: 3, downloadSuccesses: 2, downloadAttempts: 2, exitIp: nil, errors: ["exit-ip-failed"], testedAt: fresh, requiresRefresh: false)
        ]
        comparisonPreview.completed = 5; comparisonPreview.total = 8
        comparisonPreview.recommendedIdentityKey = "fixture-jp"
        comparisonPreview.leaders = ChainLeaders(balanced: "fixture-jp", download: "fixture-us", latency: "compare-sg")
        comparisonPreview.canUseCachedResults = true; comparisonPreview.stopReason = "completed"
        var failedComparison = comparisonPreview
        failedComparison.results = [comparisonPreview.results[4]]
        failedComparison.recommendedIdentityKey = nil; failedComparison.leaders = ChainLeaders()
        let emptyComparison = ChainScanState()
        var ispSnapshot = snapshot
        ispSnapshot.status.settings.staticExit = StaticExitConfiguration(enabled: true, protocol: "socks5", server: "proxy.example.test", port: 1080, username: "fixture", expectedIp: "203.0.113.8")
        ispSnapshot.chainScan = ChainScanActivity(running: true, mode: "continuous", testing: false, completed: 7, total: 8)
        let ispHome = VPNStore(preview: ispSnapshot)
        var ispOffSnapshot = ispSnapshot
        ispOffSnapshot.status.settings.staticExit?.enabled = false
        let ispOffHome = VPNStore(preview: ispOffSnapshot)
        func workflowStore(running: Bool, enabled: Bool, usePhase: String? = nil) async throws -> VPNStore {
            var payload = interactive
            var payloadStatus = payload["status"] as! [String: Any]
            var settings = payloadStatus["settings"] as! [String: Any]
            var exit = ispSnapshot.status.settings.staticExit!.payload; exit["enabled"] = enabled
            settings["staticExit"] = exit
            settings["selectedProxy"] = comparisonPreview.results[0].nodeName
            payloadStatus["settings"] = settings
            payloadStatus["mihomo"] = ["state": usePhase == "recovery" ? "error" : running ? "running" : "stopped", "mode": "vpn"]
            payload["status"] = payloadStatus
            var inventory = payload["nodes"] as! [[String: Any]]
            for row in comparisonPreview.results {
                if let index = inventory.firstIndex(where: { $0["identityKey"] as? String == row.id }) { inventory[index]["name"] = row.nodeName }
                else { inventory.append(["name":row.nodeName,"type":"http","identityKey":row.id,"selected":false]) }
            }
            for index in inventory.indices where inventory[index]["identityKey"] != nil {
                inventory[index]["subscriptionId"] = inventory[index]["identityKey"] as? String == "fixture-jp" ? "fixture-other" : "fixture-subscription"
            }
            var subscriptions = payloadStatus["subscription"] as! [String: Any]
            subscriptions["entries"] = [["id":"fixture-subscription","name":"示例机场 A","url":"https://example.test/subscription","enabled":true,"nodeCount":inventory.count-1,"status":"ready"], ["id":"fixture-other","name":"示例机场 B","url":"https://example.test/other","enabled":true,"nodeCount":1,"status":"ready"]]
            payloadStatus["subscription"] = subscriptions; payload["status"] = payloadStatus
            payload["nodes"] = inventory
            payload["ownsRuntime"] = running
            let value = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: payload))
            var operationID = ""
            let store = VPNStore(core: CoreService { channel, request in
                if channel == "chain-scan:use", usePhase != nil {
                    operationID = request["operationId"] as! String
                    throw CoreService.CoreError.uncertain("模拟等待连接确认")
                }
                if channel == "chain-scan:use-state", let usePhase {
                    if usePhase == "unknown" { return .null }
                    return .object(["operationId":.string(operationID),"nodeName":.string(comparisonPreview.results[0].nodeName),"phase":.string(usePhase == "recovery" ? "failed" : usePhase),"finished":.bool(usePhase == "recovery"),"cancelRequested":.bool(false),"error":usePhase == "recovery" ? .string("原连接恢复尚未确认，恢复记录已保留。") : .null])
                }
                return value
            }, loginItems: PreviewLoginItemService(), riskKeyVault: FixtureVault())
            await store.refresh()
            if usePhase != nil { await store.useChainRoute(comparisonPreview.results[0], scanID:"preview", strategy:"balanced") }
            return store
        }
        let workflowOffline = try await workflowStore(running: false, enabled: false)
        let workflowReady = try await workflowStore(running: true, enabled: true)
        let useConfirming = try await workflowStore(running: true, enabled: true, usePhase: "confirming")
        let useUnknown = try await workflowStore(running: true, enabled: true, usePhase: "unknown")
        let useRecovery = try await workflowStore(running: true, enabled: true, usePhase: "recovery")
        defer { workflowOffline.close(); workflowReady.close(); useConfirming.close(); useUnknown.close(); useRecovery.close() }
        var subscriptionPreview = comparisonPreview
        var scopeRows = Array(comparisonPreview.results.dropFirst())
        for index in scopeRows.indices { if scopeRows[index].rank != nil { scopeRows[index].rank! -= 1 } }
        scopeRows[0].comparisonReason = "已测综合第一 · 相对当前线路：下载快 90% · 响应慢 129 ms · 波动更大 17 ms"
        scopeRows[1].comparisonReason = "相对当前线路：下载慢 83% · 响应快 54 ms · 波动更小 4 ms"
        subscriptionPreview.view = ChainScanScopeView(subscriptionId: "fixture-subscription", results: scopeRows,
            leaders: ChainLeaders(balanced: "fixture-us", download: "fixture-us", latency: "compare-sg"), recommendedIdentityKey: "fixture-us",
            recommendationSummary: "本订阅近期完整成绩中综合排名第一。", progress: ChainScanProgress(total: 10, completed: 4, remaining: 6))
        var progressPreview = subscriptionPreview
        progressPreview.running = true; progressPreview.mode = "accumulate"; progressPreview.testing = true
        progressPreview.view?.progress = ChainScanProgress(total: 10, completed: 4, remaining: 6, estimatedSeconds: 95,
            stage: "download", stageAttempt: 1, stageTotal: 2, currentNode: "美国 洛杉矶 · 高速下载")
        var progressWait = progressPreview
        progressWait.waitingReason = "network-unavailable"; progressWait.view?.progress?.estimatedSeconds = nil
        progressWait.view?.progress?.stage = nil; progressWait.view?.progress?.currentNode = nil
        var progressContinuous = progressPreview
        progressContinuous.mode = "continuous"; progressContinuous.testing = false
        progressContinuous.view?.progress = ChainScanProgress(total: 10, completed: 4, remaining: 6,
            nextTestAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(60)), earliestRetryAt: later)
        let autoConfiguration = ChainAutoRefreshState(enabled: true, intervalMinutes: 30, paused: false, status: "running")
        var autoPreview = progressContinuous
        autoPreview.automatic = true; autoPreview.autoRefresh = autoConfiguration
        var queuedPreview = comparisonPreview
        queuedPreview.running = true; queuedPreview.mode = "continuous"; queuedPreview.testing = false
        queuedPreview.queuedIdentityKeys = ["fixture-jp"]
        var inUsePreview = comparisonPreview; inUsePreview.connectedIdentityKey = "fixture-jp"
        var dailyPreview = comparisonPreview
        dailyPreview.results[0].testedAt = stamp; dailyPreview.results[0].requiresRefresh = true
        dailyPreview.results[0].connectionEligible = true
        dailyPreview.results[3].rank = 1; dailyPreview.results[0].rank = 2
        dailyPreview.results[1].rank = 3; dailyPreview.results[2].rank = 4
        dailyPreview.recommendedIdentityKey = "compare-old"
        dailyPreview.leaders = ChainLeaders(balanced: "compare-old", download: "compare-old", latency: "compare-old")
        dailyPreview.results = [dailyPreview.results[3], dailyPreview.results[0], dailyPreview.results[1], dailyPreview.results[2], dailyPreview.results[4]]
        dailyPreview.routine = ChainRoutineState(connectionState: "connected", currentSelectionConfirmed: true,
            currentIdentityKey: "fixture-jp", currentNodeName: "日本 东京 · 均衡线路",
            verification: ChainVerificationState(status: "passed", checkedAt: fresh), performanceTestedAt: stamp,
            maintenanceIdentityKeys: dailyPreview.results.map(\.id),
            backupIdentityKeys: dailyPreview.results.filter { $0.id != "fixture-jp" }.map(\.id))
        for index in dailyPreview.results.indices {
            dailyPreview.results[index].subscriptionName = ["fixture-us", "compare-sg"].contains(dailyPreview.results[index].id) ? "示例机场 A" : "示例机场 B"
            if dailyPreview.results[index].id == "compare-failed" {
                dailyPreview.results[index].status = "available"
                dailyPreview.results[index].nodeName = "韩国 首尔 · 备用线路"
                dailyPreview.results[index].exitIp = "203.0.113.8"
                dailyPreview.results[index].errors = []
                dailyPreview.results[index].connectionEligible = true
                dailyPreview.results[index].balancedScore = 60
            }
        }
        func switchingStore(failed: Bool) async throws -> VPNStore {
            let store = try await workflowStore(running: true, enabled: true)
            let id = UUID().uuidString
            store.receiveChainUse(ChainUseState(operationId: id, identityKey: "fixture-us", nodeName: "美国 洛杉矶 · 高速下载", phase: "verifying",
                automatic: true, previousNodeName: "日本 东京 · 均衡线路"))
            if failed {
                store.receiveChainUse(ChainUseState(operationId: id, identityKey: "fixture-us", nodeName: "美国 洛杉矶 · 高速下载", phase: "failed", finished: true,
                    error: "目标线路响应复核超时，请稍后重试或换一条备用线路；原配置与连接未改动。", automatic: true, previousNodeName: "日本 东京 · 均衡线路"))
            }
            return store
        }
        let switchingPreviewStore = try await switchingStore(failed: false)
        let failedSwitchPreviewStore = try await switchingStore(failed: true)
        defer { switchingPreviewStore.close(); failedSwitchPreviewStore.close() }
        var backgroundPreview = chainPreview
        backgroundPreview.running = true; backgroundPreview.mode = "continuous"
        backgroundPreview.testing = false; backgroundPreview.canUseCachedResults = true
        backgroundPreview.completed = 7
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
        var waitingChainPreview = backgroundPreview
        waitingChainPreview.waitingReason = "network-unavailable"
        var oldChainPreview = chainPreview
        for index in oldChainPreview.results.indices {
            oldChainPreview.results[index].requiresRefresh = true
            oldChainPreview.results[index].testedAt = "2026-10-20T10:00:00Z"
        }
        for (name, view) in [("diagnostics-updating", AnyView(DiagnosticsView(store: updatingDiagnostics))),
                              ("diagnostics-error", AnyView(DiagnosticsView(store: failedDiagnostics))),
                              ("overview-updating", AnyView(OverviewView(store: updatingDiagnostics, company: connected))),
                              ("overview-error", AnyView(OverviewView(store: failedDiagnostics, company: connected))),
                              ("overview-recovering", AnyView(OverviewView(store: recovering, company: connected))),
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
                              ("chain-scanner", AnyView(ChainScannerView(store: nodeDesignStore, preview: chainPreview))),
                              ("chain-scanner-background", AnyView(ChainScannerView(store: nodeDesignStore, preview: backgroundPreview))),
                              ("isp-test-history", AnyView(ChainHistoryView(store: ispOffHome, preview: true, records: [ChainHistoryRecord(recordId: "fixture-1", scanId: "fixture", sameEnvironment: true, observation: oldChainPreview.results[0]), ChainHistoryRecord(recordId: "fixture-2", scanId: "older", sameEnvironment: false, observation: oldChainPreview.results[0])]).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))),
                              ("isp-test-waiting", AnyView(ChainScannerView(store: ispOffHome, preview: waitingChainPreview, standalone: true))),
                              ("isp-comparison-empty", AnyView(ChainScannerView(store: ispOffHome, preview: emptyComparison, standalone: true))),
                              ("isp-comparison-failed", AnyView(ChainScannerView(store: ispOffHome, preview: failedComparison, standalone: true))),
                              ("isp-comparison", AnyView(ChainScannerView(store: workflowOffline, preview: comparisonPreview, standalone: true))),
                              ("isp-daily", AnyView(ChainScannerView(store: workflowReady, preview: dailyPreview, standalone: true))),
                              ("isp-switching", AnyView(ChainScannerView(store: switchingPreviewStore, preview: dailyPreview, standalone: true))),
                              ("isp-switch-failed", AnyView(ChainScannerView(store: failedSwitchPreviewStore, preview: dailyPreview, standalone: true))),
                              ("isp-overview-top", AnyView(OverviewView(store: workflowReady, company: loggedOut))),
                              ("isp-daily-advanced", AnyView(ChainScannerView(store: workflowReady, preview: dailyPreview, detailsExpanded: true, standalone: true))),
                              ("isp-subscription", AnyView(ChainScannerView(store: workflowReady, preview: subscriptionPreview, standalone: true, subscriptionID: "fixture-subscription"))),
                              ("isp-progress", AnyView(ChainScannerView(store: workflowReady, preview: progressPreview, standalone: true, subscriptionID: "fixture-subscription"))),
                              ("isp-auto-running", AnyView(ChainScannerView(store: workflowReady, preview: autoPreview, standalone: true, subscriptionID: "fixture-subscription"))),
                              ("isp-auto-settings", AnyView(ChainAutomaticRefreshView(configuration: autoConfiguration, working: false, close: {}, save: { _,_ in }).frame(maxWidth: .infinity, maxHeight: .infinity))),
                              ("isp-progress-wait", AnyView(ChainScannerView(store: workflowReady, preview: progressWait, standalone: true, subscriptionID: "fixture-subscription"))),
                              ("isp-progress-continuous", AnyView(ChainScannerView(store: workflowReady, preview: progressContinuous, standalone: true, subscriptionID: "fixture-subscription"))),
                              ("isp-workflow-ready", AnyView(ChainScannerView(store: workflowReady, preview: comparisonPreview, standalone: true))),
                              ("isp-workflow-queued", AnyView(ChainScannerView(store: workflowOffline, preview: queuedPreview, standalone: true))),
                              ("isp-workflow-inuse", AnyView(ChainScannerView(store: workflowReady, preview: inUsePreview, standalone: true))),
                              ("isp-use-confirming", AnyView(ChainScannerView(store: useConfirming, preview: comparisonPreview, standalone: true))),
                              ("isp-use-unknown", AnyView(ChainScannerView(store: useUnknown, preview: comparisonPreview, standalone: true))),
                              ("isp-use-recovery", AnyView(ChainScannerView(store: useRecovery, preview: comparisonPreview, standalone: true))),
                              ("isp-use-failed", AnyView(ChainUseStatusView(state: ChainUseState(operationId: "preview", nodeName: "东京 · 中转 01", phase: "failed", finished: true, error: "实际出口尚未确认；原配置与线路已恢复。"), cancel: {}, refresh: {}).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))),
                              ("isp-connection-prepare", AnyView(ChainConnectionPreparationView(store: workflowOffline, target: comparisonPreview.results[0], close: {}, apply: {}).frame(maxWidth: .infinity, maxHeight: .infinity))),
                              ("isp-test-old", AnyView(ChainScannerView(store: ispOffHome, preview: oldChainPreview, detailsExpanded: true, standalone: true))),
                              ("isp-test-page", AnyView(ChainScannerView(store: ispOffHome, preview: chainPreview, standalone: true))),
                              ("chain-scanner-details", AnyView(ChainScannerView(store: nodeDesignStore, preview: chainPreview, detailsExpanded: true))),
                              ("overview-isp", AnyView(OverviewView(store: ispHome, company: connected))),
                              ("overview-isp-off", AnyView(OverviewView(store: ispOffHome, company: connected))),
                              ("static-exit", AnyView(Form { StaticExitSettingsView(store: nodeDesignStore) }.formStyle(.grouped))),
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
            let sizes = name.hasPrefix("shell-") ? [NSSize(width: 960, height: 720), NSSize(width: 1120, height: 760), NSSize(width: 1440, height: 960)] : name.hasPrefix("isp-") ? [NSSize(width: 740, height: 600), NSSize(width: 840, height: 640), NSSize(width: 1040, height: 780)] : [NSSize(width: 840, height: 640), NSSize(width: 1040, height: 780)]
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
