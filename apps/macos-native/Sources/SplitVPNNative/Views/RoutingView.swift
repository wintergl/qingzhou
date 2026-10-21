import SwiftUI

struct RoutingView: View {
    @ObservedObject var store: VPNStore
    @State private var selection: String?
    @State private var search = ""
    @State private var outletFilter = "all"
    @State private var editor: RoutingRuleDraft?
    @State private var target = ""
    @State private var diagnostic: RoutingDiagnostic?
    @State private var checking = false

    private var allRules: [RoutingRule] {
        (store.status?.settings.directDomainRules ?? []).map { RoutingRule(raw: $0, outlet: .direct) }
            + (store.status?.settings.vpnDomainRules ?? []).map { RoutingRule(raw: $0, outlet: .vpn) }
    }
    private var rules: [RoutingRule] {
        allRules.filter { (outletFilter == "all" || $0.outlet.rawValue == outletFilter)
            && (search.isEmpty || $0.raw.localizedCaseInsensitiveContains(search) || $0.outlet.title.localizedCaseInsensitiveContains(search)) }
    }
    private var selectedRule: RoutingRule? { rules.first { $0.id == selection } }

    var body: some View {
        GeometryReader { viewport in VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "分流规则", subtitle: "为指定域名、IP 或网段选择 VPN 或直连")
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField("搜索地址或规则", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                    Picker("出口", selection: $outletFilter) {
                        Text("全部出口").tag("all"); Text("走 VPN").tag("vpn"); Text("直连").tag("direct")
                    }.labelsHidden().frame(width: 110)
                    Button { editor = RoutingRuleDraft() } label: { Label("添加规则", systemImage: "plus") }.disabled(!store.canMutate)
                    Spacer()
                }
                HStack {
                    Picker("未命中策略", selection: Binding(get: { store.status?.settings.unknownTraffic ?? "direct" }, set: { store.action("更新默认策略", channel: "routing:update", payload: ["unknownTraffic": $0]) })) {
                        Text("默认直连").tag("direct"); Text("默认 VPN").tag("vpn")
                    }.frame(width: 230).disabled(!store.canMutate)
                        .help("自定义规则和国内外自动分流都未命中时，才使用此策略。")
                    Picker("分流数据缺失时", selection: Binding(get: { store.status?.settings.geoFallback ?? "cn-direct-else-vpn" }, set: { store.action("更新分流数据缺失策略", channel: "routing:update", payload: ["geoFallback": $0]) })) {
                        Text("国内名单直连，其余 VPN").tag("cn-direct-else-vpn"); Text("跟随默认策略").tag("follow-default"); Text("拒绝启动").tag("block")
                    }.frame(width: 340).disabled(!store.canMutate)
                        .help("分流数据可用时使用完整的国内外规则；缺失时按此策略连接。自定义地址规则仍然生效。")
                    Spacer()
                }
            }
            Table(rules, selection: $selection) {
                TableColumn("地址") { Text($0.address).padding(.vertical, 8) }.width(min: 220, ideal: 340)
                TableColumn("匹配范围") { Text($0.matchTitle).foregroundStyle(.secondary) }.width(min: 130, ideal: 150)
                TableColumn("出口") { Text($0.outlet.title).fontWeight(.medium) }.width(min: 90, ideal: 110)
            }.frame(minHeight: 100, maxHeight: .infinity).tableCard()
                .overlay { if rules.isEmpty { Text(outletFilter == "direct" && search.isEmpty ? "还没有直连规则，点击“添加规则”指定地址。" : "没有匹配的规则").foregroundStyle(.secondary) } }
            HStack {
                Button("编辑规则") { if let selectedRule { editor = RoutingRuleDraft(original: selectedRule) } }.disabled(selectedRule == nil)
                Button("删除规则", role: .destructive) { deleteSelected() }.disabled(selectedRule == nil)
                Spacer()
                Text("VPN \(store.status?.settings.vpnDomainRules.count ?? 0) 条 · 直连 \(store.status?.settings.directDomainRules?.count ?? 0) 条").foregroundStyle(.secondary)
            }.disabled(!store.canMutate)
            Divider()
            HStack {
                TextField("输入域名、IP 或网址，检查自定义规则", text: $target).textFieldStyle(.roundedBorder)
                Button(checking ? "检查中…" : "检查匹配") { diagnose() }.disabled(target.isEmpty || checking || !store.statusKnown)
            }
            if let result = diagnostic {
                Text("\(result.host)：\(result.policy)").font(.callout)
                Text(result.matchedRules.isEmpty ? "未命中自定义规则；实际出口取决于自动分流与接入设置。" : "命中：\(result.matchedRules.joined(separator: "；"))").font(.caption).foregroundStyle(.secondary)
            }
            Text("自定义规则优先于国内外自动分流，重叠时直连优先。局域网、Tailscale 与私有网络按接入设置处理；匹配检查不检测网络是否连通。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(28).frame(width: viewport.size.width, height: viewport.size.height) }
        .sheet(item: $editor) { draft in RoutingRuleEditor(store: store, draft: draft) { selection = nil; diagnostic = nil } }
    }
    private func deleteSelected() {
        if let selectedRule { store.action("删除规则", channel: "routing:delete-rule", payload: ["rule": selectedRule.raw, "target": selectedRule.outlet.rawValue]) }
        selection = nil; diagnostic = nil
    }
    private func diagnose() {
        checking = true; diagnostic = nil
        Task {
            defer { checking = false }
            do { diagnostic = try await store.core.request("routing:diagnose", payload: ["target": target]) }
            catch { store.error = error.localizedDescription }
        }
    }
}
