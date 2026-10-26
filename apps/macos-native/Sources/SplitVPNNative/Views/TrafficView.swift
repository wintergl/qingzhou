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
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "流量", subtitle: "观察流量趋势，查看每条连接的实际出口")
            HStack {
                Metric(title: "上传速率", value: "\(byteText(store.traffic?.rates.upload ?? 0))/s")
                Metric(title: "下载速率", value: "\(byteText(store.traffic?.rates.download ?? 0))/s")
                VStack(alignment: .leading, spacing: 8) {
                    Text("累计传输").foregroundStyle(VPNTheme.secondary).font(.system(size: 13))
                    Label(byteText(store.traffic?.snapshot?.uploadTotal ?? 0), systemImage: "arrow.up")
                    Label(byteText(store.traffic?.snapshot?.downloadTotal ?? 0), systemImage: "arrow.down")
                }.font(.system(size: 14, weight: .medium)).monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
                Metric(title: "活跃连接", value: "\(store.traffic?.snapshot?.connectionCount ?? 0)")
            }.detailCard(padding: 18)
            Chart {
                ForEach(Array((store.traffic?.samples ?? []).suffix(90).enumerated()), id: \.offset) { index, sample in
                    LineMark(x: .value("采样", index), y: .value("字节 / 秒", sample.upload)).foregroundStyle(by: .value("方向", "上传"))
                    LineMark(x: .value("采样", index), y: .value("字节 / 秒", sample.download)).foregroundStyle(by: .value("方向", "下载"))
                }
            }.chartXAxis(.hidden)
                .chartForegroundStyleScale(["上传": VPNTheme.chartBlue, "下载": VPNTheme.accent])
                .chartYAxis { AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(VPNTheme.border.opacity(0.5))
                    AxisValueLabel(anchor: .trailing) { if let bytes = value.as(Double.self) { Text(byteText(bytes)).font(.system(size: 10)) } }
                } }
                .frame(height: 140).detailCard(padding: 18)
            HStack { TextField("筛选目标、进程或出口", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 340); Toggle("仅私有网络流量", isOn: $onlyCompany).toggleStyle(.checkbox); Spacer(); Text(store.activity.lowPower ? "每 5 秒更新" : "每 2 秒更新").foregroundStyle(.secondary) }
            Table(connections) {
                TableColumn("目标") { Text($0.displayTarget).textSelection(.enabled).padding(.vertical, 10) }.width(min: 170, ideal: 240)
                TableColumn("进程") { Text($0.process ?? "—").foregroundStyle(.secondary) }.width(min: 100, ideal: 130)
                TableColumn("匹配规则") { Text("\($0.rule) \($0.rulePayload)").lineLimit(1) }.width(min: 130, ideal: 170)
                TableColumn("实际出口") { Text($0.chains.joined(separator: " → ")).lineLimit(2) }.width(min: 150, ideal: 190)
                TableColumn("上传 / 下载") { Text("\(byteText($0.upload)) / \(byteText($0.download))").monospacedDigit() }.width(145)
            }.tableCard()
            if let error = store.traffic?.error { Text(error).foregroundStyle(VPNTheme.warning) }
        }.padding(28)
    }
}
