import SwiftUI

struct NodesScreen: View {
    @EnvironmentObject private var appState: SplitVpnAppState

    private let builtInNodes = ["AUTO", "BALANCE", "DIRECT"]

    var body: some View {
        NavigationStack {
            List {
                if appState.isTunnelRunning {
                    Section("当前连接") {
                        Label("节点变更会在断开并重新连接后生效", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(VPNTheme.warning)
                    }
                }

                Section("内置") {
                    ForEach(builtInNodes, id: \.self) { name in
                        nodeButton(name: name, subtitle: builtInDescription(name))
                    }
                }

                Section("订阅节点") {
                    if appState.nodes.isEmpty {
                        ContentUnavailableView("还没有节点", systemImage: "tray", description: Text("先到订阅页更新订阅"))
                    } else {
                        ForEach(appState.nodes) { node in
                            nodeButton(name: node.name, subtitle: nodeSubtitle(node))
                        }
                    }
                }
            }
            .navigationTitle("节点")
            .vpnListStyle()
            .refreshable {
                await appState.refreshVPNStatus()
            }
        }
    }

    private func nodeButton(name: String, subtitle: String) -> some View {
        Button {
            appState.selectProxy(name)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if appState.settings.selectedProxy == name {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(VPNTheme.accent)
                }
            }
        }
    }

    private func builtInDescription(_ name: String) -> String {
        switch name {
        case "AUTO":
            return "默认自动选择组"
        case "BALANCE":
            return "预留负载均衡组"
        case "DIRECT":
            return "全部直连调试"
        default:
            return ""
        }
    }

    private func nodeSubtitle(_ node: ProviderNode) -> String {
        [node.type, node.server, node.port.map(String.init)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
