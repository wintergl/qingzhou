import XCTest
@testable import SplitVPNNative

final class MenuBarStateTests: XCTestCase {
    @MainActor func testStopDuringPreflightCannotBeFollowedByLateStart() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        await f.store.refresh()
        var pending: CheckedContinuation<Void, Never>?
        f.coreModel.intercept = { channel, _ in
            if channel == "native:bootstrap" { await withCheckedContinuation { pending = $0 } }
            return nil
        }
        let connecting = Task { try await f.store.toggleConnection() }
        await menuWait { pending != nil }
        try await f.store.disconnectNow()
        pending?.resume()
        try await connecting.value
        XCTAssertFalse(f.coreModel.channels.contains("vpn:start"))
        XCTAssertEqual(f.store.menuState, .disconnected)
    }
    @MainActor func testDegradedExitIsDistinctFromRunningEngineAndKeepsStopAvailable() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        f.coreModel.running = true; f.coreModel.healthState = "degraded"
        await f.store.refresh()
        XCTAssertTrue(f.store.running)
        XCTAssertEqual(f.store.menuTitle, "VPN 出口不稳定")
        XCTAssertEqual(f.store.menuState, .error)
        XCTAssertTrue(f.store.canDisconnect)
        XCTAssertFalse(StatusBarIconState(store: f.store, company: f.company).personalConnected)
        f.coreModel.healthState = nil
        await f.store.refresh()
        XCTAssertEqual(f.store.menuState, .connected)
    }
    @MainActor func testLoadingOffOnTunOffAndRuntimeErrorHaveDistinctStates() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        XCTAssertEqual(f.store.menuState, .loading)
        XCTAssertFalse(StatusBarIconState(store: f.store, company: f.company).personalConnected)
        XCTAssertEqual(f.store.modeTitle, "尚未读取")
        await f.store.refresh(); XCTAssertEqual(f.store.menuState, .disconnected)
        XCTAssertFalse(StatusBarIconState(store: f.store, company: f.company).personalConnected)
        XCTAssertTrue(f.store.modeTitle.contains("默认直连"))
        f.coreModel.running = true
        f.coreModel.unknownTraffic = "vpn"
        await f.store.refresh(); XCTAssertEqual(f.store.menuState, .connected)
        XCTAssertTrue(StatusBarIconState(store: f.store, company: f.company).personalConnected)
        XCTAssertTrue(f.store.modeTitle.contains("默认 VPN"))
        f.coreModel.tun = false
        await f.store.refresh(); XCTAssertEqual(f.store.menuTitle, "代理服务已开启")
        XCTAssertTrue(StatusBarIconState(store: f.store, company: f.company).personalConnected)
        XCTAssertTrue(f.store.modeTitle.contains("TUN 已关闭"))
        f.coreModel.stateError = "fixture engine failure"
        await f.store.refresh(); XCTAssertEqual(f.store.menuState, .error)
        XCTAssertFalse(StatusBarIconState(store: f.store, company: f.company).personalConnected)
    }
    @MainActor func testTransportLossInvalidatesConnectedStateAndBootstrapReconfirmsIt() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        f.coreModel.running = true
        await f.store.refresh()
        f.coreModel.failure = ("traffic:get-monitor", CoreService.CoreError.transport("fixture transport unavailable"))
        await f.store.refreshTraffic()
        XCTAssertEqual(f.store.menuState, .unknown)
        XCTAssertFalse(f.store.statusKnown); XCTAssertFalse(f.store.canToggleFromMenu)
        XCTAssertFalse(StatusBarIconState(store: f.store, company: f.company).personalConnected)
        XCTAssertEqual(f.core.availability, .unavailable("fixture transport unavailable"))
        f.coreModel.failure = nil
        await f.store.refresh()
        XCTAssertEqual(f.core.availability, .available)
        XCTAssertEqual(f.store.menuState, .connected)
        XCTAssertTrue(StatusBarIconState(store: f.store, company: f.company).personalConnected)
        f.core.close(); XCTAssertEqual(f.store.menuState, .unknown)
        do { _ = try await f.core.requestValue("native:bootstrap"); XCTFail("Closed transport accepted a new request") } catch {}
        XCTAssertEqual(f.core.availability, .closed)
    }
    @MainActor func testFirstReadFailureShowsUnknownAndCompanyRoutingAlsoRequiresReconfirmation() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        f.coreModel.failure = ("native:bootstrap", CoreService.CoreError.transport("fixture loss"))
        await f.store.refresh(); XCTAssertEqual(f.store.menuState, .unknown)
        f.coreModel.failure = nil; f.coreModel.running = true; f.coreModel.companyActive = true
        await f.store.refresh(); XCTAssertEqual(f.company.menuState, .connected)
        XCTAssertTrue(StatusBarIconState(store: f.store, company: f.company).companyConnected)
        f.coreModel.failure = ("traffic:get-monitor", CoreService.CoreError.transport("fixture loss"))
        await f.store.refreshTraffic()
        XCTAssertEqual(f.company.menuState, .unknown); XCTAssertEqual(f.company.statusText, "私有网络分流状态未知")
        let unknown = StatusBarIconState(store: f.store, company: f.company)
        XCTAssertFalse(unknown.personalConnected); XCTAssertFalse(unknown.companyConnected)
        f.coreModel.failure = nil; await f.store.refresh()
        XCTAssertEqual(f.company.menuState, .connected)
        let confirmed = StatusBarIconState(store: f.store, company: f.company)
        XCTAssertTrue(confirmed.personalConnected); XCTAssertTrue(confirmed.companyConnected)
    }
    @MainActor func testSubscriptionAndConnectivityErrorsDoNotReplaceConnectionColours() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        f.coreModel.running = true; f.coreModel.companyActive = true; await f.store.refresh()
        f.store.action("更新订阅", channel: "subscription:update")
        await menuWait { f.store.busy == nil }
        XCTAssertNotNil(f.store.error); XCTAssertEqual(f.store.menuState, .connected)
        XCTAssertTrue(StatusBarIconState(store: f.store, company: f.company).personalConnected)
        f.store.checkConnectivity()
        await menuWait { f.store.busy == nil }
        XCTAssertNotNil(f.store.error); XCTAssertEqual(f.store.menuState, .connected)
        f.company.verifyInternet()
        XCTAssertTrue(f.company.working)
        XCTAssertTrue(StatusBarIconState(store: f.store, company: f.company).companyConnected)
        await menuWait { !f.company.working }
        XCTAssertTrue(f.coreModel.channels.contains("native:company-internet-check"))
        let connected = StatusBarIconState(store: f.store, company: f.company)
        XCTAssertTrue(connected.personalConnected); XCTAssertTrue(connected.companyConnected)
        f.coreModel.running = false; f.coreModel.companyActive = false
        await f.store.refresh()
        let disconnected = StatusBarIconState(store: f.store, company: f.company)
        XCTAssertFalse(disconnected.personalConnected); XCTAssertFalse(disconnected.companyConnected)
    }
    @MainActor func testLegacyConnectionAndSubscriptionProbeDisableMenuToggle() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        f.coreModel.running = true; f.coreModel.legacy = true; f.coreModel.owns = false
        await f.store.refresh()
        XCTAssertTrue(f.store.connectionProtected); XCTAssertFalse(f.store.canToggleFromMenu)
        XCTAssertTrue(f.store.menuRestriction?.contains("原版") == true)
        f.runtime.togglePersonal(); await Task.yield()
        XCTAssertFalse(f.coreModel.channels.contains("vpn:stop"))
        f.coreModel.legacy = false; f.coreModel.mode = "subscription-probe"
        await f.store.refresh()
        XCTAssertEqual(f.store.menuTitle, "订阅检测中")
        XCTAssertFalse(f.store.canToggleFromMenu)
    }
    @MainActor func testToggleReservesOperationImmediatelyAndDoesNotDuplicateRpc() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        await f.store.refresh()
        var pending: CheckedContinuation<Void, Never>?
        f.coreModel.intercept = { channel, _ in
            if channel == "vpn:start" { await withCheckedContinuation { pending = $0 } }
            return nil
        }
        f.runtime.togglePersonal(); f.runtime.togglePersonal()
        XCTAssertTrue(f.runtime.togglingPersonal)
        await menuWait { pending != nil }
        XCTAssertEqual(f.store.menuState, .connecting)
        XCTAssertFalse(StatusBarIconState(store: f.store, company: f.company).personalConnected)
        XCTAssertTrue(f.store.canToggleFromMenu)
        pending?.resume()
        await menuWait { !f.runtime.togglingPersonal }
        XCTAssertEqual(f.coreModel.channels.filter { $0 == "vpn:start" }.count, 1)
        XCTAssertEqual(f.store.menuState, .connected)
        XCTAssertTrue(StatusBarIconState(store: f.store, company: f.company).personalConnected)
        XCTAssertTrue(f.store.canToggleFromMenu)
        f.runtime.togglePersonal()
        await menuWait { !f.runtime.togglingPersonal }
        XCTAssertEqual(f.store.menuState, .disconnected)
        XCTAssertFalse(StatusBarIconState(store: f.store, company: f.company).personalConnected)
        XCTAssertEqual(f.coreModel.channels.filter { $0 == "vpn:stop" }.count, 1)
    }
    @MainActor func testStopRemainsAvailableWhileWebsiteCheckIsStalled() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        f.coreModel.running = true
        await f.store.refresh()
        var pending: CheckedContinuation<Void, Never>?
        f.coreModel.intercept = { channel, _ in
            if channel == "connectivity:test-website-speeds" {
                await withCheckedContinuation { pending = $0 }
                throw CoreService.CoreError.message("obsolete diagnostic failure")
            }
            return nil
        }
        f.store.testWebsites()
        await menuWait { pending != nil }
        XCTAssertTrue(f.store.canDisconnect)
        XCTAssertTrue(f.store.canToggleFromMenu)
        try await f.store.toggleConnection()
        XCTAssertFalse(f.store.running)
        XCTAssertEqual(f.coreModel.channels.filter { $0 == "vpn:stop" }.count, 1)
        pending?.resume()
        await menuWait { f.core.pendingRequestCount == 0 }
        XCTAssertNil(f.store.error)
        XCTAssertNil(f.store.websites)
        XCTAssertNil(f.store.busy)
    }
    @MainActor func testStopCancelsInFlightConnectWithoutAcceptingItsLateResult() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        await f.store.refresh()
        var pending: CheckedContinuation<Void, Never>?
        f.coreModel.intercept = { channel, _ in
            if channel == "vpn:start" {
                await withCheckedContinuation { pending = $0 }
                throw CoreService.CoreError.message("connect cancelled")
            }
            return nil
        }
        let connecting = Task { try await f.store.toggleConnection() }
        await menuWait { pending != nil }
        XCTAssertTrue(f.store.canDisconnect)
        try await f.store.toggleConnection()
        XCTAssertEqual(f.store.menuState, .disconnected)
        pending?.resume()
        try await connecting.value
        XCTAssertEqual(f.store.menuState, .disconnected)
        XCTAssertNil(f.store.error)
    }
    @MainActor func testMissingNodeOpensNodePageAndNeverStartsEngine() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        f.coreModel.selectedNode = "missing-node"; await f.store.refresh()
        f.runtime.togglePersonal()
        await menuWait { !f.runtime.togglingPersonal }
        XCTAssertEqual(f.store.page, .nodes); XCTAssertEqual(f.windows.mainCalls, 1)
        XCTAssertFalse(f.coreModel.channels.contains("vpn:start"))
    }
    @MainActor func testDockDefaultsVisibleAndChangesPolicyAndPersistenceTogether() throws {
        let f = try MenuBarFixture(); defer { f.close() }
        var applied: [Bool] = []
        let preferences = DesktopPreferences(defaults: f.defaults, applyPolicy: { applied.append($0) })
        XCTAssertTrue(preferences.showDockIcon); XCTAssertTrue(applied.isEmpty)
        preferences.apply(); preferences.showDockIcon = false; preferences.showDockIcon = false
        XCTAssertEqual(applied, [true, false])
        XCTAssertEqual(f.defaults.object(forKey: "showDockIcon") as? Bool, false)
        let recreated = DesktopPreferences(defaults: f.defaults, applyPolicy: { applied.append($0) })
        XCTAssertFalse(recreated.showDockIcon)
        recreated.apply(); recreated.showDockIcon = true
        XCTAssertEqual(applied, [true, false, false, true])
    }
    @MainActor func testLaunchStartsSharedStoresOnceAndCompanyNeverLogsInAutomatically() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        try f.prepareAccount()
        f.runtime.start(loginLaunch: true, installStatusBar: false)
        f.runtime.start(loginLaunch: false, installStatusBar: false)
        await menuWait { f.coreModel.channels.filter { $0 == "native:bootstrap" }.count == 2 && f.store.busy == nil }
        XCTAssertEqual(f.windows.mainCalls, 0)
        XCTAssertEqual(f.coreModel.channels.filter { $0 == "native:startup-connect" }.count, 1)
        XCTAssertTrue(f.helper.commands.isEmpty); XCTAssertEqual(f.vault.loads, 0)
        f.runtime.openMain(); f.runtime.openSettings()
        XCTAssertEqual(f.windows.mainCalls, 1); XCTAssertEqual(f.windows.settingsCalls, 1)
    }
    @MainActor func testManualLaunchOpensMainWindowWithoutCompanyLogin() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        f.runtime.start(loginLaunch: false, installStatusBar: false)
        XCTAssertEqual(f.windows.mainCalls, 1)
        XCTAssertTrue(f.helper.commands.isEmpty)
    }
}
