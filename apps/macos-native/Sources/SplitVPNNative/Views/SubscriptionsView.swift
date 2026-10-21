import SwiftUI

struct SubscriptionsView: View {
    @ObservedObject var store: VPNStore
    @State private var selection: String?
    @State private var editor: SubscriptionDraft?
    @State private var deleting: Subscription?
    var entries: [Subscription] { store.status?.subscription.entries ?? [] }
    var selected: Subscription? { entries.first { $0.id == selection } }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "订阅", subtitle: "沿用已保存的订阅与节点，更新失败时保留上次可用内容")
            HStack {
                Button { editor = SubscriptionDraft() } label: { Label("添加订阅", systemImage: "plus") }
                Button("更新全部启用订阅") { store.action("更新订阅", channel: "subscription:update") }
                Spacer()
                Text("\(entries.count) 条订阅 · \(store.status?.subscription.nodeCount ?? 0) 个节点").foregroundStyle(.secondary)
            }.disabled(!store.canMutate)
            Table(entries, selection: $selection) {
                TableColumn("订阅") { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name).fontWeight(.medium)
                        Text(entry.displayHost).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }.width(min: 180, ideal: 250)
                TableColumn("状态") { entry in Text(entry.enabled ? (entry.status == "ready" ? "可用" : "待更新") : "已停用") }.width(85)
                TableColumn("节点") { entry in Text("\(entry.nodeCount)") }.width(60)
                TableColumn("最近更新") { entry in Text(dateText(entry.updatedAt)).foregroundStyle(.secondary) }.width(min: 135, ideal: 160)
                TableColumn("更新方式") { entry in Text(entry.updateIntervalMinutes.map { "每 \($0) 分钟" } ?? "手动 / 默认设置") }.width(min: 110, ideal: 130)
            }.tableCard()
            if let entry = selected {
                HStack {
                    Button("编辑") { editor = SubscriptionDraft(entry) }
                    Button(entry.enabled ? "停用" : "启用") { store.action("调整订阅", channel: "subscription:set-enabled", payload: ["id": entry.id, "enabled": !entry.enabled]) }
                    Button("更新此订阅") { store.action("更新订阅", channel: "subscription:update", payload: ["id": entry.id]) }.disabled(!entry.enabled)
                    Menu("自动更新") {
                        Button("每天更新") { configure(entry, 1440) }
                        Button("每小时更新") { configure(entry, 60) }
                        Button("每 5 分钟更新") { configure(entry, 5) }
                        Button("仅手动更新") { configure(entry, nil) }
                    }
                    Spacer()
                    Button("删除", role: .destructive) { deleting = entry }
                }.disabled(!store.canMutate)
                if let error = entry.lastError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            } else { Text("选择一条订阅进行管理").foregroundStyle(.secondary) }
            Text("用量和到期日仅在订阅服务提供这些信息时显示。").font(.caption).foregroundStyle(.secondary)
        }.padding(32)
        .sheet(item: $editor) { draft in SubscriptionEditor(draft: draft) { name, url, id in
            store.action("保存订阅", channel: "native:save-subscription", payload: ["name": name, "url": url, "id": id ?? ""])
            editor = nil
        } }
        .alert("删除这条订阅？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) { if let entry = deleting { store.action("删除订阅", channel: "subscription:delete", payload: ["id": entry.id]) }; deleting = nil }
        } message: { Text("这条订阅的节点将停止参与连接，其他订阅会保留。") }
    }
    private func configure(_ entry: Subscription, _ minutes: Int?) {
        store.action("保存更新方式", channel: "subscription:configure-update", payload: ["id": entry.id, "intervalMinutes": minutes.map { $0 as Any } ?? NSNull()])
    }
}
struct SubscriptionDraft: Identifiable {
    var id = UUID()
    var entryID: String?
    var name = ""
    var url = ""
    init() {}
    init(_ entry: Subscription) { entryID = entry.id; name = entry.name; url = entry.url }
}
struct SubscriptionEditor: View {
    let draft: SubscriptionDraft
    let save: (String, String, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(draft.entryID == nil ? "添加订阅" : "编辑订阅").font(.title2.weight(.semibold))
            Form { TextField("名称", text: $name); TextField("订阅 URL", text: $url) }.textFieldStyle(.roundedBorder)
            Text("订阅链接只保存在本机，更新时交给现有 VPN 核心读取。").foregroundStyle(.secondary)
            HStack { Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("保存") { save(name, url, draft.entryID) }.buttonStyle(VPNButtonStyle(prominent: true)).keyboardShortcut(.defaultAction).disabled(URL(string: url)?.host == nil) }
        }.padding(24).frame(width: 520).buttonStyle(VPNButtonStyle()).onAppear { name = draft.name; url = draft.url }
    }
}
