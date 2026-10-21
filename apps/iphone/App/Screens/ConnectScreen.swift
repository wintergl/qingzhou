import SwiftUI

struct ConnectScreen: View {
    @EnvironmentObject private var appState: SplitVpnAppState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    heroCard
                    overviewGrid
                    readinessCard

                    if let notice = appState.notice {
                        VPNCard {
                            CardHeading(title: "最近提示", systemImage: "info.circle")
                            Text(notice)
                                .font(.subheadline)
                                .foregroundStyle(VPNTheme.secondary)
                        }
                    }

                    if !appState.runtimeStatus.lastError.isEmpty {
                        VPNCard {
                            CardHeading(title: "最近错误", systemImage: "exclamationmark.octagon")
                            Text(appState.runtimeStatus.lastError)
                                .font(.subheadline)
                                .foregroundStyle(VPNTheme.destructive)
                        }
                    }
                }
                .padding(16)
            }
            .background(VPNTheme.background)
            .navigationTitle(AppBrand.name)
            .refreshable {
                await appState.refreshVPNStatus()
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else {
                    return
                }
                await pollVPNStatusWhileVisible()
            }
        }
    }

    private var isActive: Bool {
        appState.runtimeStatus.state == .connected || appState.runtimeStatus.state == .connecting
    }

    private var heroCard: some View {
        VPNCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(statusTitle)
                        .font(.title2.bold())
                        .foregroundStyle(VPNTheme.text)
                    Text(statusDetail)
                        .font(.subheadline)
                        .foregroundStyle(VPNTheme.secondary)
                }
                Spacer(minLength: 8)
                StatusPill(title: statusTitle, color: statusColor)
            }

            Button(primaryButtonTitle) {
                Task {
                    if isActive {
                        await appState.disconnect()
                    } else {
                        await appState.connect()
                    }
                }
            }
            .buttonStyle(VPNButtonStyle(prominent: true, destructive: isActive))
            .disabled(appState.isBusy)
        }
    }

    private var overviewGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            metric("订阅状态", appState.subscription.status, systemImage: "link")
            metric("节点数量", "\(appState.subscription.nodeCount)", systemImage: "point.3.connected.trianglepath.dotted")
            metric("当前节点", appState.settings.selectedProxy, systemImage: "location")
            metric("未知流量", appState.settings.unknownTrafficPolicy == "vpn" ? "未匹配代理" : "默认直连", systemImage: "arrow.triangle.branch")
        }
    }

    private func metric(_ title: String, _ value: String, systemImage: String) -> some View {
        VPNCard {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(VPNTheme.secondary)
            Text(value.isEmpty ? "-" : value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(VPNTheme.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var readinessCard: some View {
        VPNCard {
            CardHeading(title: "真机状态", systemImage: "checkmark.shield")
            ForEach(appState.readinessItems) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: iconName(for: item.severity))
                        .foregroundStyle(color(for: item.severity))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.subheadline)
                            .foregroundStyle(VPNTheme.text)
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(VPNTheme.secondary)
                    }
                }
            }
            Text("TUN \(TunnelAddressing.singBoxTunAddress) · Network Extension + Libbox")
                .font(.caption2)
                .foregroundStyle(VPNTheme.secondary)
        }
    }

    private var statusColor: Color {
        switch appState.runtimeStatus.state {
        case .connected:
            return VPNTheme.green
        case .connecting, .disconnecting:
            return VPNTheme.accent
        case .error:
            return VPNTheme.destructive
        case .disconnected:
            return VPNTheme.secondary
        }
    }

    private var statusTitle: String {
        switch appState.runtimeStatus.state {
        case .connected:
            return "已连接"
        case .connecting:
            return "正在连接"
        case .disconnecting:
            return "正在断开"
        case .error:
            return "连接异常"
        case .disconnected:
            return "未连接"
        }
    }

    private var statusDetail: String {
        switch appState.runtimeStatus.state {
        case .connected:
            return "iOS VPN 已启动，当前节点 \(appState.settings.selectedProxy)"
        case .connecting:
            return "正在请求 iOS 启动 Packet Tunnel"
        case .disconnecting:
            return "正在关闭系统 VPN"
        case .error:
            return appState.runtimeStatus.lastError.isEmpty ? "请查看日志" : appState.runtimeStatus.lastError
        case .disconnected:
            return "点击连接后将安装并启动轻舟 VPN 配置"
        }
    }

    private var primaryButtonTitle: String {
        if appState.isBusy {
            return "处理中..."
        }
        return appState.runtimeStatus.state == .connected || appState.runtimeStatus.state == .connecting ? "断开" : "连接"
    }

    private func iconName(for severity: ReadinessSeverity) -> String {
        switch severity {
        case .ok:
            return "checkmark.circle"
        case .warning:
            return "exclamationmark.triangle"
        case .blocking:
            return "xmark.octagon"
        }
    }

    private func color(for severity: ReadinessSeverity) -> Color {
        switch severity {
        case .ok:
            return VPNTheme.green
        case .warning:
            return VPNTheme.warning
        case .blocking:
            return VPNTheme.destructive
        }
    }

    @MainActor
    private func pollVPNStatusWhileVisible() async {
        while !Task.isCancelled {
            await appState.refreshVPNStatus()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }
}
