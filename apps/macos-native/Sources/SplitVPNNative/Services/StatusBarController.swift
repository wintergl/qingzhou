import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private weak var runtime: NativeAppRuntime?
    private let item = NSStatusBar.system.statusItem(withLength: 28)
    private let popover = NSPopover()
    private var observations: Set<AnyCancellable> = []
    private var updateScheduled = false
    private var renderedState: StatusBarIconState?
    private var renderedAppearance: NSAppearance.Name?
    private var appearanceObservation: NSKeyValueObservation?
    private var panelClosedByStatusPress = false
    private lazy var clicks = StatusItemClickHandler(single: { [weak self] wasVisible in
        guard let self else { return }
        if wasVisible || self.popover.isShown { self.dismiss() } else { self.showPanel() }
    }, double: { [weak self] in
        self?.dismiss(); self?.runtime?.togglePersonal()
    }, secondary: { [weak self] in self?.showMenu() })

    init(runtime: NativeAppRuntime) {
        self.runtime = runtime
        super.init()
        let host = NSHostingController(rootView: StatusBarView(runtime: runtime).defaultAppStorage(runtime.preferences.defaults))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        if let button = item.button {
            button.target = self; button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseDown, .leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("轻舟 VPN")
            appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.scheduleUpdate() }
            }
        }
        for publisher in [runtime.objectWillChange, runtime.store.objectWillChange, runtime.company.objectWillChange, runtime.preferences.objectWillChange] {
            publisher.sink { [weak self] _ in
                DispatchQueue.main.async { self?.scheduleUpdate() }
            }.store(in: &observations)
        }
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.scheduleUpdate() } }.store(in: &observations)
        update()
    }
    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .leftMouseDown {
            clicks.pressed(panelVisible: popover.isShown || panelClosedByStatusPress)
            panelClosedByStatusPress = false
            return
        }
        clicks.released(clickCount: event.clickCount, isSecondary: event.type == .rightMouseUp || event.modifierFlags.contains(.control))
        panelClosedByStatusPress = false
    }
    private func showPanel() {
        guard let button = item.button, runtime?.terminating != true else { return }
        resizePanel()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        updateAppearance()
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }
    func dismiss() { popover.performClose(nil) }
    func cancelInteractions() { clicks.cancel(); panelClosedByStatusPress = false; dismiss() }
    func remove() {
        cancelInteractions(); observations.removeAll(); appearanceObservation?.invalidate()
        appearanceObservation = nil
        NSStatusBar.system.removeStatusItem(item)
    }
    private func update() {
        guard let runtime, let button = item.button else { return }
        let state = StatusBarIconState(store: runtime.store, company: runtime.company)
        let appearance = button.effectiveAppearance
        if renderedState != state || renderedAppearance != appearance.name {
            button.image = Self.icon(for: state, appearance: appearance)
            renderedState = state; renderedAppearance = appearance.name
        }
        let status = "个人：\(runtime.store.menuTitle)\n私有网络：\(runtime.company.statusText)"
        button.toolTip = "\(status)\n蓝帆：个人已连接 · 绿船：私有网络已连接\n单击打开面板 · 双击切换个人 VPN · 右键打开菜单"
        button.setAccessibilityValue(status)
        if popover.isShown { resizePanel(); updateAppearance() }
    }
    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.updateScheduled = false; self?.update()
        }
    }
    func popoverWillClose(_ notification: Notification) {
        // Transient popovers may dismiss before the status button receives down.
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown,
              let button = item.button, let window = button.window else { return }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        panelClosedByStatusPress = frame.contains(point)
    }
    private func resizePanel() {
        guard let view = popover.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let height = max(260, view.fittingSize.height)
        popover.contentSize = NSSize(width: 360, height: height)
    }
    private func updateAppearance() {
        let choice = runtime?.preferences.defaults.string(forKey: "previewAppearance") ?? "light"
        popover.contentViewController?.view.window?.appearance = choice == "system" ? nil : NSAppearance(named: choice == "dark" ? .darkAqua : .aqua)
    }
    private enum Action: Int { case main = 1, personal, company, refresh, connectivity, settings, dock, quit }
    private func showMenu() {
        dismiss()
        guard let runtime, let button = item.button else { return }
        let store = runtime.store, company = runtime.company
        let menu = NSMenu(); menu.autoenablesItems = false
        func info(_ title: String) { let row = NSMenuItem(title: title, action: nil, keyEquivalent: ""); row.isEnabled = false; menu.addItem(row) }
        func action(_ title: String, _ command: Action, enabled: Bool = true) -> NSMenuItem {
            let row = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            row.target = self; row.tag = command.rawValue; row.isEnabled = enabled
            menu.addItem(row); return row
        }
        info("个人：\(store.menuTitle)")
        info("模式：\(store.modeTitle)")
        let node = store.displaySelectedProxy
        let nodeItem = NSMenuItem(title: "节点：\(String(node.prefix(42)))\(node.count > 42 ? "…" : "")", action: nil, keyEquivalent: "")
        nodeItem.isEnabled = false; nodeItem.toolTip = node; menu.addItem(nodeItem)
        info("私有网络：\(company.statusText)")
        menu.addItem(.separator())
        _ = action("打开主窗口", .main)
        _ = action(store.running ? "断开个人 VPN" : "连接个人 VPN", .personal,
                   enabled: store.canToggleFromMenu && (!runtime.togglingPersonal || store.canDisconnect) && !runtime.terminating)
        if let reason = store.menuRestriction { info(reason) }
        _ = action(company.connectionEnabled ? "断开私有网络" : "连接私有网络", .company,
                   enabled: company.canToggleFromMenu && !runtime.terminating)
        menu.addItem(.separator())
        _ = action("刷新状态", .refresh, enabled: !runtime.terminating && !store.refreshing)
        _ = action("检测连通性", .connectivity, enabled: !runtime.terminating && store.busy == nil)
        _ = action("设置…", .settings)
        let dock = action("在 Dock 中显示轻舟", .dock, enabled: !runtime.terminating)
        dock.state = runtime.preferences.showDockIcon ? .on : .off
        menu.addItem(.separator())
        if store.connectionProtected { info("原版维护的个人连接会保留") }
        _ = action(runtime.terminating ? "正在断开连接并退出…" : "断开连接并退出轻舟", .quit, enabled: !runtime.terminating)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }
    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let runtime, let action = Action(rawValue: sender.tag) else { return }
        switch action {
        case .main: runtime.openMain()
        case .personal: runtime.togglePersonal()
        case .company: runtime.toggleCompany()
        case .refresh: runtime.refresh()
        case .connectivity: runtime.checkConnectivity()
        case .settings: runtime.openSettings()
        case .dock: runtime.preferences.showDockIcon.toggle()
        case .quit: NSApp.terminate(nil)
        }
    }
    static func icon(for state: StatusBarIconState, appearance: NSAppearance) -> NSImage {
        var foreground = NSColor.labelColor
        var sailColor = NSColor.systemBlue
        var hullColor = NSColor.systemGreen
        appearance.performAsCurrentDrawingAppearance {
            foreground = foreground.usingColorSpace(.deviceRGB) ?? foreground
            sailColor = sailColor.usingColorSpace(.deviceRGB) ?? sailColor
            hullColor = hullColor.usingColorSpace(.deviceRGB) ?? hullColor
        }
        let image = NSImage(size: NSSize(width: 26, height: 20), flipped: false) { _ in
            let mast = NSBezierPath()
            mast.move(to: NSPoint(x: 10.6, y: 5.8)); mast.line(to: NSPoint(x: 10.6, y: 18.5))
            mast.lineWidth = 1.1; mast.lineCapStyle = .round
            foreground.setStroke(); mast.stroke()

            let sails = NSBezierPath()
            sails.move(to: NSPoint(x: 8.7, y: 18))
            sails.line(to: NSPoint(x: 8.7, y: 7.8)); sails.line(to: NSPoint(x: 1.8, y: 7.8)); sails.close()
            sails.move(to: NSPoint(x: 12.5, y: 15.8))
            sails.line(to: NSPoint(x: 19.6, y: 7.8)); sails.line(to: NSPoint(x: 12.5, y: 7.8)); sails.close()
            sails.lineWidth = 1.1; sails.lineJoinStyle = .round
            if state.personalConnected { sailColor.setFill(); sails.fill(); sailColor.setStroke() }
            else { foreground.setStroke() }
            sails.stroke()

            let hull = NSBezierPath()
            hull.move(to: NSPoint(x: 1.5, y: 5.8)); hull.line(to: NSPoint(x: 21, y: 5.8))
            hull.curve(to: NSPoint(x: 17.5, y: 1.8), controlPoint1: NSPoint(x: 20.5, y: 3.8), controlPoint2: NSPoint(x: 19.4, y: 1.8))
            hull.line(to: NSPoint(x: 6, y: 1.8))
            hull.curve(to: NSPoint(x: 1.5, y: 5.8), controlPoint1: NSPoint(x: 4.2, y: 1.8), controlPoint2: NSPoint(x: 2.5, y: 3.8))
            hull.close()
            (state.companyConnected ? hullColor : foreground).setFill(); hull.fill()

            // Settled connections use component colours; badges show changes
            // and states that need attention without covering the whole boat.
            if let badge = state.personal.badge, let context = NSGraphicsContext.current?.cgContext {
                let frame = CGRect(x: 17, y: 0, width: 9, height: 9)
                context.setBlendMode(.clear); context.fillEllipse(in: frame.insetBy(dx: -0.8, dy: -0.8))
                context.setBlendMode(.normal); context.setFillColor(foreground.cgColor); context.fillEllipse(in: frame)
                NSImage(systemSymbolName: badge, accessibilityDescription: nil)?
                    .draw(in: NSRect(x: 18.5, y: 1.5, width: 6, height: 6), from: .zero, operation: .destinationOut, fraction: 1)
                context.setBlendMode(.normal)
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
