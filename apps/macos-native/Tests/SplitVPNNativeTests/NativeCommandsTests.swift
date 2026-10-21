import AppKit
import XCTest
@testable import SplitVPNNative

final class NativeCommandsTests: XCTestCase {
    @MainActor func testShortcutsRouteThroughTheSharedRuntimeWithoutCreatingAnotherWindowOwner() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let f = try MenuBarFixture(); defer { f.close() }
        let previous = (NSApp.mainMenu, NSApp.servicesMenu, NSApp.windowsMenu)
        defer { NSApp.mainMenu = previous.0; NSApp.servicesMenu = previous.1; NSApp.windowsMenu = previous.2 }
        let commands = NativeCommands(runtime: f.runtime)
        commands.install()
        let menus = try XCTUnwrap(NSApp.mainMenu).items.compactMap(\.submenu)
        let items = menus.flatMap(\.items)
        let settings = try XCTUnwrap(items.first { $0.keyEquivalent == "," })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(settings.action), to: settings.target, from: settings))
        XCTAssertEqual(f.windows.settingsCalls, 1)
        let company = try XCTUnwrap(items.first { $0.keyEquivalent == "2" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(company.action), to: company.target, from: company))
        XCTAssertEqual(f.windows.pages.last!, .company)
        XCTAssertEqual(items.first { $0.keyEquivalent == "q" }?.keyEquivalentModifierMask, .command)
        XCTAssertNil(items.first { $0.keyEquivalent == "c" }?.target, "文本编辑仍通过响应链处理")
        XCTAssertTrue(f.coreModel.channels.isEmpty); XCTAssertTrue(f.helper.commands.isEmpty)
    }

    @MainActor func testNativePersonalShortcutUsesUnknownLegacyAndTerminationGuards() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let f = try MenuBarFixture(); defer { f.close() }
        let previous = (NSApp.mainMenu, NSApp.servicesMenu, NSApp.windowsMenu)
        defer { NSApp.mainMenu = previous.0; NSApp.servicesMenu = previous.1; NSApp.windowsMenu = previous.2 }
        let commands = NativeCommands(runtime: f.runtime)
        commands.install()
        let items = try XCTUnwrap(NSApp.mainMenu).items.compactMap(\.submenu).flatMap(\.items)
        let personal = try XCTUnwrap(items.first { $0.keyEquivalent == "k" })
        let quit = try XCTUnwrap(items.first { $0.keyEquivalent == "q" })
        XCTAssertFalse(commands.validateMenuItem(personal))
        await f.store.refresh()
        XCTAssertTrue(commands.validateMenuItem(personal))
        f.coreModel.running = true; f.coreModel.legacy = true; f.coreModel.owns = false
        await f.store.refresh()
        commands.menuNeedsUpdate(try XCTUnwrap(NSApp.mainMenu))
        XCTAssertFalse(commands.validateMenuItem(personal))
        XCTAssertTrue(quit.title.contains("保留原版连接"))
        var replied = false
        f.runtime.requestTermination { _ in replied = true }
        XCTAssertFalse(commands.validateMenuItem(quit))
        await menuWait { replied }
        XCTAssertFalse(f.coreModel.channels.contains("vpn:stop"))
    }
}
