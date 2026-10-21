import AppKit
import SwiftUI

@MainActor
protocol AppWindowRouting: AnyObject {
    func openMain(page: VPNPage?)
    func openSettings()
}

/// Explicit window creation lets a login launch stay silent on macOS 14 too.
/// Each controller is retained after closing, preserving the current page.
@MainActor
final class NativeWindowRouter: AppWindowRouting {
    private let store: VPNStore
    private let company: CompanyStore
    private let preferences: DesktopPreferences
    private let showWindow: @MainActor (NSWindow) -> Void
    private let autosaveFrame: Bool
    var onSettingsRequested: (() -> Void)?
    private(set) var mainWindow: NSWindow?
    private(set) var settingsWindow: NSWindow?

    init(store: VPNStore, company: CompanyStore, preferences: DesktopPreferences,
         autosaveFrame: Bool = true, showWindow: (@MainActor (NSWindow) -> Void)? = nil) {
        self.store = store; self.company = company; self.preferences = preferences
        self.autosaveFrame = autosaveFrame
        self.showWindow = showWindow ?? { window in
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
    func openMain(page: VPNPage? = nil) {
        if let page { store.page = page }
        if mainWindow == nil {
            let root = ContentView(store: store, company: company, onOpenSettings: { [weak self] in
                guard let self else { return }
                if let onSettingsRequested { onSettingsRequested() } else { openSettings() }
            })
                .defaultAppStorage(preferences.defaults)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = AppBrand.name
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 1120, height: 760)
            window.setContentSize(NSSize(width: 1320, height: 900))
            window.center()
            if autosaveFrame { window.setFrameAutosaveName("Qingzhou.workspace") }
            mainWindow = window
        }
        reveal(mainWindow)
    }
    func openSettings() {
        if settingsWindow == nil {
            let root = SettingsView(store: store, desktop: preferences).defaultAppStorage(preferences.defaults)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "轻舟设置"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 640, height: 680))
            window.center()
            settingsWindow = window
        }
        reveal(settingsWindow)
    }
    private func reveal(_ window: NSWindow?) {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        showWindow(window)
    }
}
