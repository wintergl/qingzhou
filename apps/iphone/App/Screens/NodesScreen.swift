import SwiftUI

struct NodesScreen: View {
    @EnvironmentObject private var appState: SplitVpnAppState
    @State private var query = ""
    @State private var subscription = ""
    @State private var favoritesOnly = false
    private var favorites: [String] { appState.corePreferences["favoriteNodeNames"] as? [String] ?? [] }
    private var filtered: [ProviderNode] {
        appState.nodes.filter { (subscription.isEmpty || $0.subscriptionId == subscription) && (!favoritesOnly || favorites.contains($0.name)) && (query.isEmpty || "\($0.name) \($0.subscriptionName ?? "") \($0.type)".localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("订阅", selection: $subscription) {
                        Text("全部订阅").tag("")
                        ForEach(appState.subscriptions.filter(\.enabled)) { entry in Text(entry.name).tag(entry.id) }
                    }
                    Toggle("仅看收藏", isOn: $favoritesOnly)
                    NavigationLink("节点组") { MobileGroupsScreen() }
                }
                Section("内置出口") {
                    ForEach(["AUTO", "BALANCE", "DIRECT"], id: \.self) { name in
                        Button { Task { await appState.managedEdit("nodes:select", ["nodeName": name]) } } label: {
                            HStack { Text(name); Spacer(); if appState.settings.selectedProxy == name { Image(systemName: "checkmark.circle.fill") } }
                        }
                    }
                }
                Section("节点 · \(filtered.count)") {
                    ForEach(filtered) { node in
                        HStack {
                            Button { if let identity = node.identityKey { Task { await appState.managedEdit("nodes:select-v2", ["identityKey": identity]) } } } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(node.name).foregroundStyle(.primary)
                                    Text([node.subscriptionName, node.type].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                    if node.identityAmbiguous == true { Text("同名冲突，请调整订阅中的节点名称").font(.caption).foregroundStyle(VPNTheme.warning) }
                                    else if node.iosSupported == false { Text("此协议暂不能由 iPhone 内核转换").font(.caption).foregroundStyle(VPNTheme.warning) }
                                }
                            }.disabled(node.identityKey == nil || node.identityAmbiguous == true || node.iosSupported == false)
                            if let identity = node.identityKey { Button("测速") { Task { do { let result = try await appState.mobileCall("mobile:diagnostics:node", ["identityKey": identity]); appState.notice = result["ok"] as? Bool == true ? "\(node.name)：\(String(describing: result["delay"] ?? "—")) ms" : "节点检测未通过" } catch { appState.notice = Redaction.message(error.localizedDescription) } } }.buttonStyle(.borderless).disabled(appState.runtimeStatus.state != .connected) }
                            Spacer()
                            if selected(node) { Image(systemName: "checkmark.circle.fill").foregroundStyle(VPNTheme.accent) }
                            Button { Task { await appState.managedEdit("native:favorite", ["name": node.name], regenerate: false) } } label: {
                                Image(systemName: favorites.contains(node.name) ? "star.fill" : "star")
                            }.buttonStyle(.borderless).accessibilityLabel(favorites.contains(node.name) ? "取消收藏" : "收藏节点")
                        }
                    }
                    if filtered.isEmpty { Text("没有符合条件的节点").foregroundStyle(.secondary) }
                }
            }.navigationTitle("节点").vpnListStyle().searchable(text: $query, prompt: "节点、订阅或协议")
                .disabled(appState.isBusy)
                .task { try? await appState.refreshManagedState() }
                .refreshable { try? await appState.refreshManagedState() }
        }
    }
    private func selected(_ node: ProviderNode) -> Bool {
        if let identity = (appState.corePreferences["defaultOutlet"] as? [String: Any])?["identityKey"] as? String { return identity == node.identityKey }
        return node.identityAmbiguous != true && appState.settings.selectedProxy == node.name
    }
}
