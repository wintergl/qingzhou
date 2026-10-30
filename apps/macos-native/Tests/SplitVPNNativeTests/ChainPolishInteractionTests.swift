import AppKit
import SwiftUI
import XCTest
@testable import SplitVPNNative

final class ChainPolishInteractionTests: XCTestCase {
    @MainActor private func host<V: View>(_ view: V, size: NSSize = NSSize(width: 840, height: 300)) async throws -> (NSWindow, NSHostingView<V>) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        return (window, hosting)
    }
    // Events stay inside the synthetic component window; no global input or business account is used.
    @MainActor private func click<V: View>(_ hosting: NSHostingView<V>, window: NSWindow, x: CGFloat, y: CGFloat = 0.5) async throws {
        let point = hosting.convert(NSPoint(x: hosting.bounds.width * x, y: hosting.bounds.height * (hosting.isFlipped ? y : 1 - y)), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(80))
    }
    private func row(_ id: String) -> ChainScanRow {
        ChainScanRow(identityKey: id, nodeName: "示例线路 \(id)", status: "available", latencyMs: 100, jitterMs: 10, downloadMbps: 20,
                     latencySuccesses: 3, latencyAttempts: 3, downloadSuccesses: 2, downloadAttempts: 2, exitIp: "203.0.113.8", errors: [], balancedScore: 60)
    }
    @MainActor func test_pressing_actual_leader_buttons_selects_the_matching_strategy_and_identity() async throws {
        let state = ChainScanState(id: "fixture", results: [row("one"), row("two")], stale: false,
            leaders: ChainLeaders(balanced: "one", download: "two", latency: "one"))
        var presses: [(String, String)] = []
        let (window, hosting) = try await host(ChainLeaderCards(state: state) { strategy, row in presses.append((strategy, row.id)) })
        defer { window.close() }
        try await click(hosting, window: window, x: 0.625)
        XCTAssertEqual(presses.last?.0, "download"); XCTAssertEqual(presses.last?.1, "two")
        try await click(hosting, window: window, x: 0.25)
        XCTAssertEqual(presses.last?.0, "balanced"); XCTAssertEqual(presses.last?.1, "one")
    }
    @MainActor func test_selected_route_buttons_call_their_distinct_actions() async throws {
        var connected = 0; var retested = 0
        let (window, hosting) = try await host(ChainSelectedRouteView(row: row("one"), restriction: nil, canConnect: true, canRetest: true, working: false,
            connect: { connected += 1 }, retest: { retested += 1 }))
        defer { window.close() }
        try await click(hosting, window: window, x: 0.78)
        try await click(hosting, window: window, x: 0.93)
        XCTAssertEqual(retested, 1); XCTAssertEqual(connected, 1)
    }
    @MainActor func test_disabled_connect_button_never_invokes_the_action() async throws {
        var connected = 0
        let (window, hosting) = try await host(ChainSelectedRouteView(row: row("one"), restriction: "请先连接 VPN", canConnect: false, canRetest: true, working: false,
            connect: { connected += 1 }, retest: {}))
        defer { window.close() }
        try await click(hosting, window: window, x: 0.93)
        XCTAssertEqual(connected, 0)
    }
    @MainActor func test_native_table_selection_updates_the_bound_route() async throws {
        let state = ChainScanState(id: "fixture", results: [row("one"), row("two")], stale: false)
        var selection: String?
        let binding = Binding<String?>(get: { selection }, set: { selection = $0 })
        let (window, hosting) = try await host(ChainComparisonTable(rows: state.results, state: state, selection: binding, downloadMaximum: 20, latencyMinimum: 100))
        defer { window.close() }
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        let tableView = try XCTUnwrap(table(in: hosting))
        XCTAssertEqual(tableView.numberOfRows, 2)
        tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(selection, "two")
        XCTAssertTrue(window.makeFirstResponder(tableView))
        let up = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: 126))
        tableView.keyDown(with: up)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(selection, "one")
    }
    @MainActor func test_preparation_requires_explicit_enable_connect_and_apply_clicks() async throws {
        let model = MenuCoreModel()
        var enabled = false
        model.intercept = { channel, payload in
            if channel == "static-exit:set-enabled" {
                enabled = payload["enabled"] as? Bool == true
                return .object(["enabled": .bool(enabled)])
            }
            if channel == "native:bootstrap" {
                var data = try XCTUnwrap(JSONSerialization.jsonObject(with: model.bootstrap().encoded) as? [String: Any])
                var status = try XCTUnwrap(data["status"] as? [String: Any])
                var settings = try XCTUnwrap(status["settings"] as? [String: Any])
                settings["staticExit"] = ["enabled": enabled, "protocol": "socks5", "server": "proxy.example.test", "port": 1080, "username": "", "expectedIp": ""]
                status["settings"] = settings; data["status"] = status
                return try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: data))
            }
            return nil
        }
        let core = CoreService { channel, payload in try await model.call(channel, payload) }
        let store = VPNStore(core: core, loginItems: MenuLoginItems(), riskKeyVault: FixtureVault())
        defer { store.close(); model.intercept = nil }
        await store.refresh()
        var applied = 0
        let view = ChainConnectionPreparationView(store: store, target: row("fixture-id"), close: {}, apply: { applied += 1 })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        let (window, hosting) = try await host(view, size: NSSize(width: 840, height: 640))
        defer { window.close() }
        XCTAssertFalse(enabled); XCTAssertFalse(model.running)
        XCTAssertTrue(store.canMutate); XCTAssertEqual(store.providerNodes.count, 1)
        try await click(hosting, window: window, x: 0.815, y: 0.84)
        XCTAssertEqual(applied, 0)
        try await click(hosting, window: window, x: 0.805, y: 0.49)
        await menuWait { store.busy == nil && store.status?.settings.staticExit?.enabled == true }
        XCTAssertTrue(enabled); XCTAssertFalse(model.running)
        XCTAssertFalse(model.channels.contains("vpn:start"))
        try await click(hosting, window: window, x: 0.8, y: 0.645)
        await menuWait { store.running && store.busy == nil }
        XCTAssertTrue(store.running); XCTAssertEqual(applied, 0)
        try await click(hosting, window: window, x: 0.815, y: 0.84)
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(model.channels.filter { $0 == "static-exit:set-enabled" }.count, 1)
        XCTAssertEqual(model.channels.filter { $0 == "vpn:start" }.count, 1)
    }

    @MainActor func test_subscription_retest_button_is_explicit_and_busy_state_prevents_repeat_clicks() async throws {
        let entry = Subscription(id: "one", name: "示例机场", url: "https://example.test/subscription", enabled: true, nodeCount: 2, status: "ready")
        var calls = 0
        let (window, hosting) = try await host(ChainSubscriptionControls(subscriptions: [entry], selection: .constant("one"), candidateCount: 2,
            running: true, busy: false, canRetest: true, retest: { calls += 1 }).buttonStyle(VPNButtonStyle()))
        defer { window.close() }
        try await click(hosting, window: window, x: 0.91)
        XCTAssertEqual(calls, 1)
        let (busyWindow, busyHosting) = try await host(ChainSubscriptionControls(subscriptions: [entry], selection: .constant("one"), candidateCount: 2,
            running: false, busy: true, canRetest: true, retest: { calls += 1 }).buttonStyle(VPNButtonStyle()))
        defer { busyWindow.close() }
        try await click(busyHosting, window: busyWindow, x: 0.91)
        XCTAssertEqual(calls, 1)
    }

    @MainActor func test_clicking_scoped_recommendation_keeps_subscription_and_selects_that_route() async throws {
        let model = MenuCoreModel()
        model.intercept = { channel, _ in
            guard channel == "native:bootstrap" else { return nil }
            var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: model.bootstrap().encoded) as? [String: Any])
            var status = payload["status"] as! [String: Any]
            var subscription = status["subscription"] as! [String: Any]
            subscription["entries"] = ["one", "two"].map { ["id": $0, "name": $0, "url": "https://example.test/" + $0, "enabled": true, "nodeCount": 1, "status": "ready"] as [String: Any] }
            status["subscription"] = subscription; payload["status"] = status
            payload["nodes"] = [["name":"示例线路 one", "type":"http", "selected":true,"identityKey":"one", "subscriptionId":"one"],
                                ["name":"示例线路 two", "type":"http", "selected":false,"identityKey":"two", "subscriptionId":"two"]]
            return try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: payload))
        }
        let store = VPNStore(core: CoreService { channel, payload in try await model.call(channel, payload) }, loginItems: MenuLoginItems(), riskKeyVault: FixtureVault())
        defer { store.close(); model.intercept = nil }
        await store.refresh()
        var state = ChainScanState(id: "fixture", results: [row("two"), row("one")], stale: false, recommendedIdentityKey: "two")
        state.view = ChainScanScopeView(subscriptionId: "one", results: [row("one")], leaders: ChainLeaders(balanced: "one", download: "one", latency: "one"), recommendedIdentityKey: "one")
        let (window, hosting) = try await host(ChainScannerView(store: store, preview: state, detailsExpanded: true, standalone: true, subscriptionID: "one"), size: NSSize(width: 840, height: 780))
        defer { window.close() }
        func table(in view: NSView) -> NSTableView? {
            if let value = view as? NSTableView { return value }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        XCTAssertEqual(table(in: hosting)?.numberOfRows, 1)
        try await click(hosting, window: window, x: 0.25, y: 0.43)
        XCTAssertEqual(table(in: hosting)?.numberOfRows, 1)
        XCTAssertEqual(table(in: hosting)?.selectedRow, 0)
    }

    @MainActor func test_idle_page_stops_polling_when_hidden_or_sleeping_and_refreshes_on_return() async throws {
        let model = MenuCoreModel()
        model.intercept = { channel, _ in
            if channel == "native:runtime-environment" { return .bool(true) }
            if channel == "chain-scan:get" {
                return .object(["id": .string("idle"), "running": .bool(false), "cancelled": .bool(false),
                                "completed": .number(0), "total": .number(0), "results": .array([]), "stale": .bool(true)])
            }
            return nil
        }
        let store = VPNStore(core: CoreService { channel, payload in try await model.call(channel, payload) }, loginItems: MenuLoginItems(), riskKeyVault: FixtureVault())
        defer { store.close(); model.intercept = nil }
        await store.refresh()
        store.setActivity(DesktopActivity(visible: true, onBattery: false))
        let (window, _) = try await host(ChainScannerView(store: store, standalone: true), size: NSSize(width: 840, height: 640))
        defer { window.close() }
        func reads() -> Int { model.channels.filter { $0 == "chain-scan:get" }.count }
        await menuWait { reads() > 0 }
        let initial = reads()
        XCTAssertGreaterThan(initial, 0)
        try await Task.sleep(for: .milliseconds(1150))
        XCTAssertEqual(reads(), initial, "An idle page must not fetch its full result every second")
        store.setActivity(DesktopActivity(visible: false, onBattery: false))
        try await Task.sleep(for: .milliseconds(1150))
        XCTAssertEqual(reads(), initial)
        store.setActivity(DesktopActivity(visible: true, onBattery: false))
        await menuWait { reads() > initial }
        let returned = reads()
        XCTAssertGreaterThan(returned, initial, "Showing the page must refresh immediately")
        store.setActivity(DesktopActivity(visible: true, onBattery: false, sleeping: true))
        try await Task.sleep(for: .milliseconds(1150))
        XCTAssertEqual(reads(), returned)
        store.setActivity(DesktopActivity(visible: true, onBattery: false))
        await menuWait { reads() > returned }
        XCTAssertGreaterThan(reads(), returned, "Waking must resume the page without waiting for its idle timer")
    }

    @MainActor func test_primary_action_searches_a_small_set_without_starting_vpn_or_changing_isp() async throws {
        let model = MenuCoreModel()
        var starts: [[String: Any]] = []
        model.intercept = { channel, payload in
            if channel == "native:runtime-environment" { return .bool(true) }
            if channel == "chain-scan:get" {
                return .object(["id": .string("ready"), "running": .bool(false), "cancelled": .bool(false),
                                "completed": .number(0), "total": .number(0), "results": .array([]), "stale": .bool(true)])
            }
            if channel == "chain-scan:start" { starts.append(payload); return .object(["id": .string("started")]) }
            if channel == "native:bootstrap" {
                var data = try XCTUnwrap(JSONSerialization.jsonObject(with: model.bootstrap().encoded) as? [String: Any])
                var status = data["status"] as! [String: Any]
                var settings = status["settings"] as! [String: Any]
                settings["staticExit"] = ["enabled": false, "protocol": "socks5", "server": "proxy.example.test", "port": 1080, "username": "", "expectedIp": ""]
                status["settings"] = settings; data["status"] = status
                return try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: data))
            }
            return nil
        }
        let store = VPNStore(core: CoreService { channel, payload in try await model.call(channel, payload) }, loginItems: MenuLoginItems(), riskKeyVault: FixtureVault())
        defer { store.close(); model.intercept = nil }
        await store.refresh()
        store.setActivity(DesktopActivity(visible: true, onBattery: false))
        let (window, hosting) = try await host(ChainScannerView(store: store, standalone: true), size: NSSize(width: 840, height: 640))
        defer { window.close() }
        for y in stride(from: 0.55, through: 0.85, by: 0.015) where starts.isEmpty {
            try await click(hosting, window: window, x: 0.12, y: y)
        }
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts.first?["mode"] as? String, "quick")
        XCTAssertFalse(model.channels.contains("vpn:start"))
        XCTAssertFalse(model.channels.contains("static-exit:set-enabled"))
    }

    @MainActor func test_automatic_refresh_requires_explicit_enable_and_saves_selected_default() async throws {
        var saved: [(Bool, Int)] = []
        let view = ChainAutomaticRefreshView(configuration: ChainAutoRefreshState(), working: false, close: {}, save: { saved.append(($0, $1)) })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        let (window, hosting) = try await host(view, size: NSSize(width: 840, height: 640))
        defer { window.close() }
        XCTAssertTrue(saved.isEmpty)
        for y in stride(from: 0.60, through: 0.85, by: 0.025) where saved.isEmpty {
            try await click(hosting, window: window, x: 0.79, y: y)
        }
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.0, true); XCTAssertEqual(saved.first?.1, 30)
    }

    @MainActor func test_using_a_saved_route_from_the_native_page_sends_one_orchestrated_request() async throws {
        let model = MenuCoreModel()
        var uses: [[String: Any]] = []
        let route = row("one")
        model.intercept = { channel, payload in
            if channel == "chain-scan:get" {
                return .object(["id":.string("ready"),"running":.bool(false),"cancelled":.bool(false),"completed":.number(1),"total":.number(1),"stale":.bool(false),"canUseCachedResults":.bool(true),"recommendedIdentityKey":.string("one"),"results":.array([.object([
                    "identityKey":.string("one"),"nodeName":.string(route.nodeName),"status":.string("available"),"latencyMs":.number(100),"jitterMs":.number(10),"downloadMbps":.number(20),"latencySuccesses":.number(3),"latencyAttempts":.number(3),"downloadSuccesses":.number(2),"downloadAttempts":.number(2),"exitIp":.string("203.0.113.8"),"errors":.array([]),"balancedScore":.number(60)])])])
            }
            if channel == "chain-scan:use" {
                uses.append(payload)
                return .object(["connected":.bool(true),"nodeName":.string(route.nodeName),"identityKey":.string(route.id),
                    "exitIp":.string("203.0.113.8"),"verifiedAt":.string("2026-10-29T00:00:00Z"),"operationId":.string(payload["operationId"] as! String)])
            }
            if channel == "native:bootstrap" {
                var data = try XCTUnwrap(JSONSerialization.jsonObject(with: model.bootstrap().encoded) as? [String: Any])
                var status = data["status"] as! [String: Any]
                var settings = status["settings"] as! [String: Any]
                settings["staticExit"] = ["enabled":false,"protocol":"socks5","server":"proxy.example.test","port":1080,"username":"","expectedIp":""]
                status["settings"] = settings
                var engine = status["mihomo"] as! [String: Any]
                engine["state"] = "stopped"; engine["pid"] = NSNull(); status["mihomo"] = engine
                data["status"] = status
                data["nodes"] = [["name":route.nodeName,"type":"http","selected":true,"identityKey":route.id]]
                return try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: data))
            }
            return nil
        }
        let store = VPNStore(core: CoreService { channel, payload in try await model.call(channel, payload) }, loginItems: MenuLoginItems(), riskKeyVault: FixtureVault())
        defer { store.close(); model.intercept = nil }
        await store.refresh()
        store.setActivity(DesktopActivity(visible:true,onBattery:false))
        let (window, hosting) = try await host(ChainScannerView(store:store,standalone:true),size:NSSize(width:840,height:640))
        defer { window.close() }
        for y in stride(from:0.40,through:0.70,by:0.015) where uses.isEmpty {
            try await click(hosting,window:window,x:0.89,y:y)
        }
        await menuWait { !uses.isEmpty && store.chainUse?.finished == true }
        XCTAssertEqual(uses.count,1)
        XCTAssertEqual(uses.first?["identityKey"] as? String,"one")
        XCTAssertEqual(store.chainUse?.phase,"connected")
        XCTAssertFalse(model.channels.contains("vpn:start"))
        XCTAssertFalse(model.channels.contains("static-exit:set-enabled"))
        XCTAssertFalse(model.channels.contains("nodes:select-v2"))
    }

    @MainActor func test_permission_failure_and_unconfirmed_timeout_are_not_reported_as_connected() async throws {
        for pending in [false,true] {
            let model = MenuCoreModel()
            var id = ""
            model.intercept = { channel,payload in
                if channel == "chain-scan:use" { id = payload["operationId"] as! String; throw CoreService.CoreError.message(pending ? "服务响应超时" : "用户取消了系统授权") }
                if channel == "chain-scan:use-state" {
                    return pending ? .object(["operationId":.string(id),"nodeName":.string("示例线路 one"),"phase":.string("confirming"),"finished":.bool(false),"cancelRequested":.bool(false)]) : .null
                }
                return nil
            }
            let store = VPNStore(core:CoreService { channel,payload in try await model.call(channel,payload) },loginItems:MenuLoginItems(),riskKeyVault:FixtureVault())
            await store.refresh()
            await store.useChainRoute(row("one"),scanID:"fixture",strategy:"balanced")
            XCTAssertNotEqual(store.chainUse?.phase,"connected")
            XCTAssertEqual(store.chainUse?.active,pending)
            XCTAssertEqual(store.busy != nil,pending)
            XCTAssertNil(store.chainUse?.result)
            XCTAssertFalse(model.channels.contains("vpn:stop"))
            store.close(); model.intercept = nil
        }
    }

    @MainActor func test_native_cancel_button_and_store_cancellation_keep_the_original_request_identity() async throws {
        var pressed = 0
        let status = ChainUseState(operationId:UUID().uuidString,nodeName:"示例线路",phase:"confirming")
        let (window, hosting) = try await host(ChainUseStatusView(state:status,cancel:{ pressed += 1 },refresh:{}).buttonStyle(VPNButtonStyle()),size:NSSize(width:840,height:120))
        defer { window.close() }
        try await click(hosting,window:window,x:0.94,y:0.27)
        XCTAssertEqual(pressed,1)
        let model = MenuCoreModel()
        var originalID = ""
        var cancelledID = ""
        model.intercept = { channel,payload in
            if channel == "chain-scan:use" { originalID = payload["operationId"] as! String; throw CoreService.CoreError.message("操作仍在进行") }
            if channel == "chain-scan:use-state" { return .object(["operationId":.string(originalID),"nodeName":.string("示例线路"),"phase":.string("confirming"),"finished":.bool(false),"cancelRequested":.bool(false)]) }
            if channel == "chain-scan:cancel-use" {
                cancelledID = payload["operationId"] as! String
                return .object(["operationId":.string(cancelledID),"nodeName":.string("示例线路"),"phase":.string("cancelled"),"finished":.bool(true),"cancelRequested":.bool(true),"error":.string("连接已取消；原配置与线路已恢复。")])
            }
            return nil
        }
        let store = VPNStore(core:CoreService { channel,payload in try await model.call(channel,payload) },loginItems:MenuLoginItems(),riskKeyVault:FixtureVault())
        defer { store.close(); model.intercept = nil }
        await store.refresh()
        await store.useChainRoute(row("one"),scanID:"fixture",strategy:"balanced")
        XCTAssertTrue(store.chainUse?.active == true)
        await store.cancelChainUse()
        XCTAssertEqual(cancelledID,originalID)
        XCTAssertEqual(store.chainUse?.phase,"cancelled")
        XCTAssertNil(store.busy)
        XCTAssertFalse(model.channels.contains("vpn:stop"))
    }

    @MainActor func test_unconfirmed_timeout_without_readable_state_stays_unknown_and_cancellable() async throws {
        let model = MenuCoreModel()
        model.intercept = { channel, _ in
            if channel == "chain-scan:use" { throw CoreService.CoreError.uncertain("响应超时，结果未确认") }
            if channel == "chain-scan:use-state" { return .null }
            return nil
        }
        let store = VPNStore(core: CoreService { channel,payload in try await model.call(channel,payload) }, loginItems:MenuLoginItems(), riskKeyVault:FixtureVault())
        defer { store.close(); model.intercept = nil }
        await store.refresh()
        await store.useChainRoute(row("one"), scanID:"fixture", strategy:"balanced")
        XCTAssertEqual(store.chainUse?.phase,"unknown")
        XCTAssertTrue(store.chainUse?.active == true)
        XCTAssertNotNil(store.busy)
        XCTAssertNil(store.chainUse?.result)
    }

}
