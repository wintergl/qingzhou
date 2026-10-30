import SwiftUI

struct ChainSubscriptionControls: View {
    let subscriptions: [Subscription]
    @Binding var selection: String
    let candidateCount: Int
    let running: Bool
    let busy: Bool
    let canRetest: Bool
    let retest: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Picker("订阅范围", selection: $selection) {
                Text("全部订阅").tag("")
                ForEach(subscriptions) { entry in Text(entry.name).tag(entry.id) }
            }.labelsHidden().frame(width: 195).disabled(busy).accessibilityIdentifier("isp-subscription-scope")
            Text(selection.isEmpty ? "可按订阅查看和重测" : "\(candidateCount) 条可测 · 推荐、排名和统计均在此范围内")
                .font(.system(size: 11)).foregroundStyle(VPNTheme.secondary).lineLimit(1)
            Spacer(minLength: 4)
            if !selection.isEmpty {
                Button(busy ? "处理中…" : running ? "暂停并重测此订阅" : "全量重测此订阅", action: retest)
                    .disabled(busy || !canRetest).accessibilityIdentifier("isp-retest-subscription")
                    .help("重测本订阅全部可测节点，跳过新鲜度与失败冷却；保留其他订阅成绩和全部历史")
            }
        }
    }
}
