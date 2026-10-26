import SwiftUI

/// Exact times stay visible; a scheduled check never needs a modal notification.
struct DiagnosticTimingView: View {
    var record: DiagnosticRecord?
    var pausedReason: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if record?.running == true {
                    ProgressView().controlSize(.mini)
                    Text("\(record?.sourceLabel ?? "自动检测")中 · \(MeasurementTime.clock(record?.startedAt))")
                } else {
                    Image(systemName: record?.stale == true ? "clock.badge.exclamationmark" : "clock")
                    Text(record?.checkedAt.map { "\(record?.sourceLabel ?? "上次检测") · \(MeasurementTime.clock($0))" } ?? "等待首次检测")
                }
                if record?.stale == true { Text("已过期").foregroundStyle(VPNTheme.warning) }
                if record?.state == "error" { Text("未完成").foregroundStyle(VPNTheme.warning) }
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(VPNTheme.secondary)
            Text(nextText).font(.system(size: 11)).foregroundStyle(VPNTheme.secondary.opacity(0.85))
        }
        .help(record?.checkedAt.map { "检测完成：\(dateText($0))" } ?? "自动检查不会切换当前节点。")
        .accessibilityElement(children: .combine)
    }
    private var nextText: String {
        if record?.running == true {
            return record?.checkedAt.map { "上次完成 \(MeasurementTime.clock($0))" } ?? "首次检测，结果将在这里更新"
        }
        switch pausedReason {
        case "sleeping": return "休眠期间暂停自动检测"
        case "disconnected": return "连接后自动检测"
        case "recovering": return "连接恢复后继续检测"
        case "node-test": return "节点检测结束后继续自动检查"
        default:
            guard let next = record?.nextCheckAt else { return "连接检测每 5 分钟 · 站点测速每 15 分钟" }
            let minutes = (record?.intervalSeconds ?? 300) / 60
            return "下次 \(MeasurementTime.clock(next)) · 每 \(minutes) 分钟"
        }
    }
}
