import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: VPNStore
    @ObservedObject var desktop: DesktopPreferences
    @AppStorage("previewAppearance") private var appearance = "light"
    init(store: VPNStore, desktop: DesktopPreferences? = nil) {
        self.store = store; self.desktop = desktop ?? DesktopPreferences()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "设置", subtitle: "沿用现有配置，网络调整经校验后在线应用")
            Form {
                Section("界面外观") {
                    Picker("显示模式", selection: $appearance) {
                        Text("浅色").tag("light"); Text("深色").tag("dark"); Text("跟随系统").tag("system")
                    }.pickerStyle(.segmented)
                }
                Section("网络") {
                    setting("TUN 系统分流", key: "tun", value: store.status?.settings.tun ?? true)
                    setting("IPv6", key: "ipv6", value: store.status?.settings.ipv6 ?? false)
                    setting("局域网直连", key: "lanDirect", value: store.status?.settings.lanDirect ?? true)
                    setting("Tailscale 直连", key: "tailscaleDirect", value: store.status?.settings.tailscaleDirect ?? true)
                }.disabled(!store.canMutate)
                Section("兼容规则") {
                    Toggle("网易邮箱大师代理 8081", isOn: Binding(get: { store.status?.settings.specialCompatibilityRules.mailMasterProxy8081 ?? true }, set: { store.action("保存兼容设置", channel: "routing:update", payload: ["specialCompatibilityRules": ["mailMasterProxy8081": $0]]) }))
                    Toggle("微信图片发送回退", isOn: Binding(get: { store.status?.settings.specialCompatibilityRules.wechatImageSendFallback ?? true }, set: { store.action("保存兼容设置", channel: "routing:update", payload: ["specialCompatibilityRules": ["wechatImageSendFallback": $0]]) }))
                }.disabled(!store.canMutate)
                Section("启动与数据") {
                    Toggle("在 Dock 中显示轻舟", isOn: $desktop.showDockIcon)
                        .disabled(store.terminating)
                    Text("关闭窗口后，轻舟继续在菜单栏运行。").foregroundStyle(VPNTheme.secondary)
                    Toggle("登录 Mac 后启动", isOn: Binding(get: { store.loginItemState.requested }, set: { store.setLaunchAtLogin($0) })).disabled(!store.canMutate)
                    Text(store.loginItemState.detail).foregroundStyle(VPNTheme.secondary)
                    if store.loginItemState == .requiresApproval || store.loginItemState == .needsRepair {
                        Button("打开系统登录项设置") { store.openLoginItemSettings() }
                    }
                    Text("继续使用已有的订阅、节点、组、规则与缓存。").foregroundStyle(VPNTheme.secondary)
                    Button("重新读取当前配置") { Task { await store.refresh() } }
                }
            }.formStyle(.grouped)
            Text("原版应用保持运行；当前由原版维护的连接不会被新版强制停止。").foregroundStyle(VPNTheme.secondary).font(.system(size: 13))
        }.padding(28).frame(width: 640, height: 680)
            .font(.system(size: 15)).controlSize(.large).tint(VPNTheme.accent).buttonStyle(VPNButtonStyle())
            .background(VPNTheme.background)
            .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.refreshLoginItem() }
    }
    private func setting(_ title: String, key: String, value: Bool) -> some View {
        Toggle(title, isOn: Binding(get: { value }, set: { store.action("保存网络设置", channel: "native:preferences", payload: [key: $0]) }))
    }
}
