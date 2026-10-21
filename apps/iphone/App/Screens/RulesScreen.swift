import SwiftUI

struct RulesScreen: View {
    @EnvironmentObject private var appState: SplitVpnAppState
    @State private var domainText = ""
    @State private var routeProbeText = "www.baidu.com"
    @State private var routeDecision: RouteDecision?

    var body: some View {
        NavigationStack {
            Form {
                if appState.isTunnelRunning {
                    Section("当前连接") {
                        Label("规则变更会在断开并重新连接后生效", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(VPNTheme.warning)
                    }
                }

                Section("默认路由") {
                    ForEach(DefaultRules.directRuleSummary, id: \.self) { item in
                        Label(item, systemImage: "arrow.down.left.and.arrow.up.right")
                    }
                }

                Section("规则集库") {
                    LabeledContent("状态", value: ruleSetStatusText(appState.ruleSetLibrary.status))
                    LabeledContent("总大小", value: byteString(appState.ruleSetLibrary.totalBytes))
                    if let updatedAt = appState.ruleSetLibrary.updatedAt {
                        LabeledContent("更新时间", value: updatedAt.formatted(date: .abbreviated, time: .standard))
                    } else {
                        LabeledContent("更新时间", value: "仅使用内置")
                    }
                    if let lastAttemptAt = appState.ruleSetLibrary.lastAttemptAt {
                        LabeledContent("上次尝试", value: lastAttemptAt.formatted(date: .abbreviated, time: .standard))
                    }
                    if !appState.ruleSetLibrary.lastError.isEmpty {
                        Text(appState.ruleSetLibrary.lastError)
                            .font(.caption)
                            .foregroundStyle(VPNTheme.destructive)
                            .textSelection(.enabled)
                    }

                    Button {
                        Task {
                            await appState.updateRuleSets(force: true)
                        }
                    } label: {
                        Label(appState.isRuleSetUpdating ? "更新中..." : "更新规则集", systemImage: "arrow.clockwise")
                    }
                    .disabled(appState.isRuleSetUpdating)

                    ForEach(appState.ruleSetLibrary.files) { file in
                        LabeledContent(file.tag, value: "\(byteString(file.bytes)) · \(sourceText(file.source))")
                    }
                }

                Section("系统直连网段") {
                    ForEach(DefaultRules.directIPv4Routes) { route in
                        LabeledContent(route.cidr, value: route.label)
                    }
                }

                Section("VPN 域名") {
                    LabeledContent("数量", value: "\(appState.domains.domains.count)")
                    TextEditor(text: $domainText)
                        .frame(minHeight: 180)
                        .ruleTextInputBehavior()

                    Button("保存规则") {
                        appState.saveDomains(from: domainText)
                    }
                }

                Section("路由诊断") {
                    TextField("域名或 IP", text: $routeProbeText)
                        .ruleTextInputBehavior()

                    Button {
                        routeDecision = appState.routeDecision(for: routeProbeText)
                    } label: {
                        Label("判断出站", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    }

                    if let routeDecision {
                        LabeledContent("目标", value: routeDecision.normalizedTarget)
                        LabeledContent("出站", value: routeDecision.outbound == "proxy" ? "代理" : "直连")
                        LabeledContent("命中", value: routeDecision.matchedRule)
                        Text(routeDecision.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("未知流量") {
                    Picker("默认策略", selection: Binding(
                        get: { appState.settings.unknownTrafficPolicy },
                        set: { appState.setUnknownTrafficPolicy($0) }
                    )) {
                        Text("默认直连").tag("direct")
                        Text("未匹配代理").tag("vpn")
                    }
                    .pickerStyle(.segmented)

                    Text(appState.settings.unknownTrafficPolicy == "vpn" ? "VPN 域名和 Geo 非 CN 走所选节点；未匹配公网也走所选节点" : "VPN 域名和 Geo 非 CN 走所选节点；其他未匹配流量直连")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Packet Tunnel") {
                    Picker("MTU", selection: Binding(
                        get: { appState.settings.packetTunnelMTU },
                        set: { appState.setPacketTunnelMTU($0) }
                    )) {
                        ForEach(TunnelAddressing.supportedMTUs, id: \.self) { value in
                            Text("\(value)").tag(value)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("1400 是默认测试值；1280 用于排查路径 MTU 黑洞；1500 用于回退到旧行为。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("节点 DNS") {
                    Picker("server 解析器", selection: Binding(
                        get: { appState.settings.proxyServerDomainResolver },
                        set: { appState.setProxyServerDomainResolver($0) }
                    )) {
                        Text("Cloudflare").tag(ProxyServerDomainResolver.cloudflareDirect)
                        Text("Ali").tag(ProxyServerDomainResolver.ali)
                    }
                    .pickerStyle(.segmented)

                    Text(appState.settings.proxyServerDomainResolver == ProxyServerDomainResolver.ali ? "回退模式：代理节点 server 域名用 Ali DNS 解析。" : "默认模式：代理节点 server 域名用 Cloudflare 直连解析，避免走国内 DNS。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("生成配置") {
                    LabeledContent("sing-box", value: appState.generatedConfigReady ? "已生成" : "未生成")
                    LabeledContent("已转换节点", value: "\(appState.convertedOutboundCount)")
                    LabeledContent("暂不支持节点", value: "\(appState.unsupportedNodeCount)")
                }
            }
            .navigationTitle("规则")
            .vpnListStyle()
            .onAppear {
                domainText = appState.domains.domains.joined(separator: "\n")
                routeDecision = appState.routeDecision(for: routeProbeText)
            }
            .refreshable {
                appState.refreshFromDisk()
                domainText = appState.domains.domains.joined(separator: "\n")
                routeDecision = appState.routeDecision(for: routeProbeText)
            }
        }
    }
}

private func byteString(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
}

private func ruleSetStatusText(_ status: String) -> String {
    switch status {
    case "updated":
        return "已更新"
    case "installed":
        return "已安装"
    case "partial":
        return "不完整"
    case "error":
        return "更新失败"
    default:
        return "未安装"
    }
}

private func sourceText(_ source: String) -> String {
    source == "remote" ? "远端" : "内置"
}

private extension View {
    @ViewBuilder
    func ruleTextInputBehavior() -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
        #endif
    }
}
