import AppKit
import Carbon

@main
@MainActor
enum SplitVPNNativeApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = NativeAppDelegate()
        app.delegate = delegate
        // A Settings-only SwiftUI App opens Settings even on a login launch.
        // AppKit owns launch/window creation; window contents remain SwiftUI.
        withExtendedLifetime(delegate) { app.run() }
    }
}
@MainActor
final class NativeAppDelegate: NSObject, NSApplicationDelegate {
    let runtime = NativeAppRuntime.make()
    private var commands: NativeCommands?
    private var loginLaunch = false
    private var duplicateInstance = false
    func applicationWillFinishLaunching(_ notification: Notification) {
        runtime.preferences.apply()
        NSWindow.allowsAutomaticWindowTabbing = false
        commands = NativeCommands(runtime: runtime)
        commands?.install()
        loginLaunch = NativeLaunchContext.isBackground(NSAppleEventManager.shared().currentAppleEvent)
        #if DEBUG
        if MenuBarPreview.isEnabled { loginLaunch = ProcessInfo.processInfo.arguments.contains("--preview-login-launch") }
        #endif
        if !isPreview && NSWorkspace.shared.runningApplications.contains(where: {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.executableURL?.lastPathComponent == "SplitVPNNative"
        }) {
            duplicateInstance = true
            let alert = NSAlert()
            alert.messageText = "轻舟已在运行"
            alert.informativeText = "请先退出已经打开的轻舟，再打开当前版本（\(NativeBuild.version)）。原有 VPN 和当前外网连接可以保持运行。"
            alert.addButton(withTitle: "知道了")
            alert.runModal()
            NSApp.terminate(nil)
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !duplicateInstance else { return }
        // The launch marker can also arrive after willFinishLaunching.
        let loginEvent = NativeLaunchContext.isBackground(NSAppleEventManager.shared().currentAppleEvent)
        let backgroundLaunch = loginLaunch || loginEvent
        runtime.start(loginLaunch: backgroundLaunch)
        #if DEBUG
        if MenuBarPreview.isEnabled { MenuBarPreview.recordStartup(loginLaunch: backgroundLaunch) }
        #endif
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if runtime.started, !NativeLaunchContext.isBackground(NSAppleEventManager.shared().currentAppleEvent) { runtime.openMain() }
        return false
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !duplicateInstance, runtime.started else { return .terminateNow }
        runtime.requestTermination { sender.reply(toApplicationShouldTerminate: $0) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { runtime.finish() }
    private var isPreview: Bool {
        #if DEBUG
        return MenuBarPreview.isEnabled
        #else
        return false
        #endif
    }
}

enum NativeLaunchContext {
    // LaunchServices puts the launch kind in keyAEPropData, not a Bool parameter.
    static func isBackground(_ event: NSAppleEventDescriptor?) -> Bool {
        guard event?.eventID == AEEventID(kAEOpenApplication),
              let source = event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue else { return false }
        return source == keyAELaunchedAsLogInItem || source == keyAELaunchedAsServiceItem
    }
}

enum NativeBuild {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版" }
}
