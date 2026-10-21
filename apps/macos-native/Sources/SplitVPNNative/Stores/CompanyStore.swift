import AppKit
import Combine
import Foundation

@MainActor
final class CompanyStore: ObservableObject {
    @Published private(set) var businessVerified = false
    @Published private(set) var tunnelProof: TunnelProof?
    @Published private(set) var routingState: CompanyRoutingState?
    @Published private(set) var routingKnown = true
    @Published var target = ""
    @Published private(set) var takeoverEnabled: Bool
    @Published private(set) var rememberCredentials: Bool
    @Published private(set) var hasSavedCredentials = false
    @Published private(set) var credentialMessage: String?
    var connectionEnabled: Bool { tunnelProof != nil || routingState?.active == true || routingState?.recovering == true }
    var connectionReady: Bool { takeoverEnabled ? routingState?.active == true : tunnelProof != nil }
    var statusText: String {
        if connectionOperation == .disconnecting { return "正在断开私有网络" }
        if takeoverEnabled && connectionEnabled && !routingKnown { return "私有网络分流状态未知" }
        if routingState?.recovering == true { return "私有网络分流恢复中" }
        if routingState?.active == true { return "私有网络已连接" }
        if tunnelProof != nil { return takeoverEnabled ? "私有网络隧道已连接 · 分流未接入" : "私有网络隧道已连接 · 未接管" }
        if phases["tunnel"] == .running { return "正在连接私有网络" }
        if hasSession { return "已登录 · 未连接" }
        if challenge?.kind == "password_change" { return "等待修改接入密码" }
        if let loginIssue { return loginIssue.title }
        if quickPreparing || working { return "正在准备私有网络连接" }
        return quickConnectionID != nil ? "等待完成私有网络认证" : "私有网络未连接"
    }
    @Published var origin = "" {
        didSet {
            if origin != oldValue {
                stopSession()
                hasSavedCredentials = false; credentialMessage = nil; username = ""; password = ""
                probe = nil
                certificateState = .pending
                phases["probe"] = .pending
                resetAccountResults()
                requiresNewPassword = passwordChangePending(origin: origin)
                errorMessage = nil
            }
        }
    }
    @Published var username = ""
    @Published var password = ""
    @Published var selectedDomain = "local"
    @Published private(set) var certificateState: GatewayCertificateState = .pending
    @Published private(set) var probe: ProbeInfo?
    @Published private(set) var resources: ResourceResult?
    @Published private(set) var phases: [String: TestPhase] = ["probe": .pending, "login": .pending, "resources": .pending, "tunnel": .pending, "business": .pending, "routing": .pending]
    @Published private(set) var timeline: [TimelineItem] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var errorStage: String?
    @Published private(set) var loginIssue: CompanyLoginIssue?
    @Published private(set) var authenticatedUsername: String?
    @Published private(set) var working = false
    @Published private(set) var hasSession = false
    @Published private(set) var terminating = false
    @Published private(set) var quickPreparing = false
    @Published private(set) var quickConnectionID: UUID?
    @Published private(set) var connectionOperation: ConnectionOperation?
    @Published var requestedInteraction: CompanyInteraction?
    var onNeedsInteraction: ((CompanyInteraction) -> Void)?
    @Published var challenge: AuthChallenge?
    @Published var searchText = ""
    private let helper: any CompanyHelper
    private var currentRun: UUID?
    private var started = false
    private var preferencesLoaded = false
    private var initialization: Task<Void, Never>?
    private var quickTask: Task<Void, Never>?
    private var networkOperations: [UUID: Task<Void, Never>] = [:]
    private var credentialGeneration = UUID()
    private var stableRunBeforeTermination: UUID?
    private var helperCallbacksRetired = false
    private var core: CoreService?
    private var coreObservation: AnyCancellable?
    private let credentialVault: any CompanyCredentialVault
    private let preferences: UserDefaults
    private var gatewayTrust: CompanyGatewayTrust { CompanyGatewayTrust(preferences: preferences) }
    private var credentialDraft = CompanyCredentialDraft()
    private static let passwordChangePendingKey = "companyPasswordChangePendingGateways"
    private var requiresNewPassword = false {
        didSet {
            guard let key = try? CompanyCredentials.gatewayKey(origin) else { return }
            var entries = preferences.dictionary(forKey: Self.passwordChangePendingKey) ?? [:]
            if requiresNewPassword { entries[key] = true } else { entries.removeValue(forKey: key) }
            preferences.set(entries, forKey: Self.passwordChangePendingKey)
        }
    }
    private func passwordChangePending(origin: String) -> Bool {
        guard let key = try? CompanyCredentials.gatewayKey(origin) else { return false }
        return preferences.dictionary(forKey: Self.passwordChangePendingKey)?[key] as? Bool == true
    }
    private struct PendingPasswordChange {
        let id: String
        let username: String
        let credentials: CompanyCredentials?
    }
    private var pendingPasswordChange: PendingPasswordChange?
    private var passwordChangedDuringLogin = false
    init(credentialVault: any CompanyCredentialVault = KeychainCompanyCredentialVault(), preferences: UserDefaults = .standard,
         helper: any CompanyHelper = HelperService(), preview: CompanyPreview? = nil) {
        self.credentialVault = credentialVault; self.preferences = preferences; self.helper = helper
        takeoverEnabled = preferences.object(forKey: "companyTakeoverEnabled") as? Bool ?? true
        rememberCredentials = preferences.object(forKey: "companyRememberCredentials") as? Bool ?? true
        if let preview {
            started = true; preferencesLoaded = true; origin = preview.probe.origin; probe = preview.probe; certificateState = .remembered
            username = "测试账号"; password = "fixture-only"
            phases["probe"] = .passed; resources = preview.resources; tunnelProof = preview.tunnel
            if preview.resources != nil { hasSession = true; authenticatedUsername = username; phases["login"] = .passed; phases["resources"] = .passed }
            if preview.tunnel != nil { phases["tunnel"] = .passed }
            if let tunnel = preview.tunnel, !tunnel.target.isEmpty { target = tunnel.target }
            if let routing = preview.routing { updateRouting(routing) }
        }
    }
    /// Last entry that authenticated; not a secret, so it lives in preferences.
    static let originKey = "companyOrigin"
    /// Last business address checked; kept locally, never shipped in the app.
    static let targetKey = "companyTarget"
    func configure(core: CoreService) {
        self.core = core
        coreObservation = core.$availability.sink { [weak self] availability in
            switch availability {
            case .unavailable, .closed: self?.routingKnown = false
            default: break
            }
        }
    }
    func updateRouting(_ state: CompanyRoutingState) {
        routingKnown = true
        let previous = routingState
        routingState = state
        businessVerified = hasSession && takeoverEnabled && state.verified
        if businessVerified { phases["routing"] = .passed; phases["business"] = .passed }
        else if state.recovering {
            phases["routing"] = .running; phases["business"] = .pending
            if previous?.lastError != state.lastError, let message = state.lastError { append(message) }
        }
        else if let message = state.lastError {
            if previous?.lastError != message { fail(stage: state.active ? "business" : "routing", message: message) }
        }
        else if state.active { phases["routing"] = .passed; phases["business"] = .pending }
        else if !state.active && tunnelProof != nil { phases["routing"] = .pending }
        if state.active && state.lastError == nil && (errorStage == "routing" || errorStage == "business") {
            errorStage = nil; errorMessage = nil
        }
        if state.recoveryCount > (previous?.recoveryCount ?? 0) { append("现有 VPN 配置更新后，私有网络分流已恢复；私有网络隧道与登录会话继续使用。") }
    }

    var passwordMethods: [AuthMethod] { probe?.methods.filter { $0.authType == "auth/psw" } ?? [] }
    var confirmedCertificate: Bool {
        guard let probe else { return false }
        return certificateState.approved && gatewayTrust.isCurrent(probe) &&
            (try? CompanyCredentials.gatewayKey(origin)) == (try? CompanyCredentials.gatewayKey(probe.origin))
    }
    var previousCertificateFingerprint: String? { gatewayTrust.rememberedFingerprint(origin: origin) }
    var canLogin: Bool {
        !terminating && !working && probe != nil && confirmedCertificate && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !password.isEmpty && passwordMethods.contains { $0.loginDomain == selectedDomain }
    }
    var filteredRows: [ResourceRow] {
        let rows = resources?.rows ?? []
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if term.isEmpty { return rows }
        return rows.filter { "\($0.name) \($0.address) \($0.ports) \($0.network) \($0.appID)".localizedCaseInsensitiveContains(term) }
    }
    var errorHeading: String {
        if let loginIssue { return loginIssue.title }
        switch errorStage {
        case "probe": return "入口检测失败"
        case "login": return "账号认证未通过"
        case "resources": return "授权资源获取失败"
        case "tunnel": return "私有网络隧道连接未完成"
        case "business": return "内网访问未通过"
        case "routing": return "私有网络分流未完成"
        default: return "连接未完成"
        }
    }

    func startOnce() {
        guard !started, !terminating else { return }
        started = true
        loadPreferencesOnce()
        initialization = Task {
            await loadCredentials()
            guard !Task.isCancelled, !terminating else { return }
            detectEntry()
        }
    }
    private func loadPreferencesOnce() {
        guard !preferencesLoaded else { return }
        preferencesLoaded = true
        if let url = Bundle.main.url(forResource: "config", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let configuredOrigin = config["origin"] as? String {
            origin = configuredOrigin
            selectedDomain = config["loginDomain"] as? String ?? "local"
            target = config["target"] as? String ?? target
        } else if let saved = preferences.string(forKey: Self.originKey), !saved.isEmpty {
            // The keychain stores the account per entry, so the entry itself
            // must survive a restart for the account to be found again.
            origin = saved
        }
        if target.isEmpty, let saved = preferences.string(forKey: Self.targetKey) { target = saved }
    }
    func initializePreferences() { loadPreferencesOnce() }

    func loadCredentials() async {
        guard rememberCredentials, !requiresNewPassword, !hasSession, !working, (try? CompanyCredentials.gatewayKey(origin)) != nil else { return }
        let entry = origin, previousUsername = username, previousPassword = password, generation = credentialGeneration
        do {
            let saved = try await credentialVault.load(origin: entry)
            guard !Task.isCancelled, !terminating, generation == credentialGeneration,
                  origin == entry, !hasSession, username == previousUsername, password == previousPassword else { return }
            hasSavedCredentials = saved != nil
            if let saved {
                username = saved.username; password = saved.password
                if probe == nil || passwordMethods.contains(where: { $0.loginDomain == saved.domain }) { selectedDomain = saved.domain }
                credentialMessage = "已从钥匙串读取接入账号。"
            }
        } catch { credentialMessage = error.localizedDescription }
    }
    func setRememberCredentials(_ value: Bool) {
        guard !terminating else { return }
        rememberCredentials = value; preferences.set(value, forKey: "companyRememberCredentials")
        if !value {
            credentialDraft.cancel()
            if let pending = pendingPasswordChange { pendingPasswordChange = PendingPasswordChange(id: pending.id, username: pending.username, credentials: nil) }
            forgetCredentials(clearFields: false)
        }
    }
    func forgetCredentials(clearFields: Bool = true) {
        guard !terminating else { return }
        let entry = origin
        guard (try? CompanyCredentials.gatewayKey(entry)) != nil else { hasSavedCredentials = false; return }
        Task {
            do {
                try await credentialVault.remove(origin: entry)
                guard origin == entry else { return }
                hasSavedCredentials = false; credentialMessage = "已移除保存的接入账号。"
                if clearFields && !hasSession { username = ""; password = "" }
            } catch { credentialMessage = error.localizedDescription }
        }
    }
    func setTakeover(_ value: Bool) {
        guard !terminating, !working, value != takeoverEnabled else { return }
        let previous = takeoverEnabled
        takeoverEnabled = value; businessVerified = false
        if value {
            preferences.set(true, forKey: "companyTakeoverEnabled")
            if tunnelProof != nil { connectTunnel() }
        } else if let core, tunnelProof != nil || routingState?.active == true || routingState?.recovering == true {
            working = true
            runNetworkOperation { [self] in
                do {
                    let state: CompanyRoutingState = try await core.request("native:company-remove")
                    updateRouting(state); working = false
                    preferences.set(false, forKey: "companyTakeoverEnabled")
                    phases["routing"] = .pending; phases["business"] = .pending
                    append("已关闭授权资源接管，账号与私有网络隧道继续保留。")
                } catch { takeoverEnabled = previous; fail(stage: "routing", message: error.localizedDescription) }
            }
        } else { preferences.set(false, forKey: "companyTakeoverEnabled") }
    }

    func detectEntry(preservingQuickConnection: Bool = false) {
        guard !terminating else { return }
        stopSession(preserveQuickConnection: preservingQuickConnection)
        resetAccountResults()
        probe = nil
        certificateState = .pending
        errorMessage = nil
        errorStage = nil
        timeline = []
        phases["probe"] = .running
        launch(["type": "probe", "origin": origin.trimmingCharacters(in: .whitespacesAndNewlines)])
    }

    func acceptProbe(_ info: ProbeInfo) {
        probe = info
        guard let entry = try? CompanyCredentials.gatewayKey(origin),
              entry == (try? CompanyCredentials.gatewayKey(info.origin)) else {
            certificateState = .invalid; phases["probe"] = .failed; return
        }
        certificateState = gatewayTrust.evaluate(info)
        if certificateState == .systemTrusted { try? gatewayTrust.remember(info) }
        phases["probe"] = certificateState.approved ? .passed : certificateState == .invalid ? .failed : .pending
    }

    func confirmGatewayCertificate() {
        guard !terminating, !working, !hasSession, certificateState.requiresUserConfirmation, let probe,
              (try? CompanyCredentials.gatewayKey(origin)) == (try? CompanyCredentials.gatewayKey(probe.origin)) else { return }
        do {
            try gatewayTrust.remember(probe)
            certificateState = .remembered; phases["probe"] = .passed
            append("接入网关证书已记住，后续自动核验，不再重复确认。")
            advanceQuickConnection()
        } catch {
            certificateState = .invalid; phases["probe"] = .failed
            errorStage = "probe"; errorMessage = error.localizedDescription
        }
    }

    func login(core: CoreService) {
        self.core = core
        guard canLogin, let probe else { return }
        requestedInteraction = nil
        stopSession(preserveQuickConnection: true)
        resetAccountResults()
        errorMessage = nil
        errorStage = nil
        phases["login"] = .running
        var command: [String: Any] = ["type": "login", "origin": probe.origin, "username": username,
                                      "password": password, "domain": selectedDomain, "fingerprint": probe.fingerprint]
        credentialDraft.prepare(CompanyCredentials(origin: probe.origin, domain: selectedDomain, username: username, password: password), remember: rememberCredentials)
        password = ""
        working = true
        let id = UUID(); currentRun = id
        runNetworkOperation { [self] in
            do {
                let context: CompanyNetworkContext = try await core.request("native:company-context")
                guard currentRun == id else { return }
                guard let interfaceName = context.interfaceName, !interfaceName.hasPrefix("utun") else {
                    fail(stage: "login", message: "尚未确认接入网关的底层网络入口，请稍后重试。"); return
                }
                command["interfaceName"] = interfaceName
                launch(command)
            } catch { if currentRun == id { fail(stage: "login", message: error.localizedDescription) } }
        }
    }

    var passwordChangeEntryURL: URL? {
        guard loginIssue == .passwordChangeRequired, let probe,
              let components = URLComponents(string: probe.origin), components.scheme == "https",
              components.host != nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { return nil }
        return components.url
    }

    func prepareAfterPasswordChange() {
        guard !terminating, !working, loginIssue == .passwordChangeRequired else { return }
        stopSession()
        resetAccountResults()
        password = ""
        errorMessage = nil; errorStage = nil
        credentialMessage = "请输入修改后的新密码，确认登录成功后再保存。"
    }

    func connectTunnel() {
        guard !terminating, hasSession, resources != nil, !working else { return }
        errorMessage = nil; errorStage = nil
        if tunnelProof != nil {
            if takeoverEnabled && routingState?.active != true { applyRouting() }
            return
        }
        connectionOperation = .connecting
        working = true; phases["tunnel"] = .running
        do { try helper.send(["type": "connect"]) }
        catch { fail(stage: "tunnel", message: error.localizedDescription) }
    }

    private func applyRouting() {
        guard let proof = tunnelProof, let core, let resources, let helperPid = helper.processID else {
            fail(stage: "routing", message: "私有网络接入服务未就绪。"); return
        }
        connectionOperation = .connecting
        working = true; businessVerified = false
        phases["routing"] = .running; phases["business"] = .pending
        let run = currentRun
        runNetworkOperation { [self] in
            do {
                let payload: [String: Any] = ["port": proof.port, "helperPid": Int(helperPid), "rows": VPNStore.jsonObjects(resources.rows)]
                let installed: CompanyRoutingState = try await core.request("native:company-apply", payload: payload)
                guard currentRun == run && hasSession else { _ = try? await core.requestValue("native:company-remove"); return }
                updateRouting(installed); working = false; connectionOperation = nil
                append("私有网络已连接，授权资源已接入私有网络分流。")
                advanceQuickConnection()
            } catch { if currentRun == run { fail(stage: "routing", message: error.localizedDescription) } }
        }
    }

    func verifyBusiness() {
        guard !terminating, hasSession, tunnelProof != nil, !working, !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        preferences.set(target.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.targetKey)
        businessVerified = false
        working = true; errorMessage = nil; errorStage = nil
        phases["business"] = .running
        let run = currentRun
        runNetworkOperation { [self] in
            do {
                guard hasSession, currentRun == run else { return }
                if takeoverEnabled {
                    guard let core else { throw CoreService.CoreError.message("私有网络接入服务未就绪。") }
                    let checked: CompanyRoutingState = try await core.request("native:company-verify", payload: ["target": target])
                    guard currentRun == run && hasSession else { return }
                    updateRouting(checked); working = false
                    append("现有私有网络连接验证通过，隧道继续保持。")
                } else {
                    try helper.send(["type": "verify", "target": target])
                }
            } catch { if currentRun == run { fail(stage: "business", message: error.localizedDescription) } }
        }
    }

    func verifyInternet() {
        guard !terminating, !working, let core else { return }
        working = true
        runNetworkOperation { [self] in
            defer { working = false }
            do {
                let state: CompanyRoutingState = try await core.request("native:company-internet-check")
                updateRouting(state)
                append(state.internet?.result.ok == true ? "GPT 网络检测通过。" : "GPT 网络检测未通过，请检查当前外网节点；私有网络连接继续保持。")
            } catch { append("外网检测未完成：\(error.localizedDescription)。私有网络连接继续保持。") }
        }
    }

    func disconnectTunnel() {
        guard !terminating, connectionEnabled, !working else { return }
        cancelQuickConnection()
        connectionOperation = .disconnecting
        working = true; errorMessage = nil; errorStage = nil
        let run = currentRun
        runNetworkOperation { [self] in
            do {
                if let core {
                    let removed: CompanyRoutingState = try await core.request("native:company-remove")
                    guard currentRun == run else { return }
                    updateRouting(removed)
                }
                if helper.processID != nil, !helperCallbacksRetired { try helper.send(["type": "disconnect"]) }
                else if helper.processID != nil { try await helper.stopAndWait(timeout: 10); tunnelClosed() }
                else { tunnelClosed() }
            } catch { if currentRun == run { fail(stage: "routing", message: error.localizedDescription) } }
        }
    }

    func refreshResources() {
        guard !terminating, hasSession && !working else { return }
        errorMessage = nil
        errorStage = nil
        working = true
        phases["resources"] = .running
        do { try helper.send(["type": "refresh_resources"]) }
        catch { fail(stage: "resources", message: error.localizedDescription) }
    }

    func answerChallenge(_ response: [String: Any]) {
        guard !terminating, let challenge else { return }
        if challenge.kind == "password_change" {
            guard let newPassword = response["newPassword"] as? String, !newPassword.isEmpty,
                  let oldPassword = response["oldPassword"] as? String, !oldPassword.isEmpty, newPassword != oldPassword else { return }
            let account = (response["newUsername"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? username
            guard !account.isEmpty, let probe else { return }
            let credentials = rememberCredentials ? CompanyCredentials(origin: probe.origin, domain: selectedDomain, username: account, password: newPassword) : nil
            pendingPasswordChange = PendingPasswordChange(id: challenge.id, username: account, credentials: credentials)
            requiresNewPassword = true // A cancelled/in-flight request can already have reached the server.
        }
        var command = response
        command["type"] = "challenge_response"
        command["id"] = challenge.id
        self.challenge = nil
        requestedInteraction = nil
        do { try helper.send(command); append("验证信息已提交，等待接入服务响应…") }
        catch { fail(stage: "login", message: error.localizedDescription) }
    }

    private func saveCredentials(_ saved: CompanyCredentials, changedPassword: Bool = false) {
        Task {
            do {
                try await credentialVault.save(saved)
                if !rememberCredentials { try await credentialVault.remove(origin: saved.origin); return }
                guard (try? CompanyCredentials.gatewayKey(origin)) == (try? CompanyCredentials.gatewayKey(saved.origin)) else { return }
                hasSavedCredentials = true
                if changedPassword { requiresNewPassword = false }
                credentialMessage = changedPassword ? "接入密码已修改，新密码已保存到 macOS 钥匙串。" : "账号与密码已保存到 macOS 钥匙串。"
            } catch {
                guard (try? CompanyCredentials.gatewayKey(origin)) == (try? CompanyCredentials.gatewayKey(saved.origin)) else { return }
                if changedPassword { requiresNewPassword = true; hasSavedCredentials = false }
                credentialMessage = error.localizedDescription
            }
        }
    }

    func endTest() {
        guard !terminating else { return }
        cancelQuickConnection()
        let wasWorking = working
        if routingState?.active == true, let core {
            working = true; businessVerified = false
            runNetworkOperation { [self] in
                do { _ = try await core.requestValue("native:company-remove"); stopSession(); append("私有网络分流已移除，会话已结束。现有外网 VPN 保持运行。"); await loadCredentials() }
                catch { fail(stage: "routing", message: error.localizedDescription) }
            }
        } else {
            stopSession()
            for key in ["probe", "login", "resources"] where phases[key] == .running { phases[key] = .pending }
            append(wasWorking ? "已取消本次连接。" : "私有网络会话已结束，现有外网 VPN 保持运行。")
            if !wasWorking { Task { await loadCredentials() } }
        }
    }

    func close() {
        password = ""
        stopSession()
    }

    func copyDiagnostics() {
        var lines = ["轻舟 \(NativeBuild.version) 私有网络连接诊断", "入口：\(probe?.origin ?? origin)"]
        if let probe {
            lines.append("证书 SHA-256：\(probe.fingerprint)")
            lines.append("证书核验：\(certificateState.title)")
            lines.append("认证方式：\(probe.methods.map { "\($0.authName) / \($0.loginDomain)" }.joined(separator: ", "))")
        }
        for (key, name) in [("probe", "入口检测"), ("login", "账号登录"), ("resources", "授权资源")] {
            lines.append("\(name)：\(phases[key]?.rawValue ?? "待测试")")
        }
        if let resources { lines.append("应用数量：\(resources.appCount)，地址规则：\(resources.rows.count)") }
        if let state = routingState {
            lines.append("系统分流：\(state.active ? "已接入" : state.recovering ? "正在恢复" : "未接入")，自动恢复次数：\(state.recoveryCount)")
            if let error = state.lastError { lines.append("私有网络访问：\(error)") }
            if let internet = state.internet { lines.append("GPT 网络：\(internet.result.ok ? "可达" : "不可达")，检测时间：\(internet.checkedAt)") }
        }
        lines += timeline.map { "\($0.time.formatted(date: .omitted, time: .standard)) \($0.message)" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func launch(_ command: [String: Any]) {
        helperCallbacksRetired = false
        let id = UUID()
        currentRun = id
        working = true
        do {
            try helper.start(command: command, onEvent: { [weak self] event in
                guard let self, self.currentRun == id else { return }
                self.receive(event)
            }, onExit: { [weak self] status in
                guard let self, self.currentRun == id else { return }
                self.hasSession = false
                self.tunnelProof = nil
                self.businessVerified = false
                if self.working {
                    self.fail(stage: self.phases["tunnel"] == .running ? "tunnel" : self.phases["login"] == .running ? "login" : "probe",
                              message: status == 0 ? "私有网络连接服务已结束，请重新登录。" : "私有网络连接服务意外结束（\(status)），请重试。")
                }
            })
        } catch {
            fail(stage: phases["login"] == .running ? "login" : "probe", message: error.localizedDescription)
        }
    }

    func receive(_ event: HelperEvent) {
        guard !terminating else { return }
        switch event.type {
        case "progress":
            if let stage = event.stage { phases[stage] = .running }
            if let message = event.message { append(message) }
        case "probe":
            guard let info = event.probe else { return }
            acceptProbe(info)
            if !passwordMethods.contains(where: { $0.loginDomain == selectedDomain }) {
                selectedDomain = passwordMethods.first?.loginDomain ?? ""
            }
            working = false
            append("入口检测成功，发现 \(info.methods.count) 种认证方式。")
            append(certificateState.title)
            let intent = quickConnectionID
            Task {
                if username.isEmpty && password.isEmpty { await loadCredentials() }
                guard quickConnectionID == intent, !terminating else { return }
                advanceQuickConnection()
            }
        case "login_success":
            if !passwordChangedDuringLogin { requiresNewPassword = false }
            loginIssue = nil
            authenticatedUsername = event.username
            phases["login"] = .passed
            hasSession = true
            append("接入账号认证成功。")
            if let entry = probe?.origin { preferences.set(entry, forKey: Self.originKey) }
            if let saved = credentialDraft.authenticated(remember: rememberCredentials) {
                saveCredentials(saved)
            }
        case "password_changed":
            guard let pending = pendingPasswordChange, event.id == pending.id else { return }
            pendingPasswordChange = nil
            credentialDraft.cancel() // The original password is now invalid, even if a later OTP fails.
            passwordChangedDuringLogin = true; requiresNewPassword = true
            username = pending.username
            credentialMessage = "接入密码已修改；下次登录请使用新密码。"
            append("接入密码已修改，正在继续认证…")
            if let saved = pending.credentials, rememberCredentials { saveCredentials(saved, changedPassword: true) }
        case "resources":
            guard let result = event.resources else { return }
            resources = result
            phases["resources"] = .passed
            working = false
            append("授权资源获取成功：\(result.appCount) 个应用，\(result.rows.count) 条地址规则。")
            advanceQuickConnection()
        case "challenge":
            pendingPasswordChange = nil
            challenge = event.challenge
            if let challenge = event.challenge { append("接入服务要求完成\(challenge.title)。") }
            if quickConnectionID != nil { requireInteraction(.challenge) }
        case "tunnel_ready":
            guard let proof = event.tunnel, (1...65535).contains(proof.port), proof.transport == "atrust-tcp" else {
                fail(stage: "tunnel", message: "未取得有效的私有网络隧道连接信息。"); return
            }
            tunnelProof = proof
            phases["tunnel"] = .passed; phases["business"] = .pending
            if !takeoverEnabled {
                phases["routing"] = .pending
                businessVerified = false; working = false; connectionOperation = nil
                append("私有网络隧道已连接；资源接管已关闭，可随时开启。")
                advanceQuickConnection()
                return
            }
            applyRouting()
        case "tunnel_verified":
            guard let proof = event.tunnel, proof.port == tunnelProof?.port, proof.sent > 0, proof.received > 0,
                  (200..<400).contains(proof.httpStatus), proof.transport == "atrust-tcp" else {
                fail(stage: "business", message: "未取得有效的私有网络隧道访问证据。"); return
            }
            tunnelProof = proof; phases["business"] = .passed; working = false
            append("指定业务经现有私有网络隧道验证通过，连接继续保持。")
        case "tunnel_closed":
            tunnelClosed()
        case "error":
            if event.stage == "login", event.code == "password_change_uncertain" {
                let fromQuickConnection = quickConnectionID != nil
                stopSession(); resetAccountResults(); password = ""; requiresNewPassword = true
                credentialMessage = "改密结果待确认，已暂停读取旧密码。请先尝试使用新密码登录。"
                fail(stage: "login", message: event.message ?? "未能确认改密结果，请先尝试使用新密码重新登录。")
                if fromQuickConnection { requireInteraction(.account) }
            } else if let issue = event.loginIssue {
                let fromQuickConnection = quickConnectionID != nil
                stopSession()
                resetAccountResults()
                password = ""; credentialMessage = nil; requiresNewPassword = true
                fail(stage: "login", message: issue.message)
                loginIssue = issue
                if fromQuickConnection { requireInteraction(.account) }
            } else {
                loginIssue = nil
                fail(stage: event.stage ?? "local", message: event.message ?? "连接验证失败。")
            }
        default: break
        }
    }

    private func tunnelClosed() {
        connectionOperation = nil
        tunnelProof = nil; routingState = nil; businessVerified = false
        phases["tunnel"] = .pending; phases["business"] = .pending
        phases["routing"] = .pending; working = false
        append("本次私有网络隧道已关闭，原有 VPN 保持运行。")
    }

    private func fail(stage: String, message: String) {
        if quickConnectionID != nil {
            // A failed quick attempt must not accept late resources/tunnel events.
            currentRun = nil; helperCallbacksRetired = true; hasSession = false
        }
        cancelQuickConnection()
        connectionOperation = nil
        phases[stage] = .failed
        if stage == "tunnel" { phases["business"] = .failed }
        errorStage = stage
        errorMessage = message
        working = false
        challenge = nil
        if stage == "login" { credentialDraft.cancel(); pendingPasswordChange = nil }
        if stage == "tunnel" { tunnelProof = nil }
        if stage == "tunnel" || stage == "business" || stage == "routing" { businessVerified = false }
        append(message)
    }

    private func stopSession(preserveQuickConnection: Bool = false) {
        if !preserveQuickConnection { cancelQuickConnection() }
        currentRun = nil
        credentialGeneration = UUID()
        credentialDraft.cancel()
        pendingPasswordChange = nil; passwordChangedDuringLogin = false
        helper.stop()
        clearSessionState()
    }
    private func clearSessionState() {
        connectionOperation = nil
        routingKnown = true
        working = false
        hasSession = false
        challenge = nil
        tunnelProof = nil; businessVerified = false
        phases["tunnel"] = .pending; phases["business"] = .pending; phases["routing"] = .pending
        routingState = nil
    }

    /// Only an explicit click creates this intent; ordinary startup never logs in.
    func requestQuickConnection() {
        guard !terminating, !working, !quickPreparing else { return }
        if connectionEnabled { disconnectTunnel(); return }
        if helperCallbacksRetired { stopSession() }
        loadPreferencesOnce()
        // Opening the company page during this intent must not start another probe.
        started = true
        if quickConnectionID == nil { quickConnectionID = UUID() }
        let intent = quickConnectionID
        quickPreparing = true
        quickTask = Task {
            defer { if quickConnectionID == intent { quickPreparing = false } }
            await loadCredentials()
            guard !Task.isCancelled, !terminating, quickConnectionID == intent else { return }
            quickPreparing = false
            advanceQuickConnection()
        }
    }
    func cancelQuickConnection() {
        quickConnectionID = nil; quickPreparing = false
        quickTask?.cancel(); requestedInteraction = nil
    }
    private func advanceQuickConnection() {
        guard quickConnectionID != nil, !terminating, !working else { return }
        if connectionReady { cancelQuickConnection(); return }
        if hasSession {
            if resources != nil { connectTunnel() } else { refreshResources() }
            return
        }
        guard (try? CompanyCredentials.gatewayKey(origin)) != nil else { requireInteraction(.account); return }
        guard probe != nil else { detectEntry(preservingQuickConnection: true); return }
        guard confirmedCertificate else { requireInteraction(.certificate); return }
        guard canLogin, let core else { requireInteraction(.account); return }
        login(core: core)
    }
    private func requireInteraction(_ interaction: CompanyInteraction) {
        requestedInteraction = interaction
        onNeedsInteraction?(interaction)
    }
    func beginTermination() {
        terminating = true
        cancelQuickConnection(); initialization?.cancel()
        stableRunBeforeTermination = hasSession && connectionReady && !working ? currentRun : nil
        helperCallbacksRetired = true
        // Retire callbacks before waiting for RPCs, preventing late auto-connects.
        currentRun = nil; credentialDraft.cancel(); pendingPasswordChange = nil; challenge = nil
    }
    func waitForOperations() async {
        await initialization?.value
        guard !Task.isCancelled else { return }
        await quickTask?.value
        while !Task.isCancelled, let task = networkOperations.values.first { await task.value }
        guard !Task.isCancelled else { return }
        await core?.waitForPendingRequests()
    }
    func prepareForTermination(timeout: TimeInterval = 10) async throws {
        if let core {
            let removed: CompanyRoutingState = try await core.request("native:company-remove", timeout: .seconds(45))
            guard !removed.active, !removed.recovering else {
                throw CoreService.CoreError.message("私有网络分流清理尚未确认，应用继续运行。")
            }
            updateRouting(removed)
        }
        try await helper.stopAndWait(timeout: timeout)
        password = ""; clearSessionState()
    }
    func resumeAfterTerminationFailure() {
        terminating = false; working = false; connectionOperation = nil
        if helper.processID != nil, let run = stableRunBeforeTermination { currentRun = run; helperCallbacksRetired = false }
        else { hasSession = false }
        stableRunBeforeTermination = nil
    }
    private func runNetworkOperation(_ action: @escaping @MainActor () async -> Void) {
        let id = UUID()
        networkOperations[id] = Task {
            await action()
            networkOperations.removeValue(forKey: id)
        }
    }

    private func resetAccountResults() {
        loginIssue = nil
        authenticatedUsername = nil
        resources = nil
        phases["login"] = .pending
        phases["resources"] = .pending
        searchText = ""
    }

    private func append(_ message: String) {
        timeline.append(TimelineItem(message: message))
        if timeline.count > 80 { timeline.removeFirst(timeline.count - 80) }
    }
}
