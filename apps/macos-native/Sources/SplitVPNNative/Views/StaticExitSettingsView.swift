import SwiftUI

struct StaticExitSettingsView: View {
    @ObservedObject var store: VPNStore
    @State private var configuration = StaticExitConfiguration()
    @State private var port = ""
    @State private var password = ""
    @State private var line = ""
    @State private var working = false
    @State private var note: String?
    @State private var failed = false
    @State private var loaded = false
    @State private var showChainScanner = false
    var body: some View {
        Section("静态 ISP 出口") {
            Toggle("经机场连接静态出口", isOn: $configuration.enabled)
            Text("开启后，走代理的流量按“机场 → 静态 IP → 网站”连接。关闭或未配置时照常使用机场；直连规则继续生效。")
                .foregroundStyle(VPNTheme.secondary)
            SecureField("粘贴 hostname:port:username:password", text: $line)
                .onSubmit { parse() }
            Button("解析粘贴内容") { parse() }.disabled(line.isEmpty)
            Picker("出口协议", selection: $configuration.protocol) {
                Text("SOCKS5").tag("socks5")
                Text("HTTP").tag("http")
                Text("HTTPS").tag("https")
            }
            TextField("服务器", text: $configuration.server)
            TextField("端口", text: $port)
            TextField("用户名", text: $configuration.username)
            SecureField("密码（留空沿用已保存密码）", text: $password)
            TextField("预期出口 IP（选填，用于核对）", text: $configuration.expectedIp)
            Text("机场前置使用当前所选节点。开启后若出口失效会报错，不自动换成机场出口。当前链路仅支持 TCP，代理 UDP 会被拦截。保存时会重建现有代理连接。")
                .foregroundStyle(VPNTheme.secondary)
            HStack {
                Button(working ? "处理中…" : "保存并应用") { Task { await save() } }
                Button("寻找最快链路") { showChainScanner = true }
                    .disabled(store.status?.settings.staticExit?.configured != true)
                Button("测试已保存出口") { Task { await test() } }
                    .disabled(!store.running || store.status?.settings.staticExit?.enabled != true)
            }
            if let note { Text(note).foregroundStyle(failed ? VPNTheme.destructive : VPNTheme.secondary).textSelection(.enabled) }
        }
        .sheet(isPresented: $showChainScanner) { ChainScannerView(store: store) }
        .disabled(!store.canMutate || working)
        .task {
            guard !loaded else { return }; loaded = true
            configuration = store.status?.settings.staticExit ?? StaticExitConfiguration()
            port = configuration.port > 0 ? String(configuration.port) : ""
        }
    }
    private func parse() {
        working = true; note = nil
        Task {
            defer { working = false }
            do {
                let input: StaticExitInput = try await store.core.request("static-exit:parse", payload: ["line": line])
                configuration = input.configuration; password = input.password
                port = String(configuration.port); line = ""
                failed = false; note = "已解析，默认使用 SOCKS5；请核对协议后保存。"
            } catch { failed = true; note = error.localizedDescription }
        }
    }
    private func save() async {
        working = true; note = nil
        defer { working = false }
        do {
            guard let number = Int(port.isEmpty ? "0" : port), (0...65535).contains(number) else {
                throw CoreService.CoreError.message("请填写有效端口。")
            }
            configuration.port = number
            configuration.server = configuration.server.trimmingCharacters(in: .whitespacesAndNewlines)
            configuration.expectedIp = configuration.expectedIp.trimmingCharacters(in: .whitespacesAndNewlines)
            let old = try await StaticExitKeychain.load()
            let sameEndpoint = old.map { $0.configuration.server == configuration.server && $0.configuration.port == configuration.port && $0.configuration.username == configuration.username && $0.configuration.protocol == configuration.protocol } ?? false
            let secret = password.isEmpty && sameEndpoint ? old?.password ?? "" : password
            guard !configuration.enabled || configuration.username.isEmpty || !secret.isEmpty else {
                throw CoreService.CoreError.message("请填写这个静态出口的密码。")
            }
            // Secure persistence precedes runtime activation. Roll back the vault
            // if validation or reload fails, so restart keeps the previous chain.
            try await StaticExitKeychain.save(configuration, password: secret)
            do {
                _ = try await store.core.requestValue("static-exit:configure", payload: ["configuration": configuration.payload, "password": secret])
            } catch {
                if let old { try await StaticExitKeychain.save(old.configuration, password: old.password) }
                else { try await StaticExitKeychain.vault.remove(origin: StaticExitKeychain.origin) }
                throw error
            }
            password = ""; line = ""; failed = false
            note = configuration.enabled ? "已启用。连接 VPN 后可测试实际出口 IP。" : "配置已保存，ISP 保持关闭；可进入 ISP 测试独立测速。"
            await store.refresh()
        } catch { failed = true; note = error.localizedDescription }
    }
    private func test() async {
        working = true; note = "正在通过机场和静态出口查询实际 IP…"; failed = false
        defer { working = false }
        do {
            let result: StaticExitTestResult = try await store.core.request("static-exit:test")
            failed = result.matchesExpected == false
            let verification = result.matchesExpected.map { $0 ? "与预期 IP 一致" : "与预期 IP 不一致，请核对商家配置" } ?? "未填写预期 IP，请与商家提供的出口核对"
            note = "实际出口：\(result.ip)；\(verification)。查询耗时 \(Int(result.elapsedMs)) ms。"
        } catch { failed = true; note = error.localizedDescription }
    }
}
