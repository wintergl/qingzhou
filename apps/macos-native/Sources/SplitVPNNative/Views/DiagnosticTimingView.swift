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
            Text(record?.nextCheckText(pausedReason: pausedReason) ?? "连接后自动检测")
                .font(.system(size: 11)).foregroundStyle(VPNTheme.secondary.opacity(0.85))
        }
        .help(record?.checkedAt.map { "检测完成：\(dateText($0))" } ?? "自动检查不会切换当前节点。")
        .accessibilityElement(children: .combine)
    }
}
