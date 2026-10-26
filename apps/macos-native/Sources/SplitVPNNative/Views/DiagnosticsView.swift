import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var store: VPNStore
    @State private var section = "网络检测"
    @State private var riskSearch = ""
    @State private var showingRiskKey = false
    @State private var riskKey = ""
    @State private var savingRiskKey = false
    init(store: VPNStore, section: String = "网络检测") { self.store = store; _section = State(initialValue: section) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "诊断与风险", subtitle: "连通性、站点表现和风险各自保留真实检测结果")
            Picker("检测项目", selection: $section) { Text("网络检测").tag("网络检测"); Text("节点风险").tag("节点风险"); Text("订阅探测").tag("订阅探测") }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 440, alignment: .leading)
            if section == "网络检测" {
                DiagnosticsNetworkPanel(store: store)
            } else if section == "节点风险" {
                HStack {
                    TextField("搜索节点或出口 IP", text: $riskSearch).textFieldStyle(.roundedBorder).frame(maxWidth: 210)
                    Button("检测当前出口") { store.action("检测风险", channel: "nodes:check-current-risk", payload: ["forceRefresh": true]) }.disabled(!store.canMutate || !store.running || store.riskBatchRunning)
                    Button("全量检测风险") { store.checkAllRisks() }.buttonStyle(VPNButtonStyle(prominent: true)).disabled(!store.canMutate || !store.running || store.riskBatchRunning || store.providerNodes.isEmpty)
                    if store.riskBatchRunning { Button("取消") { store.cancelRiskBatch() } }
                    Spacer(); Text("\(store.risks.count) 条保留记录").foregroundStyle(.secondary)
                }
                if let progress = store.riskProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(progress.checked), total: Double(max(1, progress.total)))
                        Text("\(progress.checked) / \(progress.total) · \(progress.finished ? progress.error != nil ? "未完成" : progress.cancelled ? "已取消" : "已完成" : progress.nodeName ?? "准备检测")")
                            .font(.caption).foregroundStyle(.secondary)
                        if let reason = progress.stoppedReason { Text(reason).font(.caption).foregroundStyle(VPNTheme.warning) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Table(store.risks.filter { riskSearch.isEmpty || "\($0.nodeName) \($0.ip ?? "")".localizedCaseInsensitiveContains(riskSearch) }) {
                    TableColumn("节点") { Text($0.nodeName).lineLimit(1).padding(.vertical, 10) }.width(min: 160, ideal: 240, max: 300)
                    TableColumn("出口 IP") { item in Text(item.ip ?? "—").font(.system(size: 13)) }.width(125)
                    TableColumn("风险") { item in Text(item.label) }.width(75)
                    TableColumn("检测时间") { item in Text(dateText(item.checkedAt)).font(.system(size: 11)).lineLimit(2).help(dateText(item.checkedAt)) }.width(125)
                    TableColumn("说明") { item in Text(item.error ?? item.reasons.joined(separator: "、")).lineLimit(2) }
                }.tableCard()
                Text("全量检测覆盖所有订阅节点，会暂时逐个切换外网出口，结束或取消后恢复原出口；已有连接保留。需要已配置的 ipdata 密钥。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("配置风险密钥") { riskKey = ""; store.riskKeyMessage = nil; showingRiskKey = true }.disabled(!store.canMutate || store.riskBatchRunning)
                    Text(store.riskKeyConfigured ? "原生版密钥已保存在钥匙串" : "旧版加密密钥无法读取时，可在此重新填写，原版数据保留。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let note = store.riskBatchNote { Text(note).font(.caption).foregroundStyle(VPNTheme.warning) }
            } else {
                Text(store.connectionProtected ? "原版正在维护 VPN 连接，先在原版结束连接，再进入订阅探测。" : "订阅探测会临时切换到直连模式，原有分流会暂停。").foregroundStyle(.secondary)
                HStack {
                    Button("进入订阅探测模式") { store.action("启动订阅探测", channel: "subscription-probe:start") }
                    Button("结束订阅探测") { store.action("结束订阅探测", channel: "subscription-probe:stop") }
                    Button("前往节点测速") { store.page = .nodes }
                }.disabled(!store.canMutate || store.connectionProtected)
                Spacer()
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showingRiskKey) {
            VStack(alignment: .leading, spacing: 16) {
                Text("风险检测密钥").font(.title2.weight(.semibold))
                Text("输入 ipdata API Key，保存到 macOS 钥匙串。保存时会补齐 ipdata 的 VPN 分流规则，原版已有的加密密钥保留。").font(.system(size: 14)).foregroundStyle(.secondary)
                SecureField("ipdata API Key", text: $riskKey).textFieldStyle(.roundedBorder).disabled(savingRiskKey)
                if let message = store.riskKeyMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("取消") { riskKey = ""; showingRiskKey = false }.disabled(savingRiskKey)
                    if store.riskKeyConfigured { Button("移除原生版密钥") { Task { savingRiskKey = true; let ok = await store.clearRiskKey(); savingRiskKey = false; if ok { showingRiskKey = false } } }.disabled(savingRiskKey) }
                    Spacer()
                    Button("保存") { Task { savingRiskKey = true; let ok = await store.saveRiskKey(riskKey); savingRiskKey = false; if ok { riskKey = ""; showingRiskKey = false } } }
                        .buttonStyle(VPNButtonStyle(prominent: true)).disabled(savingRiskKey || riskKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 520).buttonStyle(VPNButtonStyle())
        }
    }
}
