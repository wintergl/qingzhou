import SwiftUI

struct ChainComparisonTable: View {
    let rows: [ChainScanRow]
    let state: ChainScanState
    @Binding var selection: String?
    let downloadMaximum: Double
    let latencyMinimum: Double
    @FocusState private var tableFocused: Bool
    @Environment(\.controlActiveState) private var activeState
    private func bright(_ row: ChainScanRow) -> Bool { selection == row.id && tableFocused && activeState == .key }
    private func ink(_ row: ChainScanRow, secondary: Bool = false) -> Color {
        bright(row) ? Color.white.opacity(secondary ? 0.88 : 1) : secondary ? VPNTheme.secondary : VPNTheme.text
    }
    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn("线路 / 排名") { row in
                HStack(alignment: .top, spacing: 9) {
                    Text(row.rank.map(String.init) ?? "—")
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(bright(row) ? Color.white : row.rank == 1 ? VPNTheme.accent : VPNTheme.secondary)
                        .frame(width: 23, height: 23).background(bright(row) ? Color.white.opacity(0.16) : row.rank == 1 ? VPNTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.nodeName).font(.system(size: 13, weight: .medium)).foregroundStyle(ink(row)).lineLimit(1).help(row.nodeName)
                        Text(status(row)).font(.system(size: 11))
                            .foregroundStyle(bright(row) ? Color.white.opacity(0.88) : row.status == "available" || row.status == "pending" ? VPNTheme.secondary : VPNTheme.warning)
                    }
                }.padding(.vertical, 6)
            }.width(min: 155, ideal: 235)
            TableColumn("下载 Mbps ↑") { row in
                metric(row.downloadMbps, unit: "Mbps", decimals: 1, fraction: (row.downloadMbps ?? 0) / max(downloadMaximum, 0.01), color: VPNTheme.chartBlue, passed: row.status == "available", reference: row.requiresRefresh == true || state.stale, selected: bright(row))
            }.width(115)
            TableColumn("响应 ms ↓") { row in
                metric(row.latencyMs, unit: "ms", decimals: 0, fraction: latencyMinimum / max(row.latencyMs ?? 0, 0.01), color: VPNTheme.green, passed: row.status == "available", reference: row.requiresRefresh == true || state.stale, selected: bright(row))
            }.width(100)
            TableColumn("综合分") { row in
                Text(ChainComparisonPresentation.number(row.balancedScore))
                    .font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle(ink(row, secondary: row.status != "available"))
            }.width(62)
            TableColumn("测量时间") { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(ChainComparisonPresentation.relativeTime(row.testedAt)).font(.system(size: 12)).foregroundStyle(ink(row))
                    if row.otherEnvironment == true {
                        Text("其他环境").font(.system(size: 11)).foregroundStyle(ink(row, secondary: true))
                    } else if row.environmentUncertain == true {
                        Text("结果待复核").font(.system(size: 11)).foregroundStyle(bright(row) ? Color.white : VPNTheme.warning)
                    } else if row.requiresRefresh == true && row.status != "pending" {
                        Text("较早测量").font(.system(size: 11)).foregroundStyle(ink(row, secondary: true))
                    } else if row.status == "available" {
                        Text("近期测量").font(.system(size: 11)).foregroundStyle(ink(row, secondary: true))
                    }
                }.help(row.testedAt.map { chainDate($0) } ?? "尚未采样")
            }.width(88)
        }.focused($tableFocused).tint(VPNTheme.buttonAccent).tableCard().accessibilityIdentifier("isp-comparison-table")
            .overlay {
                if rows.isEmpty { Text("没有符合条件的线路").font(.system(size: 13)).foregroundStyle(VPNTheme.secondary) }
            }
    }
    private func status(_ row: ChainScanRow) -> String {
        if state.queuedIdentityKeys?.contains(row.id) == true { return row.status == "pending" ? "已排队 · 优先测试" : "已排队 · 优先重测" }
        if state.testing == true && state.currentNode == row.nodeName { return row.status == "pending" ? "正在测试" : "正在复测 · 保留上次成绩" }
        let current = state.routine?.connectionState == "connected" && row.id == state.routine?.currentIdentityKey
        let prefix = current ? "当前线路 · " : ""
        if row.status == "pending" { return "尚未测试" }
        if row.status != "available" { return row.status == "unstable" ? "部分通过 · 不参与推荐" : "未连通 · 不参与推荐" }
        if row.otherEnvironment == true || state.stale { return prefix + (row.connectionEligible == true ? "其他环境成绩 · 可先复核" : "其他环境 · 待验证") }
        if row.environmentUncertain == true { return prefix + "最近测试未通过 · 保留原成绩" }
        if row.requiresRefresh == true { return prefix + "性能测量较早 · 可复核使用" }
        var tags: [String] = []
        if row.id == state.recommendedIdentityKey { tags.append(state.running && state.canUseCachedResults != true ? "暂领先" : "已测排名第一") }
        if state.routine?.connectionState == "connected", row.id == state.routine?.currentIdentityKey {
            tags.append(state.routine?.currentSelectionConfirmed == true ? "当前使用" : "已选线路")
        } else if row.id == state.connectedIdentityKey { tags.append("上次使用") }
        return tags.isEmpty ? "完整通过" : tags.joined(separator: " · ")
    }
    private func metric(_ value: Double?, unit: String, decimals: Int, fraction: Double, color: Color, passed: Bool, reference: Bool, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(ChainComparisonPresentation.number(value, decimals: decimals)).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(selected ? Color.white : passed && !reference ? VPNTheme.text : VPNTheme.secondary)
            GeometryReader { geometry in
                Capsule().fill(selected ? Color.white.opacity(0.22) : VPNTheme.border)
                if let value, value.isFinite, value > 0, passed {
                    Capsule().fill(selected ? Color.white.opacity(0.88) : reference ? VPNTheme.secondary.opacity(0.25) : color.opacity(0.85)).frame(width: geometry.size.width * max(0, min(1, fraction.isFinite ? fraction : 0)))
                }
            }.frame(height: 3)
        }.padding(.trailing, 8).accessibilityElement(children: .ignore)
            .accessibilityLabel("\(ChainComparisonPresentation.number(value, decimals: decimals)) \(unit)\(passed ? reference ? "，历史参考" : "" : "，未完整通过测试")")
    }
}
