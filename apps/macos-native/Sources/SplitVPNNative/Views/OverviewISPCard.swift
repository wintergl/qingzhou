import SwiftUI

struct OverviewISPCard: View {
    @ObservedObject var store: VPNStore
    var showsRouteLink = true
    var showsSwitchStatus = true
    @State private var modal: Modal?
    private enum Modal: String, Identifiable {
        case configure
        var id: String { rawValue }
    }
    private var configuration: StaticExitConfiguration { store.status?.settings.staticExit ?? StaticExitConfiguration() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { identity; actions }
                VStack(alignment: .leading, spacing: 12) { identity; actions }
            }.detailCard(padding: 14).accessibilityIdentifier("isp-top-configuration")
            if showsSwitchStatus, let use = store.chainUse {
                ChainUseStatusView(state: use, cancel: { Task { await store.cancelChainUse() } }, refresh: { Task { await store.refreshChainUse() } },
                    retry: { Task { await store.retryChainUse() } }, dismiss: store.dismissChainUse)
            }
        }
            .sheet(item: $modal) { selection in
                switch selection {
                case .configure: StaticExitConfigurationSheet(store: store)
                }
            }
    }
    private var identity: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 20)).foregroundStyle(VPNTheme.accent)
                .frame(width: 38, height: 38).background(VPNTheme.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 5) {
                Text(store.status == nil ? "正在读取代理出口…" : configuration.enabled ? "机场 → ISP 出口" : store.selectedProxy == "DIRECT" ? "本机直连" : "机场直接出口")
                    .font(.system(size: 15, weight: .semibold))
                Text(configuration.configured ? configuration.enabled && store.running ? "当前前置：\(store.selectedProxy)" : "ISP 已配置 · 连接前可选择备用线路" : "先配置 ISP，再选择连接线路")
                    .font(.system(size: 11)).foregroundStyle(VPNTheme.secondary)
                    .lineLimit(1)
                if let activity = store.chainActivity, activity.running {
                    Text(activity.mode == "continuous" ? "持续测试在后台运行 · 累计 \(activity.completed) 次" : "链路测试在后台运行 · \(activity.completed) / \(activity.total)")
                        .font(.system(size: 10)).foregroundStyle(VPNTheme.accent)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var actions: some View {
        HStack(spacing: 10) {
            Toggle("走 ISP", isOn: Binding(get: { configuration.enabled }, set: { enabled in
                if enabled && !configuration.configured { modal = .configure }
                else { store.setStaticExitEnabled(enabled) }
            })).toggleStyle(.switch).disabled(!store.canMutate)
            Button(configuration.configured ? "ISP 配置" : "配置 ISP") { modal = .configure }.disabled(!store.canMutate)
                .accessibilityIdentifier("isp-open-configuration")
            if showsRouteLink { Button("备用线路") { store.page = .ispTest }.accessibilityIdentifier("isp-open-backups") }
        }.fixedSize(horizontal: true, vertical: false)
    }

}

struct StaticExitConfigurationSheet: View {
    @ObservedObject var store: VPNStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("ISP 出口配置").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }
            }.padding(.horizontal, 24).padding(.top, 20)
            Form { StaticExitSettingsView(store: store) }.formStyle(.grouped)
        }.frame(minWidth: 620, idealWidth: 650, maxWidth: .infinity, minHeight: 600, idealHeight: 700, maxHeight: .infinity)
            .background(VPNTheme.background).foregroundStyle(VPNTheme.text).tint(VPNTheme.accent)
    }
}
