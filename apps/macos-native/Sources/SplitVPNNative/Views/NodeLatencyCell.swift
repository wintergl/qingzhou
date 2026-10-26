import SwiftUI

struct NodeLatencyCell: View {
    let node: VPNNode
    var testing: Bool
    var selected: Bool
    var body: some View {
        HStack(spacing: 9) {
            if testing || node.latencyStatus == "testing" {
                ProgressView().controlSize(.small).frame(width: 14, height: 14)
            } else {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(testing || node.latencyStatus == "testing" ? "检测中" : node.latencyText)
                    .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                Text(testing || node.latencyStatus == "testing" ? "正在等待响应" : node.latencyLabel)
                    .font(.system(size: 10)).foregroundStyle(selected ? Color.white.opacity(0.82) : VPNTheme.secondary)
            }
        }.foregroundStyle(selected ? Color.white : tone)
            .padding(.vertical, 3)
            .help(node.latencyFailure == "timeout" ? "请求超时，没有得到有效延迟。可右键重新测速。" : "经此节点访问检测目标的响应耗时，不代表下载带宽。")
            .accessibilityElement(children: .combine)
    }
    private var tone: Color {
        if testing || node.latencyStatus == "testing" { return VPNTheme.accent }
        if node.latencyStatus == "stale" { return VPNTheme.secondary }
        if node.available == false || node.latencyStatus == "unstable" { return VPNTheme.warning }
        return node.delay.map { $0 > 0 ? VPNTheme.green : VPNTheme.warning } ?? VPNTheme.secondary
    }
    private var symbol: String {
        if node.latencyStatus == "stale" { return "clock" }
        if node.available == false { return "exclamationmark.circle" }
        return node.delay.map { $0 > 0 ? "checkmark.circle.fill" : "exclamationmark.circle" } ?? "minus.circle"
    }
}
