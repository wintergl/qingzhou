import AppKit

extension NativeAppRuntime {
    static func make() -> NativeAppRuntime {
        #if DEBUG
        if MenuBarPreview.isEnabled { return MenuBarPreview.make() }
        #endif
        let log = NativeTerminationLog()
        return NativeAppRuntime(store: VPNStore(), company: CompanyStore(), preferences: DesktopPreferences(),
                                terminationLog: log.record)
    }
}

#if DEBUG
/// An explicit development-only launch uses no subprocess, keychain or network.
@MainActor
enum MenuBarPreview {
    static var isEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "QZMenuBarPreview") as? Bool == true ||
        ProcessInfo.processInfo.arguments.contains("--menu-bar-preview")
    }
    static func make() -> NativeAppRuntime {
        precondition(Bundle.main.object(forInfoDictionaryKey: "QZMenuBarPreview") as? Bool == true ||
                     ProcessInfo.processInfo.environment["SPLITVPN_ISOLATED"] == "1", "菜单栏预览必须使用隔离启动入口。")
        // Foundation rejects adding the application's own domain as a suite.
        // The preview bundle's standard domain is already separate from the app.
        let previewDomain = "dev.split-vpn.menu-bar-preview"
        let defaults = Bundle.main.bundleIdentifier == previewDomain ? UserDefaults.standard : UserDefaults(suiteName: previewDomain)!
        if ProcessInfo.processInfo.arguments.contains("--preview-reset") { defaults.removePersistentDomain(forName: "dev.split-vpn.menu-bar-preview") }
        let model = PreviewCore()
        let core = CoreService { channel, payload in try await model.call(channel, payload) }
        let store = VPNStore(core: core, loginItems: PreviewLoginItems(), riskKeyVault: PreviewVault(empty: true))
        if defaults.string(forKey: CompanyStore.originKey) == nil { defaults.set("https://gateway.example.test", forKey: CompanyStore.originKey) }
        let needsCertificate = ProcessInfo.processInfo.arguments.contains("--preview-certificate")
        if needsCertificate { defaults.removeObject(forKey: "companyConfirmedGatewayCertificates") }
        if !needsCertificate { try? CompanyGatewayTrust(preferences: defaults).remember(PreviewHelper.probe) }
        let helper = PreviewHelper()
        helper.needsChallenge = ProcessInfo.processInfo.arguments.contains("--preview-challenge")
        let company = CompanyStore(credentialVault: PreviewVault(), preferences: defaults, helper: helper)
        return NativeAppRuntime(store: store, company: company, preferences: DesktopPreferences(defaults: defaults))
    }
    /// Capture the initial state before a UI inspector's reopen event opens main.
    /// Only the isolated preview writes this report next to its development bundle.
    static func recordStartup(loginLaunch: Bool) {
        guard Bundle.main.object(forInfoDictionaryKey: "QZMenuBarPreview") as? Bool == true else { return }
        let report: [String: Any] = ["loginLaunch": loginLaunch,
            "visibleWindowCount": NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.count,
            "dockVisible": NSApp.activationPolicy() == .regular,
            "fakeServices": true]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("startup-report.json"), options: .atomic)
        }
    }
}

@MainActor
private final class PreviewCore {
    var running = false
    var companyActive = false
    var tun = true
    var state: JSONValue { .object(["state": .string(running ? "running" : "stopped"), "mode": .string("vpn"), "pid": running ? .number(0) : .null]) }
    var routing: JSONValue { .object(["active": .bool(companyActive), "verified": .bool(false), "recovering": .bool(false),
                                     "recoveryCount": .number(0), "ruleCount": .number(companyActive ? 1 : 0), "routes": .array([])]) }
    func call(_ channel: String, _ payload: [String: Any]) async throws -> JSONValue {
        switch channel {
        case "native:bootstrap":
            let data: [String: Any] = ["status": ["appStartedAt": "fixture", "mihomo": try JSONSerialization.jsonObject(with: state.encoded),
                "subscription": ["nodeCount": 1, "status": "ready", "entries": []],
                "settings": ["launchAtLogin": false, "unknownTraffic": "direct", "tun": tun, "ipv6": false, "lanDirect": true, "tailscaleDirect": true,
                             "specialCompatibilityRules": ["mailMasterProxy8081": false, "wechatImageSendFallback": false],
                             "selectedProxy": "示例节点", "vpnDomainRules": [], "favoriteNodeNames": [], "nodeGroups": []]],
                "nodes": [["name": "示例节点", "type": "ss", "selected": true, "identityKey": "fixture-node", "delay": 32, "available": true]],
                "groups": [], "risks": [], "traffic": ["rates": ["upload": 0, "download": 0], "samples": [], "running": running],
                "legacyOwnerRunning": false, "previewOnly": false, "ownsRuntime": true,
                "companyRouting": try JSONSerialization.jsonObject(with: routing.encoded), "dataDir": "/fixture"]
            return try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: data))
        case "native:startup-connect": return .object(["startupOutcome": .string("disabled"), "mihomo": state])
        case "vpn:start", "vpn:stop":
            try await Task.sleep(for: .milliseconds(450))
            running = channel == "vpn:start"; return state
        case "native:company-context": return .object(["interfaceName": .string("fixture-interface")])
        case "native:company-apply", "native:company-remove": companyActive = channel == "native:company-apply"; return routing
        case "traffic:get-monitor": return .object(["rates": .object(["upload": .number(0), "download": .number(0)]), "samples": .array([]), "running": .bool(running)])
        case "native:preferences": if let value = payload["tun"] as? Bool { tun = value }; return .null
        default: throw CoreService.CoreError.message("隔离预览没有执行此操作。")
        }
    }
}

private struct PreviewVault: CompanyCredentialVault {
    var empty = false
    func load(origin: String) async throws -> CompanyCredentials? {
        empty ? nil : CompanyCredentials(origin: origin, domain: "local", username: "示例账号", password: "fixture-only")
    }
    func save(_ credentials: CompanyCredentials) async throws {}
    func remove(origin: String) async throws {}
}
@MainActor
private final class PreviewLoginItems: LoginItemService {
    func state() -> LoginItemState { .disabled }
    func setEnabled(_ enabled: Bool) throws -> LoginItemState { enabled ? .enabled : .disabled }
    func openSystemSettings() {}
}
private final class PreviewHelper: CompanyHelper {
    static let probe = ProbeInfo(origin: "https://gateway.example.test", fingerprint: String(repeating: "AB", count: 32), subject: "示例网关",
        validTo: "2099-01-01T00:00:00Z", nameMatches: true, selfSigned: true,
        methods: [AuthMethod(loginDomain: "local", authType: "auth/psw", authName: "接入账号")])
    var processID: Int32?
    var needsChallenge = false
    private var onEvent: ((HelperEvent) -> Void)?
    func start(command: [String: Any], onEvent: @escaping (HelperEvent) -> Void, onExit: @escaping (Int32) -> Void) throws {
        self.onEvent = onEvent; processID = 0
        if command["type"] as? String == "probe" { emit("probe", probe: Self.probe) }
        else if needsChallenge {
            emit("challenge", challenge: AuthChallenge(id: "fixture", kind: "sms", title: "示例验证码", message: "填写任意示例验证码即可继续。", imageBase64: nil, url: nil))
        } else { loggedIn() }
    }
    func send(_ command: [String: Any]) throws {
        switch command["type"] as? String {
        case "challenge_response": loggedIn()
        case "connect": emit("tunnel_ready", tunnel: TunnelProof(port: 10000, target: "", httpStatus: 0, elapsedMs: 0, sent: 0, received: 0, verifiedAt: "", transport: "atrust-tcp"))
        case "disconnect": emit("tunnel_closed")
        default: break
        }
    }
    func stop() { processID = nil; onEvent = nil }
    private func loggedIn() {
        emit("login_success")
        emit("resources", resources: ResourceResult(rows: [ResourceRow(id: "fixture", appID: "fixture", name: "示例应用", address: "10.0.0.8", ports: "443", network: "tcp", accessModel: "vpn")], appCount: 1, dns: [], gateways: [], fetchedAt: "fixture"))
    }
    private func emit(_ type: String, probe: ProbeInfo? = nil, resources: ResourceResult? = nil, tunnel: TunnelProof? = nil, challenge: AuthChallenge? = nil) {
        let event = HelperEvent(type: type, stage: nil, message: nil, username: type == "login_success" ? "示例账号" : nil, probe: probe, resources: resources, tunnel: tunnel, challenge: challenge)
        let callback = onEvent
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { callback?(event) }
    }
}
#endif
