import XCTest
@testable import SplitVPNNative

final class StartupConnectionTests: XCTestCase {
    @MainActor func testLaunchRepairsLegacyLoginItemOnceAndRefreshStaysReadOnly() async throws {
        let fixture = StartupFixture()
        fixture.loginItems.current = .needsRepair
        let store = fixture.store()
        defer { store.close() }
        store.startOnce(); store.startOnce()
        await waitUntil { fixture.bootstraps == 2 && store.busy == nil }
        XCTAssertEqual(fixture.loginItems.repairCalls, 1)
        XCTAssertEqual(store.loginItemState, .enabled)
        await store.refresh(); store.startOnce()
        XCTAssertEqual(fixture.loginItems.repairCalls, 1)
        XCTAssertTrue(store.running)
        XCTAssertNil(store.error)
    }

    @MainActor func testFailedLoginMigrationKeepsRepairStateAndDoesNotPreventVPNConnection() async throws {
        let fixture = StartupFixture()
        fixture.loginItems.current = .needsRepair
        fixture.loginItems.repairError = LoginItemError.message("系统没有确认登录项注册。")
        let store = fixture.store()
        defer { store.close() }
        store.startOnce()
        await waitUntil { fixture.bootstraps == 2 && store.busy == nil }
        XCTAssertEqual(store.loginItemState, .needsRepair)
        XCTAssertTrue(store.error?.contains("登录启动未完成") == true)
        XCTAssertTrue(store.running)
        await store.refresh(); store.startOnce()
        XCTAssertEqual(fixture.loginItems.repairCalls, 1)
    }

    @MainActor func testLaunchConnectsAfterBootstrapOnceAndManualDisconnectStaysOff() async throws {
        let fixture = StartupFixture()
        let store = fixture.store()
        defer { store.close() }
        store.startOnce(); store.startOnce()
        await waitUntil { fixture.bootstraps == 2 && store.busy == nil }
        XCTAssertEqual(Array(fixture.channels.prefix(2)), ["native:bootstrap", "native:startup-connect"])
        XCTAssertTrue(store.running)
        XCTAssertEqual(store.selectedProxy, "fixture-node")
        XCTAssertEqual(store.message, "已自动连接 VPN。")
        await store.refresh()
        store.connectOrVerify()
        await waitUntil { fixture.stopCalls == 1 && store.busy == nil }
        await store.refresh(); store.startOnce()
        XCTAssertFalse(store.running)
        XCTAssertEqual(fixture.startupCalls, 1)
        XCTAssertFalse(fixture.channels.contains("vpn:start"))
        XCTAssertNil(store.error)
    }

    @MainActor func testLaunchAdoptsExistingConnectionWithoutStoppingOrSelectingIt() async throws {
        let fixture = StartupFixture()
        fixture.running = true
        let store = fixture.store()
        defer { store.close() }
        store.startOnce()
        await waitUntil { fixture.bootstraps == 2 && store.busy == nil }
        XCTAssertTrue(store.running)
        XCTAssertEqual(store.status?.mihomo.pid, 1234)
        XCTAssertEqual(fixture.startupCalls, 1)
        XCTAssertFalse(fixture.channels.contains { $0 == "vpn:stop" || $0 == "vpn:start" || $0.hasPrefix("nodes:select") })
        XCTAssertNil(store.message)
    }

    @MainActor func testFailedAutomaticConnectionIsShownOnceAndDoesNotRetryOnRefresh() async throws {
        let fixture = StartupFixture()
        fixture.startupError = "特权服务尚未安装；连接时会自动请求系统授权。"
        let store = fixture.store()
        defer { store.close() }
        store.startOnce()
        await waitUntil { store.error != nil && store.busy == nil }
        XCTAssertTrue(store.error?.contains("自动连接未完成") == true)
        XCTAssertTrue(store.error?.contains("连接时会自动请求系统授权") == true)
        await store.refresh(); store.startOnce()
        XCTAssertEqual(fixture.startupCalls, 1)
        XCTAssertFalse(store.running)
        XCTAssertNil(store.message)
    }

    @MainActor func testUnreadableConfigurationDoesNotAttemptConnection() async throws {
        let fixture = StartupFixture()
        fixture.bootstrapError = "配置文件无法读取。"
        let store = fixture.store()
        defer { store.close() }
        store.startOnce()
        await waitUntil { store.error != nil }
        XCTAssertEqual(fixture.channels, ["native:bootstrap", "vpn:get-status"])
        XCTAssertEqual(fixture.startupCalls, 0)
        XCTAssertNil(store.status)
    }

    @MainActor func testPreviewCannotAutoConnect() async throws {
        let fixture = StartupFixture()
        let preview = try JSONDecoder().decode(Bootstrap.self, from: fixture.bootstrap().encoded)
        let store = VPNStore(preview: preview, core: fixture.core(), loginItems: StartupLoginItems(), riskKeyVault: FixtureVault())
        defer { store.close() }
        store.startOnce()
        await Task.yield()
        XCTAssertTrue(fixture.channels.isEmpty)
        XCTAssertTrue(store.previewOnly)
    }

    @MainActor func testClosingWhileBootstrapIsPendingCancelsAutomaticConnection() async throws {
        let fixture = StartupFixture()
        var pending: CheckedContinuation<JSONValue, Never>?
        let core = CoreService { channel, _ in
            fixture.channels.append(channel)
            return await withCheckedContinuation { pending = $0 }
        }
        let store = VPNStore(core: core, loginItems: StartupLoginItems(), riskKeyVault: FixtureVault())
        store.startOnce()
        await waitUntil { pending != nil }
        store.close()
        pending?.resume(returning: try fixture.bootstrap())
        await waitUntil { !store.refreshing }
        await Task.yield()
        XCTAssertEqual(fixture.channels, ["native:bootstrap"])
    }

    @MainActor private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition(), "Startup task did not reach its expected state", file: file, line: line)
    }
}

@MainActor private final class StartupLoginItems: LoginItemService {
    var current: LoginItemState = .disabled
    var repairCalls = 0
    var repairError: Error?
    func state() -> LoginItemState { current }
    func repairLegacyRegistration() throws -> LoginItemState {
        repairCalls += 1
        if let error = repairError { throw error }
        if current == .needsRepair { current = .enabled }
        return current
    }
    func setEnabled(_ enabled: Bool) -> LoginItemState { enabled ? .enabled : .disabled }
    func openSystemSettings() {}
}

@MainActor private final class StartupFixture {
    let loginItems = StartupLoginItems()
    var channels: [String] = []
    var running = false
    var startupError: String?
    var bootstrapError: String?
    var bootstraps = 0
    var startupCalls: Int { channels.filter { $0 == "native:startup-connect" }.count }
    var stopCalls: Int { channels.filter { $0 == "vpn:stop" }.count }
    func core() -> CoreService {
        CoreService { channel, _ in
            self.channels.append(channel)
            switch channel {
            case "native:bootstrap":
                if let error = self.bootstrapError { throw CoreService.CoreError.message(error) }
                self.bootstraps += 1
                return try self.bootstrap()
            case "native:startup-connect":
                if let error = self.startupError { throw CoreService.CoreError.message(error) }
                let outcome = self.running ? "already-running" : "connected"
                self.running = true
                return .object(["startupOutcome": .string(outcome), "mihomo": self.state])
            case "vpn:stop":
                self.running = false
                return self.state
            default: throw CoreService.CoreError.message("Unexpected fixture channel: \(channel)")
            }
        }
    }
    func store() -> VPNStore {
        VPNStore(core: core(), loginItems: loginItems, riskKeyVault: FixtureVault())
    }
    private var state: JSONValue {
        .object(["state": .string(running ? "running" : "stopped"), "pid": running ? .number(1234) : .null])
    }
    func bootstrap() throws -> JSONValue {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"status":{"appStartedAt":"fixture","mihomo":{"state":"stopped"},
        "subscription":{"nodeCount":1,"status":"ready","entries":[]},
        "settings":{"launchAtLogin":false,"unknownTraffic":"direct","tun":true,"ipv6":false,
        "lanDirect":true,"tailscaleDirect":true,"specialCompatibilityRules":{"mailMasterProxy8081":false,"wechatImageSendFallback":false},
        "selectedProxy":"fixture-node","vpnDomainRules":[],"favoriteNodeNames":[],"nodeGroups":[]}},
        "nodes":[{"name":"fixture-node","type":"http","selected":true,"identityKey":"fixture-id","identityAmbiguous":false}],
        "groups":[],"risks":[],"traffic":{"rates":{"upload":0,"download":0},"samples":[],"running":false},
        "legacyOwnerRunning":false,"previewOnly":false,"ownsRuntime":false,
        "companyRouting":{"active":false,"verified":false,"recovering":false,"recoveryCount":0,"ruleCount":0,"routes":[]},"dataDir":"/fixture"}
        """.utf8))
        guard case .object(var fields) = value, case .object(var status) = fields["status"] else { return value }
        status["mihomo"] = state; fields["status"] = .object(status)
        return .object(fields)
    }
}
