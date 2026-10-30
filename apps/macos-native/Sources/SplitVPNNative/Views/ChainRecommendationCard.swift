import SwiftUI

struct ChainRecommendationCard: View {
    let state: ChainScanState
    let canConnect: Bool
    let working: Bool
    let connect: () -> Void
    private var presentation: ChainRecommendationPresentation { ChainRecommendationPresentation(state) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(presentation.title).font(.system(size: 19, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(presentation.detail).font(.system(size: 12)).foregroundStyle(VPNTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(presentation.node?.exitIp.map { "ISP 出口：\($0)" } ?? "扫描不会切换正在使用的机场")
                    .font(.system(size: 11)).foregroundStyle(VPNTheme.secondary)
                Spacer()
                Button(working ? "处理中…" : presentation.node?.requiresRefresh == true ? "复核并连接" : "连接推荐链路", action: connect)
                    .buttonStyle(VPNButtonStyle(prominent: true)).disabled(!canConnect)
            }
        }.detailCard(padding: 16)
    }
}
