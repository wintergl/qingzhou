import Foundation
import XCTest
@testable import SplitVPNNative

@MainActor
final class MenuBarFixture {
    let suite = "splitvpn-menu-test-\(UUID())"
    let defaults: UserDefaults
    let coreModel = MenuCoreModel()
    let helper = MenuHelper()
    let vault = MenuVault()
    let windows = MenuWindows()
    let core: CoreService
    let store: VPNStore
    let company: CompanyStore
    let preferences: DesktopPreferences
    let runtime: NativeAppRuntime
    var policies: [Bool] = []
    init(terminationLog: @escaping (NativeTerminationEvent) -> Void = { _ in }) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = coreModel
        core = CoreService { channel, payload in try await model.call(channel, payload) }
        store = VPNStore(core: core, loginItems: MenuLoginItems(), riskKeyVault: FixtureVault())
        company = CompanyStore(credentialVault: vault, preferences: defaults, helper: helper)
        preferences = DesktopPreferences(defaults: defaults, applyPolicy: { _ in })
        runtime = NativeAppRuntime(store: store, company: company, preferences: preferences, windows: windows,
                                   terminationLog: terminationLog)
        helper.record = { model.events.append($0) }
    }
    func close() { company.close(); store.close(); defaults.removePersistentDomain(forName: suite) }
    func prepareAccount(rememberCertificate: Bool = true) throws {
        defaults.set(MenuHelper.probe.origin, forKey: CompanyStore.originKey)
        if rememberCertificate { try CompanyGatewayTrust(preferences: defaults).remember(MenuHelper.probe) }
        vault.saved = CompanyCredentials(origin: MenuHelper.probe.origin, domain: "local", username: "fixture", password: "fixture-only")
    }
    func finishLogin() async {
        helper.emit("probe", probe: MenuHelper.probe)
        await menuWait { self.helper.commands.contains { $0["type"] as? String == "login" } }
        helper.emit("login_success")
        helper.emit("resources", resources: MenuHelper.resources)
        await menuWait { self.helper.commands.contains { $0["type"] as? String == "connect" } }
        helper.emit("tunnel_ready", tunnel: MenuHelper.tunnel)
        await menuWait { self.company.connectionReady && !self.company.working }
    }
}

@MainActor
final class MenuCoreModel {
    var channels: [String] = []
    var events: [String] = []
    var running = false
    var tun = true
    var mode = "vpn"
    var unknownTraffic = "direct"
    var legacy = false
    var owns = true
    var stateError: String?
    var processStartedAt: String?
    var networkHistory: [JSONValue] = []
    var networkState: String?
    var networkError: String?
    var selectedNode = "fixture-node"
    var companyActive = false
    var failure: (String, Error)?
    var intercept: ((String, [String: Any]) async throws -> JSONValue?)?
    var state: JSONValue {
        .object(["state": .string(stateError == nil ? (running ? "running" : "stopped") : "error"),
                 "mode": .string(mode), "pid": running ? .number(1234) : .null,
                 "startedAt": processStartedAt.map(JSONValue.string) ?? .null,
                 "lastError": stateError.map(JSONValue.string) ?? .null,
                 "networkRecovery": networkState.map { .object([
                    "state": .string($0), "history": .array(networkHistory), "error": networkError.map(JSONValue.string) ?? .null,
                    "helperUpdateRequired": .bool($0 == "helper-update-required")
                 ]) } ?? .null])
    }
    var routing: JSONValue {
        .object(["active": .bool(companyActive), "verified": .bool(false), "recovering": .bool(false),
                 "recoveryCount": .number(0), "ruleCount": .number(companyActive ? 1 : 0), "routes": .array([])])
    }
    func call(_ channel: String, _ payload: [String: Any]) async throws -> JSONValue {
        channels.append(channel); events.append(channel)
        if let value = try await intercept?(channel, payload) { return value }
        if let (failed, error) = failure, failed == channel { throw error }
        switch channel {
        case "native:bootstrap": return try bootstrap()
        case "native:startup-connect": return .object(["startupOutcome": .string("already-running"), "mihomo": state])
        case "vpn:start", "vpn:stop": running = channel == "vpn:start"; networkState = nil; networkError = nil; return state
        case "native:upgrade-helper": running = true; networkState = "ready"; networkError = nil; return .object(["mihomo": state])
        case "native:company-context": return .object(["interfaceName": .string("fixture-interface")])
        case "native:company-apply", "native:company-remove": companyActive = channel == "native:company-apply"; return routing
        case "traffic:get-monitor": return .object(["rates": .object(["upload": .number(0), "download": .number(0)]), "samples": .array([]), "running": .bool(running)])
        default: throw CoreService.CoreError.message("Unexpected test channel: \(channel)")
        }
    }
    func bootstrap() throws -> JSONValue {
        let data: [String: Any] = ["status": ["appStartedAt": "fixture", "mihomo": try JSONSerialization.jsonObject(with: state.encoded),
            "subscription": ["nodeCount": 1, "status": "ready", "entries": []],
            "settings": ["launchAtLogin": false, "unknownTraffic": unknownTraffic, "tun": tun, "ipv6": false, "lanDirect": true, "tailscaleDirect": true,
                "specialCompatibilityRules": ["mailMasterProxy8081": false, "wechatImageSendFallback": false],
                "selectedProxy": selectedNode, "vpnDomainRules": [], "favoriteNodeNames": [], "nodeGroups": []]],
            "nodes": [["name": "fixture-node", "type": "ss", "selected": true, "identityKey": "fixture-id"]],
            "groups": [], "risks": [], "traffic": ["rates": ["upload": 0, "download": 0], "samples": [], "running": running],
            "legacyOwnerRunning": legacy, "previewOnly": false, "ownsRuntime": owns,
            "companyRouting": try JSONSerialization.jsonObject(with: routing.encoded), "dataDir": "/fixture"]
        return try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: data))
    }
}

final class MenuHelper: CompanyHelper {
    static let probe = ProbeInfo(origin: "https://gateway.example.test", fingerprint: String(repeating: "AB", count: 32), subject: "fixture",
        validTo: "2099-01-01T00:00:00Z", nameMatches: true, selfSigned: true,
        methods: [AuthMethod(loginDomain: "local", authType: "auth/psw", authName: "接入账号")])
    static let resources = ResourceResult(rows: [ResourceRow(id: "fixture", appID: "fixture", name: "fixture", address: "10.0.0.8", ports: "443", network: "tcp", accessModel: "vpn")], appCount: 1, dns: [], gateways: [], fetchedAt: "fixture")
    static let tunnel = TunnelProof(port: 10000, target: "", httpStatus: 0, elapsedMs: 0, sent: 0, received: 0, verifiedAt: "", transport: "atrust-tcp")
    var processID: Int32?
    var commands: [[String: Any]] = []
    var callbacks: [(HelperEvent) -> Void] = []
    var onExit: ((Int32) -> Void)?
    var record: ((String) -> Void)?
    var waitForConfirmation = false
    var stopError: Error?
    var pendingStop: CheckedContinuation<Void, Error>?
    func start(command: [String: Any], onEvent: @escaping (HelperEvent) -> Void, onExit: @escaping (Int32) -> Void) throws {
        processID = 10000; commands.append(command); callbacks.append(onEvent); self.onExit = onExit
    }
    func send(_ command: [String: Any]) throws { commands.append(command) }
    func stop() { processID = nil }
    func stopAndWait(timeout: TimeInterval) async throws {
        record?("helper:stop")
        if let stopError { throw stopError }
        if waitForConfirmation { try await withCheckedThrowingContinuation { pendingStop = $0 } }
        processID = nil; record?("helper:confirmed")
    }
    func emit(_ type: String, probe: ProbeInfo? = nil, resources: ResourceResult? = nil, tunnel: TunnelProof? = nil, challenge: AuthChallenge? = nil) {
        callbacks.last?(HelperEvent(type: type, stage: nil, message: nil, username: "fixture", probe: probe, resources: resources, tunnel: tunnel, challenge: challenge))
    }
}

@MainActor
final class MenuVault: CompanyCredentialVault {
    var saved: CompanyCredentials?
    var loads = 0
    var saves = 0
    var loadGate: CheckedContinuation<Void, Never>?
    var delayLoad = false
    func load(origin: String) async throws -> CompanyCredentials? {
        loads += 1
        if delayLoad { await withCheckedContinuation { loadGate = $0 } }
        return saved
    }
    func save(_ credentials: CompanyCredentials) async throws { saves += 1 }
    func remove(origin: String) async throws { saved = nil }
}
@MainActor
final class MenuWindows: AppWindowRouting {
    var mainCalls = 0
    var settingsCalls = 0
    var pages: [VPNPage?] = []
    func openMain(page: VPNPage?) { mainCalls += 1; pages.append(page) }
    func openSettings() { settingsCalls += 1 }
}
@MainActor
final class MenuLoginItems: LoginItemService {
    func state() -> LoginItemState { .disabled }
    func setEnabled(_ enabled: Bool) throws -> LoginItemState { enabled ? .enabled : .disabled }
    func openSystemSettings() {}
}
@MainActor
func menuWait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    let end = Date().addingTimeInterval(2)
    while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(2)) }
    XCTAssertTrue(condition(), "未达到预期的假服务状态", file: file, line: line)
}
