import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var appState: SplitVpnAppState
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TabView {
            ConnectScreen()
                .tabItem {
                    Label("连接", systemImage: "power")
                }

            SubscriptionScreen()
                .tabItem {
                    Label("订阅", systemImage: "link")
                }

            NodesScreen()
                .tabItem {
                    Label("节点", systemImage: "point.3.connected.trianglepath.dotted")
                }

            RulesScreen()
                .tabItem {
                    Label("规则", systemImage: "list.bullet.rectangle")
                }

            MoreScreen()
                .tabItem {
                    Label("更多", systemImage: "ellipsis.circle")
                }
        }
        .tint(VPNTheme.accent)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await appState.refreshVPNStatus()
                await appState.updateDueSubscriptions()
                let seconds: UInt64 = appState.isTunnelRunning && !ProcessInfo.processInfo.isLowPowerModeEnabled ? 3 : 15
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }
}
