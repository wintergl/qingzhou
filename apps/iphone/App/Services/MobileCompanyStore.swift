import Foundation
#if canImport(Libbox)
import Libbox
#endif

@MainActor
final class MobileCompanyStore: ObservableObject {
    @Published var metadata: [String: Any] = [:]
    @Published var probe: [String: Any] = [:]
    @Published var challenge: [String: Any]?
    @Published var phase = "idle"
    @Published var message = "请先检测入口并核对证书"
    @Published var certificateConfirmed = false
    @Published var verification: [String: Any]?
    @Published var busy = false
    private unowned let app: SplitVpnAppState
    private let underlay = CompanyUnderlay()
    private var operation = UUID()
    private var polling: Task<Void, Never>?
    private var password = ""
    private var pendingPassword: [String: String]?
    #if canImport(Libbox)
    private var controller: CompanymobileController?
    #endif
    init(appState: SplitVpnAppState) { app = appState }
    var connected: Bool { phase == "connected" }
    var active: Bool { ["connected", "connecting", "applying", "waiting-network"].contains(phase) }
    private func configure(_ patch: [String: Any]) async throws { metadata = try await app.core.object("company:mobile:configure", patch) }
    func load() async {
        do { metadata = try await app.core.object("company:mobile:get"); await refresh() } catch { fail(error) }
    }
    func refresh() async {
        guard app.runtimeStatus.state == .connected || app.runtimeStatus.state == .connecting else {
            if active { phase = "blocked"; message = "共享 VPN 未运行；重新连接后需恢复接入认证" }
            return
        }
        do {
            let value = try await app.vpnManager.companyMessage(["op": "company.status"])
            let backendPhase = value["phase"] as? String ?? "idle"
            if backendPhase != "idle" || active { phase = backendPhase; message = value["message"] as? String ?? message; verification = value["verification"] as? [String: Any] }
        } catch { if active { message = "接入状态读取失败，等待确认" } }
    }
    func detect(origin: String) async {
        await refresh(); guard !active else { message = "请先断开接入，再检测或更换网关"; return }
        do {
            try await configure(["origin": origin]); certificateConfirmed = false
            try await begin(["type": "probe", "origin": metadata["origin"] ?? ""])
        } catch { fail(error) }
    }
    func login(username: String, domain: String, enteredPassword: String, remember: Bool) async {
        await refresh(); guard !active else { message = "请先断开接入，再更换账号"; return }
        do {
            guard certificateConfirmed, let fingerprint = probe["fingerprint"] as? String, probe["origin"] as? String == metadata["origin"] as? String else { throw error("请检测入口并明确确认当前证书指纹") }
            try await configure(["username": username.trimmingCharacters(in: .whitespacesAndNewlines), "domain": domain, "fingerprint": fingerprint, "remember": remember])
            password = enteredPassword
            if password.isEmpty, remember, metadata["passwordChangeUncertain"] as? Bool != true,
               let saved = try MobileSecretVault.load("company"), let value = try JSONSerialization.jsonObject(with: saved) as? [String: String], value["origin"] == metadata["origin"] as? String, value["username"] == metadata["username"] as? String { password = value["password"] ?? "" }
            guard !password.isEmpty else { throw error("请输入接入密码；改密结果不明确时不会自动使用旧密码") }
            try await begin(["type": "login", "origin": metadata["origin"] ?? "", "username": metadata["username"] ?? "", "domain": domain, "fingerprint": fingerprint, "password": password])
        } catch { password = ""; busy = false; fail(error) }
    }
    private func begin(_ fields: [String: Any]) async throws {
        cancelAuthentication(preservingPassword: true); operation = UUID(); let token = operation
        #if canImport(Libbox)
        guard !underlay.interfaceName.isEmpty else { throw error("物理网络尚未就绪，请稍后重试") }
        controller = CompanymobileNewController()
        guard let controller else { throw error("无法创建认证内核") }
        var fields = fields; fields["interfaceName"] = underlay.interfaceName
        let data = try JSONSerialization.data(withJSONObject: fields); let line = String(decoding: data, as: UTF8.self)
        busy = true; phase = fields["type"] as? String == "probe" ? "probing" : "authenticating"; message = "正在连接认证服务"
        try await Task.detached { try controller.send(line) }.value
        polling = Task { [weak self] in
            while !Task.isCancelled, let self, self.operation == token {
                do { try await self.consume(controller.poll(), token: token) } catch { self.fail(error); self.busy = false; break }
                if !self.busy { break }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        #else
        throw error("此构建没有接入认证内核")
        #endif
    }
    private func consume(_ text: String, token: UUID) async throws {
        let events = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] ?? []
        for event in events {
            guard operation == token else { return }
            switch event["type"] as? String {
            case "probe": probe = event["probe"] as? [String: Any] ?? [:]; phase = "probed"; message = "核对指纹后选择认证方式"; busy = false
            case "challenge": challenge = event["challenge"] as? [String: Any]; phase = "challenge"; message = challenge?["message"] as? String ?? "请完成认证步骤"
            case "password_changed":
                if let submitted = pendingPassword, event["id"] as? String == submitted["id"] {
                    password = submitted["newPassword"] ?? ""
                    let username = (event["username"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? metadata["username"] as? String ?? ""
                    try await configure(["username": username, "passwordChangeUncertain": false]); try checkOperation(token); try saveCredential(); pendingPassword = nil
                }
            case "login_success":
                let username = (event["username"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? metadata["username"] as? String ?? ""
                try await configure(["username": username, "passwordChangeUncertain": false]); try checkOperation(token); try saveCredential(); password = ""
            case "resources":
                let rows = (event["resources"] as? [String: Any])?["rows"] as? [[String: Any]] ?? []
                try await configure(["resources": rows]); try checkOperation(token); phase = "authenticated"; message = "认证成功，已获取授权资源"; busy = false; challenge = nil
            case "error":
                if event["code"] as? String == "password_change_uncertain" { try await configure(["passwordChangeUncertain": true]) }
                phase = "error"; message = event["message"] as? String ?? "接入失败"; busy = false; password = ""; pendingPassword = nil
            case "progress": message = event["message"] as? String ?? "正在认证"
            default: break
            }
        }
    }
    private func saveCredential() throws {
        if metadata["remember"] as? Bool == true {
            try MobileSecretVault.save("company", data: JSONSerialization.data(withJSONObject: ["origin": metadata["origin"] ?? "", "username": metadata["username"] ?? "", "password": password]))
        } else { try MobileSecretVault.save("company", data: nil) }
    }
    func answer(_ input: [String: Any]) async {
        do {
            guard let challenge, input["id"] as? String == challenge["id"] as? String else { throw error("认证步骤已变化") }
            if challenge["kind"] as? String == "password_change" {
                pendingPassword = input as? [String: String]; try await configure(["passwordChangeUncertain": true])
            }
            var command = input; command["type"] = "challenge_response"
            let text = String(decoding: try JSONSerialization.data(withJSONObject: command), as: UTF8.self)
            #if canImport(Libbox)
            guard let controller else { throw error("认证已结束") }
            try await Task.detached { try controller.send(text) }.value
            #endif
            self.challenge = nil; phase = "authenticating"; message = "正在提交认证步骤"
        } catch { fail(error) }
    }
    func connect(takeover: Bool = true) async {
        guard !busy else { return }; let token = operation; busy = true; defer { if operation == token { busy = false } }
        do {
            #if canImport(Libbox)
            guard let controller else { throw error("请先完成认证") }
            let transfer = try CompanySDK.export(controller)
            try await configure(["enabled": takeover]); try await app.regenerateConfig()
            if app.isTunnelRunning { try await app.applyManagedConfiguration() } else { await app.connect() }
            let deadline = Date().addingTimeInterval(30)
            while app.runtimeStatus.state != .connected && Date() < deadline { try checkOperation(token); try await Task.sleep(nanoseconds: 500_000_000); await app.refreshVPNStatus() }
            guard app.runtimeStatus.state == .connected else { throw error("共享 VPN 尚未连接") }
            try checkOperation(token)
            let bytes = Data(transfer.utf8); let id = UUID().uuidString; let parts = (bytes.count + 1535) / 1536
            _ = try await app.vpnManager.companyMessage(["op": "company.begin", "id": id, "parts": parts])
            for index in 0..<parts {
                try checkOperation(token)
                let chunk = bytes.subdata(in: index * 1536..<min(bytes.count, (index + 1) * 1536)).base64EncodedString()
                _ = try await app.vpnManager.companyMessage(["op": "company.chunk", "id": id, "index": index, "chunk": chunk])
            }
            try checkOperation(token)
            _ = try await app.vpnManager.companyMessage(["op": "company.commit", "id": id]); phase = "connecting"; message = "正在建立接入并应用授权分流"
            #else
            throw error("此构建没有接入内核")
            #endif
        } catch { if operation == token { fail(error) } }
    }
    func setTakeover(_ enabled: Bool) async {
        guard active else { message = "请先连接接入"; return }
        do { try await configure(["enabled": enabled]); try await app.regenerateConfig(); try await app.applyManagedConfiguration(); message = enabled ? "授权资源已接管" : "接入保持连接，其他应用的资源尚未接管" } catch { fail(error) }
    }
    func disconnect() async {
        operation = UUID(); polling?.cancel(); busy = false; challenge = nil; password = ""; pendingPassword = nil
        do { try await configure(["enabled": false]); try await app.regenerateConfig(); if app.isTunnelRunning { _ = try await app.vpnManager.companyMessage(["op": "company.disconnect"]); try await app.applyManagedConfiguration() }; phase = "idle"; message = "已断开并解除资源接管" } catch { fail(error) }
    }
    func verify(target: String) async { do { _ = try await app.vpnManager.companyMessage(["op": "company.verify", "target": target]); message = "正在验证指定业务" } catch { fail(error) } }
    func refreshResources() async {
        guard !active else { message = "请先断开接入，再刷新资源"; return }
        #if canImport(Libbox)
        do { guard let controller else { throw error("请重新登录") }; try controller.send(#"{"type":"refresh_resources"}"#); busy = true; let token = operation; polling = Task { while !Task.isCancelled && operation == token && busy { do { try await consume(controller.poll(), token: token) } catch { fail(error); busy = false }; try? await Task.sleep(nanoseconds: 400_000_000) } } } catch { fail(error) }
        #endif
    }
    func cancel() async { cancelAuthentication(); _ = try? await app.vpnManager.companyMessage(["op": "company.cancel"]); phase = "cancelled"; message = "已取消；已启用的授权保护保留" }
    func clearCredential() async { do { try MobileSecretVault.save("company", data: nil); try await configure(["remember": false]); message = "已清除记住的接入密码" } catch { fail(error) } }
    private func cancelAuthentication(preservingPassword: Bool = false) {
        if !preservingPassword { password = "" }
        operation = UUID(); polling?.cancel(); polling = nil; pendingPassword = nil; challenge = nil; busy = false
        #if canImport(Libbox)
        controller?.close(); controller = nil
        #endif
    }
    func leaveAuthentication() async { if ["probing", "authenticating", "challenge"].contains(phase), challenge?["kind"] as? String != "external" { await cancel() } }
    private func checkOperation(_ token: UUID) throws { if operation != token || Task.isCancelled { throw CancellationError() } }
    private func fail(_ error: Error) { busy = false; phase = "error"; message = Redaction.message(error.localizedDescription) }
    private func error(_ message: String) -> NSError { NSError(domain: "MobileCompany", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
