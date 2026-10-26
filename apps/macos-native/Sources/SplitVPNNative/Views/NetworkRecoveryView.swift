import SwiftUI

struct MihomoUptimeView: View {
    @ObservedObject var store: VPNStore
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Label(store.statusKnown ? store.running ? "内核已运行 \(RuntimeTime.uptime(store.status?.mihomo.startedAt, at: context.date))" : "内核未运行" : "内核状态未知", systemImage: "clock")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

struct NetworkRecoveryView: View {
    @ObservedObject var store: VPNStore
    var compact = false
    @State private var highlighted = false
    private var recovery: NetworkRecoveryStatus? { store.statusKnown ? store.status?.mihomo.networkRecovery : nil }
    var body: some View {
        if let recovery, recovery.active || recovery.latest != nil {
            HStack(alignment: .center, spacing: 10) {
                if recovery.state == "recovering" || (!recovery.active && recovery.latest?.outcome == "checking") {
                    ProgressView().controlSize(.small).frame(width: 14)
                } else {
                    Circle().fill(tone(recovery)).frame(width: 5, height: 5).frame(width: 14)
                }
                Text(summary(recovery)).foregroundStyle(recovery.active || highlighted ? tone(recovery) : VPNTheme.secondary)
                    .lineLimit(compact ? 2 : 3).fixedSize(horizontal: false, vertical: true)
                    .help(recovery.error ?? recovery.latest?.title ?? "")
                if !compact {
                    Spacer(minLength: 4)
                    if recovery.state == "failed" {
                        Button("重试") { store.action("重试网络恢复", channel: "vpn:retry-recovery") }
                            .disabled(!store.canMutate).foregroundStyle(VPNTheme.warning)
                    }
                    Button { store.page = .diagnostics } label: {
                        HStack(spacing: 3) { Text("详情"); Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)) }
                    }.foregroundStyle(VPNTheme.accent)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: compact ? 11 : 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, compact ? 0 : 6)
            .background(highlighted && !compact ? VPNTheme.green.opacity(0.06) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .task(id: recovery.latest?.id.description.appending(recovery.latest?.outcome ?? "")) {
                highlighted = recovery.latest?.outcome == "verified" && RuntimeTime.parse(recovery.latest?.checkedAt ?? recovery.latest?.finishedAt).map { Date().timeIntervalSince($0) < 8 } == true
                if highlighted {
                    try? await Task.sleep(for: .seconds(8))
                    if !Task.isCancelled { highlighted = false }
                }
            }
        }
    }
    private func tone(_ recovery: NetworkRecoveryStatus) -> Color {
        if recovery.state == "failed" || recovery.state == "helper-update-required" { return VPNTheme.warning }
        if recovery.active { return VPNTheme.accent }
        return recovery.latest?.outcome == "verified" ? VPNTheme.green : VPNTheme.secondary
    }
    private func summary(_ recovery: NetworkRecoveryStatus) -> String {
        if let detail = recovery.detail { return detail }
        guard let record = recovery.latest else { return "" }
        let result: String
        switch record.outcome {
        case "verified": result = "代理访问已验证"
        case "unverified": result = "代理访问尚未确认"
        case "checking": result = "正在检查代理访问"
        case "failed": result = "恢复失败"
        case "cancelled": result = "已取消"
        case "interrupted": result = "网络再次变化"
        default: result = "请查看详情"
        }
        return "最近恢复：\(shortTime(record.finishedAt)) · \(record.durationText) · \(result)"
    }
    private func shortTime(_ stamp: String) -> String {
        guard let date = RuntimeTime.parse(stamp) else { return "时间未知" }
        let formatter = DateFormatter(); formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

struct NetworkRecoveryHistoryView: View {
    let records: [NetworkRecoveryRecord]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最近网络恢复").font(.headline)
            Text("保留本次后台运行期间最近 10 次记录；代理检查不代表所有网站或私有网络可用。")
                .font(.caption).foregroundStyle(.secondary)
            if records.isEmpty { Text("暂无恢复记录").foregroundStyle(.secondary) }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(records) { record in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.title)
                                Text("\(record.timeText) · \(record.reasonTitle) · 耗时 \(record.durationText)").foregroundStyle(.secondary)
                                if let error = record.error { Text(error).foregroundStyle(VPNTheme.warning).textSelection(.enabled) }
                            }
                            Divider()
                        }
                    }
                }.frame(maxHeight: 180)
            }
        }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).detailCard()
    }
}
