import SwiftUI

struct RootTabView: View {
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
    }
}
