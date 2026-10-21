import SwiftUI

struct ContentView: View {
    @ObservedObject var store: VPNStore
    @ObservedObject var company: CompanyStore
    var onOpenSettings: () -> Void = {}
    @AppStorage("previewAppearance") private var appearance = "light"
    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 240, max: 270)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "network").foregroundStyle(VPNTheme.accent)
                    Text(store.legacyOwnerRunning ? "共用现有 VPN 内核" : "\(AppBrand.name) VPN").fontWeight(.semibold)
                    Text(store.legacyOwnerRunning ? "原版应用保持运行；节点、配置和私有网络接入可以在这里操作。" : "沿用已有订阅、节点、收藏和分流规则。")
                    Spacer()
                }.font(.system(size: 13)).foregroundStyle(VPNTheme.secondary)
                    .padding(.horizontal, 32).padding(.vertical, 13)
                    .background(VPNTheme.surface)
                    .overlay(alignment: .bottom) { Rectangle().fill(VPNTheme.border).frame(height: 1) }
                Group {
                    switch store.page ?? .overview {
                    case .overview: OverviewView(store: store, company: company)
                    case .company: CompanyView(store: company, vpn: store)
                    case .subscriptions: SubscriptionsView(store: store)
                    case .nodes: NodesView(store: store)
                    case .groups: NodeGroupsView(store: store)
                    case .routing: RoutingView(store: store)
                    case .diagnostics: DiagnosticsView(store: store)
                    case .traffic: TrafficView(store: store)
                    case .logs: LogsView(store: store)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if let busy = store.busy {
                    HStack(spacing: 12) { ProgressView().controlSize(.small); Text(busy); Spacer() }
                        .padding(16).background(VPNTheme.surface)
                } else if let message = store.message {
                    HStack { Image(systemName: "checkmark.circle"); Text(message); Spacer(); Button { store.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                        .font(.system(size: 14)).padding(16).background(VPNTheme.surface)
                }
            }.background(VPNTheme.background)
        }
        .tint(VPNTheme.accent).font(.system(size: 15)).foregroundStyle(VPNTheme.text)
        .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
        .controlSize(.large).buttonStyle(VPNButtonStyle())
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
            HStack(spacing: 13) {
                Group {
                    if let icon = AppBrand.icon {
                        Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
                    } else {
                        Image(systemName: "sailboat").font(.system(size: 25)).foregroundStyle(VPNTheme.accent)
                    }
                }.frame(width: 44, height: 44).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppBrand.name).font(.system(size: 21, weight: .bold))
                    Text("智能分流与私有网络接入").font(.system(size: 12)).foregroundStyle(VPNTheme.secondary)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    navSection("VPN", pages: [.overview, .subscriptions, .nodes, .groups, .routing])
                    navSection("私有网络", pages: [.company])
                    navSection("监控", pages: [.diagnostics, .traffic, .logs])
                }.padding(.horizontal, 14).padding(.bottom, 20)
            }
            VStack(alignment: .leading, spacing: 12) {
                Divider().overlay(VPNTheme.border)
                HStack(spacing: 8) {
                    Circle().fill(store.menuState == .connected ? VPNTheme.green : VPNTheme.secondary).frame(width: 8, height: 8)
                    Text(store.menuTitle)
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(store.status == nil ? "保留当前订阅与设置" : store.selectedProxy)
                    .font(.system(size: 12)).foregroundStyle(VPNTheme.secondary).lineLimit(2)
                Button(action: onOpenSettings) { Label("设置", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(.plain).font(.system(size: 16))
            }.padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 22)
        }.background(VPNTheme.surface)
    }
    private func navSection(_ title: String, pages: [VPNPage]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(VPNTheme.secondary)
                .padding(.leading, 14).padding(.bottom, 5)
            ForEach(pages) { page in
                Button { store.page = page } label: {
                    HStack(spacing: 13) {
                        Image(systemName: page.icon).font(.system(size: 18, weight: .medium)).frame(width: 23)
                        Text(page.rawValue).font(.system(size: 16, weight: store.page == page ? .semibold : .medium))
                        Spacer(minLength: 4)
                        if let count = count(for: page) { Text(count).font(.system(size: 12, weight: .medium)).foregroundStyle(VPNTheme.secondary) }
                    }.padding(.horizontal, 14).frame(height: 44)
                        .foregroundStyle(store.page == page ? VPNTheme.accent : VPNTheme.text)
                        .background(store.page == page ? VPNTheme.selection : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(store.page == page ? .isSelected : [])
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
