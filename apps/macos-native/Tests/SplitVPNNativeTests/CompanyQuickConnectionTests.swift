import XCTest
@testable import SplitVPNNative

final class CompanyQuickConnectionTests: XCTestCase {
    @MainActor func testSavedAccountPreparesLogsInAndConnectsWithoutBusinessVerification() async throws {
        let f = try MenuBarFixture(); defer { f.close() }; try f.prepareAccount()
        f.runtime.toggleCompany(); f.runtime.toggleCompany()
        XCTAssertTrue(f.company.quickPreparing)
        await menuWait { f.helper.commands.count == 1 }
        let intent = try XCTUnwrap(f.company.quickConnectionID)
        await f.finishLogin()
        XCTAssertNil(f.company.quickConnectionID)
        XCTAssertTrue(f.company.connectionReady); XCTAssertFalse(f.company.businessVerified)
        XCTAssertEqual(f.helper.commands.compactMap { $0["type"] as? String }, ["probe", "login", "connect"])
        XCTAssertFalse(f.coreModel.channels.contains("native:company-verify"))
        XCTAssertFalse(f.helper.commands.contains { $0["type"] as? String == "verify" })
        XCTAssertEqual(f.windows.mainCalls, 0)
        XCTAssertNotNil(intent)
    }
    @MainActor func testCertificateConfirmationResumesTheOriginalIntent() async throws {
        let f = try MenuBarFixture(); defer { f.close() }; try f.prepareAccount(rememberCertificate: false)
        f.runtime.toggleCompany()
        await menuWait { f.helper.commands.count == 1 }
        let intent = f.company.quickConnectionID
        f.helper.emit("probe", probe: MenuHelper.probe)
        await menuWait { f.company.requestedInteraction == .certificate }
        XCTAssertEqual(f.windows.pages.last ?? nil, .company)
        XCTAssertEqual(f.helper.commands.count, 1)
        f.company.confirmGatewayCertificate()
        await menuWait { f.helper.commands.count == 2 }
        XCTAssertEqual(f.company.quickConnectionID, intent)
        f.helper.emit("login_success"); f.helper.emit("resources", resources: MenuHelper.resources)
        f.helper.emit("tunnel_ready", tunnel: MenuHelper.tunnel)
        await menuWait { f.company.connectionReady }
        XCTAssertNil(f.company.quickConnectionID)
    }
    @MainActor func testChallengeOpensCompanyPageAndContinuesAfterAnswer() async throws {
        let f = try MenuBarFixture(); defer { f.close() }; try f.prepareAccount()
        f.runtime.toggleCompany(); await menuWait { f.helper.commands.count == 1 }
        f.helper.emit("probe", probe: MenuHelper.probe)
        await menuWait { f.helper.commands.count == 2 }
        let intent = f.company.quickConnectionID
        let challenge = AuthChallenge(id: "fixture-otp", kind: "sms", title: "验证码", message: "fixture", imageBase64: nil, url: nil)
        f.helper.emit("challenge", challenge: challenge)
        XCTAssertEqual(f.company.challenge?.id, "fixture-otp")
        XCTAssertEqual(f.company.requestedInteraction, .challenge)
        XCTAssertEqual(f.windows.pages.last ?? nil, .company)
        f.company.answerChallenge(["code": "123456"])
        XCTAssertEqual(f.helper.commands.last?["id"] as? String, "fixture-otp")
        XCTAssertEqual(f.company.quickConnectionID, intent)
        f.helper.emit("login_success"); f.helper.emit("resources", resources: MenuHelper.resources)
        f.helper.emit("tunnel_ready", tunnel: MenuHelper.tunnel)
        await menuWait { f.company.connectionReady }
        XCTAssertNil(f.company.challenge); XCTAssertNil(f.company.quickConnectionID)
    }
    @MainActor func testMissingGatewayOrAccountRequestsInputWithoutAutomaticLogin() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        f.runtime.toggleCompany()
        await menuWait { f.company.requestedInteraction == .account }
        XCTAssertEqual(f.helper.commands.count, 0); XCTAssertEqual(f.windows.pages.last ?? nil, .company)
        f.company.endTest()
        f.defaults.set(MenuHelper.probe.origin, forKey: CompanyStore.originKey)
        f.company.origin = MenuHelper.probe.origin
        try CompanyGatewayTrust(preferences: f.defaults).remember(MenuHelper.probe)
        f.runtime.toggleCompany(); await menuWait { f.helper.commands.count == 1 }
        f.helper.emit("probe", probe: MenuHelper.probe)
        await menuWait { f.company.requestedInteraction == .account }
        XCTAssertEqual(f.helper.commands.count, 1)
    }
    @MainActor func testCancelRetiresLoginCallbackAndCannotSaveOrReconnect() async throws {
        let f = try MenuBarFixture(); defer { f.close() }; try f.prepareAccount()
        f.runtime.toggleCompany(); await menuWait { f.helper.commands.count == 1 }
        f.helper.emit("probe", probe: MenuHelper.probe); await menuWait { f.helper.commands.count == 2 }
        let old = try XCTUnwrap(f.helper.callbacks.last)
        f.company.endTest()
        old(HelperEvent(type: "login_success", stage: nil, message: nil, username: "fixture", probe: nil, resources: nil, tunnel: nil, challenge: nil))
        old(HelperEvent(type: "resources", stage: nil, message: nil, username: nil, probe: nil, resources: MenuHelper.resources, tunnel: nil, challenge: nil))
        await Task.yield()
        XCTAssertNil(f.company.quickConnectionID); XCTAssertFalse(f.company.hasSession)
        XCTAssertEqual(f.vault.saves, 0)
        XCTAssertFalse(f.helper.commands.contains { $0["type"] as? String == "connect" })
    }
    @MainActor func testGatewayChangeRetiresProbeAndPendingCredentialLoad() async throws {
        let f = try MenuBarFixture(); defer { f.close() }; try f.prepareAccount()
        f.vault.delayLoad = true
        f.runtime.toggleCompany(); await menuWait { f.vault.loadGate != nil }
        f.company.origin = "https://another.example.test"
        f.vault.loadGate?.resume()
        await Task.yield(); await Task.yield()
        XCTAssertNil(f.company.quickConnectionID); XCTAssertTrue(f.company.username.isEmpty)
        XCTAssertTrue(f.company.password.isEmpty); XCTAssertTrue(f.helper.commands.isEmpty)
        f.vault.delayLoad = false
        f.runtime.toggleCompany(); await menuWait { f.helper.commands.count == 1 }
        let old = try XCTUnwrap(f.helper.callbacks.last)
        f.company.origin = "https://third.example.test"
        old(HelperEvent(type: "probe", stage: nil, message: nil, username: nil, probe: MenuHelper.probe, resources: nil, tunnel: nil, challenge: nil))
        XCTAssertNil(f.company.probe); XCTAssertNil(f.company.quickConnectionID)
        XCTAssertEqual(f.helper.commands.count, 1)
    }
    @MainActor func testFailedAttemptIgnoresLateTunnelAndDoesNotResumeIntent() async throws {
        let f = try MenuBarFixture(); defer { f.close() }; try f.prepareAccount()
        f.runtime.toggleCompany(); await menuWait { f.helper.commands.count == 1 }
        f.helper.emit("probe", probe: MenuHelper.probe); await menuWait { f.helper.commands.count == 2 }
        f.helper.emit("login_success"); f.helper.emit("resources", resources: MenuHelper.resources)
        let old = try XCTUnwrap(f.helper.callbacks.last)
        old(HelperEvent(type: "error", stage: "tunnel", message: "fixture failure", username: nil, probe: nil, resources: nil, tunnel: nil, challenge: nil))
        old(HelperEvent(type: "tunnel_ready", stage: nil, message: nil, username: nil, probe: nil, resources: nil, tunnel: MenuHelper.tunnel, challenge: nil))
        await Task.yield()
        XCTAssertNil(f.company.quickConnectionID); XCTAssertFalse(f.company.connectionEnabled)
        XCTAssertEqual(f.company.errorMessage, "fixture failure")
        XCTAssertFalse(f.coreModel.channels.contains("native:company-apply"))
    }
    @MainActor func testLoggingOutRetiresSuccessfulSessionAndLateEvents() async throws {
        let f = try MenuBarFixture(); defer { f.close() }; try f.prepareAccount()
        f.runtime.toggleCompany(); await menuWait { f.helper.commands.count == 1 }; await f.finishLogin()
        let old = try XCTUnwrap(f.helper.callbacks.last)
        f.company.endTest(); await menuWait { !f.company.hasSession && !f.company.working }
        old(HelperEvent(type: "tunnel_ready", stage: nil, message: nil, username: nil, probe: nil, resources: nil, tunnel: MenuHelper.tunnel, challenge: nil))
        XCTAssertNil(f.company.quickConnectionID); XCTAssertFalse(f.company.connectionEnabled)
        XCTAssertEqual(f.coreModel.channels.filter { $0 == "native:company-apply" }.count, 1)
    }
}
