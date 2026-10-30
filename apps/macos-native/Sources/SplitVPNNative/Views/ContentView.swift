import SwiftUI

struct ContentView: View {
    @ObservedObject var store: VPNStore
    @ObservedObject var company: CompanyStore
    var onOpenSettings: () -> Void = {}
    @AppStorage("previewAppearance") private var appearance = "light"
    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 205, ideal: 218, max: 245)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "sailboat").foregroundStyle(VPNTheme.accent)
                    Text("轻舟").fontWeight(.medium)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).opacity(0.55)
                    Text((store.page ?? .overview).rawValue)
                    Spacer(minLength: 8)
                    if store.legacyOwnerRunning {
                        Text("共用现有 VPN 内核").lineLimit(1).help("原版应用保持运行，当前连接由原版维护。")
                    } else {
                        Circle().fill(store.menuState == .connected ? VPNTheme.green : VPNTheme.secondary).frame(width: 5, height: 5)
                        Text(store.menuTitle).lineLimit(1)
                    }
                }.font(.system(size: 11)).foregroundStyle(VPNTheme.secondary)
                    .padding(.horizontal, 28).frame(height: 42)
                    .overlay(alignment: .bottom) { Rectangle().fill(VPNTheme.border.opacity(0.7)).frame(height: 1) }
                Group {
                    switch store.page ?? .overview {
                    case .overview: OverviewView(store: store, company: company)
                    case .company: CompanyView(store: company, vpn: store)
                    case .subscriptions: SubscriptionsView(store: store)
                    case .nodes: NodesView(store: store)
                    case .ispTest: ChainScannerView(store: store, standalone: true)
                    case .groups: NodeGroupsView(store: store)
                    case .routing: RoutingView(store: store)
                    case .diagnostics: DiagnosticsView(store: store)
                    case .traffic: TrafficView(store: store)
                    case .logs: LogsView(store: store)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                OperationStatusBar(store: store)
            }.background(VPNTheme.background)
        }
        .tint(VPNTheme.accent).font(.system(size: 13)).foregroundStyle(VPNTheme.text)
        .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
        .controlSize(.regular).buttonStyle(VPNButtonStyle())
        .navigationTitle(AppBrand.name)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { Task { await store.refresh() } } label: { Label("刷新状态", systemImage: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(store.refreshing).help("只读取当前连接与保存的数据")
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("好") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Group {
                    if let icon = AppBrand.icon {
                        Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
                    } else {
                        Image(systemName: "sailboat").font(.system(size: 25)).foregroundStyle(VPNTheme.accent)
                    }
                }.frame(width: 38, height: 38).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppBrand.name).font(.system(size: 22, weight: .semibold))
                    Text("让连接从容有序").font(.system(size: 12)).foregroundStyle(VPNTheme.secondary)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 20).padding(.top, 25).padding(.bottom, 28)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    navSection("VPN", pages: [.overview, .subscriptions, .nodes, .ispTest, .groups, .routing])
                    navSection("私有网络", pages: [.company])
                    navSection("监控", pages: [.diagnostics, .traffic, .logs])
                }.padding(.horizontal, 14).padding(.bottom, 20)
            }
            VStack(alignment: .leading, spacing: 12) {
                Divider().overlay(VPNTheme.border)
                HStack(spacing: 8) {
                    Circle().fill(store.menuState == .connected ? VPNTheme.green : VPNTheme.secondary).frame(width: 8, height: 8)
                    Text(store.menuTitle)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(store.status == nil ? "保留当前订阅与设置" : store.selectedProxy)
                    .font(.system(size: 12)).foregroundStyle(VPNTheme.secondary).lineLimit(2)
                Button(action: onOpenSettings) { Label("设置", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(.plain).font(.system(size: 13))
            }.padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 22)
        }.background(.regularMaterial)
    }
    private func navSection(_ title: String, pages: [VPNPage]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(VPNTheme.secondary)
                .padding(.leading, 14).padding(.bottom, 5)
            ForEach(pages) { page in
                SidebarNavigationRow(page: page, selected: (store.page ?? .overview) == page, count: count(for: page)) {
                    store.page = page
                }
            }
        }
    }
    private func count(for page: VPNPage) -> String? {
        guard let status = store.status else { return nil }
        switch page {
        case .subscriptions: return String(status.subscription.entries.count)
        case .nodes: return String(status.subscription.nodeCount)
        case .groups: return String(store.groups.count)
        case .routing: return String(status.settings.vpnDomainRules.count)
        default: return nil
        }
    }
}
