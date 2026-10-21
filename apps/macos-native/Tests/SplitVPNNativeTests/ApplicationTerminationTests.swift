import XCTest
@testable import SplitVPNNative

final class ApplicationTerminationTests: XCTestCase {
    @MainActor func testPendingOperationTimeoutCancelsQuitWithoutAbandoningStartAndRetryExits() async throws {
        var events: [NativeTerminationEvent] = []
        let f = try MenuBarFixture(terminationLog: { events.append($0) }); defer { f.close() }
        await f.store.refresh()
        var pending: CheckedContinuation<Void, Never>?
        f.coreModel.intercept = { channel, _ in
            if channel == "vpn:start" { await withCheckedContinuation { pending = $0 } }
            return nil
        }
        f.runtime.togglePersonal(); await menuWait { pending != nil }
        var replies: [Bool] = []
        f.runtime.requestTermination(operationsTimeout: 0.02) { replies.append($0) }
        await menuWait { !replies.isEmpty }
        XCTAssertEqual(replies, [false]); XCTAssertFalse(f.runtime.terminating)
        XCTAssertFalse(f.coreModel.channels.contains("native:company-remove"))
        XCTAssertEqual(events.last?.reason, .operationsTimeout)
        XCTAssertEqual(events.last?.stage, .waiting)
        XCTAssertEqual(f.core.availability, .available)
        pending?.resume()
        await menuWait { !f.runtime.togglingPersonal }
        XCTAssertTrue(f.coreModel.running)
        XCTAssertEqual(replies, [false], "A late result must not reply or close the core")
        f.runtime.requestTermination { replies.append($0) }
        await menuWait { replies.count == 2 }
        XCTAssertEqual(replies, [false, true]); XCTAssertEqual(f.core.availability, .closed)
        XCTAssertEqual(events.last?.outcome, .completed)
    }

    @MainActor func testPendingCompanyOperationTimeoutCannotReconnectFromLateReply() async throws {
        let f = try MenuBarFixture(); defer { f.close() }; try f.prepareAccount()
        await f.store.refresh()
        var pending: CheckedContinuation<Void, Never>?
        f.coreModel.intercept = { channel, _ in
            if channel == "native:company-context" { await withCheckedContinuation { pending = $0 } }
            return nil
        }
        f.runtime.toggleCompany(); await menuWait { f.helper.commands.count == 1 }
        f.helper.emit("probe", probe: MenuHelper.probe); await menuWait { pending != nil }
        var replies: [Bool] = []
        f.runtime.requestTermination(operationsTimeout: 0.02) { replies.append($0) }
        await menuWait { !replies.isEmpty }
        XCTAssertEqual(replies, [false]); XCTAssertFalse(f.runtime.terminating)
        XCTAssertFalse(f.coreModel.channels.contains("native:company-remove"))
        pending?.resume()
        await menuWait { f.core.pendingRequestCount == 0 }
        XCTAssertEqual(f.helper.commands.count, 1)
        XCTAssertEqual(replies, [false])
        f.runtime.requestTermination { replies.append($0) }
        await menuWait { replies.count == 2 }
        XCTAssertEqual(replies, [false, true])
    }

    @MainActor func testIdentityFailureRecordsStageWithoutLeakingErrorPayload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = NativeTerminationLog(directory: directory)
        let f = try MenuBarFixture(terminationLog: log.record); defer { f.close() }
        f.coreModel.running = true; await f.store.refresh()
        f.coreModel.failure = ("vpn:stop", CoreService.CoreError.message("identity_mismatch https://gateway.example.test password=fixture-secret"))
        var result: Bool?
        f.runtime.requestTermination { result = $0 }
        await menuWait { result != nil }
        XCTAssertEqual(result, false); XCTAssertTrue(f.coreModel.running)
        let text = try String(contentsOf: directory.appendingPathComponent("app.log"), encoding: .utf8)
        XCTAssertTrue(text.contains("outcome=failed stage=personal"))
        XCTAssertTrue(text.contains("reason=identityMismatch"))
        XCTAssertFalse(text.contains("fixture-secret")); XCTAssertFalse(text.contains("gateway.example.test"))
        XCTAssertFalse(text.contains("outcome=completed"))
    }

    @MainActor func testQuitRemovesRoutingConfirmsHelperStopsPersonalThenClosesCore() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        f.coreModel.running = true; f.coreModel.companyActive = true; f.helper.processID = 10000
        await f.store.refresh(); f.coreModel.events.removeAll()
        var replies: [Bool] = []
        f.runtime.requestTermination { replies.append($0) }
        XCTAssertTrue(f.runtime.terminating); XCTAssertFalse(f.store.canMutate)
        await menuWait { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(f.coreModel.events, ["native:company-remove", "helper:stop", "helper:confirmed", "native:bootstrap", "vpn:stop"])
        XCTAssertEqual(f.core.availability, .closed)
        XCTAssertFalse(f.coreModel.running); XCTAssertFalse(f.coreModel.companyActive)
    }
    @MainActor func testRepeatedQuitAndNewOperationsWaitForHelperConfirmation() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        f.coreModel.running = true; f.helper.processID = 10000; f.helper.waitForConfirmation = true
        await f.store.refresh(); f.coreModel.events.removeAll()
        var replies: [Bool] = [], duplicateReplies: [Bool] = []
        f.runtime.requestTermination { replies.append($0) }
        await menuWait { f.helper.pendingStop != nil }
        f.runtime.requestTermination { duplicateReplies.append($0) }
        f.runtime.togglePersonal(); f.runtime.toggleCompany(); f.store.connectOrVerify(); f.company.verifyInternet()
        await Task.yield()
        XCTAssertTrue(replies.isEmpty); XCTAssertTrue(duplicateReplies.isEmpty)
        XCTAssertEqual(f.coreModel.events, ["native:company-remove", "helper:stop"])
        XCTAssertEqual(f.core.availability, .available)
        f.helper.pendingStop?.resume()
        await menuWait { !replies.isEmpty }
        XCTAssertEqual(replies, [true]); XCTAssertTrue(duplicateReplies.isEmpty)
        XCTAssertEqual(f.coreModel.events.suffix(3), ["helper:confirmed", "native:bootstrap", "vpn:stop"])
    }
    @MainActor func testQuitWaitsForAcceptedPersonalStartBeforeCleanup() async throws {
        let f = try MenuBarFixture(); defer { f.close() }; await f.store.refresh()
        var pending: CheckedContinuation<Void, Never>?
        f.coreModel.intercept = { channel, _ in
            if channel == "vpn:start" { await withCheckedContinuation { pending = $0 } }
            return nil
        }
        f.runtime.togglePersonal(); await menuWait { pending != nil }
        var result: Bool?
        f.runtime.requestTermination { result = $0 }
        await Task.yield()
        XCTAssertNil(result); XCTAssertFalse(f.coreModel.channels.contains("native:company-remove"))
        pending?.resume()
        await menuWait { result != nil }
        XCTAssertEqual(result, true)
        let start = try XCTUnwrap(f.coreModel.events.firstIndex(of: "vpn:start"))
        let cleanup = try XCTUnwrap(f.coreModel.events.firstIndex(of: "native:company-remove"))
        XCTAssertLessThan(start, cleanup); XCTAssertFalse(f.coreModel.running)
    }
    @MainActor func testInteractiveLoginIsCancelledAndLateEventsCannotRestartIt() async throws {
        let f = try MenuBarFixture(); defer { f.close() }; try f.prepareAccount()
        await f.store.refresh()
        f.runtime.toggleCompany(); await menuWait { f.helper.commands.count == 1 }
        f.helper.emit("probe", probe: MenuHelper.probe); await menuWait { f.helper.commands.count == 2 }
        let old = try XCTUnwrap(f.helper.callbacks.last)
        f.helper.emit("challenge", challenge: AuthChallenge(id: "fixture", kind: "sms", title: "fixture", message: "fixture", imageBase64: nil, url: nil))
        var result: Bool?
        f.runtime.requestTermination { result = $0 }
        XCTAssertNil(f.company.challenge); XCTAssertNil(f.company.quickConnectionID)
        old(HelperEvent(type: "resources", stage: nil, message: nil, username: nil, probe: nil, resources: MenuHelper.resources, tunnel: nil, challenge: nil))
        await menuWait { result != nil }
        XCTAssertEqual(result, true)
        XCTAssertFalse(f.helper.commands.contains { $0["type"] as? String == "connect" })
        XCTAssertEqual(f.vault.saves, 0)
    }
    @MainActor func testCompanyRpcAlreadySubmittedIsAwaitedAndItsLateResultIsRetired() async throws {
        let f = try MenuBarFixture(); defer { f.close() }; try f.prepareAccount()
        await f.store.refresh()
        var pending: CheckedContinuation<Void, Never>?
        f.coreModel.intercept = { channel, _ in
            if channel == "native:company-context" { await withCheckedContinuation { pending = $0 } }
            return nil
        }
        f.runtime.toggleCompany(); await menuWait { f.helper.commands.count == 1 }
        f.helper.emit("probe", probe: MenuHelper.probe); await menuWait { pending != nil }
        var result: Bool?
        f.runtime.requestTermination { result = $0 }
        await Task.yield()
        XCTAssertNil(result); XCTAssertFalse(f.coreModel.channels.contains("native:company-remove"))
        pending?.resume()
        await menuWait { result != nil }
        XCTAssertEqual(result, true)
        XCTAssertEqual(f.helper.commands.count, 1)
    }
    @MainActor func testHelperTimeoutKeepsAppAliveAndCanBeRetried() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        f.coreModel.running = true; f.helper.stopError = HelperService.ServiceError.stopTimeout
        await f.store.refresh()
        var replies: [Bool] = []
        f.runtime.requestTermination { replies.append($0) }
        await menuWait { replies.count == 1 }
        XCTAssertEqual(replies, [false]); XCTAssertFalse(f.runtime.terminating)
        XCTAssertFalse(f.store.terminating); XCTAssertFalse(f.company.terminating)
        XCTAssertTrue(f.store.canToggleFromMenu); XCTAssertTrue(f.company.canToggleFromMenu)
        XCTAssertTrue(f.store.error?.contains("退出未完成") == true)
        XCTAssertEqual(f.windows.mainCalls, 1)
        XCTAssertFalse(f.coreModel.channels.contains("vpn:stop")); XCTAssertEqual(f.core.availability, .available)
        f.helper.stopError = nil
        f.runtime.requestTermination { replies.append($0) }
        await menuWait { replies.count == 2 }
        XCTAssertEqual(replies, [false, true]); XCTAssertEqual(f.core.availability, .closed)
    }
    @MainActor func testRoutingFailureDoesNotStopHelperOrPersonalConnection() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        f.coreModel.running = true; await f.store.refresh()
        f.coreModel.failure = ("native:company-remove", CoreService.CoreError.message("fixture routing failure"))
        var result: Bool?
        f.runtime.requestTermination { result = $0 }
        await menuWait { result != nil }
        XCTAssertEqual(result, false); XCTAssertTrue(f.coreModel.running)
        XCTAssertFalse(f.coreModel.events.contains("helper:stop"))
        XCTAssertFalse(f.coreModel.channels.contains("vpn:stop")); XCTAssertEqual(f.core.availability, .available)
    }
    @MainActor func testPersonalStopFailureDoesNotCloseCommunicationAndRetryCanExit() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        f.coreModel.running = true; await f.store.refresh()
        f.coreModel.failure = ("vpn:stop", CoreService.CoreError.message("fixture DNS cleanup failure"))
        var replies: [Bool] = []
        f.runtime.requestTermination { replies.append($0) }
        await menuWait { replies.count == 1 }
        XCTAssertEqual(replies, [false]); XCTAssertEqual(f.core.availability, .available)
        XCTAssertTrue(f.coreModel.running); XCTAssertFalse(f.runtime.terminating)
        f.coreModel.failure = nil
        f.runtime.requestTermination { replies.append($0) }
        await menuWait { replies.count == 2 }
        XCTAssertEqual(replies, [false, true])
    }
    @MainActor func testUnconfirmedStopResultCannotBeTreatedAsSuccessfulExit() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        f.coreModel.running = true; await f.store.refresh()
        f.coreModel.intercept = { channel, _ in channel == "vpn:stop" ? f.coreModel.state : nil }
        var result: Bool?
        f.runtime.requestTermination { result = $0 }
        await menuWait { result != nil }
        XCTAssertEqual(result, false)
        XCTAssertTrue(f.store.error?.contains("断开尚未确认") == true)
        XCTAssertEqual(f.core.availability, .available)
    }
    @MainActor func testQuitPreservesLegacyOwnedPersonalConnection() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        f.coreModel.running = true; f.coreModel.legacy = true; f.coreModel.owns = false
        await f.store.refresh()
        var result: Bool?
        f.runtime.requestTermination { result = $0 }
        await menuWait { result != nil }
        XCTAssertEqual(result, true); XCTAssertTrue(f.coreModel.running)
        XCTAssertFalse(f.coreModel.channels.contains("vpn:stop"))
        XCTAssertTrue(f.coreModel.channels.contains("native:company-remove"))
        XCTAssertEqual(f.core.availability, .closed)
    }
    func testHelperDefaultWaitTimesOutInsteadOfReportingAnUnconfirmedStop() async {
        let helper = UnconfirmedHelper()
        do { try await helper.stopAndWait(timeout: 0.001); XCTFail("An unconfirmed process was treated as stopped") }
        catch { XCTAssertTrue(error.localizedDescription.contains("尚未退出")) }
        XCTAssertEqual(helper.stops, 1)
    }
}

private final class UnconfirmedHelper: CompanyHelper {
    var processID: Int32? { 10000 }
    var stops = 0
    func stop() { stops += 1 }
    func start(command: [String: Any], onEvent: @escaping (HelperEvent) -> Void, onExit: @escaping (Int32) -> Void) throws {}
    func send(_ command: [String: Any]) throws {}
}
