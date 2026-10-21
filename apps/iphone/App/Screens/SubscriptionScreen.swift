import SwiftUI

struct SubscriptionScreen: View {
    @EnvironmentObject private var appState: SplitVpnAppState
    @State private var urlText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("订阅 URL") {
                    TextField("https://example.com/sub", text: $urlText)
                        .urlInputBehavior()

                    Button("保存 URL") {
                        appState.saveSubscriptionURL(urlText)
                    }

                    Button("更新订阅") {
                        // updateSubscription saves the URL itself, in order.
                        Task {
                            await appState.updateSubscription(url: urlText)
                        }
                    }
                    .disabled(appState.isBusy)
                }

                Section("订阅状态") {
                    LabeledContent("状态", value: appState.subscription.status)
                    LabeledContent("节点", value: "\(appState.subscription.nodeCount)")
                    LabeledContent("上次更新", value: formattedDate(appState.subscription.updatedAt))
                    if !appState.subscription.lastError.isEmpty {
                        Text(appState.subscription.lastError)
                            .foregroundStyle(VPNTheme.destructive)
                    }
                }

                Section("支持格式") {
                    Text("Clash / Mihomo YAML")
                    Text("URI 列表")
                    Text("base64 URI 列表")
                }
            }
            .navigationTitle("订阅")
            .vpnListStyle()
            .onAppear {
                urlText = appState.subscription.url
            }
        }
    }

    private func formattedDate(_ value: Date?) -> String {
        guard let value else {
            return "-"
        }
        return value.formatted(date: .abbreviated, time: .shortened)
    }
}

private extension View {
    @ViewBuilder
    func urlInputBehavior() -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
        #else
        self
        #endif
    }
}
