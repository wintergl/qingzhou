import SwiftUI

struct ChainConnectionPreparationView: View {
    @ObservedObject var store: VPNStore
    let target: ChainScanRow
    var verificationReady = true
    var verificationReason: String? = nil
    let close: () -> Void
    let apply: () -> Void
    private var nodes: [VPNNode] { store.providerNodes.filter { $0.identityAmbiguous != true } }
    private var front: VPNNode? { nodes.first { $0.name == store.selectedProxy } }
    private var enabled: Bool { store.status?.settings.staticExit?.enabled == true }
    private var ready: Bool { store.running && enabled && front != nil && !store.connectionProtected && store.canMutate && verificationReady }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("准备使用线路").font(.system(size: 23, weight: .semibold)); Spacer(); Button("关闭", action: close).disabled(store.busy != nil) }
            Text(target.nodeName).font(.system(size: 15, weight: .medium))
            Text("先完成 ISP 和 VPN 准备，最后复核并切换到上方线路。每一步只在你点击时执行。")
                .font(.system(size: 12)).foregroundStyle(VPNTheme.secondary)
            VStack(alignment: .leading, spacing: 16) {
                step("VPN 启动节点", ready: front != nil) {
                    if store.running && front != nil {
                        Text(store.selectedProxy).font(.system(size: 12)).lineLimit(1)
                    } else {
                        Picker("前置机场", selection: Binding(get: { front?.identityKey ?? "" }, set: { id in
                            if let node = nodes.first(where: { $0.identityKey == id }) { store.select(node) }
                        })) {
                            Text("请选择机场").tag("")
                            ForEach(nodes) { node in Text(node.name).tag(node.identityKey ?? "") }
                        }.labelsHidden().frame(width: 280).disabled(!store.canMutate || store.connectionProtected)
                    }
                }
                Divider()
                step("启用 ISP 出口", ready: enabled) {
                    if enabled { Text("已开启").foregroundStyle(VPNTheme.green) }
                    else { Button("开启 ISP") { store.setStaticExitEnabled(true) }.disabled(!store.canMutate || front == nil || store.connectionProtected) }
                }
                Text("开启 ISP 会让代理流量经 ISP 出口；如果 VPN 已连接，这一步会应用到当前连接。")
                    .font(.system(size: 11)).foregroundStyle(VPNTheme.secondary)
                Divider()
                step("连接 VPN", ready: store.running) {
                    if store.running { Text("已连接").foregroundStyle(VPNTheme.green) }
                    else { Button("连接 VPN") { store.connectOrVerify() }.disabled(!store.canMutate || front == nil || !enabled) }
                }
            }.detailCard(padding: 18)
            VStack(alignment: .leading, spacing: 0) {
                if let busy = store.busy {
                    HStack {
                        ProgressView().controlSize(.small); Text(busy)
                        Spacer()
                        if store.connectionOperation == .connecting {
                            Button("取消连接") { Task { try? await store.disconnectNow() } }
                        }
                    }.font(.system(size: 12))
                } else if store.connectionProtected {
                    Text("当前连接由其他客户端维护，请先在原客户端断开。").foregroundStyle(VPNTheme.warning)
                } else if let error = store.error {
                    Text(error).font(.system(size: 12)).foregroundStyle(VPNTheme.destructive).textSelection(.enabled)
                }
            }.frame(minHeight: 36, alignment: .leading)
            HStack {
                Text(!verificationReady ? verificationReason ?? "测量条件已变化，请返回重新测试后使用。" : ready ? "准备就绪，复核通过后切换到所选线路。" : "按顺序完成准备，不需要离开对比页。")
                    .font(.system(size: 12)).foregroundStyle(VPNTheme.secondary)
                Spacer()
                Button("复核并使用", action: apply).buttonStyle(VPNButtonStyle(prominent: true)).disabled(!ready)
            }
        }.padding(26).frame(width: 680).background(VPNTheme.background)
            .foregroundStyle(VPNTheme.text).buttonStyle(VPNButtonStyle()).tint(VPNTheme.accent)
            .interactiveDismissDisabled(store.busy != nil)
    }
    private func step<Content: View>(_ title: String, ready: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 9) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle").foregroundStyle(ready ? VPNTheme.green : VPNTheme.secondary)
            Text(title).font(.system(size: 13, weight: .medium)); Spacer(); content().font(.system(size: 12))
        }.frame(minHeight: 36)
    }
}
