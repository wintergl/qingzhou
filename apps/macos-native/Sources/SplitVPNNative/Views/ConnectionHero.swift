import SwiftUI

/// A quiet route map gives the connection a visual identity without implying live traffic.
struct ConnectionHero: View {
    @ObservedObject var store: VPNStore
    var compact = false
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 24) {
                heading.frame(minWidth: 230, alignment: .leading)
                Spacer(minLength: 0)
                RouteIllustration().frame(width: compact ? 125 : 175, height: 104).accessibilityHidden(true)
                connectionControl
            }
            VStack(alignment: .leading, spacing: 20) {
                heading
                connectionControl
            }
        }
        .padding(.horizontal, compact ? 24 : 30)
        .padding(.vertical, compact ? 20 : 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 22).fill(VPNTheme.heroInk.gradient)
        }
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.white.opacity(0.08)))
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            HStack(spacing: 8) {
                Circle().fill(store.menuState == .connected ? VPNTheme.heroMuted : .white.opacity(0.4)).frame(width: 6, height: 6)
                Text("连接概览").tracking(2)
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(VPNTheme.heroMuted)
            Text(!store.statusKnown ? store.menuTitle : store.menuState == .connected ? "智能分流中" : store.running || store.connectionServiceUpdateRequired ? store.menuTitle : "从容连接，自由抵达。")
                .font(.system(size: compact ? 30 : 34, weight: .medium)).tracking(-0.8)
                .foregroundStyle(VPNTheme.heroText).fixedSize(horizontal: true, vertical: false)
            Group {
                if store.statusKnown, store.running {
                    MihomoUptimeView(store: store, foreground: VPNTheme.heroMuted)
                } else {
                    Text(!store.statusKnown ? "刷新状态后重新确认连接" : store.menuState == .connecting ? "网络就绪后自动恢复分流" : "选择节点，开启你的网络连接")
                        .font(.system(size: 12))
                }
            }.foregroundStyle(VPNTheme.heroMuted)
        }
    }
    private var connectionControl: some View {
        VStack(alignment: .trailing, spacing: 12) {
            Text(store.menuTitle).font(.system(size: 11, weight: .medium)).foregroundStyle(VPNTheme.heroMuted)
            Button { store.connectOrVerify() } label: {
                Label(store.connectionProtected ? "验证连接" : store.connectionRequested ? "断开 VPN" : "连接 VPN", systemImage: "power")
                    .padding(.horizontal, 7).padding(.vertical, 3)
            }.buttonStyle(VPNButtonStyle())
                .disabled(!store.canControlConnection)
        }.fixedSize()
    }
}

private struct RouteIllustration: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                ForEach(0..<4) { i in
                    Path { p in
                        p.move(to: CGPoint(x: 8, y: h * 0.67))
                        p.addCurve(to: CGPoint(x: w - 8, y: h * (0.08 + Double(i) * 0.28)),
                                   control1: CGPoint(x: w * 0.52, y: h * 0.67),
                                   control2: CGPoint(x: w * 0.46, y: h * (0.08 + Double(i) * 0.28)))
                    }.stroke(VPNTheme.heroMuted.opacity(i == 1 ? 0.85 : 0.22),
                             style: StrokeStyle(lineWidth: i == 1 ? 2 : 1, dash: i == 1 ? [] : [2, 5]))
                    Circle().fill(i == 1 ? VPNTheme.heroMuted : VPNTheme.heroInk)
                        .overlay(Circle().strokeBorder(VPNTheme.heroMuted.opacity(0.65)))
                        .frame(width: i == 1 ? 9 : 6, height: i == 1 ? 9 : 6)
                        .position(x: w - 8, y: h * (0.08 + Double(i) * 0.28))
                }
                Circle().stroke(VPNTheme.heroMuted.opacity(0.15), lineWidth: 8).frame(width: 18, height: 18)
                    .overlay(Circle().fill(VPNTheme.heroMuted).frame(width: 8, height: 8))
                    .position(x: 8, y: h * 0.67)
            }
        }
    }
}
