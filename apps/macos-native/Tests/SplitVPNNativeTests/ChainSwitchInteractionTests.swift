import AppKit
import SwiftUI
import XCTest
@testable import SplitVPNNative

final class ChainSwitchInteractionTests: XCTestCase {
    @MainActor private func click<V: View>(_ host: NSHostingView<V>, window: NSWindow, x: CGFloat, y: CGFloat) async throws {
        let point = host.convert(NSPoint(x: host.bounds.width * x, y: host.bounds.height * (host.isFlipped ? y : 1-y)), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(80))
    }
    private func route(_ id: String) -> ChainScanRow {
        ChainScanRow(identityKey: id, nodeName: "示例线路 \(id)", status: "available", latencyMs: 80, jitterMs: 5, downloadMbps: 20,
            latencySuccesses: 3, latencyAttempts: 3, downloadSuccesses: 2, downloadAttempts: 2, exitIp: "203.0.113.8", errors: [],
            balancedScore: 70, connectionEligible: true, subscriptionName: id == "one" || id == "two" ? "示例订阅 A" : "示例订阅 B")
    }
    @MainActor private func fixtureStore() async throws -> (VPNStore, MenuCoreModel) {
        let model = MenuCoreModel()
        model.running = true
        model.intercept = { channel, _ in
            guard channel == "native:bootstrap" else { return nil }
            var data = try JSONSerialization.jsonObject(with: model.bootstrap().encoded) as! [String: Any]
            var status = data["status"] as! [String: Any]
            var settings = status["settings"] as! [String: Any]
            settings["staticExit"] = ["enabled":true,"protocol":"socks5","server":"proxy.example.test","port":1080,"username":"","expectedIp":""]
            status["settings"] = settings; data["status"] = status
            return try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: data))
        }
        let store = VPNStore(core: CoreService { channel, payload in try await model.call(channel, payload) }, loginItems: MenuLoginItems(), riskKeyVault: FixtureVault())
        await store.refresh()
        return (store, model)
    }
    @MainActor func test_all_four_backup_buttons_are_visible_and_switch_directly_with_no_detail_click() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let rows = ["one", "two", "three", "four"].map(route)
        let state = ChainScanState(id: "fixture", results: rows, stale: false,
            routine: ChainRoutineState(connectionState: "connected", currentNodeName: "当前线路", backupIdentityKeys: rows.map(\.id)))
        var switched: [String] = []
        let view = ChainDailyStatusView(state: state, fallbackCurrent: "当前线路", fallbackConnected: true, canSwitch: true,
            switchRoute: { switched.append($0.id) }, select: { _ in XCTFail("Backup click must switch directly") })
            .buttonStyle(VPNButtonStyle()).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 708, height: 380), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFrontRegardless()
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("qz-isp-switch-buttons.png"))
        }
        for point in [(0.25, 0.38), (0.75, 0.38), (0.25, 0.61), (0.75, 0.61)] {
            try await click(host, window: window, x: point.0, y: point.1)
        }
        XCTAssertEqual(switched, rows.map(\.id))
    }
    @MainActor func test_automatic_switch_status_is_adopted_and_failures_stay_inline() async throws {
        let (store, model) = try await fixtureStore()
        defer { store.close(); model.intercept = nil }
        let id = UUID().uuidString
        store.receiveChainUse(ChainUseState(operationId: "unrelated", nodeName: "其他操作", phase: "verifying"))
        XCTAssertNil(store.chainUse)
        let previous = store.selectedProxy
        store.receiveChainUse(ChainUseState(operationId: id, identityKey: "two", nodeName: "备用线路", phase: "verifying", automatic: true, previousNodeName: previous))
        XCTAssertEqual(store.chainUse?.operationId, id)
        XCTAssertEqual(store.chainUse?.automatic, true)
        XCTAssertEqual(store.selectedProxy, previous)
        XCTAssertNotNil(store.busy)
        store.receiveChainUse(ChainUseState(operationId: id, identityKey: "two", nodeName: "备用线路", phase: "failed", finished: true,
            error: "目标线路响应复核超时；原配置与连接未改动。", automatic: true, previousNodeName: previous))
        XCTAssertEqual(store.chainUse?.phase, "failed")
        XCTAssertTrue(store.chainUse?.error?.contains("超时") == true)
        XCTAssertNil(store.error, "Switch errors are shown in the persistent status card")
        XCTAssertNil(store.busy)
        XCTAssertTrue(store.canMutate)
        store.dismissChainUse()
        XCTAssertNil(store.chainUse)
    }
    @MainActor func test_disconnect_retires_automatic_status_so_a_late_result_cannot_replace_it() async throws {
        let (store, model) = try await fixtureStore()
        defer { store.close(); model.intercept = nil }
        let id = UUID().uuidString
        store.receiveChainUse(ChainUseState(operationId: id, identityKey: "two", nodeName: "备用线路", phase: "confirming", automatic: true, previousNodeName: store.selectedProxy))
        try await store.disconnectNow()
        let result = ChainUseResult(connected: true, nodeName: "备用线路", identityKey: "two", exitIp: "203.0.113.8", verifiedAt: "2026-10-30T00:00:00Z", operationId: id)
        store.receiveChainUse(ChainUseState(operationId: id, phase: "connected", finished: true, result: result, automatic: true))
        XCTAssertFalse(store.running)
        XCTAssertFalse(store.chainUse?.active == true)
        XCTAssertNotEqual(store.chainUse?.phase, "connected")
        XCTAssertEqual(store.message, "VPN 已断开。")
    }
}
