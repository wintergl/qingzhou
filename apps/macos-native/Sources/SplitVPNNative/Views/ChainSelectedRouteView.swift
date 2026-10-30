import SwiftUI

struct ChainSelectedRouteView: View {
    let row: ChainScanRow?
    var heading = "所选线路"
    let restriction: String?
    var guidanceWarning = true
    var primaryTitle: String? = nil
    var retestTitle = "单独重测"
    var showRetest = true
    let canConnect: Bool
    let canRetest: Bool
    let working: Bool
    let connect: () -> Void
    let retest: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.map { "\(heading)：\($0.nodeName)" } ?? "选择一条线路查看并操作")
                        .font(.system(size: 14, weight: .semibold)).lineLimit(1).help(row?.nodeName ?? "")
                    Text(row?.status == "available" ? row?.comparisonReason ?? detail : detail)
                        .font(.system(size: 12)).foregroundStyle(VPNTheme.secondary).lineLimit(2)
                        .help(detail).accessibilityIdentifier("isp-route-reason")
                }
                Spacer(minLength: 10)
                if showRetest {
                    Button(retestTitle, action: retest).disabled(!canRetest).accessibilityIdentifier("isp-retest-selected")
                        .help("只重测这一条；持续测试中可优先排队，不影响其他结果")
                }
                Button(working ? "处理中…" : primaryTitle ?? "复核并连接", action: connect)
                    .buttonStyle(VPNButtonStyle(prominent: true)).disabled(!canConnect).accessibilityIdentifier("isp-connect-selected")
                    .help("按提示完成当前操作；测试不会切换连接，使用前会复核连通性和出口")
            }
            Text(restriction ?? "连接前复核连通性和出口；短测速不能代表持续带宽，旧成绩不会因复核而变成新成绩。")
                .font(.system(size: 11)).foregroundStyle(restriction == nil || !guidanceWarning ? VPNTheme.secondary : VPNTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }.detailCard(padding: 11)
    }
    private var detail: String {
        guard let row else { return "点击上方领先线路卡片或表格行，不会自动切换连接。" }
        if row.status == "pending" { return "尚未测试；可以开始批量测试，或只测这一条。" }
        if row.status != "available" {
            let issues = row.errors.map { code in
                switch code {
                case "latency-failed": return "响应检测失败"
                case "download-failed": return "下载检测未完整通过"
                case "exit-ip-failed": return "出口 IP 核对失败"
                case "selector-failed", "client-failed": return "检测入口暂不可用"
                case "cancelled": return "采样已中断"
                default: return "部分检测未通过"
                }
            }
            return Array(Set(issues)).sorted().joined(separator: " · ") + (row.nextRetryAt.map { "；重试时间 \(chainDate($0))" } ?? "")
        }
        return "波动 \(ChainComparisonPresentation.number(row.jitterMs, decimals: 0)) ms · 响应通过 \(row.latencySuccesses)/\(row.latencyAttempts) · 下载通过 \(row.downloadSuccesses)/\(row.downloadAttempts) · 出口 \(row.exitIp ?? "待核对")"
    }
}
