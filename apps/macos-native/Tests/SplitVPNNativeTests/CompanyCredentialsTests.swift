import XCTest
@testable import SplitVPNNative

final class CompanyCredentialsTests: XCTestCase {
    let entered = CompanyCredentials(origin: "https://gateway.invalid:443/", domain: "local", username: "fixture", password: "fixture-only")
    func testGatewayIdentitySurvivesTrailingPathAndDefaultPortButNotAnotherGateway() throws {
        XCTAssertEqual(try CompanyCredentials.gatewayKey(entered.origin), try CompanyCredentials.gatewayKey("https://GATEWAY.invalid"))
        XCTAssertNotEqual(try CompanyCredentials.gatewayKey(entered.origin), try CompanyCredentials.gatewayKey("https://another.invalid"))
        XCTAssertThrowsError(try CompanyCredentials.gatewayKey("http://gateway.invalid"))
        XCTAssertThrowsError(try CompanyCredentials.gatewayKey("https://user:secret@gateway.invalid"))
    }
    func testPasswordIsReleasedForSavingOnlyOnceAfterSuccessfulAuthentication() {
        var draft = CompanyCredentialDraft()
        draft.prepare(entered, remember: true)
        XCTAssertEqual(draft.authenticated(remember: true), entered)
        XCTAssertNil(draft.authenticated(remember: true))
    }
    func testCancelledOrUnrememberedAuthenticationCannotSaveCredentials() {
        var draft = CompanyCredentialDraft()
        draft.prepare(entered, remember: true); draft.cancel()
        XCTAssertNil(draft.authenticated(remember: true))
        draft.prepare(entered, remember: false)
        XCTAssertNil(draft.authenticated(remember: true))
        draft.prepare(entered, remember: true)
        XCTAssertNil(draft.authenticated(remember: false))
    }
    @MainActor func testTakeoverPreferenceIsIndependentOfConnectionAndSurvivesRecreation() async throws {
        let suite = "splitvpn-credential-fixture-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = FixtureVault()
        let store = CompanyStore(credentialVault: vault, preferences: defaults)
        XCTAssertTrue(store.takeoverEnabled)
        store.setTakeover(false)
        XCTAssertFalse(store.takeoverEnabled)
        XCTAssertFalse(store.hasSession)
        let reopened = CompanyStore(credentialVault: vault, preferences: defaults)
        XCTAssertFalse(reopened.takeoverEnabled)
        XCTAssertTrue(reopened.rememberCredentials)
        let count = await vault.calls()
        XCTAssertEqual(count, 0)
    }
    @MainActor func testTurningOffTakeoverRemovesOnlyRoutingAndKeepsAuthenticatedTunnel() async throws {
        let suite = "splitvpn-takeover-fixture-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = ProbeInfo(origin: "https://gateway.invalid", fingerprint: "fixture", subject: "fixture", validTo: "fixture", nameMatches: true, selfSigned: false, methods: [])
        let resources = ResourceResult(rows: [], appCount: 1, dns: [], gateways: [], fetchedAt: "fixture")
        let proof = TunnelProof(port: 10000, target: "192.0.2.55", httpStatus: 200, elapsedMs: 1, sent: 1, received: 1, verifiedAt: "fixture", transport: "atrust-tcp")
        let active = CompanyRoutingState(active: true, verified: false, recovering: false, recoveryCount: 0, proxyName: "fixture", ruleCount: 1, routes: [], lastError: nil, proof: nil, internet: nil)
        let store = CompanyStore(credentialVault: FixtureVault(), preferences: defaults, preview: CompanyPreview(probe: probe, resources: resources, tunnel: proof, routing: active))
        var channels: [String] = []
        let core = CoreService { channel, _ in
            channels.append(channel)
            return try JSONDecoder().decode(JSONValue.self, from: Data("{\"active\":false,\"verified\":false,\"recovering\":false,\"recoveryCount\":0,\"ruleCount\":0,\"routes\":[]}".utf8))
        }
        store.configure(core: core); store.setTakeover(false)
        for _ in 0..<20 where store.working { await Task.yield() }
        XCTAssertEqual(channels, ["native:company-remove"])
        XCTAssertFalse(store.working); XCTAssertFalse(store.takeoverEnabled)
        XCTAssertTrue(store.hasSession); XCTAssertNotNil(store.tunnelProof)
        XCTAssertNotNil(store.resources); XCTAssertFalse(store.businessVerified)
        XCTAssertEqual(store.statusText, "私有网络隧道已连接 · 未接管")
    }
}
actor FixtureVault: CompanyCredentialVault {
    private var count = 0
    func load(origin: String) -> CompanyCredentials? { count += 1; return nil }
    func save(_ credentials: CompanyCredentials) { count += 1 }
    func remove(origin: String) { count += 1 }
    func calls() -> Int { count }
}
