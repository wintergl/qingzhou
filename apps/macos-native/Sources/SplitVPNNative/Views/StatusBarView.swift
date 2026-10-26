import SwiftUI

struct StatusBarView: View {
    @ObservedObject var runtime: NativeAppRuntime
    @ObservedObject var store: VPNStore
    @ObservedObject var company: CompanyStore
    @AppStorage("previewAppearance") private var appearance = "light"
    init(runtime: NativeAppRuntime) {
        self.runtime = runtime; store = runtime.store; company = runtime.company
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("轻舟", systemImage: "sailboat").font(.system(size: 17, weight: .semibold))
                Spacer()
                if runtime.terminating { ProgressView().controlSize(.small); Text("正在退出").font(.caption) }
            }
            VStack(alignment: .leading, spacing: 10) {
                status("个人 VPN", text: store.menuTitle, state: store.menuState)
                MihomoUptimeView(store: store)
                NetworkRecoveryView(store: store, compact: true)
                HStack(spacing: 8) {
                    Text("模式").foregroundStyle(.secondary)
                    Spacer()
                    Text(store.modeTitle)
                }.font(.system(size: 12))
                HStack(alignment: .top, spacing: 8) {
                    Text("节点").foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(store.displaySelectedProxy).lineLimit(2).multilineTextAlignment(.trailing).help(store.displaySelectedProxy)
                }.font(.system(size: 12))
                Button(action: runtime.togglePersonal) {
                    Text(store.canDisconnect ? "断开个人 VPN" : store.connectionOperation != nil || runtime.togglingPersonal ? "正在处理…" : "连接个人 VPN")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(VPNButtonStyle(prominent: true))
                    .disabled(!store.canToggleFromMenu || (runtime.togglingPersonal && !store.canDisconnect) || runtime.terminating)
                if let reason = store.menuRestriction { Text(reason).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if store.connectionServiceUpdateRequired {
                    Button("更新连接服务", action: store.updateConnectionService).disabled(!store.canMutate)
                } else if store.status?.mihomo.networkRecovery?.state == "failed" {
                    Button("重试网络恢复") { store.action("重试网络恢复", channel: "vpn:retry-recovery") }.disabled(!store.canMutate)
                }
                if let error = personalError { errorRow(error) { runtime.openMain(page: .diagnostics) } }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                status("私有网络", text: company.statusText, state: company.menuState)
                Text(company.takeoverEnabled ? "授权资源走私有网络分流" : "资源接管已关闭")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button(action: runtime.toggleCompany) {
                    Text(company.working || company.quickPreparing ? "正在处理…" : company.connectionEnabled ? "断开私有网络" : "连接私有网络")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(VPNButtonStyle()).disabled(!company.canToggleFromMenu || runtime.terminating)
                if company.quickConnectionID != nil, !company.working, !company.quickPreparing {
                    Button("完成私有网络认证后继续连接") { runtime.openMain(page: .company) }.font(.system(size: 12))
                }
                if let error = company.errorMessage { errorRow(error, detail: runtime.openCompanyDetails) }
            }
            Divider()
            HStack {
                Button("打开主窗口", action: { runtime.openMain() })
                Spacer()
                Button(action: runtime.openSettings) { Label("设置", systemImage: "gearshape") }
            }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(VPNTheme.accent)
        }.padding(18).frame(width: 360).fixedSize(horizontal: false, vertical: true)
            .font(.system(size: 13)).tint(VPNTheme.accent)
            .background(VPNTheme.surface)
            .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
    }
    private var personalError: String? {
        if case .unavailable(let reason) = store.core.availability { return reason }
        if store.menuState == .error { return store.networkRecoveryError ?? store.status?.mihomo.lastError ?? "请打开详情检查连接。" }
        return store.error
    }
    private func status(_ name: String, text: String, state: VPNMenuState) -> some View {
        HStack(alignment: .top) {
            Text(name).fontWeight(.semibold)
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Circle().fill(stateColor(state)).frame(width: 6, height: 6)
                Text(text).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.trailing)
            }
        }
    }
    private func stateColor(_ state: VPNMenuState) -> Color {
        switch state {
        case .connected: return VPNTheme.green
        case .connecting, .disconnecting: return VPNTheme.accent
        case .error: return VPNTheme.warning
        default: return .secondary
        }
    }
    private func errorRow(_ reason: String, detail: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(reason).font(.system(size: 11)).foregroundStyle(VPNTheme.warning).lineLimit(2).help(reason)
            Spacer(minLength: 0)
            Button("详情", action: detail).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(VPNTheme.accent)
        }
    }
}
