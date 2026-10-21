import SwiftUI

struct OverviewView: View {
    @ObservedObject var store: VPNStore
    @ObservedObject var company: CompanyStore
    @State private var showingVerification = false
    var body: some View {
        GeometryReader { geometry in
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(!store.statusKnown ? store.menuTitle : store.menuState == .connected ? "智能分流中" : store.running || store.connectionServiceUpdateRequired ? store.menuTitle : "网络总览")
                            .font(.system(size: 30, weight: .bold))
                        if store.statusKnown, store.running {
                            MihomoUptimeView(store: store)
                        } else {
                            Text(!store.statusKnown ? "刷新状态后重新确认连接" : store.menuState == .connecting ? "网络就绪后自动恢复分流" : "选择节点后连接 VPN")
                                .font(.system(size: 13)).foregroundStyle(VPNTheme.secondary)
                        }
                    }
                    Spacer(minLength: 16)
                    StatusPill(title: store.menuTitle, passed: store.menuState == .connected)
                    Button { store.connectOrVerify() } label: {
                        Label(store.connectionProtected ? "验证连接" : store.running ? "断开 VPN" : "连接 VPN", systemImage: "power")
                    }.buttonStyle(VPNButtonStyle(prominent: true, destructive: store.running && !store.connectionProtected)).disabled(!store.canMutate)
                }
                NetworkRecoveryView(store: store)
            }.padding(.bottom, 4)
            if store.connectionServiceUpdateRequired {
                HStack {
                    Text("更新需要 macOS 授权；你可以准备好后再继续。").font(.system(size: 13)).foregroundStyle(VPNTheme.secondary)
                    Spacer()
                    Button("更新连接服务", action: store.updateConnectionService).disabled(!store.canMutate)
                }
            }
            HStack(spacing: 14) {
                summary("分流模式", icon: "arrow.triangle.branch", value: store.status?.settings.unknownTraffic == "vpn" ? "默认 VPN" : "默认直连",
                        note: store.status?.settings.tun == true ? "系统 TUN 分流" : "系统 TUN 未开启")
                summary("当前出口", icon: "network", value: store.displaySelectedProxy, note: "点击节点或节点组切换")
                summary("启动设置", icon: "power", value: store.loginItemState.title, note: store.loginItemState == .requiresApproval ? "请在系统登录项中批准" : "登录 Mac 后启动轻舟")
            }
            HStack(spacing: 10) {
                Button { store.page = .nodes } label: { Label("切换节点", systemImage: "network") }
                Button { store.page = .groups } label: { Label("节点组", systemImage: "square.stack.3d.up") }
                Button { store.action("更新订阅", channel: "subscription:update") } label: { Label("更新订阅", systemImage: "arrow.clockwise") }.disabled(!store.canMutate)
                Spacer(minLength: 0)
                Button { store.page = .routing } label: { Label("分流规则", systemImage: "arrow.triangle.branch") }
                Button { store.page = .traffic } label: { Image(systemName: "chart.xyaxis.line") }.help("流量监控")
            }
            HStack(spacing: 14) {
                Image(systemName: "building.2").font(.system(size: 24)).foregroundStyle(VPNTheme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("私有网络").font(.system(size: 17, weight: .semibold))
                    Text(company.resources.map { "\($0.appCount) 个授权应用 · \(company.connectionReady && company.takeoverEnabled ? "授权资源已接入" : "授权资源")" } ?? "账号认证、授权资源与接管设置")
                        .font(.system(size: 12)).foregroundStyle(VPNTheme.secondary)
                }
                Spacer(minLength: 4)
                StatusPill(title: company.statusText, passed: company.menuState == .connected)
                if company.working { ProgressView().controlSize(.small) }
                Toggle("私有网络", isOn: Binding(get: { company.connectionEnabled }, set: { enabled in
                    if enabled {
                        if company.hasSession && company.resources != nil { company.connectTunnel() }
                        else { store.page = .company }
                    } else { company.disconnectTunnel() }
                })).labelsHidden().toggleStyle(.switch).disabled(company.working || !store.canMutate)
                    .help(company.connectionEnabled ? "断开私有网络" : "连接私有网络")
                Button("验证") { showingVerification = true }.disabled(company.tunnelProof == nil || company.working || !store.canMutate)
                Button("私有网络接入") { store.page = .company }
            }.detailCard(padding: 16)
            HStack(alignment: .top, spacing: 14) {
                connectivityCard
                websiteCard
            }.frame(height: max(185, geometry.size.height - 400), alignment: .topLeading)
            HStack(spacing: 16) {
                Text("\(count(store.status?.subscription.entries.count)) 订阅")
                Text("\(count(store.status?.subscription.nodeCount)) 节点")
                Text("\(store.favoriteNames.count) 收藏")
                Text("\(store.groups.count) 节点组")
                Text("\(count(store.status?.settings.vpnDomainRules.count)) 分流规则")
                Spacer(minLength: 0)
                Button("管理订阅") { store.page = .subscriptions }.buttonStyle(.plain).foregroundStyle(VPNTheme.accent)
            }.font(.system(size: 12)).foregroundStyle(VPNTheme.secondary)
        }.padding(24).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        }
        .sheet(isPresented: $showingVerification) { CompanyVerificationSheet(store: company) }
    }
    private func summary(_ title: String, icon: String, value: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon).font(.system(size: 13)).foregroundStyle(VPNTheme.secondary)
            Text(store.status == nil ? "—" : value).font(.system(size: 18, weight: .semibold)).lineLimit(1).help(value)
            Text(note).font(.system(size: 12)).foregroundStyle(VPNTheme.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).detailCard(padding: 16)
    }
    private var connectivityCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack { CardHeading(title: "连接检测", icon: "waveform.path.ecg"); Spacer(); Button("检测") { store.checkConnectivity() }.disabled(!store.canMutate) }
            resultRow("国内网络", value: checkText(store.connectivity?.connectivity.domesticOk, store.connectivity?.connectivity.latency.domesticMs))
            resultRow("国外网络", value: checkText(store.connectivity?.connectivity.foreignOk, store.connectivity?.connectivity.latency.foreignMs))
            resultRow("出口 IP", value: store.connectivity?.connectivity.externalIp ?? store.currentRisk?.ip ?? "尚未读取")
            resultRow("出口风险", value: store.currentRisk?.label ?? "尚未检测")
            Spacer(minLength: 0)
            Text(store.connectivity?.connectivity.error ?? store.currentRisk.map { "风险记录：\(dateText($0.checkedAt))" } ?? "检测包含系统 DNS 与 ChatGPT 网络响应。")
                .font(.system(size: 12)).foregroundStyle(VPNTheme.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).detailCard(padding: 18)
    }
    private var websiteCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack { CardHeading(title: "站点测速", icon: "speedometer"); Spacer(); Button("检测") { store.testWebsites() }.disabled(!store.canMutate) }
            if let tests = store.websites {
                ForEach(Array(tests.results.prefix(3))) { item in
                    resultRow(item.label, value: item.ok ? item.delay.map { "\(Int($0)) ms" } ?? "连通" : "失败")
                }
            } else {
                Text("Google · ChatGPT · Claude").font(.system(size: 15, weight: .medium))
                Text("通过当前出口检测站点响应，结果在此显示。")
                    .font(.system(size: 14)).foregroundStyle(VPNTheme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("查看完整诊断") { store.page = .diagnostics }.buttonStyle(.plain).foregroundStyle(VPNTheme.accent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).detailCard(padding: 18)
    }
    private func resultRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(VPNTheme.secondary)
            Spacer(minLength: 8)
            Text(value).fontWeight(.medium).lineLimit(1).textSelection(.enabled)
        }.font(.system(size: 14))
    }
    private func count(_ number: Int?) -> String { number.map(String.init) ?? "—" }
    private func checkText(_ ok: Bool?, _ ms: Double?) -> String {
        guard let ok else { return "尚未检测" }
        return ok ? "正常\(ms.map { " · \(Int($0)) ms" } ?? "")" : "未连通"
    }
}
