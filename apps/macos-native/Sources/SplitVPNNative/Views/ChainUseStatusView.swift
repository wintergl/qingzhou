import SwiftUI

struct ChainUseStatusView: View {
    let state: ChainUseState
    let cancel: () -> Void
    let refresh: () -> Void
    var retry: (() -> Void)? = nil
    var dismiss: (() -> Void)? = nil
    private var stage: Int {
        switch state.phase {
        case "authorizing", "applying": return 1
        case "confirming": return 2
        case "connected": return 3
        default: return 0
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                if state.active && state.phase != "unknown" { ProgressView().controlSize(.small) }
                else { Image(systemName: state.phase == "connected" ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(state.phase == "connected" ? VPNTheme.green : VPNTheme.warning) }
                Text(state.title).font(.system(size: 13, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if state.automatic == true { Text("自动换线").font(.system(size: 10)).foregroundStyle(VPNTheme.secondary) }
                Spacer(minLength: 8)
                if state.phase == "unknown" { Button("刷新状态", action: refresh).accessibilityIdentifier("isp-use-refresh") }
                if state.active {
                    Button(state.cancelRequested ? "取消中…" : "取消切换", action: cancel)
                        .disabled(state.cancelRequested).accessibilityIdentifier("isp-use-cancel")
                } else {
                    if state.phase == "failed", let retry { Button("重试这条", action: retry).accessibilityIdentifier("isp-use-retry") }
                    if let dismiss { Button("收起", action: dismiss).accessibilityIdentifier("isp-use-dismiss") }
                }
            }
            HStack(spacing: 8) {
                if let previous = state.previousNodeName {
                    Text(previous).foregroundStyle(VPNTheme.secondary).lineLimit(1).help(previous)
                    Image(systemName: "arrow.right").foregroundStyle(VPNTheme.secondary)
                }
                Text(state.nodeName ?? "所选线路").fontWeight(.medium).lineLimit(1).help(state.nodeName ?? "所选线路")
            }.font(.system(size: 12)).accessibilityIdentifier("isp-switch-path")
            if state.active && state.phase != "unknown" && !state.cancelRequested {
                HStack(spacing: 14) {
                    ForEach(Array(["复核线路", "切换线路", "确认出口"].enumerated()), id: \.offset) { index, title in
                        Label(title, systemImage: index < stage ? "checkmark.circle.fill" : index == stage ? "circle.inset.filled" : "circle")
                            .foregroundStyle(index <= stage ? VPNTheme.accent : VPNTheme.secondary)
                    }
                }.font(.system(size: 10)).accessibilityIdentifier("isp-switch-steps")
            }
            if let error = state.error {
                Text(error).font(.system(size: 11)).foregroundStyle(VPNTheme.destructive).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("isp-switch-error")
            } else if let result = state.result {
                Text("实际 ISP 出口 \(result.exitIp)").font(.system(size: 11)).foregroundStyle(VPNTheme.secondary)
            } else if state.cancelRequested {
                Text("正在取消切换，等待确认原线路状态。")
                    .font(.system(size: 11)).foregroundStyle(VPNTheme.secondary)
            }
        }.detailCard(padding: 12).accessibilityElement(children: .contain)
            .accessibilityIdentifier("isp-switch-status")
    }
}
