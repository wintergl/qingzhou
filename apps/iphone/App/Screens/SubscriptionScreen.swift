import SwiftUI

struct SubscriptionScreen: View {
    @EnvironmentObject private var appState: SplitVpnAppState
    @State private var editor: MobileSubscriptionDraft?
    @State private var deleting: ManagedSubscription?
    var body: some View {
        NavigationStack {
            List {
                if appState.subscriptions.isEmpty {
                    ContentUnavailableView("还没有订阅", systemImage: "link", description: Text("添加 Clash / Mihomo YAML 或 URI 订阅，更新后即可选择节点。"))
                }
                ForEach(appState.subscriptions) { entry in
                    Section {
                        Toggle(entry.name, isOn: Binding(get: { appState.subscriptions.first { $0.id == entry.id }?.enabled ?? entry.enabled }, set: { enabled in
                            Task { await appState.managedEdit("subscription:set-enabled", ["id": entry.id, "enabled": enabled]) }
                        }))
                        LabeledContent("节点", value: "\(entry.nodeCount) · \(subscriptionStatusTitle(entry.status))")
                        LabeledContent("自动更新", value: entry.interval == 0 ? "仅手动" : "每 \(entry.interval) 分钟")
                        if let error = entry.lastError, !error.isEmpty { Text(error).font(.caption).foregroundStyle(VPNTheme.destructive) }
                        HStack {
                            Button("更新") { Task { await appState.updateManagedSubscription(entry.id) } }
                            Spacer()
                            Button("编辑") { editor = MobileSubscriptionDraft(entry: entry) }
                            Button("删除", role: .destructive) { deleting = entry }
                        }.buttonStyle(.borderless)
                    }
                }
                if let notice = appState.notice { Section { Text(notice).font(.caption).foregroundStyle(.secondary) } }
            }
            .navigationTitle("订阅")
            .vpnListStyle()
            .disabled(appState.isBusy)
            .toolbar { Button { editor = MobileSubscriptionDraft() } label: { Label("添加订阅", systemImage: "plus") } }
            .sheet(item: $editor) { MobileSubscriptionEditor(draft: $0) }
            .confirmationDialog("删除这条订阅及其节点？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("删除订阅", role: .destructive) { if let entry = deleting { Task { await appState.managedEdit("subscription:delete", ["id": entry.id]) } }; deleting = nil }
            }
            .task { try? await appState.refreshManagedState() }
            .refreshable { try? await appState.refreshManagedState() }
        }
    }
}

struct MobileSubscriptionDraft: Identifiable {
    let id = UUID()
    var recordID: String?
    var name = ""
    var url = ""
    var interval = 1440
    init() {}
    init(entry: ManagedSubscription) { recordID = entry.id; name = entry.name; url = entry.url; interval = entry.interval }
}

struct MobileSubscriptionEditor: View {
    @EnvironmentObject private var appState: SplitVpnAppState
    @Environment(\.dismiss) private var dismiss
    @State var draft: MobileSubscriptionDraft
    var body: some View {
        NavigationStack {
            Form {
                Section("订阅信息") {
                    TextField("名称", text: $draft.name)
                    TextField("https://example.test/subscription", text: $draft.url).mobileAddressInput()
                    Picker("自动更新", selection: $draft.interval) {
                        ForEach([0, 15, 30, 60, 360, 1440, 10080], id: \.self) { minutes in Text(minutes == 0 ? "仅手动" : "每 \(minutes) 分钟").tag(minutes) }
                        if ![0, 15, 30, 60, 360, 1440, 10080].contains(draft.interval) { Text("每 \(draft.interval) 分钟").tag(draft.interval) }
                    }
                    Text("保存后可单独更新；下载失败保留上次可用节点。").font(.caption).foregroundStyle(.secondary)
                }
                if let error = appState.notice { Text(error).foregroundStyle(VPNTheme.destructive) }
            }.navigationTitle(draft.recordID == nil ? "添加订阅" : "编辑订阅")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(appState.isBusy) }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { Task {
                        var payload: [String: Any] = ["name": draft.name, "url": draft.url, "updateIntervalMinutes": draft.interval]
                        if let id = draft.recordID { payload["id"] = id }
                        if await appState.managedEdit("subscription:save", payload) { dismiss() }
                    } }.disabled(appState.isBusy || draft.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
        }
    }
}
