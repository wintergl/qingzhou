import SwiftUI

struct ChainLeaderCards: View {
    let state: ChainScanState
    var compact = false
    var activeStrategy: String? = nil
    var selectedID: String? = nil
    var select: (String, ChainScanRow) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: String?
    @FocusState private var focused: String?
    private var presentation: ChainComparisonPresentation { ChainComparisonPresentation(state: state) }

    var body: some View {
        HStack(spacing: 12) {
            summary("balanced")
                .background(VPNTheme.hero, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(VPNTheme.accent.opacity(0.30)))
            HStack(spacing: 0) {
                summary("download")
                Divider().padding(.vertical, 14)
                summary("latency")
            }.background(VPNTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(VPNTheme.border))
        }.frame(height: compact ? 96 : 124)
    }
    private func summary(_ strategy: String) -> some View {
        let row = presentation.leader(strategy)
        let primary = strategy == "balanced"
        let color = strategy == "download" ? VPNTheme.chartBlue : VPNTheme.accent
        let emphasized = hovered == strategy || focused == strategy || (selectedID != nil && selectedID == row?.id && activeStrategy == strategy)
        return Button {
            if let row { select(strategy, row) }
        } label: {
            VStack(alignment: .leading, spacing: compact ? 7 : 9) {
                HStack(spacing: 5) {
                    Image(systemName: primary ? "arrow.triangle.branch" : strategy == "download" ? "arrow.down" : "bolt")
                        .foregroundStyle(color)
                    Text(title(strategy, row: row)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        .foregroundStyle(primary ? VPNTheme.accent : VPNTheme.text)
                    Spacer(minLength: 2)
                    if primary, let score = row?.balancedScore {
                        Text("综合 \(ChainComparisonPresentation.number(score))").font(.system(size: 11, weight: .medium))
                            .foregroundStyle(VPNTheme.accent)
                    } else if row != nil {
                        Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(VPNTheme.secondary)
                    }
                }
                if primary {
                    Text(row?.nodeName ?? (state.results.isEmpty ? "先测试，再比较线路" : "暂无完整通过的线路"))
                        .font(.system(size: compact ? 14 : 15, weight: .semibold)).lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        readout(row?.downloadMbps, unit: "Mbps", decimals: 1, size: compact ? 17 : 20)
                        Text("/").font(.system(size: 12)).foregroundStyle(VPNTheme.secondary)
                        readout(row?.latencyMs, unit: "ms", decimals: 0, size: compact ? 17 : 20)
                    }
                } else {
                    readout(strategy == "download" ? row?.downloadMbps : row?.latencyMs, unit: strategy == "download" ? "Mbps" : "ms", decimals: strategy == "download" ? 1 : 0, size: compact ? 23 : 27)
                    Text(row?.nodeName ?? "暂无通过的线路").font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                if !compact {
                    Text(primary ? "兼顾下载、响应与波动 · 点击查看" : strategy == "download" ? row.map { "约 \(ChainComparisonPresentation.number(($0.downloadMbps ?? 0) / 8)) MB/s · 点击比较" } ?? "完整通过后参与比较" : "耗时越低越快 · 点击比较")
                        .font(.system(size: 11)).foregroundStyle(primary ? VPNTheme.text.opacity(0.78) : VPNTheme.secondary).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, compact ? 12 : 15).padding(.vertical, 10)
                .background(emphasized ? VPNTheme.selection.opacity(0.65) : .clear, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(focused == strategy ? VPNTheme.accent : emphasized ? VPNTheme.accent.opacity(0.6) : .clear, lineWidth: focused == strategy ? 2 : 1))
                .contentShape(RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(ChainSummaryButtonStyle()).disabled(row == nil)
            .focused($focused, equals: strategy)
            .onHover { inside in hovered = inside ? strategy : nil }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: emphasized)
            .help(row.map { $0.nodeName + "\n" + ($0.comparisonReason ?? "完整通过测试后参与当前范围推荐") } ?? "只有完整通过测试的线路才参与推荐")
            .accessibilityIdentifier("isp-leader-\(strategy)")
            .accessibilityElement(children: .combine)
    }
    private func readout(_ value: Double?, unit: String, decimals: Int, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(ChainComparisonPresentation.number(value, decimals: decimals))
                .font(.system(size: size, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(unit).font(.system(size: 11)).foregroundStyle(VPNTheme.text.opacity(0.76))
        }
    }
    private func title(_ strategy: String, row: ChainScanRow?) -> String {
        let category = strategy == "balanced" ? "综合" : strategy == "download" ? "下载" : "响应"
        guard let row else { return strategy == "balanced" ? "综合推荐" : "\(category)最快" }
        if state.stale || row.otherEnvironment == true { return "上次\(category)成绩" }
        if row.requiresRefresh == true { return "已测\(category) · 较早成绩" }
        if !presentation.comparisonReady { return "已测\(category)领先" }
        return "已测\(category)\(strategy == "balanced" ? "推荐" : "最快")"
    }
}

private struct ChainSummaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.72 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
