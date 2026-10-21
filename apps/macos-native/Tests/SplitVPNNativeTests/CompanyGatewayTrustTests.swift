import XCTest
@testable import SplitVPNNative

final class CompanyGatewayTrustTests: XCTestCase {
    private func fixture(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "splitvpn-gateway-trust-fixture-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
    private func probe(origin: String = "https://gateway.invalid", fingerprint: String = String(repeating: "AB", count: 32),
                       systemTrusted: Bool? = false, nameMatches: Bool = true,
                       validFrom: Date = Date().addingTimeInterval(-3600), validTo: Date = Date().addingTimeInterval(86400)) -> ProbeInfo {
        let formatter = ISO8601DateFormatter()
        return ProbeInfo(origin: origin, fingerprint: fingerprint, subject: "fixture", validTo: formatter.string(from: validTo),
                         nameMatches: nameMatches, selfSigned: systemTrusted != true,
                         methods: [AuthMethod(loginDomain: "local", authType: "auth/psw", authName: "接入账号")],
                         systemTrusted: systemTrusted, validFrom: formatter.string(from: validFrom))
    }
    func testSystemTrustNeedsValidHostAndCertificateRatherThanJustPublicProbeSuccess() throws {
        try fixture { defaults in
            let trust = CompanyGatewayTrust(preferences: defaults)
            XCTAssertEqual(trust.evaluate(probe(systemTrusted: true)), .systemTrusted)
            XCTAssertEqual(trust.evaluate(probe(systemTrusted: nil)), .requiresConfirmation)
            XCTAssertEqual(trust.evaluate(probe()), .requiresConfirmation)
            XCTAssertEqual(trust.evaluate(probe(systemTrusted: true, nameMatches: false)), .requiresConfirmation)
            XCTAssertNil(trust.rememberedFingerprint(origin: "https://gateway.invalid"))
        }
    }
    func testExplicitConfirmationIsRememberedAcrossRecreationAndFingerprintFormatting() throws {
        try fixture { defaults in
            let trust = CompanyGatewayTrust(preferences: defaults)
            try trust.remember(probe(origin: "https://GATEWAY.invalid:443/", fingerprint: String(repeating: "ab:", count: 31) + "ab"))
            let reopened = CompanyGatewayTrust(preferences: defaults)
            XCTAssertEqual(reopened.evaluate(probe()), .remembered)
            XCTAssertEqual(reopened.rememberedFingerprint(origin: "https://gateway.invalid"), String(repeating: "AB", count: 32))
        }
    }
    func testConfirmationNeverCrossesAnotherHostOrPortAndChangedCertificateRequiresConfirmation() throws {
        try fixture { defaults in
            let trust = CompanyGatewayTrust(preferences: defaults)
            try trust.remember(probe())
            XCTAssertEqual(trust.evaluate(probe(origin: "https://another.invalid")), .requiresConfirmation)
            XCTAssertEqual(trust.evaluate(probe(origin: "https://gateway.invalid:8443")), .requiresConfirmation)
            XCTAssertEqual(trust.evaluate(probe(fingerprint: String(repeating: "CD", count: 32), systemTrusted: true)), .changed)
            XCTAssertEqual(trust.rememberedFingerprint(origin: "https://gateway.invalid"), String(repeating: "AB", count: 32))
        }
    }
    func testNeitherSavedPinNorSystemTrustOverridesExpiryOrInvalidCertificateData() throws {
        try fixture { defaults in
            let trust = CompanyGatewayTrust(preferences: defaults)
            try trust.remember(probe())
            for invalid in [probe(systemTrusted: true, validTo: Date().addingTimeInterval(-60)),
                            probe(validFrom: Date().addingTimeInterval(3600)),
                            probe(fingerprint: "not-a-sha256"), probe(origin: "http://gateway.invalid")] {
                XCTAssertEqual(trust.evaluate(invalid), .invalid)
                XCTAssertThrowsError(try trust.remember(invalid))
            }
            XCTAssertEqual(trust.evaluate(probe()), .remembered)
        }
    }
    func testOlderHelperWithoutSystemTrustFieldCannotSilentlyApproveUnknownCertificate() throws {
        let json = "{\"origin\":\"https://gateway.invalid\",\"fingerprint\":\"\(String(repeating: "AB", count: 32))\",\"subject\":\"fixture\",\"validTo\":\"2099-01-01T00:00:00Z\",\"nameMatches\":true,\"selfSigned\":false,\"methods\":[]}"
        let decoded = try JSONDecoder().decode(ProbeInfo.self, from: Data(json.utf8))
        XCTAssertNil(decoded.systemTrusted); XCTAssertNil(decoded.validFrom)
        try fixture { defaults in
            XCTAssertEqual(CompanyGatewayTrust(preferences: defaults).evaluate(decoded), .requiresConfirmation)
        }
    }
    @MainActor func testSystemTrustedGatewayAutomaticallyEnablesLoginAndRemembersOnlyPublicPin() throws {
        try fixture { defaults in
            let store = CompanyStore(credentialVault: FixtureVault(), preferences: defaults)
            store.origin = "https://gateway.invalid"; store.username = "fixture-user"; store.password = "fixture-password"
            store.acceptProbe(probe(systemTrusted: true))
            XCTAssertEqual(store.certificateState, .systemTrusted)
            XCTAssertTrue(store.canLogin)
            let remembered = try XCTUnwrap(defaults.dictionary(forKey: "companyConfirmedGatewayCertificates") as? [String: String])
            XCTAssertEqual(remembered, ["https://gateway.invalid": String(repeating: "AB", count: 32)])
        }
    }
    @MainActor func testFirstSelfSignedGatewayIsConfirmedOnceThenAutomaticallyVerifiedOnNextDetection() throws {
        try fixture { defaults in
            let store = CompanyStore(credentialVault: FixtureVault(), preferences: defaults)
            store.origin = "https://gateway.invalid"; store.username = "fixture"; store.password = "fixture-only"
            store.acceptProbe(probe(nameMatches: false))
            XCTAssertEqual(store.certificateState, .requiresConfirmation); XCTAssertFalse(store.canLogin)
            store.confirmGatewayCertificate()
            XCTAssertTrue(store.canLogin)
            let reopened = CompanyStore(credentialVault: FixtureVault(), preferences: defaults)
            reopened.origin = store.origin; reopened.username = "fixture"; reopened.password = "fixture-only"
            reopened.acceptProbe(probe(nameMatches: false))
            XCTAssertEqual(reopened.certificateState, .remembered); XCTAssertTrue(reopened.canLogin)
            reopened.origin = "https://another.invalid"
            XCTAssertFalse(reopened.confirmedCertificate); XCTAssertNil(reopened.probe)
        }
    }
    @MainActor func testChangedCertificateBlocksLoginUntilExplicitUpdate() async throws {
        let suite = "splitvpn-changed-certificate-fixture-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try CompanyGatewayTrust(preferences: defaults).remember(probe())
        let store = CompanyStore(credentialVault: FixtureVault(), preferences: defaults)
        store.origin = "https://gateway.invalid"; store.username = "fixture"; store.password = "fixture-only"
        store.acceptProbe(probe(fingerprint: String(repeating: "CD", count: 32), systemTrusted: true))
        XCTAssertEqual(store.certificateState, .changed); XCTAssertFalse(store.canLogin)
        var requests = 0
        let core = CoreService { _, _ in requests += 1; throw CredentialError.message("must never reach authentication") }
        store.login(core: core)
        await Task.yield()
        XCTAssertEqual(requests, 0); XCTAssertEqual(store.password, "fixture-only")
        store.confirmGatewayCertificate()
        XCTAssertTrue(store.canLogin)
        XCTAssertEqual(store.previousCertificateFingerprint, String(repeating: "CD", count: 32))
    }
    @MainActor func testExpiredCertificateCannotBeApprovedManuallyAndOriginMismatchIsRejected() throws {
        try fixture { defaults in
            let store = CompanyStore(credentialVault: FixtureVault(), preferences: defaults)
            store.origin = "https://gateway.invalid"; store.username = "fixture"; store.password = "fixture-only"
            store.acceptProbe(probe(validTo: Date().addingTimeInterval(-60)))
            store.confirmGatewayCertificate()
            XCTAssertEqual(store.certificateState, .invalid); XCTAssertFalse(store.canLogin)
            XCTAssertNil(store.previousCertificateFingerprint)
            store.acceptProbe(probe(origin: "https://another.invalid", systemTrusted: true))
            XCTAssertEqual(store.certificateState, .invalid); XCTAssertFalse(store.canLogin)
            XCTAssertNil(CompanyGatewayTrust(preferences: defaults).rememberedFingerprint(origin: "https://another.invalid"))
        }
    }
}
