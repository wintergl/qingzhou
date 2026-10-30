import SwiftUI

struct NodesView: View {
    @ObservedObject var store: VPNStore
    @FocusState private var tableFocused: Bool
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var selection = Set<String>()
    @State private var search = ""
    @State private var subscriptionID = "all"
    @State private var favoritesOnly = false
    @State private var scope = "all"
    @State private var order = "default"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(store: VPNStore, initialSelection: Set<String> = []) {
        self.store = store; _selection = State(initialValue: initialSelection)
    }

    private var providerNodes: [VPNNode] { store.nodes.filter(\.isProvider) }
    private var good: Int { providerNodes.filter { $0.available == true }.count }
    private var failed: Int { providerNodes.filter { $0.available == false }.count }
    var filtered: [VPNNode] {
        let nodes = store.nodes.filter { node in
            (node.isProvider || node.name == "DIRECT") &&
            (subscriptionID == "all" || node.subscriptionId == subscriptionID) &&
            (!favoritesOnly || store.favoriteNames.contains(node.name)) &&
            (scope == "all" || (scope == "available" && node.available == true) || (scope == "failed" && node.available == false) || (scope == "pending" && node.available == nil)) &&
            (search.isEmpty || "\(node.name) \(node.subscriptionName ?? "") \(node.location?.country ?? "") \(node.location?.city ?? "")".localizedCaseInsensitiveContains(search))
        }
        if order == "latency" {
            return nodes.sorted {
                let a = $0.available == true ? ($0.delay.flatMap { $0 > 0 ? $0 : nil } ?? .infinity) : .infinity
                let b = $1.available == true ? ($1.delay.flatMap { $0 > 0 ? $0 : nil } ?? .infinity) : .infinity
                return a == b ? $0.name < $1.name : a < b
            }
        }
        if order == "issues" { return nodes.sorted { ($0.available == false ? 0 : 1, $0.name) < ($1.available == false ? 0 : 1, $1.name) } }
        return nodes
    }
    private func brightSelection(_ node: VPNNode) -> Bool {
        selection.contains(node.id) && tableFocused && controlActiveState == .key
    }
    private var selected: [VPNNode] { filtered.filter { selection.contains($0.id) } }
    private var canTest: Bool { store.canMutate && store.running && !store.speedBatchRunning }

    var body: some View {
        GeometryReader { geometry in
        let compact = geometry.size.height < 720
        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
            HStack(alignment: .top) {
                if compact { Text("节点").font(.system(size: 28, weight: .semibold)).foregroundStyle(VPNTheme.text) }
                else { PageHeader(title: "节点", subtitle: "找到一条稳定、顺畅的路径") }
                Spacer()
                Text("\(providerNodes.count) 个节点").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VPNTheme.secondary).padding(.top, 9)
            }
            if compact { compactSummary } else { connectionSummary }
            controls
            if let error = store.nodesError {
                Text("节点读取失败：\(error)").font(.system(size: 12)).foregroundStyle(VPNTheme.warning)
            }
            nodeTable
            progressStrip
            actions
            Text("⌘ 多选 · 右键重新测速或切换出口。延迟是响应耗时；IP 风险独立于连接质量。")
                .font(.system(size: 11)).foregroundStyle(VPNTheme.secondary)
        }.padding(compact ? 20 : 24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task(id: store.previewOnly) { await store.refreshNodes() }
    }
    private var compactSummary: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.right").foregroundStyle(VPNTheme.accent)
            Text(store.displaySelectedProxy).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            Text("\(good) 可用").foregroundStyle(VPNTheme.green)
            Text("\(failed) 异常").foregroundStyle(VPNTheme.warning)
            Text("\(max(0, providerNodes.count - good - failed)) 待测").foregroundStyle(VPNTheme.secondary)
        }.font(.system(size: 11)).padding(.horizontal, 12).frame(height: 42)
            .background(VPNTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(VPNTheme.border))
    }
    private var connectionSummary: some View {
        HStack(spacing: 16) {
            Image(systemName: "arrow.up.right").font(.system(size: 16, weight: .semibold))
                .foregroundStyle(VPNTheme.accent).frame(width: 40, height: 40)
                .background(VPNTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text("当前出口").font(.system(size: 11)).foregroundStyle(VPNTheme.secondary)
                Text(store.displaySelectedProxy).font(.system(size: 15, weight: .semibold)).lineLimit(1).help(store.displaySelectedProxy)
            }
            Spacer(minLength: 12)
            metric(good, "可用", VPNTheme.green)
            Divider().frame(height: 26)
            metric(failed, "异常", VPNTheme.warning)
            Divider().frame(height: 26)
            metric(max(0, providerNodes.count - good - failed), "待测 / 过期", VPNTheme.secondary)
        }.detailCard(padding: 16)
    }
    private func metric(_ value: Int, _ title: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(value)").font(.system(size: 21, weight: .semibold)).monospacedDigit().foregroundStyle(color)
            Text(title).font(.system(size: 10)).foregroundStyle(VPNTheme.secondary)
        }.frame(minWidth: 42, alignment: .leading)
    }
    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(VPNTheme.secondary)
                    TextField("搜索节点、地区或订阅", text: $search).textFieldStyle(.plain)
                    if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(VPNTheme.secondary).accessibilityLabel("清除搜索") }
                }.padding(.horizontal, 12).frame(height: 34).background(VPNTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(VPNTheme.border))
                Picker("排序", selection: $order) {
                    Text("默认排序").tag("default"); Text("延迟优先").tag("latency"); Text("先看异常").tag("issues")
                }.labelsHidden().frame(width: 126).controlSize(.regular)
            }
            HStack(spacing: 12) {
                Picker("连接质量", selection: $scope) {
                    Text("全部").tag("all"); Text("可用").tag("available"); Text("异常").tag("failed"); Text("待测").tag("pending")
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 252)
                Spacer(minLength: 0)
                Picker("订阅", selection: $subscriptionID) {
                    Text("全部订阅").tag("all")
                    ForEach(store.status?.subscription.entries ?? []) { Text($0.name).tag($0.id) }
                }.labelsHidden().frame(width: 142).controlSize(.regular)
                Toggle("仅收藏", isOn: $favoritesOnly).toggleStyle(.checkbox).font(.system(size: 12))
            }
        }
    }
    private var nodeTable: some View {
        Table(filtered, selection: $selection) {
            TableColumn("节点 / 订阅") { node in
                let picked = brightSelection(node)
                HStack(spacing: 9) {
                    Image(systemName: node.selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14)).foregroundStyle(picked ? Color.white : node.selected ? VPNTheme.green : VPNTheme.border)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(node.name).font(.system(size: 13, weight: node.selected ? .semibold : .medium)).lineLimit(1).help(node.name)
                            .foregroundStyle(picked ? Color.white : VPNTheme.text)
                        Text("\(node.type.uppercased()) · \(node.subscriptionName ?? "内置出口")")
                            .font(.system(size: 10)).foregroundStyle(picked ? Color.white.opacity(0.82) : VPNTheme.secondary).lineLimit(1)
                    }
                }.padding(.vertical, 4)
            }.width(min: 170, ideal: 210, max: .infinity)
            TableColumn("连接质量") { node in NodeLatencyCell(node: node, testing: store.speedTestingNode == node.name, selected: brightSelection(node)) }.width(96)
            TableColumn("最近测速") { node in
                VStack(alignment: .leading, spacing: 5) {
                    Text(node.latencyCheckedAt.map(MeasurementTime.clock) ?? "—").monospacedDigit().font(.system(size: 11, weight: .medium))
                    Text(node.latencyCheckedAt == nil ? "尚无记录" : node.latencySource == "engine" ? "自动探测" : "手动测速")
                        .font(.system(size: 10)).opacity(0.8)
                }.foregroundStyle(brightSelection(node) ? Color.white : VPNTheme.secondary).help(dateText(node.latencyCheckedAt))
            }.width(76)
            TableColumn("位置") { node in
                Text([node.location?.country, node.location?.city].compactMap { $0 }.joined(separator: " · ").isEmpty ? "未识别" : [node.location?.country, node.location?.city].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(brightSelection(node) ? Color.white.opacity(0.9) : VPNTheme.secondary).lineLimit(1)
            }.width(80)
            TableColumn("IP 风险") { node in
                let risk = node.identityAmbiguous == true ? nil : store.risks.first { $0.nodeName == node.name }
                Text(risk?.label ?? "未检测").font(.system(size: 11))
                    .foregroundStyle(brightSelection(node) ? Color.white : risk?.riskLevel == "high" ? VPNTheme.destructive : risk?.riskLevel == "medium" ? VPNTheme.warning : VPNTheme.secondary)
                    .help(risk.map { "\(dateText($0.checkedAt)) · \($0.error ?? $0.reasons.joined(separator: "、"))" } ?? "IP 风险不代表节点的连接质量。")
            }.width(60)
            TableColumn("") { node in
                Button { store.toggleFavorite(node) } label: { Image(systemName: store.favoriteNames.contains(node.name) ? "star.fill" : "star") }
                    .buttonStyle(.plain).foregroundStyle(brightSelection(node) ? Color.white : store.favoriteNames.contains(node.name) ? VPNTheme.warning : VPNTheme.secondary.opacity(0.65))
                    .disabled(!store.canMutate || !node.isProvider).help("切换收藏")
                    .accessibilityLabel("\(store.favoriteNames.contains(node.name) ? "取消收藏" : "收藏") \(node.name)")
            }.width(30)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let chosen = filtered.filter { ids.contains($0.id) }
            Button("测速所选节点") { store.startNodeSpeed(chosen) }.disabled(chosen.isEmpty || !canTest)
            if chosen.count == 1, let node = chosen.first {
                Button("设为当前出口") { store.select(node) }.disabled(!store.canMutate)
            }
        }
        .focused($tableFocused)
        .tableCard()
        .overlay { if filtered.isEmpty { ContentUnavailableView("没有匹配的节点", systemImage: "line.3.horizontal.decrease.circle", description: Text("试试其他关键词，或切回全部节点。")) } }
    }
    private var progressStrip: some View {
        HStack(spacing: 10) {
            if store.speedBatchRunning {
                ProgressView().controlSize(.small).frame(width: 14, height: 14)
                Text(store.speedTestingNode.map { "正在测速 · \($0)" } ?? "正在准备测速").lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if let progress = store.speedProgress {
                    ProgressView(value: Double(progress.checked), total: Double(max(1, progress.total))).frame(width: 100)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: progress.checked)
                    Text("\(progress.checked) / \(progress.total)").monospacedDigit()
                }
                Button("取消", action: store.cancelNodeSpeed).buttonStyle(.plain).foregroundStyle(VPNTheme.accent).keyboardShortcut(.cancelAction)
            } else {
                Image(systemName: store.speedProgress == nil ? "info.circle" : "checkmark.circle")
                Text(store.speedProgress.map { $0.cancelled == true ? "已取消 · 完成 \($0.checked) / \($0.total)" : "本次测速完成 · \($0.checked) 个节点" } ?? "选择节点即可测速，结果会逐条更新。")
                Spacer()
                Text("显示 \(filtered.count) 项").monospacedDigit()
            }
        }.font(.system(size: 11)).foregroundStyle(VPNTheme.secondary).frame(height: 22)
    }
    private var actions: some View {
        HStack(spacing: 10) {
            Button("设为当前出口") { if let node = selected.first { store.select(node) } }.buttonStyle(VPNButtonStyle(prominent: true)).disabled(selected.count != 1 || !store.canMutate)
            Button("测速所选") { store.startNodeSpeed(selected) }.disabled(selected.isEmpty || !canTest)
            Button("测速列表") { store.startNodeSpeed(filtered) }.disabled(filtered.isEmpty || !canTest)
            if store.status?.settings.staticExit?.enabled == true {
                Button("ISP 测试") { store.page = .ispTest }.disabled(!store.canMutate)
            }
            Spacer(minLength: 0)
            Menu("更多") {
                Button("多站点复测所选节点") { if let node = selected.first, let key = node.identityKey { store.action("多站点复测", channel: "nodes:test-recommended", payload: ["identityKey": key]) } }.disabled(selected.count != 1 || selected.first?.identityKey == nil || !canTest)
                Button("UDP 探测所选节点") { store.action("启动 UDP 探测", channel: "nodes:start-udp-batch", payload: ["nodeNames": selected.filter(\.isProvider).map(\.name)]) }.disabled(selected.isEmpty || !canTest)
            }.fixedSize().disabled(!store.canMutate || !store.running)
        }
    }
}
