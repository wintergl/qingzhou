import Combine
import AppKit
import SwiftUI
import XCTest
@testable import SplitVPNNative

final class SystemOptimizationTests: XCTestCase {
    func testTrafficOwnershipUsesCoreClassificationAndSupportsOlderCores() throws {
        func connection(_ extra: String) throws -> TrafficConnection {
            try JSONDecoder().decode(TrafficConnection.self, from: Data("""
            {"id":"fixture","host":"example.test","network":"tcp","type":"TUN","rule":"IPCIDR","rulePayload":"10.0.0.8/32","chains":["COMPANY-0123456789abcdef","VPN"],"upload":1,"download":2,"destination":"10.0.0.8:443"\(extra)}
            """.utf8))
        }
        XCTAssertTrue(try connection("").isCompanyTraffic)
        XCTAssertTrue(try connection(",\"routeKind\":\"company\"").isCompanyTraffic)
        XCTAssertFalse(try connection(",\"routeKind\":\"proxy\"").isCompanyTraffic)
    }

    func testRestrictedSiteDoesNotChangeProxyOrDnsSuccess() throws {
        let value = try JSONDecoder().decode(Connectivity.self, from: Data(#"{"domesticOk":true,"foreignOk":false,"proxyOk":true,"latency":{"foreignMs":25},"systemDns":{"ok":true},"chatgpt":{"ok":false,"httpStatus":403,"failureReason":"restricted"}}"#.utf8))
        XCTAssertEqual(value.proxyOk, true)
        XCTAssertEqual(value.systemDns?.responseText, "正常")
        XCTAssertEqual(value.chatgpt?.responseText, "访问受限 · 403")
        XCTAssertFalse(value.foreignOk, "The older aggregate field remains compatible")
    }

    @MainActor func testTrafficRefreshDoesNotInvalidateTheWholeVpnStore() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        await f.store.refresh()
        var broad = 0, narrow = 0
        let first = f.store.objectWillChange.sink { broad += 1 }
        let second = f.store.trafficStore.objectWillChange.sink { narrow += 1 }
        await f.store.refreshTraffic()
        XCTAssertEqual(broad, 0)
        XCTAssertEqual(narrow, 1)
        withExtendedLifetime((first,second)) {}
    }

    @MainActor func testNativePrivateNetworkCheckboxFiltersActualCompanyRouteNames() async throws {
        _ = NSApplication.shared
        let f = try MenuBarFixture(); defer { f.close() }
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: f.coreModel.bootstrap().encoded) as? [String:Any])
        func connection(_ id: String, _ chains: [String], _ kind: String) -> [String:Any] {
            ["id":id,"host":"example.test","network":"tcp","type":"TUN","rule":"IPCIDR","rulePayload":"10.0.0.8/32","chains":chains,"routeKind":kind,"upload":1,"download":2,"destination":"10.0.0.8:443"]
        }
        payload["traffic"] = ["rates":["upload":1,"download":2],"samples":[],"running":true,
            "snapshot":["uploadTotal":1,"downloadTotal":2,"connectionCount":2,
                "connections":[connection("private",["COMPANY-0123456789abcdef","VPN"],"company"), connection("direct",["DIRECT"],"direct")]]]
        let reply = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: payload))
        f.coreModel.intercept = { channel,_ in channel == "native:bootstrap" ? reply : nil }
        await f.store.refresh()
        let host = NSHostingView(rootView: TrafficView(store:f.store).frame(width:1100,height:800))
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:800),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false; window.contentView=host; defer { window.close() }
        host.frame = NSRect(x:0,y:0,width:1100,height:800)
        window.orderFrontRegardless()
        func views<T:NSView>(_ view:NSView, _ type:T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { views($0,type) }
        }
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for:.milliseconds(120))
        let table = try XCTUnwrap(views(host,NSTableView.self).first)
        XCTAssertEqual(table.numberOfRows,2)
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        let frame = scroll.convert(scroll.bounds, to:host)
        let local = NSPoint(x:384,y:host.isFlipped ? frame.minY - 32 : frame.maxY + 32)
        let point = host.convert(local,to:nil)
        for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
        await menuWait { table.numberOfRows == 1 }
        XCTAssertEqual(table.numberOfRows,1)
    }

    @MainActor func testFreshNodeAndExitRiskEventsSurviveAnOlderBootstrapReply() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        f.coreModel.running = true; f.store.startOnce()
        await menuWait { f.coreModel.channels.contains("native:startup-connect") && f.store.busy == nil }
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: f.coreModel.bootstrap().encoded) as? [String:Any])
        old["viewRevision"] = 10
        let oldReply = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: old))
        var pending: CheckedContinuation<JSONValue, Never>?
        f.coreModel.intercept = { channel,_ in
            guard channel == "native:bootstrap" else { return nil }
            return await withCheckedContinuation { pending = $0 }
        }
        let refresh = Task { await f.store.refresh() }
        await menuWait { pending != nil }
        func event(_ name: String, _ payload: String) throws {
            f.core.onEvent?(name, try JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)))
        }
        try event("nodes:updated", #"{"viewRevision":20,"nodes":[{"name":"fresh-fixture","type":"http","selected":true,"identityKey":"fresh","delay":44,"available":true}],"groups":[],"error":null}"#)
        try event("risk:current-updated", #"{"viewRevision":20,"result":{"nodeName":"fixture-node","ip":"203.0.113.8","riskLevel":"low","reasons":[],"checkedAt":"2026-10-29T00:00:00Z","scope":"current-exit"}}"#)
        pending?.resume(returning: oldReply); await refresh.value
        XCTAssertEqual(f.store.nodes.first?.name, "fresh-fixture")
        XCTAssertEqual(f.store.currentRisk?.ip, "203.0.113.8")
        XCTAssertNil(f.store.nodesError)
        try event("nodes:updated", #"{"viewRevision":21,"nodes":null,"groups":null,"error":"Fixture provider cannot be read"}"#)
        XCTAssertTrue(f.store.nodes.isEmpty)
        XCTAssertNotNil(f.store.nodesError)
        XCTAssertFalse(f.store.statusKnown)
        try event("nodes:updated", #"{"viewRevision":19,"nodes":[{"name":"obsolete-fixture","type":"http","selected":false}],"groups":[],"error":null}"#)
        XCTAssertTrue(f.store.nodes.isEmpty)
    }

    @MainActor func testAirportRiskHistoryIsNeverUsedAsCurrentExitRisk() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: f.coreModel.bootstrap().encoded) as? [String:Any])
        payload["risks"] = [["nodeName":"fixture-node","ip":"203.0.113.9","riskLevel":"low","reasons":[],"checkedAt":"2026-10-29T00:00:00Z"]]
        let reply = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: payload))
        f.coreModel.intercept = { channel,_ in channel == "native:bootstrap" ? reply : nil }
        await f.store.refresh()
        XCTAssertEqual(f.store.risks.count, 1)
        XCTAssertNil(f.store.currentRisk)
    }

    @MainActor func testBrokenNodeSnapshotDoesNotHideSeparatelyConfirmedConnection() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        f.coreModel.running = true; await f.store.refresh()
        guard case .object(let bootstrap) = try f.coreModel.bootstrap(), let status = bootstrap["status"] else {
            return XCTFail("Missing fixture status")
        }
        f.coreModel.intercept = { channel,_ in
            if channel == "native:bootstrap" { throw CoreService.CoreError.message("Fixture provider cannot be read") }
            if channel == "vpn:get-status" { return status }
            return nil
        }
        await f.store.refresh()
        XCTAssertTrue(f.store.statusKnown)
        XCTAssertTrue(f.store.canDisconnect)
        XCTAssertNotNil(f.store.error)
    }

    @MainActor func testPendingConnectionRemainsCancellableWhenSnapshotBecomesUnknown() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        await f.store.refresh()
        var pending: CheckedContinuation<Void,Never>?
        var failReads = false
        f.coreModel.intercept = { channel,_ in
            if failReads && ["native:bootstrap","vpn:get-status"].contains(channel) {
                throw CoreService.CoreError.message("Fixture snapshot expired")
            }
            if channel == "vpn:start" {
                await withCheckedContinuation { pending = $0 }
                throw CoreService.CoreError.message("Fixture start cancelled")
            }
            return nil
        }
        let connect = Task { try? await f.store.toggleConnection() }
        await menuWait { pending != nil }
        failReads = true; await f.store.refresh()
        XCTAssertFalse(f.store.statusKnown)
        XCTAssertTrue(f.store.canDisconnect)
        try await f.store.disconnectNow()
        pending?.resume(); await connect.value
        XCTAssertEqual(f.coreModel.channels.filter { $0 == "vpn:stop" }.count,1)
        XCTAssertFalse(f.store.running)
    }
}
