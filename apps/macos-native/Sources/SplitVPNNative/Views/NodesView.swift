import SwiftUI

struct NodesView: View {
    @ObservedObject var store: VPNStore
    @State private var selection = Set<String>()
    @State private var search = ""
    @State private var subscriptionID = "all"
    @State private var favoritesOnly = false
    var filtered: [VPNNode] {
        store.nodes.filter { node in
            (node.isProvider || node.name == "DIRECT") &&
            (subscriptionID == "all" || node.subscriptionId == subscriptionID) &&
            (!favoritesOnly || store.favoriteNames.contains(node.name)) &&
            (search.isEmpty || "\(node.name) \(node.subscriptionName ?? "") \(node.location?.country ?? "") \(node.location?.city ?? "")".localizedCaseInsensitiveContains(search))
        }
    }
    var selected: [VPNNode] { filtered.filter { selection.contains($0.id) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "节点", subtitle: "当前出口：\(store.displaySelectedProxy)")
            HStack {
                TextField("搜索节点、地区或订阅", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Picker("订阅", selection: $subscriptionID) {
                    Text("全部订阅").tag("all")
                    ForEach(store.status?.subscription.entries ?? []) { Text($0.name).tag($0.id) }
                }.labelsHidden().frame(width: 170)
                Toggle("仅收藏", isOn: $favoritesOnly).toggleStyle(.checkbox)
                Spacer(); Text("\(filtered.count) 个节点").foregroundStyle(.secondary)
            }
            Table(filtered, selection: $selection) {
                TableColumn("节点") { node in
                    HStack {
                        if node.selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(node.name).lineLimit(1).help(node.name)
                            Text("\(node.type.uppercased()) · \(node.subscriptionName ?? "内置出口") · \(node.availabilityText)")
                                .font(.system(size: 11)).foregroundStyle(node.identityAmbiguous == true || node.available == false ? Color.orange : .secondary).lineLimit(1)
                                .help("\(node.type) · \(node.subscriptionName ?? "内置出口") · \(node.availabilityText)")
                        }
                    }.padding(.vertical, 7)
                }.width(min: 160, ideal: 260, max: 360)
                TableColumn("国家") { node in Text(node.location?.country ?? (node.isProvider ? "未识别" : "—")) }.width(75)
                TableColumn("地区") { node in Text(node.location?.city ?? "—") }.width(85)
                TableColumn("风险") { node in
                    let risk = node.identityAmbiguous == true ? nil : store.risks.first { $0.nodeName == node.name }
                    Text(risk?.label ?? "未检测")
                        .foregroundStyle(risk?.riskLevel == "high" ? Color.red : risk?.riskLevel == "medium" ? Color.orange : Color.secondary)
                        .help(risk.map { "\(dateText($0.checkedAt)) · \($0.error ?? $0.reasons.joined(separator: "、"))" } ?? "在诊断与风险中进行检测")
                }.width(75)
                TableColumn("延迟") { node in Text(node.latencyText).monospacedDigit() }.width(95)
                TableColumn("收藏") { node in
                    Button { store.toggleFavorite(node) } label: { Image(systemName: store.favoriteNames.contains(node.name) ? "star.fill" : "star") }
                        .buttonStyle(.plain).foregroundStyle(store.favoriteNames.contains(node.name) ? Color.orange : Color.secondary)
                        .disabled(!store.canMutate || !node.isProvider).help("切换收藏")
                }.width(50)
            }.tableCard()
            HStack {
                Button("设为当前出口") { if let node = selected.first { store.select(node) } }.buttonStyle(VPNButtonStyle(prominent: true)).disabled(selected.count != 1 || !store.canMutate)
                Button("测速选中节点") { speed(selected) }.disabled(selected.isEmpty || !store.canMutate || !store.running)
                Button("测速当前列表") { speed(filtered) }.disabled(filtered.isEmpty || !store.canMutate || !store.running)
                Menu("更多检测") {
                    Button("推荐多站点测速") { if let node = selected.first, let key = node.identityKey { store.action("推荐测速", channel: "nodes:test-recommended", payload: ["identityKey": key]) } }.disabled(selected.count != 1 || selected.first?.identityKey == nil)
                    Button("UDP 探测选中节点") { store.action("启动 UDP 探测", channel: "nodes:start-udp-batch", payload: ["nodeNames": selected.map(\.name)]) }.disabled(selected.isEmpty)
                    Button("取消测速") { store.action("取消测速", channel: "nodes:cancel-speed-batch") }
                }.disabled(!store.canMutate || !store.running)
                Spacer()
                if let progress = store.batchMessage { Text(progress).foregroundStyle(.secondary) }
            }
            Text("可按住 ⌘ 多选；国家和地区由节点名称识别，风险显示上次实际出口检测结果。").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func speed(_ nodes: [VPNNode]) { store.action("启动节点测速", channel: "nodes:start-speed-batch", payload: ["nodeNames": nodes.map(\.name)]) }
}
