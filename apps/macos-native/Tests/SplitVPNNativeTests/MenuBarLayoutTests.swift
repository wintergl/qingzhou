import AppKit
import SwiftUI
import XCTest
@testable import SplitVPNNative

final class MenuBarLayoutTests: XCTestCase {
    @MainActor func testPanelFits360PointsInBothThemesAndAdjustsForErrors() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let f = try MenuBarFixture(); defer { f.close() }
        f.coreModel.running = true
        f.coreModel.processStartedAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-8280))
        f.coreModel.networkState = "ready"
        f.coreModel.networkHistory = [.object([
            "id": .number(1), "startedAt": .string("2026-10-13T12:00:00Z"),
            "finishedAt": .string("2026-10-13T12:00:05Z"), "durationMs": .number(5000),
            "reason": .string("network-change"), "outcome": .string("verified"), "attempts": .number(0)
        ])]
        await f.store.refresh()
        let destination = ProcessInfo.processInfo.environment["SPLITVPN_MENU_LAYOUT_OUTPUT"]
        if let destination { try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true) }
        var heights: [CGFloat] = []
        for scheme in [ColorScheme.light, .dark] {
            for hasError in [false, true] {
                f.preferences.defaults.set(scheme == .dark ? "dark" : "light", forKey: "previewAppearance")
                f.store.error = hasError ? "连接未完成，请检查节点后重试。完整原因可以在详情中查看。" : nil
                let host = NSHostingView(rootView: StatusBarView(runtime: f.runtime).defaultAppStorage(f.defaults).preferredColorScheme(scheme))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(60))
                let size = host.fittingSize
                XCTAssertEqual(size.width, 360, accuracy: 0.5)
                XCTAssertGreaterThan(size.height, 260); XCTAssertLessThan(size.height, 650)
                heights.append(size.height)
                window.setContentSize(size); host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                if let destination {
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    let name = "panel-\(scheme == .dark ? "dark" : "light")\(hasError ? "-error" : "").png"
                    try png.write(to: URL(fileURLWithPath: destination).appendingPathComponent(name))
                }
                window.close()
            }
        }
        XCTAssertGreaterThan(heights[1], heights[0]); XCTAssertGreaterThan(heights[3], heights[2])
        XCTAssertTrue(f.coreModel.channels.allSatisfy { $0 == "native:bootstrap" })
        XCTAssertTrue(f.helper.commands.isEmpty)
    }
    @MainActor func testNativeRouterReusesClosedWindowsAndKeepsCurrentPageAndDockChoice() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let f = try MenuBarFixture(); defer { f.close() }
        var shown: [NSWindow] = []
        let router = NativeWindowRouter(store: f.store, company: f.company, preferences: f.preferences, autosaveFrame: false, showWindow: { shown.append($0) })
        f.preferences.showDockIcon = false
        router.openMain(page: .nodes)
        let original = try XCTUnwrap(router.mainWindow)
        XCTAssertEqual(f.store.page, .nodes)
        original.close(); router.openMain()
        XCTAssertTrue(router.mainWindow === original); XCTAssertEqual(f.store.page, .nodes)
        router.openSettings()
        let settings = try XCTUnwrap(router.settingsWindow)
        settings.close(); router.openSettings()
        XCTAssertTrue(router.settingsWindow === settings)
        XCTAssertFalse(f.preferences.showDockIcon)
        XCTAssertEqual(shown.count, 4)
        original.close(); settings.close()
        XCTAssertTrue(f.coreModel.channels.isEmpty); XCTAssertTrue(f.helper.commands.isEmpty)
    }
    @MainActor func testSharedCoreEventsContinueUpdatingAfterWindowCloses() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let f = try MenuBarFixture(); defer { f.close() }
        f.runtime.start(loginLaunch: true, installStatusBar: false)
        await menuWait { f.coreModel.channels.filter { $0 == "native:bootstrap" }.count == 2 && f.store.busy == nil }
        let router = NativeWindowRouter(store: f.store, company: f.company, preferences: f.preferences, autosaveFrame: false, showWindow: { _ in })
        router.openMain(page: .nodes)
        router.mainWindow?.close()
        f.coreModel.running = true; f.coreModel.companyActive = true
        f.core.onEvent?("vpn:status", f.coreModel.state)
        f.core.onEvent?("company:routing-state", f.coreModel.routing)
        XCTAssertEqual(f.store.menuState, .connected)
        XCTAssertTrue(f.company.connectionReady); XCTAssertEqual(f.company.menuState, .connected)
        XCTAssertEqual(f.store.page, .nodes)
        XCTAssertFalse(router.mainWindow?.isVisible ?? true)
    }
    @MainActor func testMenuIconsColourSailsAndHullIndependentlyInBothAppearances() throws {
        let settled = [
            StatusBarIconState(personal: .disconnected, personalConnected: false, companyConnected: false),
            StatusBarIconState(personal: .connected, personalConnected: true, companyConnected: false),
            StatusBarIconState(personal: .disconnected, personalConnected: false, companyConnected: true),
            StatusBarIconState(personal: .connected, personalConnected: true, companyConnected: true)
        ]
        var unconnectedPixels: [Data] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let bitmaps = try settled.map { state in
                let image = StatusBarController.icon(for: state, appearance: appearance)
                XCTAssertFalse(image.isTemplate); XCTAssertEqual(image.size, NSSize(width: 26, height: 20))
                return try rasterize(image)
            }
            let sails = bitmaps.map { pixels($0, x: 2..<42, y: 0..<27) }
            let hulls = bitmaps.map { pixels($0, x: 3..<40, y: 29..<38) }
            XCTAssertEqual(sails[0], sails[2]); XCTAssertEqual(sails[1], sails[3])
            XCTAssertNotEqual(sails[0], sails[1])
            XCTAssertEqual(hulls[0], hulls[1]); XCTAssertEqual(hulls[2], hulls[3])
            XCTAssertNotEqual(hulls[0], hulls[2])
            let sail = try XCTUnwrap(bitmaps[1].colorAt(x: 12, y: 16)?.usingColorSpace(.deviceRGB))
            let hull = try XCTUnwrap(bitmaps[2].colorAt(x: 24, y: 32)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(sail.blueComponent, sail.redComponent + 0.2)
            XCTAssertGreaterThan(hull.greenComponent, hull.redComponent + 0.2)
            var marks: [Data] = [try XCTUnwrap(bitmaps[0].tiffRepresentation), try XCTUnwrap(bitmaps[1].tiffRepresentation)]
            for state in [VPNMenuState.connecting, .error, .unknown] {
                let icon = StatusBarIconState(personal: state, personalConnected: false, companyConnected: false)
                marks.append(try XCTUnwrap(rasterize(StatusBarController.icon(for: icon, appearance: appearance)).tiffRepresentation))
            }
            XCTAssertEqual(Set(marks).count, 5)
            unconnectedPixels.append(try XCTUnwrap(bitmaps[0].tiffRepresentation))
        }
        XCTAssertNotEqual(unconnectedPixels[0], unconnectedPixels[1])
        if let destination = ProcessInfo.processInfo.environment["SPLITVPN_MENU_LAYOUT_OUTPUT"] {
            try writeIconPreview(to: URL(fileURLWithPath: destination))
        }
    }
    @MainActor private func rasterize(_ image: NSImage) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * 2),
            pixelsHigh: Int(image.size.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context; context.cgContext.scaleBy(x: 2, y: 2)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        bitmap.size = image.size
        return bitmap
    }
    private func pixels(_ bitmap: NSBitmapImageRep, x: Range<Int>, y: Range<Int>) -> Data {
        var bytes = Data()
        for row in y {
            for column in x {
                guard let color = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB) else { continue }
                bytes.append(contentsOf: [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
                    .map { UInt8(max(0, min(255, ($0 * 255).rounded()))) })
            }
        }
        return bytes
    }
    @MainActor private func writeIconPreview(to directory: URL) throws {
        let samples: [(String, StatusBarIconState)] = [
            ("均未连接", .init(personal: .disconnected, personalConnected: false, companyConnected: false)),
            ("个人已连接", .init(personal: .connected, personalConnected: true, companyConnected: false)),
            ("私有网络已连接", .init(personal: .disconnected, personalConnected: false, companyConnected: true)),
            ("同时连接", .init(personal: .connected, personalConnected: true, companyConnected: true)),
            ("切换中", .init(personal: .connecting, personalConnected: false, companyConnected: false)),
            ("连接异常", .init(personal: .error, personalConnected: false, companyConnected: false)),
            ("状态未知", .init(personal: .unknown, personalConnected: false, companyConnected: false))
        ]
        let appearances = try [NSAppearance.Name.aqua, .darkAqua].map { try XCTUnwrap(NSAppearance(named: $0)) }
        let preview = NSImage(size: NSSize(width: 704, height: 304), flipped: false) { _ in
            for (row, appearance) in appearances.enumerated() {
                let base = CGFloat(1 - row) * 152
                NSColor(calibratedWhite: row == 0 ? 0.94 : 0.12, alpha: 1).setFill()
                NSRect(x: 0, y: base, width: 704, height: 152).fill()
                appearance.performAsCurrentDrawingAppearance {
                    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
                    let title = NSAttributedString(string: row == 0 ? "浅色菜单栏" : "深色菜单栏", attributes: attributes)
                    title.draw(at: NSPoint(x: 16, y: base + 130))
                    for (column, sample) in samples.enumerated() {
                        let x = CGFloat(column) * 96 + 16
                        let icon = StatusBarController.icon(for: sample.1, appearance: appearance)
                        icon.draw(in: NSRect(x: x + 9, y: base + 58, width: 78, height: 60))
                        icon.draw(in: NSRect(x: x + 35, y: base + 30, width: 26, height: 20))
                        let label = NSAttributedString(string: sample.0, attributes: attributes)
                        label.draw(at: NSPoint(x: x + (96 - label.size().width) / 2, y: base + 9))
                    }
                }
            }
            return true
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rasterize(preview).representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("status-icons.png"))
    }
}
