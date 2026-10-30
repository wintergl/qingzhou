import SwiftUI

struct DiagnosticsNetworkPanel: View {
    @ObservedObject var store: VPNStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 18) {
                    connectivity.frame(maxWidth: .infinity, alignment: .topLeading)
                    websites.frame(maxWidth: .infinity, alignment: .topLeading)
                }.fixedSize(horizontal: false, vertical: true)
                NetworkRecoveryHistoryView(records: store.status?.mihomo.networkRecovery?.history ?? [])
                HStack(alignment: .center, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("连接异常时").font(.system(size: 13, weight: .semibold))
                        Text(store.connectionProtected ? "当前连接由原版应用维护，请在那里执行修复。" : "修复会停止当前内核，并恢复应用设置的 DNS。")
                            .font(.system(size: 11)).foregroundStyle(VPNTheme.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("修复当前网络") { store.action("网络修复", channel: "network:repair") }
                        .disabled(!store.canMutate || store.connectionProtected)
                }.padding(.top, 2)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var connectivity: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                CardHeading(title: "连接检测", icon: "waveform.path.ecg")
                if store.diagnostics?.connectivity.stale == true {
                    Text("历史结果").font(.system(size: 10)).foregroundStyle(VPNTheme.secondary)
                }
                Spacer(minLength: 8)
                Button(store.diagnostics?.connectivity.running == true ? "检测中…" : "立即检测") { store.checkConnectivity() }.buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(VPNTheme.accent)
                    .disabled(!store.canMutate || store.diagnostics?.connectivity.running == true)
            }
            if let check = store.connectivity {
                probe("国内网络", passed: check.connectivity.domesticOk)
                probe("代理出口", passed: check.connectivity.proxyOk ?? check.connectivity.foreignOk)
                if let dns = check.connectivity.systemDns { probe("系统 DNS", passed: dns.ok) }
                if let chatgpt = check.connectivity.chatgpt { probe("ChatGPT 响应", passed: chatgpt.ok, text: chatgpt.responseText) }
                HStack { Text("出口 IP").foregroundStyle(VPNTheme.secondary); Spacer(); Text(check.connectivity.externalIp ?? "未取得").textSelection(.enabled) }
                    .font(.system(size: 12))
                if let error = check.connectivity.error { Text(error).font(.system(size: 11)).foregroundStyle(VPNTheme.warning).textSelection(.enabled) }
                if let error = check.nodeRiskError { Text(error).font(.system(size: 11)).foregroundStyle(VPNTheme.secondary) }
            } else {
                Text("连接后自动检查国内网络、代理出口和系统 DNS。").font(.system(size: 12)).foregroundStyle(VPNTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = store.diagnostics?.connectivity.error {
                Text(error).font(.system(size: 11)).foregroundStyle(VPNTheme.warning).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Divider().opacity(0.6)
            DiagnosticTimingView(record: store.diagnostics?.connectivity, pausedReason: store.diagnostics?.pausedReason)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).detailCard(padding: 20)
    }
    private var websites: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                CardHeading(title: "站点表现", icon: "speedometer")
                if store.diagnostics?.websites.stale == true {
                    Text("历史结果").font(.system(size: 10)).foregroundStyle(VPNTheme.secondary)
                }
                Spacer(minLength: 8)
                Button(store.diagnostics?.websites.running == true ? "检测中…" : "立即测速") { store.testWebsites() }.buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(VPNTheme.accent)
                    .disabled(!store.canMutate || store.diagnostics?.websites.running == true)
            }
            if let tests = store.websites {
                ForEach(tests.results) { item in
                    HStack(spacing: 8) {
                        Text(item.label)
                        Spacer(minLength: 4)
                        Text(item.responseText).monospacedDigit()
                            .foregroundStyle(store.diagnostics?.websites.stale == true ? VPNTheme.secondary : item.ok ? VPNTheme.green : VPNTheme.warning)
                    }.font(.system(size: 12)).help(item.error ?? "站点响应耗时，不代表下载带宽。")
                }
                Text("出口 · \(tests.proxyName)").font(.system(size: 11)).foregroundStyle(VPNTheme.secondary).lineLimit(1).help(tests.proxyName)
            } else {
                Text("连接后自动检查 Google、ChatGPT 与 Claude 的站点响应。").font(.system(size: 12)).foregroundStyle(VPNTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = store.diagnostics?.websites.error {
                Text(error).font(.system(size: 11)).foregroundStyle(VPNTheme.warning).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Divider().opacity(0.6)
            DiagnosticTimingView(record: store.diagnostics?.websites, pausedReason: store.diagnostics?.pausedReason)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).detailCard(padding: 20)
    }
    private func probe(_ title: String, passed: Bool, text: String? = nil) -> some View {
        HStack {
            Text(title).foregroundStyle(VPNTheme.secondary)
            Spacer(minLength: 8)
            Label(text ?? (passed ? "正常" : "未连通"), systemImage: passed ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(store.diagnostics?.connectivity.stale == true ? VPNTheme.secondary : passed ? VPNTheme.green : VPNTheme.warning)
        }.font(.system(size: 12))
    }
}
