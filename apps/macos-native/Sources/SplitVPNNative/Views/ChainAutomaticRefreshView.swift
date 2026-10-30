import SwiftUI

struct ChainAutomaticRefreshView: View {
    let configuration: ChainAutoRefreshState
    let working: Bool
    let close: () -> Void
    let save: (Bool, Int) -> Void
    @State private var minutes: Int
    init(configuration: ChainAutoRefreshState, working: Bool, close: @escaping () -> Void, save: @escaping (Bool, Int) -> Void) {
        self.configuration = configuration; self.working = working; self.close = close; self.save = save
        _minutes = State(initialValue: configuration.intervalMinutes)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("省电自动维护").font(.system(size: 23, weight: .semibold)); Spacer(); Button("关闭", action: close).disabled(working) }
            Text("验证一条线路就能开始，每个启用的订阅各保留两条已验证备选。")
                .font(.system(size: 14, weight: .medium))
            Text(configuration.message).font(.system(size: 13)).foregroundStyle(VPNTheme.accent)
            VStack(alignment: .leading, spacing: 12) {
                Text("省电维护").font(.system(size: 13, weight: .medium))
                Text("常用线路会记住，其他节点不会自动加入。24 小时内的成功成绩跳过完整测速，到期后才少量更新；需要全面比较时，可手动重新比较。")
                    .font(.system(size: 12)).foregroundStyle(VPNTheme.secondary).fixedSize(horizontal: false, vertical: true)
                Text("每两小时最多维护三条，测完即结束，不持续占用后台。")
                    .font(.system(size: 12)).foregroundStyle(VPNTheme.secondary).fixedSize(horizontal: false, vertical: true)
            }.detailCard(padding: 16)
            Text("仅接通电源时维护；低电量模式、睡眠或网络变化后暂缓。连续两条失败会结束本批，旧成功成绩保留为待复核的历史参考。")
                .font(.system(size: 12)).foregroundStyle(VPNTheme.secondary).fixedSize(horizontal: false, vertical: true)
            Text("需要保持轻舟运行。退出应用会停止，重新启动后恢复；点击“暂停测试”会保留暂停状态。ISP 连接连续异常时会另行复核备用线路，确认可用后自动切换，两次尝试至少间隔五分钟。")
                .font(.system(size: 12)).foregroundStyle(VPNTheme.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if configuration.enabled && !configuration.paused {
                    Button("关闭省电维护") { save(false, minutes) }.disabled(working)
                }
                Spacer()
                Button(working ? "保存中…" : configuration.paused ? "恢复省电维护" : configuration.enabled ? "保存" : "开启省电维护") {
                    save(true, minutes)
                }.buttonStyle(VPNButtonStyle(prominent: true)).disabled(working)
                    .accessibilityIdentifier("isp-enable-auto-refresh")
            }
        }.padding(26).frame(width: 620).background(VPNTheme.background)
            .foregroundStyle(VPNTheme.text).buttonStyle(VPNButtonStyle()).tint(VPNTheme.accent)
            .interactiveDismissDisabled(working)
    }
}
