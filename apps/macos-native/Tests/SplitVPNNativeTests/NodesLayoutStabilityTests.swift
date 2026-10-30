import AppKit
import SwiftUI
import XCTest
@testable import SplitVPNNative

final class NodesLayoutStabilityTests: XCTestCase {
    @MainActor func testSpeedOperationDoesNotResizeTableOrMoveScrolledViewport() async throws {
        _ = NSApplication.shared
        let f = try MenuBarFixture(); defer { f.close() }
        f.coreModel.running = true
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: f.coreModel.bootstrap().encoded) as? [String: Any])
        payload["nodes"] = (0..<50).map { i in
            ["name": i == 0 ? "fixture-node" : "Fixture node \(i)", "type":"http", "identityKey":"fixture-\(i)",
             "selected":i == 0,"delay":100 + i,"available":true,"latencyStatus":"available"] as [String:Any]
        }
        let bootstrap = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: payload))
        var release: CheckedContinuation<Void, Never>?
        f.coreModel.intercept = { channel, _ in
            if channel == "native:bootstrap" { return bootstrap }
            if channel == "nodes:list", case .object(let fields) = bootstrap { return fields["nodes"] }
            if channel == "nodes:test-recommended" {
                await withCheckedContinuation { release = $0 }
                return .object([:])
            }
            return nil
        }
        f.store.page = .nodes; f.store.startOnce()
        await menuWait { f.store.nodes.count == 50 && f.coreModel.channels.contains("native:startup-connect") && f.store.busy == nil }
        let host = NSHostingView(rootView: ContentView(store: f.store, company: f.company).frame(width: 1100, height: 800))
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:1100,height:800), styleMask:[.borderless], backing:.buffered, defer:false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { release?.resume(); window.close() }
        func settle() async throws { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(70)); host.layoutSubtreeIfNeeded() }
        func tables(_ view: NSView) -> [NSTableView] { (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables($0) } }
        try await settle()
        let table = try XCTUnwrap(tables(host).first)
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        table.selectRowIndexes(IndexSet(integer:45), byExtendingSelection:false)
        table.scrollRowToVisible(49)
        try await settle()
        let frame = scroll.frame
        let origin = scroll.contentView.bounds.origin
        let widths = table.tableColumns.map(\.width)
        func assertStable(_ message: String) {
            XCTAssertEqual(scroll.frame.height, frame.height, accuracy:0.5, message)
            XCTAssertEqual(scroll.frame.width, frame.width, accuracy:0.5, message)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, origin.y, accuracy:0.5, message)
            for (actual, expected) in zip(table.tableColumns.map(\.width), widths) { XCTAssertEqual(actual, expected, accuracy:0.5, message) }
        }
        XCTAssertGreaterThan(origin.y, 0)
        f.store.action("多站点复测", channel:"nodes:test-recommended", payload:["identityKey":"fixture-45"])
        await menuWait { release != nil }
        try await settle()
        XCTAssertEqual(scroll.frame.height, frame.height, accuracy:0.5, "测速状态不应挤压表格高度")
        XCTAssertEqual(scroll.contentView.bounds.origin.y, origin.y, accuracy:0.5, "测速状态不应改变滚动位置")
        for _ in 0..<4 {
            await f.store.refreshTraffic()
            try await settle()
            XCTAssertEqual(scroll.frame.height, frame.height, accuracy:0.5)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, origin.y, accuracy:0.5)
        }
        release?.resume(); release = nil
        await menuWait { f.store.busy == nil }
        try await settle()
        assertStable("完成提示也应保留相同布局")
        f.store.message = nil
        try await settle()
        assertStable("关闭提示不能挤动表格")
        func progress(_ raw: String) throws {
            f.core.onEvent?("nodes:speed-progress", try JSONDecoder().decode(JSONValue.self, from:Data(raw.utf8)))
        }
        for i in 0..<4 {
            try progress(#"{"id":"layout","checked":0,"total":1,"nodeName":"Fixture node 45","phase":"testing","finished":false}"#)
            try await settle()
            assertStable("逐条测速时列宽和视口不能来回变化")
            let raw = #"{"id":"layout","checked":1,"total":1,"nodeName":"Fixture node 45","finished":false,"result":{"nodeName":"Fixture node 45","status":"available","medianDelayMs":\#(100+i),"testedAt":"2026-10-25T20:00:00Z"}}"#
            try progress(raw)
            await f.store.refreshTraffic()
            try await settle()
            assertStable("结果和后台流量刷新不能改变滚动位置")
        }
        try progress(#"{"id":"layout","checked":1,"total":1,"finished":true}"#)
        try await settle()
        assertStable("批次结束与完整快照刷新不应跳动")
    }
}
