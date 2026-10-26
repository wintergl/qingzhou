import AppKit
import SwiftUI
import XCTest
@testable import SplitVPNNative

final class LogFollowingTests: XCTestCase {
    @MainActor func testRollingTailFollowsLatestAndPauseKeepsViewport() async throws {
        _ = NSApplication.shared
        let model = LogOutputFixture()
        let host = NSHostingView(rootView: LogOutputFixtureView(model: model).frame(width: 520, height: 260))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 260), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        func settle() async throws {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
            host.layoutSubtreeIfNeeded()
        }
        func scrollViews(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? v.subviews.flatMap(scrollViews) }
        try await settle()
        let scroll = try XCTUnwrap(scrollViews(host).first)
        let document = try XCTUnwrap(scroll.documentView)
        func atBottom(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
            let visible = scroll.contentView.bounds
            if document.isFlipped { XCTAssertEqual(visible.maxY, document.bounds.maxY, accuracy: 3, message, file: file, line: line) }
            else { XCTAssertEqual(visible.minY, document.bounds.minY, accuracy: 3, message, file: file, line: line) }
        }
        atBottom("首次打开即显示最新一屏")
        model.lines += (100..<110).map { "Fixture log \($0)" }
        try await settle()
        atBottom("追加记录后跟随到底部")
        func showEarlier() {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? 100 : max(0, document.bounds.height - 360)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        showEarlier()
        model.lines = Array(model.lines.dropFirst()) + ["A new rolling-tail record"]
        try await settle()
        atBottom("行数相同但内容滚动更新时仍然跟随")
        model.following = false
        try await settle()
        showEarlier()
        try await settle()
        let origin = scroll.contentView.bounds.origin.y
        model.lines.append("Record while follow is disabled")
        try await settle()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, origin, accuracy: 1, "暂停跟随后保留阅读位置")
        model.following = true
        try await settle()
        atBottom("重新开启跟随时立即回到最新一屏")
    }
}

@MainActor private final class LogOutputFixture: ObservableObject {
    @Published var lines = (0..<100).map { i in "Fixture log \(i) " + (i % 4 == 0 ? String(repeating: "wrapped diagnostic text ", count: 20) : "") }
    @Published var following = true
}
private struct LogOutputFixtureView: View {
    @ObservedObject var model: LogOutputFixture
    var body: some View { LogOutputView(lines: model.lines, following: model.following) }
}
