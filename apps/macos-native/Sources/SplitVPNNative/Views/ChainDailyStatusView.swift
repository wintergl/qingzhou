import SwiftUI

struct ChainDailyStatusView: View {
    let state: ChainScanState
    let fallbackCurrent: String?
    let fallbackConnected: Bool
    var pending: ChainUseState? = nil
    var runtimeUncertain = false
    var canSwitch = false
    var switchRoute: ((ChainScanRow) -> Void)? = nil
    let select: (String) -> Void
    private var routine: ChainRoutineState? { state.routine }
    private var connected: Bool { routine.map { $0.connectionState == "connected" } ?? fallbackConnected }
    private var currentID: String? { routine?.currentIdentityKey ?? routine?.preferredIdentityKey }
    private var name: String? {
        if connected { return routine?.currentNodeName ?? fallbackCurrent }
        return state.results.first { $0.id == currentID }?.nodeName
    }
    private var backups: [ChainScanRow] {
        let rows = (routine?.backupIdentityKeys ?? []).compactMap { key in state.results.first { $0.id == key } }
        var groups: [String] = []
        for row in rows {
            let group = row.subscriptionId ?? row.subscriptionName ?? ""
            if !groups.contains(group) { groups.append(group) }
        }
        return groups.flatMap { group in rows.filter { ($0.subscriptionId ?? $0.subscriptionName ?? "") == group } }
    }
    private var verification: String {
        guard connected else { return "连接后复核连通性和出口" }
        let time = ChainComparisonPresentation.relativeTime(routine?.verification.checkedAt)
        switch routine?.verification.status {
        case "passed": return "复核通过 · \(time)"
        case "failed": return "复核未通过 · \(time)"
        default: return "尚未复核当前环境"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(connected ? routine?.currentSelectionConfirmed == true ? "当前使用" : "已选线路" : "日常线路").font(.system(size: 12, weight: .medium)).foregroundStyle(VPNTheme.secondary)
                if let currentID {
                    Button(name ?? "连接信息待确认") { select(currentID) }
                        .buttonStyle(.plain).font(.system(size: 15, weight: .semibold))
                        .lineLimit(1).help(name ?? "").accessibilityIdentifier("isp-current-route")
                } else {
                    Text(connected ? name ?? "连接信息待确认" : "先验证线路，即可连接和设置备用")
                        .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(runtimeUncertain ? "待确认" : connected ? "已连接" : "未连接")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(runtimeUncertain ? VPNTheme.warning : connected ? VPNTheme.green : VPNTheme.secondary)
            }
            HStack(spacing: 18) {
                Text(runtimeUncertain ? "请先检查并恢复网络" : verification)
                    .foregroundStyle(runtimeUncertain || routine?.verification.status == "failed" ? VPNTheme.warning : VPNTheme.secondary)
                    .accessibilityIdentifier("isp-verification-status")
                Text("性能测量 · \(ChainComparisonPresentation.relativeTime(routine?.performanceTestedAt))\(routine?.performanceOtherEnvironment == true ? "（其他环境）" : "")")
                    .foregroundStyle(VPNTheme.secondary).accessibilityIdentifier("isp-performance-age")
                Spacer(minLength: 0)
            }.font(.system(size: 11)).lineLimit(1)
            Divider().opacity(0.5)
            HStack {
                Text("备用线路").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("每个订阅最多两条 · 点击切换").font(.system(size: 11)).foregroundStyle(VPNTheme.secondary)
            }
            if backups.isEmpty {
                Text("还没有已验证的备用，完成性能比较后会从各订阅选入。")
                    .font(.system(size: 12)).foregroundStyle(VPNTheme.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(backups) { row in backup(row) }
                }
            }
            Text("连续异常时也会自动复核备用，确认可用后切换。")
                .font(.system(size: 11)).foregroundStyle(VPNTheme.secondary)
        }.detailCard(padding: 14)
    }
    private func backup(_ row: ChainScanRow) -> some View {
        let target = pending?.active == true && pending?.identityKey == row.id
        let eligible = ChainComparisonPresentation(state: state).canApply(row)
        return Button { switchRoute?(row) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(row.subscriptionName ?? "已验证备用").font(.system(size: 10)).foregroundStyle(VPNTheme.secondary)
                    Spacer(minLength: 6)
                    Text(target ? "切换中…" : pending?.active == true ? "备用" : connected ? "切换 →" : "连接 →")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(target ? VPNTheme.secondary : VPNTheme.accent)
                }
                Text(row.nodeName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("响应 \(ChainComparisonPresentation.number(row.latencyMs, decimals: 0)) ms · 下载 \(ChainComparisonPresentation.number(row.downloadMbps)) Mbps")
                    .font(.system(size: 10)).foregroundStyle(VPNTheme.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
        }.buttonStyle(ChainBackupButtonStyle(target: target))
            .disabled(!canSwitch || !eligible || pending?.active == true || runtimeUncertain || switchRoute == nil)
            .help(target ? "正在复核并切换这条线路" : eligible ? "复核通过后切换到 \(row.nodeName)" : "线路结果已变化，请先重新测试")
            .accessibilityLabel("\(row.subscriptionName ?? "备用")，\(row.nodeName)，\(target ? "正在切换" : "切换线路")")
            .accessibilityIdentifier("isp-backup-\(row.id)")
    }
}

private struct ChainBackupButtonStyle: ButtonStyle {
    let target: Bool
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(VPNTheme.text).padding(.horizontal, 14).padding(.vertical, 6)
            .background(target || hovered && enabled ? VPNTheme.selection : VPNTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(target ? VPNTheme.accent : VPNTheme.border, lineWidth: target ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10)).opacity(configuration.isPressed ? 0.8 : 1)
            .onHover { hovered = $0 }
    }
}
