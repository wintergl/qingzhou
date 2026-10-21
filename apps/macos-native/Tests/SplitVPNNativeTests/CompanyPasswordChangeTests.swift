import XCTest
@testable import SplitVPNNative

final class CompanyPasswordChangeTests: XCTestCase {
    private func nativeChallenge(id: String = "change-1", error: String? = nil) -> AuthChallenge {
        AuthChallenge(id: id, kind: "password_change", title: "修改接入密码", message: "接入密码已到期", imageBase64: nil, url: nil,
                      username: "fixture", rules: ["密码至少 12 位。"], errorMessage: error)
    }
    private func changedEvent(id: String = "change-1") -> HelperEvent {
        HelperEvent(type: "password_changed", stage: "login", message: nil, username: "fixture", probe: nil, resources: nil, tunnel: nil, challenge: nil, id: id)
    }
    private var passwordResponse: [String: Any] { ["oldPassword": "fixture-old-password", "newPassword": " fixture-new-password! "] }

    func testPasswordFormRequiresMatchingNewPasswordAndPreservesSpaces() {
        var input = CompanyPasswordChangeInput(oldPassword: "fixture-old", newPassword: " new-password! ", confirmation: " new-password! ")
        XCTAssertNil(input.validationMessage(requireUsername: false))
        input.confirmation = "new-password!"
        XCTAssertEqual(input.validationMessage(requireUsername: false), "两次输入的新密码不一致。")
        input.newPassword = input.oldPassword; input.confirmation = input.oldPassword
        XCTAssertEqual(input.validationMessage(requireUsername: false), "新密码不能与旧密码相同。")
        input.newPassword = String(repeating: "😀", count: 65); input.confirmation = input.newPassword
        XCTAssertEqual(input.validationMessage(requireUsername: false), "账号名和密码不能超过 128 个字符。")
        input.newPassword = "new-password!"; input.confirmation = input.newPassword
        XCTAssertEqual(input.validationMessage(requireUsername: true), "请填写新账号名。")
        input.newUsername = "fixture-renamed"
        XCTAssertNil(input.validationMessage(requireUsername: true))
    }

    @MainActor func testNativePasswordChangeKeepsQuickConnectIntentUntilFullLogin() async throws {
        let f = try MenuBarFixture(); defer { f.close() }; try f.prepareAccount()
        f.runtime.toggleCompany(); await menuWait { f.helper.commands.count == 1 }
        f.helper.emit("probe", probe: MenuHelper.probe); await menuWait { f.helper.commands.count == 2 }
        let intent = try XCTUnwrap(f.company.quickConnectionID)
        f.helper.emit("challenge", challenge: nativeChallenge())
        XCTAssertEqual(f.company.statusText, "等待修改接入密码")
        XCTAssertEqual(f.company.requestedInteraction, .challenge)
        XCTAssertEqual(f.company.quickConnectionID, intent)
        XCTAssertFalse(f.company.hasSession); XCTAssertEqual(f.vault.saves, 0)
        f.company.answerChallenge(passwordResponse)
        XCTAssertEqual(f.helper.commands.last?["type"] as? String, "challenge_response")
        XCTAssertEqual(f.helper.commands.last?["id"] as? String, "change-1")
        XCTAssertEqual(f.helper.commands.last?["newPassword"] as? String, " fixture-new-password! ")
        XCTAssertEqual(f.vault.saves, 0); XCTAssertNil(f.company.challenge)
        try XCTUnwrap(f.helper.callbacks.last)(changedEvent())
        await menuWait { f.vault.saves == 1 }
        XCTAssertFalse(f.company.hasSession)
        XCTAssertFalse(f.helper.commands.contains { $0["type"] as? String == "connect" })
        f.helper.emit("login_success"); f.helper.emit("resources", resources: MenuHelper.resources)
        await menuWait { f.helper.commands.contains { $0["type"] as? String == "connect" } }
        XCTAssertEqual(f.vault.saves, 1, "完整认证成功时不能再次保存旧密码")
        XCTAssertFalse(f.company.timeline.contains { $0.message.contains("fixture-new-password") || $0.message.contains("fixture-old-password") })
    }

    @MainActor private func nativeSession() async throws -> (CompanyStore, PasswordRecoveryVault, MenuHelper, UserDefaults, String) {
        let suite = "splitvpn-native-password-change-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let old = CompanyCredentials(origin: MenuHelper.probe.origin, domain: "local", username: "fixture", password: "fixture-old-password")
        let vault = PasswordRecoveryVault(stored: old)
        let helper = MenuHelper()
        let store = CompanyStore(credentialVault: vault, preferences: defaults, helper: helper)
        store.origin = old.origin
        try CompanyGatewayTrust(preferences: defaults).remember(MenuHelper.probe)
        store.acceptProbe(MenuHelper.probe)
        await store.loadCredentials()
        let core = CoreService { channel, _ in
            XCTAssertEqual(channel, "native:company-context")
            return .object(["interfaceName": .string("fixture-interface")])
        }
        store.login(core: core); await menuWait { helper.commands.count == 1 }
        helper.emit("challenge", challenge: nativeChallenge())
        return (store, vault, helper, defaults, suite)
    }

    @MainActor func testNativeRetrySavesOnlyConfirmedPasswordEvenIfLaterOTPFails() async throws {
        let (store, vault, helper, defaults, suite) = try await nativeSession()
        defer { store.close(); defaults.removePersistentDomain(forName: suite) }
        let old = vault.stored
        store.answerChallenge(passwordResponse)
        XCTAssertEqual(vault.stored, old); XCTAssertEqual(vault.saves, 0)
        helper.emit("challenge", challenge: nativeChallenge(id: "change-2", error: "密码不能属于弱密码库"))
        XCTAssertEqual(store.challenge?.errorMessage, "密码不能属于弱密码库")
        try XCTUnwrap(helper.callbacks.last)(changedEvent()) // Retired first attempt.
        XCTAssertEqual(vault.saves, 0)
        store.answerChallenge(passwordResponse)
        try XCTUnwrap(helper.callbacks.last)(changedEvent(id: "change-2"))
        await menuWait { vault.saves == 1 }
        XCTAssertEqual(vault.stored?.password, " fixture-new-password! ")
        XCTAssertFalse(store.hasSession)
        helper.emit("challenge", challenge: AuthChallenge(id: "otp", kind: "code", title: "动态口令", message: "输入验证码", imageBase64: nil, url: nil))
        store.answerChallenge(["code": "123456"])
        let failure = try JSONDecoder().decode(HelperEvent.self, from: Data(#"{"type":"error","stage":"login","message":"验证码不正确"}"#.utf8))
        try XCTUnwrap(helper.callbacks.last)(failure)
        XCTAssertEqual(vault.stored?.password, " fixture-new-password! ")
        XCTAssertEqual(vault.saves, 1); XCTAssertFalse(store.hasSession)
        XCTAssertFalse(store.timeline.contains { $0.message.contains("fixture-new-password") || $0.message.contains("fixture-old-password") })
        let reopened = CompanyStore(credentialVault: vault, preferences: defaults, helper: MenuHelper())
        defer { reopened.close() }
        reopened.origin = store.origin
        await reopened.loadCredentials()
        XCTAssertEqual(reopened.password, " fixture-new-password! ", "重启后读取的也应是已确认的新密码")
    }

    @MainActor func testNativePasswordChangeRespectsRememberSettingAtConfirmation() async throws {
        let (store, vault, helper, defaults, suite) = try await nativeSession()
        defer { store.close(); defaults.removePersistentDomain(forName: suite) }
        store.answerChallenge(passwordResponse)
        store.setRememberCredentials(false)
        await menuWait { vault.stored == nil }
        try XCTUnwrap(helper.callbacks.last)(changedEvent())
        helper.emit("login_success")
        await Task.yield()
        XCTAssertEqual(vault.saves, 0); XCTAssertNil(vault.stored)
        XCTAssertTrue(store.password.isEmpty); XCTAssertTrue(store.hasSession)
    }

    @MainActor func testNativePasswordChangeCancellationRejectsLateConfirmation() async throws {
        let (store, vault, helper, defaults, suite) = try await nativeSession()
        defer { store.close(); defaults.removePersistentDomain(forName: suite) }
        let callback = try XCTUnwrap(helper.callbacks.last)
        store.answerChallenge(passwordResponse)
        let loads = vault.loads
        store.endTest()
        callback(changedEvent()); helper.emit("login_success")
        await Task.yield()
        await store.loadCredentials()
        XCTAssertEqual(vault.saves, 0); XCTAssertEqual(vault.loads, loads)
        XCTAssertEqual(vault.stored?.password, "fixture-old-password")
        XCTAssertTrue(store.password.isEmpty); XCTAssertFalse(store.hasSession)
    }

    @MainActor func testUnknownPasswordChangeDoesNotReuseSavedOldPassword() async throws {
        let (store, vault, helper, defaults, suite) = try await nativeSession()
        defer { store.close(); defaults.removePersistentDomain(forName: suite) }
        let callback = try XCTUnwrap(helper.callbacks.last)
        store.answerChallenge(passwordResponse)
        callback(try JSONDecoder().decode(HelperEvent.self, from: Data(#"{"type":"error","stage":"login","code":"password_change_uncertain","message":"未能确认改密结果，请先尝试新密码。"}"#.utf8)))
        callback(changedEvent()); helper.emit("login_success")
        let loads = vault.loads
        await store.loadCredentials()
        XCTAssertEqual(vault.loads, loads); XCTAssertEqual(vault.saves, 0)
        XCTAssertTrue(store.password.isEmpty); XCTAssertFalse(store.hasSession)
        XCTAssertEqual(store.phases["login"], .failed)
        XCTAssertTrue(store.credentialMessage?.contains("旧密码") == true)
        let reopened = CompanyStore(credentialVault: vault, preferences: defaults, helper: MenuHelper())
        defer { reopened.close() }
        reopened.origin = store.origin
        await reopened.loadCredentials()
        XCTAssertEqual(vault.loads, loads); XCTAssertTrue(reopened.password.isEmpty, "重启后仍不能自动重用状态不确定的旧密码")
        reopened.origin = "https://other.example.test"
        await reopened.loadCredentials()
        XCTAssertEqual(vault.loads, loads + 1, "其他网关不应被暂停读取凭据")
    }

    @MainActor func testFailedKeychainUpdateDoesNotRestoreOldPasswordAfterLogin() async throws {
        let (store, vault, helper, defaults, suite) = try await nativeSession()
        defer { store.close(); defaults.removePersistentDomain(forName: suite) }
        vault.saveFailure = CredentialError.message("fixture keychain unavailable")
        store.answerChallenge(passwordResponse)
        try XCTUnwrap(helper.callbacks.last)(changedEvent())
        helper.emit("login_success")
        await menuWait { vault.saves == 1 }
        XCTAssertEqual(vault.stored?.password, "fixture-old-password")
        store.endTest()
        let loads = vault.loads
        await store.loadCredentials()
        XCTAssertEqual(vault.loads, loads); XCTAssertTrue(store.password.isEmpty)
        XCTAssertFalse(store.hasSavedCredentials)
        let reopened = CompanyStore(credentialVault: vault, preferences: defaults, helper: MenuHelper())
        defer { reopened.close() }
        reopened.origin = store.origin
        await reopened.loadCredentials()
        XCTAssertEqual(vault.loads, loads); XCTAssertTrue(reopened.password.isEmpty)
    }
    private func renewalEvent() throws -> HelperEvent {
        try JSONDecoder().decode(HelperEvent.self, from: Data(
            #"{"type":"error","stage":"login","code":"password_change_required","message":"fixture response"}"#.utf8))
    }

    @MainActor func testPasswordRenewalStopsQuickLoginAndRejectsLateSuccess() async throws {
        let f = try MenuBarFixture(); defer { f.close() }; try f.prepareAccount()
        f.runtime.toggleCompany(); await menuWait { f.helper.commands.count == 1 }
        f.helper.emit("probe", probe: MenuHelper.probe)
        await menuWait { f.helper.commands.count == 2 }
        let old = try XCTUnwrap(f.helper.callbacks.last)
        old(try renewalEvent())

        XCTAssertEqual(f.company.loginIssue, .passwordChangeRequired)
        XCTAssertEqual(f.company.errorHeading, "需要修改接入密码")
        XCTAssertEqual(f.company.statusText, "需要修改接入密码")
        XCTAssertEqual(f.company.phases["login"], .failed)
        XCTAssertEqual(f.company.phases["resources"], .pending)
        XCTAssertEqual(f.company.requestedInteraction, .account)
        XCTAssertEqual(f.windows.pages.last ?? nil, .company)
        XCTAssertNil(f.company.quickConnectionID); XCTAssertNil(f.helper.processID)
        XCTAssertFalse(f.company.working); XCTAssertFalse(f.company.hasSession)
        XCTAssertTrue(f.company.password.isEmpty)
        XCTAssertEqual(f.company.username, "fixture")
        XCTAssertEqual(f.company.passwordChangeEntryURL?.absoluteString, MenuHelper.probe.origin)

        old(HelperEvent(type: "login_success", stage: nil, message: nil, username: "fixture", probe: nil, resources: nil, tunnel: nil, challenge: nil))
        old(HelperEvent(type: "resources", stage: nil, message: nil, username: nil, probe: nil, resources: MenuHelper.resources, tunnel: nil, challenge: nil))
        await Task.yield()
        XCTAssertEqual(f.vault.saves, 0); XCTAssertFalse(f.company.hasSession)
        XCTAssertNil(f.company.resources); XCTAssertFalse(f.company.connectionEnabled)
        XCTAssertFalse(f.helper.commands.contains { $0["type"] as? String == "connect" })
        XCTAssertFalse(f.coreModel.channels.contains("native:company-apply"))
    }

    func testLegacyHelperAndOrdinaryFailuresRemainDistinct() throws {
        let legacy = try JSONDecoder().decode(HelperEvent.self, from: Data(
            #"{"type":"error","stage":"login","message":"unsupported next authentication service: auth/modifyPwd"}"#.utf8))
        XCTAssertEqual(legacy.loginIssue, .passwordChangeRequired)
        for json in [
            #"{"type":"error","stage":"login","message":"password authentication failed with code 1"}"#,
            #"{"type":"error","stage":"login","message":"unsupported next authentication service: auth/other"}"#,
            #"{"type":"error","stage":"tunnel","code":"password_change_required"}"#,
            #"{"type":"progress","stage":"login","code":"password_change_required"}"#
        ] {
            XCTAssertNil(try JSONDecoder().decode(HelperEvent.self, from: Data(json.utf8)).loginIssue)
        }
    }

    @MainActor func testOnlySuccessfulRetryWithNewPasswordUpdatesSavedCredentials() async throws {
        let suite = "splitvpn-password-recovery-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = CompanyCredentials(origin: MenuHelper.probe.origin, domain: "local", username: "fixture", password: "fixture-old-password")
        let vault = PasswordRecoveryVault(stored: old)
        let helper = MenuHelper()
        let store = CompanyStore(credentialVault: vault, preferences: defaults, helper: helper)
        defer { store.close() }
        store.origin = old.origin
        try CompanyGatewayTrust(preferences: defaults).remember(MenuHelper.probe)
        store.acceptProbe(MenuHelper.probe)
        let core = CoreService { channel, _ in
            XCTAssertEqual(channel, "native:company-context")
            return .object(["interfaceName": .string("fixture-interface")])
        }
        await store.loadCredentials()
        XCTAssertEqual(store.password, old.password)
        store.login(core: core); await menuWait { helper.commands.count == 1 }
        try XCTUnwrap(helper.callbacks.last)(renewalEvent())
        XCTAssertEqual(vault.stored, old); XCTAssertEqual(vault.saves, 0)
        let loads = vault.loads
        await store.loadCredentials()
        XCTAssertEqual(vault.loads, loads); XCTAssertTrue(store.password.isEmpty)

        store.prepareAfterPasswordChange()
        XCTAssertNil(store.loginIssue); XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.canLogin); XCTAssertEqual(helper.commands.count, 1)
        await store.loadCredentials()
        XCTAssertEqual(vault.loads, loads); XCTAssertTrue(store.password.isEmpty)
        store.password = "fixture-new-password"
        XCTAssertTrue(store.canLogin)
        store.login(core: core); await menuWait { helper.commands.count == 2 }
        XCTAssertEqual(helper.commands.last?["password"] as? String, "fixture-new-password")
        XCTAssertEqual(vault.stored, old)
        helper.emit("login_success")
        await menuWait { vault.saves == 1 }
        XCTAssertEqual(vault.stored?.password, "fixture-new-password")
        XCTAssertTrue(store.hasSession)
        XCTAssertFalse(store.timeline.contains { $0.message.contains("fixture-new-password") || $0.message.contains(old.password) })
    }

    @MainActor func testRecoveryDoesNotOpenURLsContainingCredentialsOrTokens() throws {
        let suite = "splitvpn-password-recovery-url-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for origin in ["http://gateway.example.test", "https://user:secret@gateway.example.test", "https://gateway.example.test/?ticket=fixture", "https://gateway.example.test/#fixture", "https://gateway.example.test/passport/v1/auth/modifyPwd"] {
            let probe = ProbeInfo(origin: origin, fingerprint: "fixture", subject: "fixture", validTo: "2099-01-01T00:00:00Z", nameMatches: true, selfSigned: true, methods: [])
            let store = CompanyStore(credentialVault: FixtureVault(), preferences: defaults, helper: MenuHelper(), preview: CompanyPreview(probe: probe))
            store.receive(try renewalEvent())
            XCTAssertNil(store.passwordChangeEntryURL)
            store.close()
        }
    }
}

@MainActor private final class PasswordRecoveryVault: CompanyCredentialVault {
    var stored: CompanyCredentials?
    var loads = 0
    var saves = 0
    var saveFailure: Error?
    init(stored: CompanyCredentials) { self.stored = stored }
    func load(origin: String) async throws -> CompanyCredentials? { loads += 1; return stored }
    func save(_ credentials: CompanyCredentials) async throws { saves += 1; if let saveFailure { throw saveFailure }; stored = credentials }
    func remove(origin: String) async throws { stored = nil }
}
