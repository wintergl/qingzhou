import Foundation
import XCTest
@testable import SplitVPNNative

final class LoginItemTests: XCTestCase {
    @MainActor func testDisablingAbsentNativeItemDoesNotUnregister() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        XCTAssertEqual(service.state(), .disabled)
        XCTAssertEqual(try service.setEnabled(false), .disabled)
        XCTAssertEqual(fixture.unregisterCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.agent.path))
    }
    @MainActor func testEnablingRegistersAppItselfAndDoesNotCreateOpenAgent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        XCTAssertEqual(try service.setEnabled(true), .enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.agent.path))
        XCTAssertEqual(try service.setEnabled(true), .enabled)
        XCTAssertEqual(fixture.registerCalls, 1)
        XCTAssertEqual(try service.setEnabled(false), .disabled)
        XCTAssertEqual(fixture.unregisterCalls, 1)
    }
    @MainActor func testLegacyFileAloneIsNotProofOfRegisteredLoginItem() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeLegacyAgent()
        let before = try Data(contentsOf: fixture.agent)
        let service = fixture.service()
        XCTAssertEqual(service.state(), .needsRepair)
        XCTAssertFalse(service.state().requested)
        XCTAssertEqual(fixture.registerCalls, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.agent), before)
    }
    @MainActor func testUpgradeRegistersPreviouslyEnabledItemBeforeRemovingLegacyFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeLegacyAgent()
        let service = fixture.service()
        XCTAssertEqual(try service.repairLegacyRegistration(), .enabled)
        XCTAssertEqual(fixture.registerCalls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.agent.path))
        XCTAssertEqual(try service.repairLegacyRegistration(), .enabled)
        XCTAssertEqual(fixture.registerCalls, 1)
    }
    @MainActor func testUpgradeDoesNotEnableLoginForUserWithoutOptInFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertEqual(try fixture.service().repairLegacyRegistration(), .disabled)
        XCTAssertEqual(fixture.registerCalls, 0)
    }
    @MainActor func testRegistrationFailurePreservesLegacyFileAndDoesNotClaimEnabled() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeLegacyAgent()
        let before = try Data(contentsOf: fixture.agent)
        fixture.registerError = NSError(domain: "SMAppServiceErrorDomain", code: 1)
        let service = fixture.service()
        XCTAssertThrowsError(try service.repairLegacyRegistration())
        XCTAssertEqual(service.state(), .needsRepair)
        XCTAssertEqual(try Data(contentsOf: fixture.agent), before)
    }
    @MainActor func testUnconfirmedRegistrationPreservesLegacyFileAndDoesNotClaimEnabled() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeLegacyAgent()
        let before = try Data(contentsOf: fixture.agent)
        fixture.registerResult = .disabled
        let service = fixture.service()
        XCTAssertThrowsError(try service.setEnabled(true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("系统没有确认"))
        }
        XCTAssertEqual(service.state(), .needsRepair)
        XCTAssertEqual(try Data(contentsOf: fixture.agent), before)
    }
    @MainActor func testSystemApprovalIsShownWithoutClaimingEnabled() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.registerResult = .requiresApproval
        let service = fixture.service()
        XCTAssertEqual(try service.setEnabled(true), .requiresApproval)
        XCTAssertEqual(service.state(), .requiresApproval)
        XCTAssertEqual(try service.setEnabled(true), .requiresApproval)
        XCTAssertEqual(fixture.registerCalls, 1)
    }
    @MainActor func testSystemDenialIsPreservedAndSettingsCanBeOpenedExplicitly() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        try fixture.writeLegacyAgent()
        let before = try Data(contentsOf: fixture.agent)
        fixture.legacy = .requiresApproval
        XCTAssertEqual(service.state(), .requiresApproval)
        XCTAssertEqual(try service.repairLegacyRegistration(), .requiresApproval)
        XCTAssertEqual(try service.setEnabled(true), .requiresApproval)
        XCTAssertEqual(fixture.registerCalls, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.agent), before)
        XCTAssertEqual(fixture.openCalls, 0)
        service.openSystemSettings()
        XCTAssertEqual(fixture.openCalls, 1)
    }
    @MainActor func testForeignLoginFileIsPreserved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.agent.deletingLastPathComponent(), withIntermediateDirectories: true)
        let before = Data("foreign file".utf8)
        try before.write(to: fixture.agent)
        let service = fixture.service()
        XCTAssertEqual(service.state(), .needsRepair)
        XCTAssertEqual(try service.repairLegacyRegistration(), .needsRepair)
        XCTAssertEqual(fixture.registerCalls, 0)
        XCTAssertThrowsError(try service.setEnabled(true))
        XCTAssertThrowsError(try service.setEnabled(false))
        XCTAssertEqual(try Data(contentsOf: fixture.agent), before)
    }
    @MainActor func testPreviewBundleCannotBecomeLoginTarget() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service(installed: false)
        XCTAssertThrowsError(try service.setEnabled(true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("应用程序"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.agent.path))
    }
    @MainActor func testModernApprovalCannotBeBypassedByLocalAgent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.modern = .requiresApproval
        let service = fixture.service()
        XCTAssertEqual(try service.setEnabled(true), .requiresApproval)
        XCTAssertEqual(fixture.registerCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.agent.path))
    }
    @MainActor func testLoginFileSymlinkIsRejectedWithoutChangingTarget() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.agent.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = fixture.root.appendingPathComponent("other.plist")
        let before = Data("keep me".utf8)
        try before.write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.agent, withDestinationURL: target)
        let service = fixture.service()
        XCTAssertThrowsError(try service.setEnabled(true))
        XCTAssertThrowsError(try service.setEnabled(false))
        XCTAssertEqual(try Data(contentsOf: target), before)
    }
    @MainActor func testSignedServiceUsesActualStateAndDoesNotDuplicateRegistration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service()
        XCTAssertEqual(try service.setEnabled(true), .enabled)
        XCTAssertEqual(try service.setEnabled(true), .enabled)
        XCTAssertEqual(fixture.registerCalls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.agent.path))
        XCTAssertEqual(try service.setEnabled(false), .disabled)
        XCTAssertEqual(try service.setEnabled(false), .disabled)
        XCTAssertEqual(fixture.unregisterCalls, 1)
    }
    @MainActor func testPermissionFailureIsReadableAndDoesNotClaimEnabled() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.registerError = NSError(domain: "SMAppServiceErrorDomain", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        let service = fixture.service()
        XCTAssertThrowsError(try service.setEnabled(true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("无法开启登录启动"))
            XCTAssertTrue(error.localizedDescription.contains("SMAppServiceErrorDomain（1）"))
            XCTAssertFalse(error.localizedDescription.contains("Operation not permitted"))
        }
        XCTAssertEqual(service.state(), .disabled)
    }
    @MainActor func testNativeToggleDoesNotRewriteSharedLegacyPreferenceOrCallRust() async throws {
        let service = MemoryService()
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(Self.bootstrap.utf8))
        var channels: [String] = []
        let core = CoreService(transport: { channel, _ in channels.append(channel); return value })
        let store = VPNStore(core: core, loginItems: service)
        await store.refresh()
        XCTAssertEqual(store.status?.settings.launchAtLogin, true)
        XCTAssertEqual(store.loginItemState, .disabled)
        store.setLaunchAtLogin(true)
        XCTAssertEqual(store.loginItemState, .enabled)
        store.setLaunchAtLogin(false)
        XCTAssertEqual(store.loginItemState, .disabled)
        XCTAssertEqual(service.changes, [true, false])
        XCTAssertEqual(channels, ["native:bootstrap"])
        XCTAssertEqual(store.status?.settings.launchAtLogin, true)
        XCTAssertNil(store.error)
    }
    private static let bootstrap = """
    {"status":{"appStartedAt":"2026-10-09T00:00:00Z","mihomo":{"state":"stopped"},
    "subscription":{"nodeCount":0,"status":"empty","entries":[]},
    "settings":{"launchAtLogin":true,"unknownTraffic":"direct","tun":true,"ipv6":false,
    "lanDirect":true,"tailscaleDirect":true,"specialCompatibilityRules":{"mailMasterProxy8081":false,"wechatImageSendFallback":false},
    "selectedProxy":"DIRECT","vpnDomainRules":[],"favoriteNodeNames":[],"nodeGroups":[]}},
    "nodes":[],"groups":[],"risks":[],"traffic":{"rates":{"upload":0,"download":0},"samples":[],"running":false},
    "legacyOwnerRunning":false,"previewOnly":false,"ownsRuntime":false,
    "companyRouting":{"active":false,"verified":false,"recovering":false,"recoveryCount":0,"ruleCount":0,"routes":[]},"dataDir":"/fixture"}
    """
}

@MainActor private final class MemoryService: LoginItemService {
    var current: LoginItemState = .disabled
    var changes: [Bool] = []
    func state() -> LoginItemState { current }
    func setEnabled(_ enabled: Bool) throws -> LoginItemState {
        changes.append(enabled); current = enabled ? .enabled : .disabled; return current
    }
    func openSystemSettings() {}
}

@MainActor private final class Fixture {
    let root: URL
    let app: URL
    let agent: URL
    let bundleID = "dev.split-vpn.login-fixture"
    var modern: LoginItemState = .disabled
    var legacy: LoginItemState = .disabled
    var registerCalls = 0, unregisterCalls = 0, openCalls = 0
    var registerError: Error?
    var registerResult: LoginItemState = .enabled
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("splitvpn-login-\(UUID())")
        app = root.appendingPathComponent("Applications/轻舟 '本地版'.app")
        agent = root.appendingPathComponent("LaunchAgents/\(NativeLoginItemService.label).plist")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let executable = contents.appendingPathComponent("MacOS/Fixture")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
    func writeLegacyAgent() throws {
        try FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record: [String: Any] = ["Label": NativeLoginItemService.label,
            "ProgramArguments": ["/usr/bin/open", "-g", app.path], "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua", "AssociatedBundleIdentifiers": [bundleID], "ProcessType": "Interactive"]
        try PropertyListSerialization.data(fromPropertyList: record, format: .xml, options: 0).write(to: agent)
    }
    func service(installed: Bool = true) -> NativeLoginItemService {
        NativeLoginItemService(appURL: app, bundleID: bundleID, agentDirectory: agent.deletingLastPathComponent(),
            installationRoots: [root.appendingPathComponent(installed ? "Applications" : "AnotherFolder")],
            modernState: { self.modern }, register: {
                self.registerCalls += 1
                if let error = self.registerError { throw error }
                self.modern = self.registerResult
            }, unregister: { self.unregisterCalls += 1; self.modern = .disabled },
            legacyState: { _ in self.legacy }, showSettings: { self.openCalls += 1 })
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
