import AppKit

/// Menus stay available when every SwiftUI-hosted window is closed.
@MainActor
final class NativeCommands: NSObject, NSMenuItemValidation, NSMenuDelegate {
    private let runtime: NativeAppRuntime
    private var personalItem: NSMenuItem?
    private var quitItem: NSMenuItem?
    init(runtime: NativeAppRuntime) { self.runtime = runtime }

    func install() {
        let root = NSMenu()
        let appMenu = submenu(AppBrand.name, in: root)
        appMenu.delegate = self
        add("关于轻舟", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp, to: appMenu)
        appMenu.addItem(.separator())
        add("设置…", action: #selector(settings), key: ",", to: appMenu)
        appMenu.addItem(.separator())
        let services = submenu("服务", in: appMenu)
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        add("隐藏轻舟", action: #selector(NSApplication.hide(_:)), key: "h", target: NSApp, to: appMenu)
        let hideOthers = add("隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), key: "h", target: NSApp, to: appMenu)
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        add("显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), target: NSApp, to: appMenu)
        appMenu.addItem(.separator())
        quitItem = add("断开连接并退出轻舟", action: #selector(quit), key: "q", to: appMenu)

        let edit = submenu("编辑", in: root)
        add("撤销", action: NSSelectorFromString("undo:"), key: "z", responder: true, to: edit)
        let redo = add("重做", action: NSSelectorFromString("redo:"), key: "z", responder: true, to: edit)
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        add("剪切", action: #selector(NSText.cut(_:)), key: "x", responder: true, to: edit)
        add("拷贝", action: #selector(NSText.copy(_:)), key: "c", responder: true, to: edit)
        add("粘贴", action: #selector(NSText.paste(_:)), key: "v", responder: true, to: edit)
        add("全选", action: #selector(NSText.selectAll(_:)), key: "a", responder: true, to: edit)

        let connection = submenu("连接", in: root)
        connection.delegate = self
        personalItem = add("连接个人 VPN", action: #selector(personal), key: "k", to: connection)
        add("私有网络", action: #selector(company), key: "2", to: connection)
        add("刷新状态", action: #selector(refresh), key: "r", to: connection)
        add("打开主窗口", action: #selector(mainWindow), to: connection)

        let window = submenu("窗口", in: root)
        add("关闭窗口", action: #selector(NSWindow.performClose(_:)), key: "w", responder: true, to: window)
        add("最小化", action: #selector(NSWindow.performMiniaturize(_:)), key: "m", responder: true, to: window)
        add("缩放", action: #selector(NSWindow.performZoom(_:)), responder: true, to: window)
        let fullscreen = add("切换全屏幕", action: #selector(NSWindow.toggleFullScreen(_:)), key: "f", responder: true, to: window)
        fullscreen.keyEquivalentModifierMask = [.command, .control]
        window.addItem(.separator())
        add("全部置于前面", action: #selector(NSApplication.arrangeInFront(_:)), target: NSApp, to: window)
        NSApp.windowsMenu = window
        NSApp.mainMenu = root
        menuNeedsUpdate(appMenu)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        personalItem?.title = runtime.store.running ? "断开个人 VPN" : "连接个人 VPN"
        quitItem?.title = runtime.store.connectionProtected ? "退出轻舟（保留原版连接）" : "断开连接并退出轻舟"
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(personal) {
            return runtime.store.canToggleFromMenu && !runtime.togglingPersonal && !runtime.terminating
        }
        if menuItem.action == #selector(refresh) { return !runtime.terminating && !runtime.store.refreshing }
        if menuItem.action == #selector(quit) { return !runtime.terminating }
        return true
    }
    @objc private func settings() { runtime.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func personal() { runtime.togglePersonal() }
    @objc private func company() { runtime.openMain(page: .company) }
    @objc private func refresh() { runtime.refresh() }
    @objc private func mainWindow() { runtime.openMain() }

    private func submenu(_ title: String, in parent: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu; parent.addItem(item)
        return menu
    }
    @discardableResult
    private func add(_ title: String, action: Selector, key: String = "", target: AnyObject? = nil,
                     responder: Bool = false, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = responder ? nil : (target ?? self)
        menu.addItem(item)
        return item
    }
}
