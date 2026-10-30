import SwiftUI

struct ConnectScreen: View {
    @EnvironmentObject private var appState: SplitVpnAppState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    heroCard
                    overviewGrid
                    networkCheckCard
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
                .padding(20)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .background(VPNTheme.background)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle(AppBrand.name)
            .refreshable {
                await appState.refreshVPNStatus()
            }

        }
    }

    private var networkCheckCard: some View {
        VPNCard {
            CardHeading(title: "连接与站点检测", systemImage: "network")
            if appState.mobileDiagnosticsRunning { ProgressView("检测中…") }
            let result = appState.mobileConnectivity
            LabeledContent("代理出口", value: (result["proxyOk"] as? Bool).map { $0 ? "正常" : "未通过" } ?? "尚未检测")
            LabeledContent("实际出口 IP", value: result["externalIp"] as? String ?? "尚未读取")
            ForEach(Array(appState.mobileWebsites.enumerated()), id: \.offset) { _, row in
                LabeledContent(row["label"] as? String ?? "站点", value: row["ok"] as? Bool == true ? "\(String(describing: row["delay"] ?? "—")) ms" : "受限或未连通")
            }
            NavigationLink("查看 DNS、站点与出口风险") { MobileDiagnosticsScreen() }
        }
    }

    private var isActive: Bool {
        appState.runtimeStatus.state == .connected || appState.runtimeStatus.state == .connecting
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                Text("连接概览").tracking(2)
                Spacer()
                Image(systemName: "sailboat").font(.title2)
            }.font(.caption.weight(.medium)).foregroundStyle(VPNTheme.heroMuted)
            VStack(alignment: .leading, spacing: 10) {
                Text(statusTitle).font(.largeTitle.weight(.medium)).tracking(-0.8)
                    .foregroundStyle(VPNTheme.heroText)
                Text(statusDetail).font(.subheadline).foregroundStyle(VPNTheme.heroMuted)
                    .fixedSize(horizontal: false, vertical: true)
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
            .buttonStyle(VPNButtonStyle(prominent: !isActive))
            .disabled(appState.isBusy && !isActive)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(VPNTheme.heroInk.gradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var overviewGrid: some View {
        LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            metric("订阅状态", subscriptionStatusTitle(appState.subscription.status), systemImage: "link")
            metric("节点数量", "\(appState.subscription.nodeCount)", systemImage: "point.3.connected.trianglepath.dotted")
            metric("当前节点", appState.settings.selectedProxy, systemImage: "location")
            metric("分流模式", appState.settings.unknownTrafficPolicy == "vpn" ? "默认 VPN" : "默认直连", systemImage: "arrow.triangle.branch")
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
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(minHeight: 40, alignment: .topLeading)
        }
    }

    private var readinessCard: some View {
        VPNCard {
            CardHeading(title: "连接准备", systemImage: "checkmark.shield")
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
            return "正在建立安全连接，请稍候"
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

}
