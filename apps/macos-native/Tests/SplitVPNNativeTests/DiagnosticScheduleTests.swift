import XCTest
@testable import SplitVPNNative

final class DiagnosticScheduleTests: XCTestCase {
    func testFailedZeroAndRestrictedResponseHaveDistinctLabels() throws {
        let zero = try JSONDecoder().decode(VPNNode.self, from: Data(#"{"name":"fixture","type":"http","selected":false,"available":false,"delay":0,"latencyStatus":"timeout"}"#.utf8))
        XCTAssertEqual(zero.latencyText, "超时")
        XCTAssertFalse(zero.latencyText.contains("0 ms"))
        let restricted = try JSONDecoder().decode(WebsiteResult.self, from: Data(#"{"id":"fixture","label":"Fixture","url":"https://example.test","ok":false,"httpStatus":403,"failureReason":"restricted"}"#.utf8))
        XCTAssertEqual(restricted.responseText, "访问受限 · 403")
    }
    @MainActor func testAutomaticResultsUpdateTimeAndCardsWithoutStartingManualRequest() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        f.coreModel.running = true; f.store.startOnce()
        await menuWait { f.coreModel.channels.contains("native:startup-connect") && f.store.busy == nil }
        let payload = #"""
        {"automatic":true,"connectivity":{"state":"ready","source":"automatic","checkedAt":"2026-10-25T20:00:00Z","nextCheckAt":"2026-10-25T20:05:00Z","intervalSeconds":300,"result":{"connectivity":{"domesticOk":true,"foreignOk":false,"latency":{"domesticMs":15,"foreignMs":null}}}},"websites":{"state":"idle","intervalSeconds":900}}
        """#
        let state = try JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8))
        f.core.onEvent?("diagnostics:updated", state)
        XCTAssertEqual(f.store.diagnostics?.connectivity.source, "automatic")
        XCTAssertNotNil(f.store.diagnostics?.connectivity.checkedAt)
        XCTAssertEqual(f.store.connectivity?.connectivity.foreignOk, false)
        XCTAssertFalse(f.coreModel.channels.contains("connectivity:check"))
        XCTAssertNil(f.store.busy)
    }
    @MainActor func testNodeBatchTracksActiveRowAndUpdatesResultsIncrementally() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        f.coreModel.running = true
        f.coreModel.intercept = { channel, _ in channel == "nodes:start-speed-batch" ? .object(["id":.string("batch")]) : nil }
        f.store.startOnce()
        await menuWait { f.coreModel.channels.contains("native:startup-connect") && f.store.busy == nil }
        f.store.startNodeSpeed(f.store.nodes); f.store.startNodeSpeed(f.store.nodes)
        await menuWait { f.coreModel.channels.contains("nodes:start-speed-batch") }
        XCTAssertEqual(f.coreModel.channels.filter { $0 == "nodes:start-speed-batch" }.count, 1)
        func event(_ value: String) throws { f.core.onEvent?("nodes:speed-progress", try JSONDecoder().decode(JSONValue.self, from: Data(value.utf8))) }
        try event(#"{"id":"batch","checked":0,"total":1,"nodeName":"fixture-node","phase":"testing","finished":false}"#)
        XCTAssertEqual(f.store.speedTestingNode, "fixture-node")
        try event(#"{"id":"batch","checked":1,"total":1,"nodeName":"fixture-node","finished":false,"result":{"nodeName":"fixture-node","status":"timeout","medianDelayMs":null,"testedAt":"2026-10-25T20:00:00Z","failureReason":"timeout"}}"#)
        XCTAssertEqual(f.store.nodes.first?.latencyText, "超时")
        XCTAssertNotNil(f.store.nodes.first?.latencyCheckedAt)
    }
}
