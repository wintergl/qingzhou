import SwiftUI

struct OverviewView: View {
    @ObservedObject var store: VPNStore
    @ObservedObject var company: CompanyStore
    @State private var showingVerification = false
    var body: some View {
        GeometryReader { geometry in
        let compact = geometry.size.height < 760
        ScrollView {
        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
            ConnectionHero(store: store, compact: compact)
            NetworkRecoveryView(store: store)
            if store.connectionServiceUpdateRequired {
                HStack {
                    Text("更新需要 macOS 授权；你可以准备好后再继续。").font(.system(size: 13)).foregroundStyle(VPNTheme.secondary)
                    Spacer()
                    Button("更新连接服务", action: store.updateConnectionService).disabled(!store.canMutate)
                }
            }
            HStack(spacing: 18) {
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
            HStack(spacing: 18) {
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
            }.detailCard(padding: 13)
            HStack(alignment: .top, spacing: 18) {
                connectivityCard
                websiteCard
            }.frame(height: compact ? 242 : 270, alignment: .topLeading)
            HStack(spacing: 16) {
                Text("\(count(store.status?.subscription.entries.count)) 订阅")
                Text("\(count(store.status?.subscription.nodeCount)) 节点")
                Text("\(store.favoriteNames.count) 收藏")
                Text("\(store.groups.count) 节点组")
                Text("\(count(store.status?.settings.vpnDomainRules.count)) 分流规则")
                Spacer(minLength: 0)
                Button("管理订阅") { store.page = .subscriptions }.buttonStyle(.plain).foregroundStyle(VPNTheme.accent)
            }.font(.system(size: 12)).foregroundStyle(VPNTheme.secondary)
        }.padding(compact ? 24 : 28).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        }
        .sheet(isPresented: $showingVerification) { CompanyVerificationSheet(store: company) }
    }
    private func summary(_ title: String, icon: String, value: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon).font(.system(size: 13)).foregroundStyle(VPNTheme.secondary)
            Text(store.status == nil ? "—" : value).font(.system(size: 17, weight: .semibold)).lineLimit(1).help(value)
            Text(note).font(.system(size: 12)).foregroundStyle(VPNTheme.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).detailCard(padding: 16)
    }
    private var connectivityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardHeading(title: "连接检测", icon: "waveform.path.ecg")
                if store.diagnostics?.connectivity.stale == true { Text("历史结果").font(.system(size: 10)).foregroundStyle(VPNTheme.secondary) }
                Spacer()
                Button(store.diagnostics?.connectivity.running == true ? "检测中…" : "立即检测") { store.checkConnectivity() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(VPNTheme.accent)
                    .disabled(!store.canMutate || store.diagnostics?.connectivity.running == true)
            }
            resultRow("国内网络", value: checkText(store.connectivity?.connectivity.domesticOk, store.connectivity?.connectivity.latency.domesticMs))
            resultRow("国外网络", value: checkText(store.connectivity?.connectivity.foreignOk, store.connectivity?.connectivity.latency.foreignMs))
            resultRow("出口 IP", value: store.connectivity?.connectivity.externalIp ?? store.currentRisk?.ip ?? "尚未读取")
            resultRow("出口风险", value: store.currentRisk?.label ?? "尚未检测")
            Spacer(minLength: 0)
            Text(store.diagnostics?.connectivity.error ?? store.connectivity?.connectivity.error ?? "包含系统 DNS 与 ChatGPT 网络响应。")
                .font(.system(size: 11)).foregroundStyle(VPNTheme.secondary).lineLimit(1)
            Divider().opacity(0.55)
            DiagnosticTimingView(record: store.diagnostics?.connectivity, pausedReason: store.diagnostics?.pausedReason)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).detailCard(padding: 16)
    }
    private var websiteCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardHeading(title: "站点测速", icon: "speedometer")
                if store.diagnostics?.websites.stale == true { Text("历史结果").font(.system(size: 10)).foregroundStyle(VPNTheme.secondary) }
                Spacer()
                Button(store.diagnostics?.websites.running == true ? "检测中…" : "立即检测") { store.testWebsites() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(VPNTheme.accent)
                    .disabled(!store.canMutate || store.diagnostics?.websites.running == true)
            }
            if let tests = store.websites {
                ForEach(Array(tests.results.prefix(3))) { item in
                    HStack {
                        Text(item.label).foregroundStyle(VPNTheme.secondary)
                        Spacer(minLength: 6)
                        Text(item.responseText).fontWeight(.medium).monospacedDigit()
                            .foregroundStyle(store.diagnostics?.websites.stale == true ? VPNTheme.secondary : item.ok ? VPNTheme.green : VPNTheme.warning)
                    }.font(.system(size: 13)).help(item.error ?? "站点响应耗时，不代表下载带宽。")
                }
            } else {
                Text("Google · ChatGPT · Claude").font(.system(size: 15, weight: .medium))
                Text("通过当前出口检测站点响应，结果在此显示。")
                    .font(.system(size: 14)).foregroundStyle(VPNTheme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Divider().opacity(0.55)
            DiagnosticTimingView(record: store.diagnostics?.websites, pausedReason: store.diagnostics?.pausedReason)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).detailCard(padding: 16)
    }
    private func resultRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(VPNTheme.secondary)
            Spacer(minLength: 8)
            Text(value).fontWeight(.medium).lineLimit(1).textSelection(.enabled)
        }.font(.system(size: 12))
    }
    private func count(_ number: Int?) -> String { number.map(String.init) ?? "—" }
    private func checkText(_ ok: Bool?, _ ms: Double?) -> String {
        guard let ok else { return "尚未检测" }
        return ok ? "正常\(ms.map { " · \(Int($0)) ms" } ?? "")" : "未连通"
    }
}
