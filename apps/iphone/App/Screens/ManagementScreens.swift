import SwiftUI

extension View {
    @ViewBuilder func mobileAddressInput() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
        #else
        self
        #endif
    }
}

struct MobileRuleDraft: Identifiable {
    let id = UUID()
    var original: String?
    var originalTarget = "vpn"
    var address = ""
    var target = "vpn"
}

struct RulesScreen: View {
    @EnvironmentObject private var appState: SplitVpnAppState
    @State private var editor: MobileRuleDraft?
    @State private var target = ""
    @State private var decision = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("分流设置") {
                    Picker("未命中策略", selection: preference("unknownTraffic", fallback: "direct")) { Text("直连").tag("direct"); Text("VPN").tag("vpn") }
                    Picker("Geo 数据缺失", selection: preference("geoFallback", fallback: "cn-direct-else-vpn")) {
                        Text("国内名单直连，其余 VPN").tag("cn-direct-else-vpn")
                        Text("跟随未命中策略").tag("follow-default")
                        Text("拒绝连接").tag("block")
                    }
                    Toggle("局域网直连", isOn: flag("lanDirect"))
                    Toggle("Tailscale 直连", isOn: flag("tailscaleDirect"))
                }
                ruleSection("直连", key: "directDomainRules", outlet: "direct")
                ruleSection("走 VPN", key: "vpnDomainRules", outlet: "vpn")
                Section("检查自定义规则") {
                    TextField("域名、IP 或网址", text: $target).mobileAddressInput()
                    Button("检查匹配") { Task {
                        do { let result = try await appState.core.object("routing:diagnose", ["target": target]); decision = "\(result["host"] as? String ?? "") · \(result["policy"] as? String ?? "")" }
                        catch { decision = Redaction.message(error.localizedDescription) }
                    } }.disabled(target.isEmpty)
                    if !decision.isEmpty { Text(decision).font(.caption) }
                    Text("只检查自定义规则，不测试联网或查询 Geo。直连规则优先于重叠的代理规则。").font(.caption).foregroundStyle(.secondary)
                }
                Section { NavigationLink("隧道、节点 DNS 与 Geo 规则库") { TunnelSettingsScreen() } }
                Section { Text("iPhone 按域名、IP 和网络规则分流。系统不向个人 VPN 提供其他应用的进程名称，微信、邮箱等沿用这些规则。").font(.caption).foregroundStyle(.secondary) }
            }.navigationTitle("分流规则").vpnListStyle().disabled(appState.isBusy)
                .toolbar { Button { editor = MobileRuleDraft() } label: { Label("添加规则", systemImage: "plus") } }
                .sheet(item: $editor) { MobileRuleEditor(draft: $0) }
                .task { try? await appState.refreshManagedState() }
        }
    }
    private func preference(_ key: String, fallback: String) -> Binding<String> {
        Binding(get: { appState.corePreferences[key] as? String ?? fallback }, set: { value in Task { await appState.managedEdit("settings:patch", [key: value]) } })
    }
    private func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { appState.corePreferences[key] as? Bool ?? true }, set: { value in Task { await appState.managedEdit("settings:patch", [key: value]) } })
    }
    @ViewBuilder private func ruleSection(_ title: String, key: String, outlet: String) -> some View {
        Section(title) {
            let rules = appState.corePreferences[key] as? [String] ?? []
            ForEach(rules, id: \.self) { rule in
                Button { editor = MobileRuleDraft(original: rule, originalTarget: outlet, address: rule, target: outlet) } label: { Text(rule).font(.subheadline).foregroundStyle(.primary) }
                    .swipeActions { Button("删除", role: .destructive) { Task { await appState.managedEdit("routing:delete-rule", ["rule": rule, "target": outlet]) } } }
            }
            Button("添加\(title)规则") { editor = MobileRuleDraft(target: outlet) }
        }
    }
}

struct MobileRuleEditor: View {
    @EnvironmentObject private var appState: SplitVpnAppState
    @Environment(\.dismiss) private var dismiss
    @State var draft: MobileRuleDraft
    var body: some View {
        NavigationStack {
            Form {
                Picker("出口", selection: $draft.target) { Text("走 VPN").tag("vpn"); Text("直连").tag("direct") }
                TextField("域名、IP、网段或网址", text: $draft.address).mobileAddressInput()
                Text("每条填写一个地址。格式检查与出口变更由共享核心完成。").font(.caption).foregroundStyle(.secondary)
                if let notice = appState.notice { Text(notice).foregroundStyle(VPNTheme.destructive) }
            }.navigationTitle(draft.original == nil ? "添加规则" : "编辑规则")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(appState.isBusy) }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { Task {
                        var payload: [String: Any] = ["rule": draft.address, "target": draft.target]
                        if let original = draft.original { payload["originalRule"] = original; payload["originalTarget"] = draft.originalTarget }
                        if await appState.managedEdit(draft.original == nil ? "routing:add-rule" : "routing:edit-rule", payload) { dismiss() }
                    } }.disabled(appState.isBusy || draft.address.isEmpty) }
                }
        }
    }
}

struct MobileGroupDraft: Identifiable {
    let id = UUID()
    var raw: [String: Any] = [:]
    var name = ""
    var members: Set<String> = []
}

struct MobileGroupsScreen: View {
    @EnvironmentObject private var appState: SplitVpnAppState
    @State private var editor: MobileGroupDraft?
    var body: some View {
        List {
            Section { Text("节点组用于整理节点；连接时仍选择具体节点，与 Mac 当前行为一致。").font(.caption).foregroundStyle(.secondary) }
            ForEach(appState.nodeGroups) { group in
                Button { editor = MobileGroupDraft(raw: group.raw, name: group.name, members: Set(appState.nodes.filter { group.nodeNames.contains($0.name) }.map(\.id))) } label: {
                    VStack(alignment: .leading, spacing: 4) { Text(group.name); Text("\(group.nodeNames.count) 个节点").font(.caption).foregroundStyle(.secondary) }
                }.swipeActions { Button("删除", role: .destructive) { Task { await appState.managedEdit("node-groups:save", ["nodeGroups": appState.nodeGroups.filter { $0.id != group.id }.map(\.raw)]) } } }
            }
            Button("添加节点组") { editor = MobileGroupDraft() }
        }.navigationTitle("节点组").vpnListStyle().disabled(appState.isBusy)
            .sheet(item: $editor) { MobileGroupEditor(draft: $0) }
            .task { try? await appState.refreshManagedState() }
    }
}

struct MobileGroupEditor: View {
    @EnvironmentObject private var appState: SplitVpnAppState
    @Environment(\.dismiss) private var dismiss
    @State var draft: MobileGroupDraft
    var body: some View {
        NavigationStack {
            Form {
                TextField("节点组名称", text: $draft.name)
                Section("选择成员") {
                    ForEach(appState.nodes) { node in
                        Toggle(node.name, isOn: Binding(get: { draft.members.contains(node.id) }, set: { enabled in if enabled { draft.members.insert(node.id) } else { draft.members.remove(node.id) } }))
                    }
                }
                if let error = appState.notice { Text(error).foregroundStyle(VPNTheme.destructive) }
            }.navigationTitle("编辑节点组")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(appState.isBusy) }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { Task {
                        var group = draft.raw
                        group["id"] = draft.raw["id"] as? String ?? UUID().uuidString; group["name"] = draft.name; group["strategy"] = group["strategy"] ?? "manual"
                        let selected = appState.nodes.filter { draft.members.contains($0.id) }
                        let knownNames = Set(appState.nodes.map(\.name))
                        let missingNames = (draft.raw["nodeNames"] as? [String] ?? []).filter { !knownNames.contains($0) }
                        let knownIDs = Set(appState.nodes.map(\.id))
                        let missing = (draft.raw["members"] as? [[String: Any]] ?? []).filter { !knownIDs.contains($0["identityKey"] as? String ?? "") }
                        group["nodeNames"] = selected.map(\.name) + missingNames
                        group["members"] = selected.compactMap { node -> [String: Any]? in guard let key = node.identityKey else { return nil }; return ["identityKey": key, "lastKnownName": node.name] } + missing
                        var groups = appState.nodeGroups.filter { $0.id != group["id"] as? String }.map(\.raw); groups.append(group)
                        if await appState.managedEdit("node-groups:save", ["nodeGroups": groups]) { dismiss() }
                    } }.disabled(appState.isBusy || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
        }
    }
}

struct MobileStaticExitScreen: View {
    @EnvironmentObject private var appState: SplitVpnAppState
    @State private var enabled = false
    @State private var protocolName = "socks5"
    @State private var server = ""
    @State private var port = ""
    @State private var username = ""
    @State private var password = ""
    @State private var expected = ""
    @State private var pasted = ""
    @State private var note = ""
    var body: some View {
        Form {
            Section("静态 ISP 出口") {
                Toggle("经机场连接静态 ISP", isOn: $enabled)
                Text("机场 → 静态 ISP → 网站。直连规则保持直连；代理 UDP 会被拦截，当前仅支持 TCP。").font(.caption).foregroundStyle(.secondary)
                SecureField("粘贴 hostname:port:username:password", text: $pasted)
                Button("解析粘贴内容") { Task {
                    do { let value = try await appState.core.object("static-exit:parse", ["line": pasted]); fill(value["configuration"] as? [String: Any] ?? [:]); password = value["password"] as? String ?? ""; pasted = "" }
                    catch { note = Redaction.message(error.localizedDescription) }
                } }.disabled(pasted.isEmpty)
                Picker("协议", selection: $protocolName) { Text("SOCKS5").tag("socks5"); Text("HTTP").tag("http"); Text("HTTPS").tag("https") }
                TextField("服务器", text: $server).mobileAddressInput()
                TextField("端口", text: $port)
                TextField("用户名", text: $username).autocorrectionDisabled()
                SecureField("密码（留空沿用相同出口的已存密码）", text: $password)
                TextField("预期出口 IP（选填）", text: $expected).mobileAddressInput()
                Button("保存并应用") { Task {
                    guard let number = Int(port.isEmpty ? "0" : port), (0...65535).contains(number) else { note = "请填写有效端口。"; return }
                    let configuration: [String: Any] = ["enabled": enabled, "protocol": protocolName, "server": server.trimmingCharacters(in: .whitespacesAndNewlines), "port": number, "username": username, "expectedIp": expected.trimmingCharacters(in: .whitespacesAndNewlines)]
                    if await appState.saveStaticExit(configuration, password: password) { password = ""; pasted = ""; note = "已保存。连接后请核对实际出口。" }
                    else { note = appState.notice ?? "保存未完成" }
                } }
                Text("密码保存在设备钥匙串；生成的隧道配置使用设备文件保护。切换出口不自动退回机场。").font(.caption).foregroundStyle(.secondary)
            }
            if !note.isEmpty { Text(note).font(.caption) }
        }.navigationTitle("静态 ISP").vpnListStyle().disabled(appState.isBusy)
            .task { try? await appState.refreshManagedState(); let value = appState.corePreferences["staticExit"] as? [String: Any] ?? [:]; enabled = value["enabled"] as? Bool ?? false; fill(value) }
            .onDisappear { password = ""; pasted = "" }
    }
    private func fill(_ value: [String: Any]) {
        protocolName = value["protocol"] as? String ?? "socks5"; server = value["server"] as? String ?? ""; port = (value["port"] as? Int).map(String.init) ?? ""; username = value["username"] as? String ?? ""; expected = value["expectedIp"] as? String ?? ""
    }
}

struct MobileDiagnosticsScreen: View {
    @EnvironmentObject private var appState: SplitVpnAppState
    @State private var key = ""
    @State private var note = ""
    private func text(_ value: Any?) -> String { value.map { $0 is NSNull ? "—" : String(describing: $0) } ?? "—" }
    private func health(_ value: Any?) -> String { (value as? Bool).map { $0 ? "正常" : "未通过" } ?? "尚未检测" }
    var body: some View {
        List {
            Section("连接检测") {
                Button(appState.mobileDiagnosticsRunning ? "检测中…" : "重新检测连接与站点") { Task { await appState.runMobileDiagnostics() } }.disabled(appState.mobileDiagnosticsRunning || appState.runtimeStatus.state != .connected)
                LabeledContent("国内网络", value: health(appState.mobileConnectivity["domesticOk"]))
                LabeledContent("代理出口", value: health(appState.mobileConnectivity["proxyOk"]))
                LabeledContent("系统 DNS", value: health((appState.mobileConnectivity["systemDns"] as? [String: Any])?["ok"]))
                LabeledContent("ChatGPT HTTP", value: text((appState.mobileConnectivity["chatgpt"] as? [String: Any])?["httpStatus"]))
                LabeledContent("实际出口", value: text(appState.mobileConnectivity["externalIp"]))
                if let error = appState.mobileConnectivity["error"] as? String { Text(error).font(.caption) }
            }
            Section("站点响应") {
                ForEach(Array(appState.mobileWebsites.enumerated()), id: \.offset) { _, row in
                    LabeledContent(text(row["label"]), value: (row["ok"] as? Bool == true) ? "\(text(row["delay"])) ms" : text(row["error"]))
                }
            }
            Section("当前出口风险") {
                SecureField("ipdata API Key", text: $key)
                Button("加密保存密钥") {
                    do { try MobileSecretVault.save("ipdata", data: Data(key.utf8)); key = ""; note = "密钥已保存到设备钥匙串" } catch { note = "保存失败，请重试" }
                }
                Button("删除密钥", role: .destructive) { do { try MobileSecretVault.save("ipdata", data: nil); note = "密钥已删除" } catch { note = "删除失败" } }
                Button("检测实际出口风险") { Task { await appState.checkCurrentExitRisk() } }.disabled(appState.runtimeStatus.state != .connected)
                LabeledContent("出口 IP", value: text(appState.currentExitRisk["ip"]))
                LabeledContent("风险", value: ["high": "高", "medium": "中", "low": "低", "unknown": "未知"][appState.currentExitRisk["riskLevel"] as? String ?? ""] ?? "尚未检测")
                if let reasons = appState.currentExitRisk["reasons"] as? [String] { Text(reasons.joined(separator: "；")).font(.caption) }
                if !note.isEmpty { Text(note).font(.caption) }
            }
            Section { Text("连接或网络变化后自动重测。HTTP 403／429 等受限响应与 DNS、代理连通分别显示。风险检测只在手动点击时访问服务。").font(.caption).foregroundStyle(.secondary) }
        }.navigationTitle("网络检测")
    }
}

struct MobileChainScreen: View {
    @EnvironmentObject private var appState: SplitVpnAppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var state: [String: Any] = [:]
    @State private var subscription = ""
    @State private var strategy = "balanced"
    @State private var running = false
    @State private var task: Task<Void, Never>?
    @State private var note = ""
    @State private var history: [[String: Any]] = []
    @State private var offset = 0
    var body: some View {
        List {
            Section("测试范围") {
                Picker("订阅", selection: $subscription) { Text("全部订阅").tag(""); ForEach(appState.subscriptions.filter(\.enabled)) { Text($0.name).tag($0.id) } }.disabled(running)
                Picker("排序", selection: $strategy) { Text("综合推荐").tag("balanced"); Text("下载优先").tag("download"); Text("响应优先").tag("latency") }.onChange(of: strategy) { _ in Task { await refreshRanking() } }
                HStack { Button("快速") { begin("quick") }; Button("全面") { begin("full") }; Button("少量复测") { begin("maintenance") }; Button("持续") { begin("continuous") } }.disabled(running || appState.runtimeStatus.state != .connected)
                Button("暂停", role: .cancel) { pause() }.disabled(!running)
                Text("\(state["completed"] as? Int ?? 0) / \(state["total"] as? Int ?? 0)")
                Text("每节点约 1.5 MiB；只在前台扫描，离开页面、锁屏或切网即暂停。持续模式每项间隔 15 秒。业务出口保持当前线路。").font(.caption).foregroundStyle(.secondary)
            }
            Section("比较结果") {
                ForEach(Array((state["results"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(row["nodeName"] as? String ?? row["name"] as? String ?? "节点")
                        Text("\(String(describing: row["latencyMs"] ?? "—")) ms · \(String(describing: row["downloadMbps"] ?? "—")) Mbps · \(row["status"] as? String ?? "")").font(.caption)
                        if row["status"] as? String == "available", let identity = row["identityKey"] as? String {
                            Button("复核并使用") { Task { await use(identity) } }.disabled(running || appState.isBusy)
                        }
                    }
                }
            }
            Section {
                Button("验证实际出口") { Task { do { let result = try await appState.mobileCall("mobile:diagnostics:verify-exit"); note = "实际出口：\(result["externalIp"] as? String ?? "未知")" } catch { note = Redaction.message(error.localizedDescription) } } }
                Button("历史（下一页）") { Task { do { let page = try await appState.core.object("mobile:chain:history", ["offset": offset, "limit": 30]); history = page["items"] as? [[String: Any]] ?? []; offset = offset + 30 >= (page["total"] as? Int ?? 0) ? 0 : offset + 30 } catch { note = Redaction.message(error.localizedDescription) } } }
                ForEach(Array(history.enumerated()), id: \.offset) { _, item in let row = item["result"] as? [String: Any] ?? [:]; Text("\(row["nodeName"] as? String ?? "节点") · \(row["status"] as? String ?? "") · \(item["checkedAt"] as? String ?? "")").font(.caption) }
                if !note.isEmpty { Text(note).font(.caption) }
            }
        }.navigationTitle("ISP 线路")
            .task { await refreshRanking() }
            .onDisappear { pause() }
            .onChange(of: scenePhase) { if $0 != .active { pause() } }
    }
    private func refreshRanking() async { if let result = try? await appState.core.object("mobile:chain:get", ["strategy": strategy]) { state = result } }
    private func pause() {
        running = false; task?.cancel()
        if let id = state["id"] as? String { Task { _ = try? await appState.core.call("mobile:chain:cancel", ["id": id]) } }
    }
    private func begin(_ mode: String) {
        guard !running else { return }; running = true
        task = Task {
            defer { running = false }
            do {
                var payload: [String: Any] = ["mode": mode]
                if !subscription.isEmpty { payload["subscriptionId"] = subscription }
                state = try await appState.mobileCall("mobile:chain:start", payload)
                guard let id = state["id"] as? String else { return }
                while !Task.isCancelled && running && state["running"] as? Bool == true {
                    state = try await appState.mobileCall("mobile:chain:next", ["id": id, "strategy": strategy])
                    if mode == "continuous" { try await Task.sleep(nanoseconds: 15_000_000_000) }
                }
            } catch is CancellationError {} catch { note = Redaction.message(error.localizedDescription) }
        }
    }
    private func use(_ identity: String) async {
        do {
            note = try await appState.useMobileChain(identity)
        } catch { note = Redaction.message(error.localizedDescription) }
    }
}
