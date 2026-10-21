import XCTest
@testable import SplitVPNNative

final class CompanyConnectionTests: XCTestCase {
    private let ready = TunnelProof(port: 10000, target: "", httpStatus: 0, elapsedMs: 0, sent: 0, received: 0, verifiedAt: "", transport: "atrust-tcp")
    private let active = "{\"active\":true,\"verified\":false,\"recovering\":false,\"recoveryCount\":0,\"ruleCount\":1,\"routes\":[\"192.0.2.0/24\"]}"
    private let inactive = "{\"active\":false,\"verified\":false,\"recovering\":false,\"recoveryCount\":0,\"ruleCount\":0,\"routes\":[]}"
    private let verified = "{\"active\":true,\"verified\":true,\"recovering\":false,\"recoveryCount\":0,\"ruleCount\":1,\"routes\":[\"192.0.2.0/24\"],\"proof\":{\"target\":\"http://192.0.2.55/\",\"httpStatus\":200,\"elapsedMs\":5,\"interfaceName\":\"utun-fixture\",\"sourcePort\":10001,\"chains\":[\"fixture\"],\"corePid\":0,\"verifiedAt\":\"fixture\"}}"

    @MainActor private func fixture(_ defaults: UserDefaults, helper: FixtureCompanyHelper, tunnel: TunnelProof? = nil) -> CompanyStore {
        let probe = ProbeInfo(origin: "https://gateway.invalid", fingerprint: "fixture", subject: "fixture", validTo: "fixture", nameMatches: true, selfSigned: false, methods: [])
        let resources = ResourceResult(rows: [ResourceRow(id: "fixture", appID: "fixture", name: "fixture", address: "192.0.2.0/24", ports: "80", network: "tcp", accessModel: "vpn")], appCount: 1, dns: [], gateways: [], fetchedAt: "fixture")
        return CompanyStore(credentialVault: FixtureVault(), preferences: defaults, helper: helper, preview: CompanyPreview(probe: probe, resources: resources, tunnel: tunnel))
    }
    private func value(_ json: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) }
    private func event(_ type: String, tunnel: TunnelProof? = nil) -> HelperEvent {
        HelperEvent(type: type, stage: nil, message: nil, username: nil, probe: nil, resources: nil, tunnel: tunnel, challenge: nil)
    }
    @MainActor private func settle(_ store: CompanyStore) async {
        for _ in 0..<50 where store.working { await Task.yield() }
        XCTAssertFalse(store.working)
    }

    @MainActor func testConnectingAndDisconnectingIgnoreTheBusinessAddressAndNeverVerifyIt() async throws {
        let suite = "splitvpn-connect-fixture-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let helper = FixtureCompanyHelper(), store = fixture(defaults, helper: helper)
        var calls: [(String, [String: Any])] = []
        store.configure(core: CoreService { channel, payload in
            calls.append((channel, payload))
            return try self.value(channel == "native:company-remove" ? self.inactive : self.active)
        })
        store.target = "file:///invalid-verification-target"
        store.connectTunnel()
        XCTAssertEqual(helper.commands.count, 1)
        XCTAssertEqual(helper.commands[0]["type"] as? String, "connect")
        XCTAssertNil(helper.commands[0]["target"])
        store.receive(event("tunnel_ready", tunnel: ready))
        await settle(store)
        XCTAssertEqual(calls.map(\.0), ["native:company-apply"])
        XCTAssertNil(calls[0].1["target"])
        XCTAssertTrue(store.connectionEnabled); XCTAssertTrue(store.connectionReady)
        XCTAssertEqual(store.statusText, "私有网络已连接")
        XCTAssertFalse(store.businessVerified)

        store.target = ""
        store.disconnectTunnel()
        for _ in 0..<50 where helper.commands.count < 2 { await Task.yield() }
        XCTAssertEqual(calls.map(\.0), ["native:company-apply", "native:company-remove"])
        XCTAssertEqual(helper.commands.last?["type"] as? String, "disconnect")
        XCTAssertNil(helper.commands.last?["target"])
        store.receive(event("tunnel_closed"))
        XCTAssertFalse(store.connectionEnabled); XCTAssertFalse(store.connectionReady)
        XCTAssertEqual(store.statusText, "已登录 · 未连接")
        XCTAssertTrue(store.hasSession)
    }

    @MainActor func testEnablingTakeoverAppliesRoutingWithoutRunningBusinessVerification() async throws {
        let suite = "splitvpn-resume-fixture-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "companyTakeoverEnabled")
        let helper = FixtureCompanyHelper(), store = fixture(defaults, helper: helper, tunnel: ready)
        var calls: [(String, [String: Any])] = []
        store.configure(core: CoreService { channel, payload in calls.append((channel, payload)); return try self.value(self.active) })
        store.target = ""
        store.setTakeover(true)
        await settle(store)
        XCTAssertEqual(calls.map(\.0), ["native:company-apply"])
        XCTAssertNil(calls.first?.1["target"])
        XCTAssertTrue(helper.commands.isEmpty)
        XCTAssertTrue(store.connectionReady); XCTAssertFalse(store.businessVerified)
        XCTAssertEqual(store.statusText, "私有网络已连接")
    }

    @MainActor func testOnlyExplicitVerificationRequestsTheTargetOnTheExistingConnection() async throws {
        let suite = "splitvpn-verify-fixture-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let helper = FixtureCompanyHelper(), store = fixture(defaults, helper: helper, tunnel: ready)
        store.updateRouting(try JSONDecoder().decode(CompanyRoutingState.self, from: Data(active.utf8)))
        var calls: [(String, [String: Any])] = []
        store.configure(core: CoreService { channel, payload in calls.append((channel, payload)); return try self.value(self.verified) })
        XCTAssertTrue(calls.isEmpty)
        store.target = "192.0.2.55"
        store.verifyBusiness()
        await settle(store)
        XCTAssertEqual(calls.map(\.0), ["native:company-verify"])
        XCTAssertEqual(calls.first?.1["target"] as? String, "192.0.2.55")
        XCTAssertTrue(helper.commands.isEmpty)
        XCTAssertTrue(store.businessVerified); XCTAssertTrue(store.connectionReady)
        XCTAssertEqual(store.tunnelProof?.port, ready.port)
    }

    @MainActor func testVerificationFailureKeepsTheConnectionAndDisconnectedVerificationCannotConnect() async throws {
        let suite = "splitvpn-failed-verify-fixture-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let helper = FixtureCompanyHelper(), store = fixture(defaults, helper: helper)
        // The app ships without a default business address.
        XCTAssertEqual(store.target, "")
        store.target = "10.0.0.8"
        var calls: [String] = []
        store.configure(core: CoreService { channel, _ in calls.append(channel); throw CoreService.CoreError.message("fixture failure") })
        store.verifyBusiness()
        XCTAssertTrue(calls.isEmpty); XCTAssertTrue(helper.commands.isEmpty)
        store.receive(event("tunnel_ready", tunnel: ready))
        await settle(store)
        store.updateRouting(try JSONDecoder().decode(CompanyRoutingState.self, from: Data(active.utf8)))
        calls.removeAll()
        store.verifyBusiness()
        await settle(store)
        XCTAssertEqual(calls, ["native:company-verify"])
        XCTAssertEqual(defaults.string(forKey: CompanyStore.targetKey), "10.0.0.8")
        XCTAssertTrue(store.connectionEnabled); XCTAssertTrue(store.connectionReady)
        XCTAssertEqual(store.statusText, "私有网络已连接")
        XCTAssertNotNil(store.tunnelProof); XCTAssertFalse(store.businessVerified)
        XCTAssertTrue(helper.commands.isEmpty)
    }

    @MainActor func testDisconnectCanClearRemainingRoutingAfterTheLoginServiceHasEnded() async throws {
        let suite = "splitvpn-ended-disconnect-fixture-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let helper = FixtureCompanyHelper()
        helper.processID = nil
        let store = CompanyStore(credentialVault: FixtureVault(), preferences: defaults, helper: helper)
        store.updateRouting(try JSONDecoder().decode(CompanyRoutingState.self, from: Data(active.utf8)))
        var calls: [String] = []
        store.configure(core: CoreService { channel, _ in calls.append(channel); return try self.value(self.inactive) })
        store.target = ""
        XCTAssertFalse(store.hasSession); XCTAssertTrue(store.connectionEnabled)
        store.disconnectTunnel()
        await settle(store)
        XCTAssertEqual(calls, ["native:company-remove"])
        XCTAssertFalse(store.connectionEnabled); XCTAssertNil(store.errorMessage)
        XCTAssertTrue(helper.commands.isEmpty)
    }
}

final class FixtureCompanyHelper: CompanyHelper {
    var processID: Int32? = 10000
    var commands: [[String: Any]] = []
    func start(command: [String: Any], onEvent: @escaping (HelperEvent) -> Void, onExit: @escaping (Int32) -> Void) throws { commands.append(command) }
    func send(_ command: [String: Any]) throws { commands.append(command) }
    func stop() {}
}
