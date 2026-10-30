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
            PageHeader(title: "设置", subtitle: "按你的使用习惯，调整外观与连接方式")
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
                StaticExitSettingsView(store: store)
                Section("兼容规则") {
                    Toggle("邮箱大师优先直连", isOn: Binding(get: { store.status?.settings.specialCompatibilityRules.mailMasterDirect ?? true }, set: { store.action("保存兼容设置", channel: "routing:update", payload: ["specialCompatibilityRules": ["mailMasterDirect": $0]]) }))
                    Text("邮箱大师全部连接优先直连，包括海外邮箱；自定义代理和私有网络规则仍优先。关闭后恢复常规分流。")
                        .font(.system(size: 11)).foregroundStyle(VPNTheme.secondary)
                    Toggle("邮箱大师 8081 端口兼容", isOn: Binding(get: { store.status?.settings.specialCompatibilityRules.mailMasterProxy8081 ?? true }, set: { store.action("保存兼容设置", channel: "routing:update", payload: ["specialCompatibilityRules": ["mailMasterProxy8081": $0]]) }))
                    Text("保留 8081 端口的原始连接目标，不决定该连接是否走代理。")
                        .font(.system(size: 11)).foregroundStyle(VPNTheme.secondary)
                    Toggle("微信直连优先与代理回退", isOn: Binding(get: { store.status?.settings.specialCompatibilityRules.wechatImageSendFallback ?? true }, set: { store.action("保存兼容设置", channel: "routing:update", payload: ["specialCompatibilityRules": ["wechatImageSendFallback": $0]]) }))
                    Text("国内连接按直连规则处理；其余微信连接优先直连，直连检测失败后回退到代理。启用静态 ISP 时回退到该出口。自定义分流规则优先。")
                        .font(.system(size: 11)).foregroundStyle(VPNTheme.secondary)
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
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            if store.legacyOwnerRunning {
                Text("当前连接由原版应用维护。").foregroundStyle(VPNTheme.secondary).font(.system(size: 11))
            }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .font(.system(size: 13)).controlSize(.regular).tint(VPNTheme.accent).buttonStyle(VPNButtonStyle())
            .background(VPNTheme.background)
            .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.refreshLoginItem() }
    }
    private func setting(_ title: String, key: String, value: Bool) -> some View {
        Toggle(title, isOn: Binding(get: { value }, set: { store.action("保存网络设置", channel: "native:preferences", payload: [key: $0]) }))
    }
}
