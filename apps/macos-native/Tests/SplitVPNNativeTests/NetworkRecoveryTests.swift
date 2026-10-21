import AppKit
import XCTest
@testable import SplitVPNNative

final class NetworkRecoveryTests: XCTestCase {
    @MainActor func testRunningProcessDoesNotHideNetworkRecoveryFailures() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        f.coreModel.running = true
        for (state, title, menu) in [
            ("waiting-network", "等待网络恢复…", VPNMenuState.connecting),
            ("recovering", "网络恢复中…", .connecting),
            ("failed", "网络恢复失败", .error),
            ("helper-update-required", "连接服务待更新", .error)
        ] {
            f.coreModel.networkState = state; f.coreModel.networkError = "fixture network recovery failure"
            await f.store.refresh()
            XCTAssertTrue(f.store.running, "A live engine must remain disconnectable")
            XCTAssertTrue(f.store.canToggleFromMenu)
            XCTAssertEqual(f.store.menuState, menu); XCTAssertEqual(f.store.menuTitle, title)
            XCTAssertFalse(StatusBarIconState(store: f.store, company: f.company).personalConnected)
        }
        f.coreModel.networkState = "ready"; f.coreModel.networkError = nil
        await f.store.refresh()
        XCTAssertEqual(f.store.menuState, .connected)
        XCTAssertTrue(StatusBarIconState(store: f.store, company: f.company).personalConnected)
    }

    @MainActor func testServiceUpgradeWaitsForAnExplicitUserAction() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        f.coreModel.running = true; f.coreModel.networkState = "helper-update-required"
        await f.store.refresh()
        XCTAssertTrue(f.store.connectionServiceUpdateRequired)
        XCTAssertFalse(f.coreModel.channels.contains("native:upgrade-helper"))
        let node = f.store.selectedProxy
        f.store.updateConnectionService()
        await menuWait { f.store.busy == nil }
        XCTAssertEqual(f.coreModel.channels.filter { $0 == "native:upgrade-helper" }.count, 1)
        XCTAssertFalse(f.store.connectionServiceUpdateRequired)
        XCTAssertEqual(f.store.selectedProxy, node)
        XCTAssertEqual(f.store.menuState, .connected)
    }

    @MainActor func testCancelledServiceUpgradeKeepsTheDisconnectActionAndWarning() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        f.coreModel.running = true; f.coreModel.networkState = "helper-update-required"
        f.coreModel.failure = ("native:upgrade-helper", CoreService.CoreError.message("fixture cancelled authorization"))
        await f.store.refresh()
        f.store.updateConnectionService()
        await menuWait { f.store.busy == nil }
        XCTAssertTrue(f.store.running); XCTAssertTrue(f.store.connectionServiceUpdateRequired)
        XCTAssertTrue(f.store.canToggleFromMenu); XCTAssertNotNil(f.store.error)
        XCTAssertFalse(f.coreModel.channels.contains("vpn:stop"))
        XCTAssertFalse(StatusBarIconState(store: f.store, company: f.company).personalConnected)
    }

    func testPathObserverIgnoresInitialAndDuplicatePhysicalPaths() {
        var changes = PhysicalPathChanges()
        XCTAssertFalse(changes.update(available: true, interfaces: ["en0", "en16"]))
        XCTAssertFalse(changes.update(available: true, interfaces: ["en16", "en0"]))
        XCTAssertFalse(changes.update(available: true, interfaces: []))
        XCTAssertTrue(changes.update(available: false, interfaces: []))
        XCTAssertFalse(changes.update(available: false, interfaces: []))
        XCTAssertTrue(changes.update(available: true, interfaces: ["en0", "en16"]))
        XCTAssertTrue(changes.update(available: true, interfaces: ["en16"]))
    }

    func testAddressChangesOnTheSameInterfaceAreDetectedWithoutDnsOrTunFeedback() {
        var changes = PhysicalConfigurationChanges()
        let key = "State:/Network/Service/fixture/IPv4"
        var values: [String: [String: Any]] = [key: ["InterfaceName": "en0", "Addresses": ["10.0.0.8"], "Router": "10.0.0.1"]]
        values["State:/Network/Global/IPv4"] = ["PrimaryInterface": "en0", "Router": "10.0.0.1"]
        XCTAssertFalse(changes.update(values))
        values["State:/Network/Service/tunnel/IPv4"] = ["InterfaceName": "utun8", "Addresses": ["192.0.2.1"]]
        values["State:/Network/Service/fixture/DNS"] = ["InterfaceName": "en0", "ServerAddresses": ["127.0.0.1"]]
        values["State:/Network/Global/IPv4"] = ["PrimaryInterface": "utun8", "Router": "192.0.2.1"]
        XCTAssertFalse(changes.update(values), "Our TUN and DNS reloads must not restart recovery")
        values["State:/Network/Global/IPv4"] = ["PrimaryInterface": "en0", "Router": "10.0.0.1"]
        XCTAssertFalse(changes.update(values))
        values[key]?["Addresses"] = ["10.0.0.9"]
        XCTAssertTrue(changes.update(values))
        XCTAssertFalse(changes.update(values))
        values[key]?["Router"] = "10.0.0.2"
        XCTAssertTrue(changes.update(values))
        values.removeValue(forKey: key)
        XCTAssertTrue(changes.update(values))
        values["State:/Network/Global/IPv4"] = ["PrimaryInterface": "en16", "Router": "10.0.0.1"]
        XCTAssertTrue(changes.update(values), "A real default-interface switch is still detected")
    }

    func testWifiIdentityOrLinkChangesAreDetectedEvenWithTheSameAddress() {
        var changes = PhysicalConfigurationChanges()
        let key = "State:/Network/Interface/en0/AirPort"
        var values: [String: [String: Any]] = [key: ["SSID_STR": "example-network-a"]]
        XCTAssertFalse(changes.update(values))
        values[key]?["SSID_STR"] = "example-network-b"
        XCTAssertTrue(changes.update(values))
        values["State:/Network/Interface/en0/Link"] = ["Active": false]
        XCTAssertTrue(changes.update(values))
    }

    func testHiddenStoppedAndSleepingWindowsDoNotSampleTraffic() {
        var activity = DesktopActivity()
        XCTAssertNil(activity.pollingInterval(statusKnown: true, running: true))
        activity.visible = true
        XCTAssertNil(activity.pollingInterval(statusKnown: true, running: false))
        XCTAssertEqual(activity.pollingInterval(statusKnown: true, running: true), .seconds(2))
        activity.lowPower = true
        XCTAssertEqual(activity.pollingInterval(statusKnown: true, running: true), .seconds(5))
        activity.sleeping = true
        XCTAssertNil(activity.pollingInterval(statusKnown: true, running: true))
        XCTAssertNil(activity.pollingInterval(statusKnown: false, running: false))
    }

    @MainActor func testAPathEventStillReachesTheCoreAfterFailedRecovery() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        f.coreModel.running = false; f.coreModel.networkState = "failed"
        await f.store.refresh()
        f.store.networkChanged(available: true)
        await menuWait { f.coreModel.channels.contains("native:network-changed") }
        XCTAssertFalse(f.coreModel.channels.contains("vpn:start"), "Reconnect intent belongs to the core")
    }

    @MainActor func testTrafficRequestsCannotPileUpWhileTheCoreIsSlow() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        var pending: CheckedContinuation<Void, Never>?
        var calls = 0
        f.coreModel.intercept = { channel, _ in
            if channel == "traffic:get-monitor" {
                calls += 1
                await withCheckedContinuation { pending = $0 }
            }
            return nil
        }
        let first = Task { await f.store.refreshTraffic() }
        await menuWait { pending != nil }
        await f.store.refreshTraffic()
        XCTAssertEqual(calls, 1)
        pending?.resume(); await first.value
    }

    @MainActor func testSleepWakeAndLowPowerNotificationsAreDeliveredWithoutVisibilityChanges() async {
        let center = NotificationCenter(), workspace = NotificationCenter()
        var lowPower = false
        var received: [DesktopActivity] = []
        let service = NativeActivityService(center: center, workspace: workspace, readState: { (true, lowPower) })
        service.start { received.append($0) }
        XCTAssertEqual(received.count, 1)
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        await menuWait { received.last?.sleeping == true }
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        await menuWait { received.last?.sleeping == false }
        lowPower = true
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        await menuWait { received.last?.lowPower == true }
        XCTAssertEqual(received.count, 4)
        service.stop()
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        await Task.yield()
        XCTAssertEqual(received.count, 4)
    }
}
