import SwiftUI

struct ChainScanProgressView: View {
    let state: ChainScanState
    let rowCount: Int
    let measuredCount: Int
    let passedCount: Int
    var pausing = false
    private var presentation: ChainProgressPresentation { ChainProgressPresentation(state: state) }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let p = state.progress, p.total > 0 {
                HStack {
                    Text(presentation.title).fontWeight(.medium)
                    Spacer(minLength: 6)
                    if let timing = presentation.timing { Text(timing).foregroundStyle(VPNTheme.secondary) }
                }.font(.system(size: 12)).monospacedDigit()
                if state.automatic != true {
                    ProgressView(value: Double(p.completed), total: Double(max(1, p.total)))
                        .tint(VPNTheme.accent).accessibilityLabel(presentation.title)
                }
            }
            HStack(spacing: 6) {
                Circle().fill(state.waitingReason != nil ? VPNTheme.warning : state.running ? VPNTheme.green : VPNTheme.secondary).frame(width: 6, height: 6)
                Text(pausing ? "正在结束当前采样，随后暂停" : presentation.phase).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(rowCount) 条 · \(measuredCount) 已测 · \(passedCount) 完整通过").fixedSize().monospacedDigit()
            }.font(.system(size: 11)).foregroundStyle(VPNTheme.secondary)
            if state.running, let retry = state.progress?.earliestRetryAt.flatMap(ChainProgressPresentation.clock) {
                Text("失败节点最早可重试：\(retry)").font(.system(size: 11)).foregroundStyle(VPNTheme.secondary)
            }
        }.accessibilityIdentifier("isp-scan-progress")
            .help("进度按本轮实际任务计算，缓存跳过也计入已处理；预计时间随实际采样调整，网络等待时暂停估算。")
    }
}
