import SwiftUI

struct NodeGroupsView: View {
    @ObservedObject var store: VPNStore
    @State private var selectedID: String?
    @State private var selectedMemberID: String?
    @State private var editing: NodeGroup?
    var selected: NodeGroupState? { store.groups.first { $0.id == selectedID } }
    var selectedNode: VPNNode? {
        guard let member = selected?.members.first(where: { $0.id == selectedMemberID }), let identity = member.identityKey else { return nil }
        return store.providerNodes.first { $0.identityKey == identity && $0.identityAmbiguous != true }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "节点组", subtitle: "整理节点与批量测速，选择具体节点作为出口")
            HStack {
                Button { editing = NodeGroup(id: UUID().uuidString, name: "", nodeNames: [], members: [], strategy: "manual") } label: { Label("新增节点组", systemImage: "plus") }.buttonStyle(VPNButtonStyle(prominent: true)).disabled(!store.canMutate)
                Spacer(); Text("\(store.groups.count) 个节点组").foregroundStyle(.secondary)
            }
            HSplitView {
                List(store.groups, selection: $selectedID) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.group.name).fontWeight(.medium)
                        Text("\(item.isSubscriptionGroup ? "订阅自动维护" : "自定义分组") · \(item.members.count) 个成员").font(.system(size: 11)).foregroundStyle(.secondary)
                    }.padding(.vertical, 8).tag(item.id)
                }.frame(minWidth: 180, idealWidth: 220, maxWidth: 260)
                VStack(alignment: .leading, spacing: 22) {
                    if let item = selected {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) { Text(item.group.name).font(.title2); Text("选择一个成员，固定使用这个节点。").foregroundStyle(.secondary) }
                            Spacer(); Button("编辑") { editing = item.group }.disabled(!store.canMutate)
                        }
                        Table(item.members, selection: $selectedMemberID) {
                            TableColumn("成员") { Text($0.lastKnownName).padding(.vertical, 10) }
                            TableColumn("状态") { member in Text(member.issue ?? member.available.map { $0 ? "可用" : "失败" } ?? "未检测") }.width(90)
                            TableColumn("延迟") { member in Text(member.delay.map { "\(Int($0)) ms" } ?? "—") }.width(85)
                            TableColumn("当前") { member in if member.lastKnownName == store.selectedProxy { Image(systemName: "checkmark").foregroundStyle(VPNTheme.green) } }.width(50)
                        }.tableCard()
                        HStack {
                            Button("使用选中节点") { if let node = selectedNode { store.select(node) } }
                                .buttonStyle(VPNButtonStyle(prominent: true)).disabled(selectedNode == nil)
                            Button("测速此组") { store.action("启动组测速", channel: "nodes:start-speed-batch", payload: ["nodeNames": item.members.filter { $0.issue == nil }.map(\.lastKnownName)]) }.disabled(!store.running)
                            Spacer()
                            if !item.isSubscriptionGroup {
                                Button("删除组", role: .destructive) { store.saveGroups((store.status?.settings.nodeGroups ?? []).filter { $0.id != item.id }); selectedID = nil }.disabled(item.selected)
                            }
                        }.disabled(!store.canMutate)
                        Text("连接固定使用选中的具体节点。\(item.isSubscriptionGroup ? "此组成员随订阅更新。" : "")")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else { ContentUnavailableView("选择节点组", systemImage: "square.stack.3d.up", description: Text("已有的组、成员和测速结果会在这里显示")) }
                }.padding(.leading, 20).frame(minWidth: 400)
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $editing) { group in GroupEditor(group: group, nodes: store.providerNodes.filter { !group.id.hasPrefix("subscription:") || $0.subscriptionId == String(group.id.dropFirst("subscription:".count)) }) { updated in
            var all = store.status?.settings.nodeGroups ?? []
            if let index = all.firstIndex(where: { $0.id == updated.id }) { all[index] = updated } else { all.append(updated) }
            store.saveGroups(all); editing = nil
        } }
        .onAppear { if selectedID == nil { selectedID = store.groups.first?.id } }
    }
}
struct GroupEditor: View {
    let group: NodeGroup
    let nodes: [VPNNode]
    let save: (NodeGroup) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected = Set<String>()
    @State private var search = ""
    var subscriptionManaged: Bool { group.id.hasPrefix("subscription:") }
    var filtered: [VPNNode] { nodes.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(group.name.isEmpty ? "新增节点组" : "编辑节点组").font(.title2.weight(.semibold))
            TextField("组名称", text: $name).textFieldStyle(.roundedBorder)
            TextField("搜索成员", text: $search).textFieldStyle(.roundedBorder)
            List(filtered) { node in
                if subscriptionManaged { Text(node.name).foregroundStyle(node.identityAmbiguous == true ? .secondary : .primary) }
                else {
                    Toggle(node.name, isOn: Binding(get: { selected.contains(node.id) }, set: { if $0 { selected.insert(node.id) } else { selected.remove(node.id) } }))
                        .toggleStyle(.checkbox).disabled(node.identityAmbiguous == true)
                }
            }.frame(height: 290)
            Text(subscriptionManaged ? "成员随订阅更新。" : "已选 \(selected.count) 个成员；原成员顺序会保留，新成员追加到末尾。").font(.caption).foregroundStyle(.secondary)
            HStack { Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("保存") { commit() }.buttonStyle(VPNButtonStyle(prominent: true)).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || selected.isEmpty) }
        }.padding(24).frame(width: 560).buttonStyle(VPNButtonStyle()).onAppear {
            name = group.name
            selected = Set((subscriptionManaged ? nodes.map { NodeMember(identityKey: $0.identityKey, lastKnownName: $0.name) } : group.members ?? nodes.filter { group.nodeNames.contains($0.name) }.map { NodeMember(identityKey: $0.identityKey, lastKnownName: $0.name) }).compactMap(\.identityKey))
        }
    }
    private func commit() {
        var result = group; result.name = name
        let previous = group.members ?? []
        let kept = previous.filter { $0.identityKey.map(selected.contains) == true }
        let oldKeys = Set(kept.compactMap(\.identityKey))
        result.members = kept + nodes.filter { selected.contains($0.id) && !oldKeys.contains($0.id) }.map { NodeMember(identityKey: $0.identityKey, lastKnownName: $0.name) }
        result.nodeNames = result.members?.map(\.lastKnownName) ?? []
        if let preferred = result.preferredIdentityKey, !selected.contains(preferred) { result.preferredIdentityKey = nil }
        save(result)
    }
}
