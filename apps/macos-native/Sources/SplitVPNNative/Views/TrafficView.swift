import SwiftUI
import Charts

struct TrafficView: View {
    @ObservedObject var store: VPNStore
    @State private var search = ""
    @State private var onlyCompany = false
    var connections: [TrafficConnection] {
        (store.traffic?.snapshot?.connections ?? []).filter {
            (search.isEmpty || "\($0.displayTarget) \($0.process ?? "") \($0.chains.joined(separator: " "))".localizedCaseInsensitiveContains(search)) &&
            (!onlyCompany || $0.chains.contains("COMPANY"))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "流量", subtitle: "同一内核的实时连接，直接查看流量最终去了哪里")
            HStack {
                Metric(title: "上传速率", value: "\(byteText(store.traffic?.rates.upload ?? 0))/s")
                Metric(title: "下载速率", value: "\(byteText(store.traffic?.rates.download ?? 0))/s")
                Metric(title: "累计上传 / 下载", value: "\(byteText(store.traffic?.snapshot?.uploadTotal ?? 0)) / \(byteText(store.traffic?.snapshot?.downloadTotal ?? 0))")
                Metric(title: "活跃连接", value: "\(store.traffic?.snapshot?.connectionCount ?? 0)")
            }
            Chart {
                ForEach(Array((store.traffic?.samples ?? []).suffix(90).enumerated()), id: \.offset) { index, sample in
                    LineMark(x: .value("采样", index), y: .value("字节 / 秒", sample.upload)).foregroundStyle(by: .value("方向", "上传"))
                    LineMark(x: .value("采样", index), y: .value("字节 / 秒", sample.download)).foregroundStyle(by: .value("方向", "下载"))
                }
            }.chartXAxis(.hidden).frame(height: 170).padding(20).background(VPNTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            HStack { TextField("筛选目标、进程或出口", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 340); Toggle("仅私有网络流量", isOn: $onlyCompany).toggleStyle(.checkbox); Spacer(); Text("每 2 秒更新").foregroundStyle(.secondary) }
            Table(connections) {
                TableColumn("目标") { Text($0.displayTarget).textSelection(.enabled).padding(.vertical, 10) }.width(min: 170, ideal: 240)
                TableColumn("进程") { Text($0.process ?? "—").foregroundStyle(.secondary) }.width(min: 100, ideal: 130)
                TableColumn("匹配规则") { Text("\($0.rule) \($0.rulePayload)").lineLimit(1) }.width(min: 130, ideal: 170)
                TableColumn("实际出口") { Text($0.chains.joined(separator: " → ")).lineLimit(2) }.width(min: 150, ideal: 190)
                TableColumn("上传 / 下载") { Text("\(byteText($0.upload)) / \(byteText($0.download))").monospacedDigit() }.width(145)
            }.tableCard()
            if let error = store.traffic?.error { Text(error).foregroundStyle(.orange) }
        }.padding(32)
    }
}
