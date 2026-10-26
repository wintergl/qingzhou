import SwiftUI

/// Decorative route lines are static: network activity never moves surrounding content.
struct ConnectionHero: View {
    @ObservedObject var store: VPNStore
    var compact = false
    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: compact ? 10 : 13) {
                HStack(spacing: 7) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                    Text("连接概览").tracking(1.5)
                }.font(.system(size: 10, weight: .medium)).foregroundStyle(VPNTheme.accent)
                Text(!store.statusKnown ? store.menuTitle : store.menuState == .connected ? "智能分流中" : store.running || store.connectionServiceUpdateRequired ? store.menuTitle : "网络总览")
                    .font(.system(size: compact ? 28 : 30, weight: .semibold)).tracking(-0.5).foregroundStyle(VPNTheme.text)
                if store.statusKnown, store.running {
                    MihomoUptimeView(store: store)
                } else {
                    Text(!store.statusKnown ? "刷新状态后重新确认连接" : store.menuState == .connecting ? "网络就绪后自动恢复分流" : "选择节点后连接 VPN")
                        .font(.system(size: 12)).foregroundStyle(VPNTheme.secondary)
                }
            }
            Spacer(minLength: 0)
            RouteIllustration().frame(width: 130, height: 90).accessibilityHidden(true)
                .layoutPriority(-1)
            VStack(alignment: .trailing, spacing: 14) {
                StatusPill(title: store.menuTitle, passed: store.menuState == .connected)
                Button { store.connectOrVerify() } label: {
                    Label(store.connectionProtected ? "验证连接" : store.connectionRequested ? "断开 VPN" : "连接 VPN", systemImage: "power")
                }.buttonStyle(VPNButtonStyle(prominent: !store.connectionRequested || store.connectionProtected,
                                             destructive: store.connectionRequested && !store.connectionProtected))
                    .disabled(!store.canControlConnection)
            }
        }.padding(.horizontal, 24).padding(.vertical, compact ? 18 : 24).frame(maxWidth: .infinity, alignment: .leading)
            .background(VPNTheme.hero, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(VPNTheme.accent.opacity(0.12)))
    }
}

private struct RouteIllustration: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                ForEach(0..<3) { i in
                    Path { p in
                        p.move(to: CGPoint(x: 4, y: h * 0.85))
                        p.addCurve(to: CGPoint(x: w - 4, y: h * (0.12 + Double(i) * 0.28)),
                                   control1: CGPoint(x: w * 0.5, y: h * 0.85), control2: CGPoint(x: w * 0.45, y: h * (0.12 + Double(i) * 0.28)))
                    }.stroke(VPNTheme.accent.opacity(i == 1 ? 0.5 : 0.15), style: StrokeStyle(lineWidth: i == 1 ? 1.5 : 1, dash: i == 1 ? [] : [3, 5]))
                    Circle().fill(VPNTheme.hero).overlay(Circle().stroke(VPNTheme.accent.opacity(0.4)))
                        .frame(width: 6, height: 6).position(x: w - 4, y: h * (0.12 + Double(i) * 0.28))
                }
                Circle().fill(VPNTheme.accent).frame(width: 7, height: 7).position(x: 4, y: h * 0.85)
            }
        }
    }
}
