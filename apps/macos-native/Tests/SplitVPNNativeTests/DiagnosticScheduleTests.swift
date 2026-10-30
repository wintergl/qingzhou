import XCTest
@testable import SplitVPNNative

final class DiagnosticScheduleTests: XCTestCase {
    func testConnectionReadinessAndHistoricalResultsHaveClearTiming() throws {
        func record(_ payload: String) throws -> DiagnosticRecord {
            try JSONDecoder().decode(DiagnosticRecord.self, from: Data(payload.utf8))
        }
        let waiting = try record(#"{"state":"idle","nextCheckAt":"2026-10-29T01:00:00Z"}"#)
        XCTAssertEqual(waiting.nextCheckText(pausedReason: nil), "连接已就绪，即将自动检测")
        XCTAssertEqual(waiting.nextCheckText(pausedReason: "recovering"), "连接恢复后自动重新检测")
        XCTAssertEqual(waiting.nextCheckText(pausedReason: "disconnected"), "连接后自动检测")
        let updating = try record(#"{"state":"running","source":"automatic","staleResult":true,"checkedAt":"2026-10-29T00:00:00Z"}"#)
        XCTAssertTrue(updating.running)
        XCTAssertTrue(updating.stale)
        XCTAssertEqual(updating.nextCheckText(pausedReason: nil), "正在更新本次连接的检测结果")
        // Older cores omit staleResult and retain their original interpretation.
        XCTAssertTrue(try record(#"{"state":"stale"}"#).stale)
        XCTAssertFalse(try record(#"{"state":"ready"}"#).stale)
        let ready = try record(#"{"state":"ready","checkedAt":"2026-10-29T00:00:00Z","nextCheckAt":"2026-10-29T00:15:00Z","intervalSeconds":900}"#)
        XCTAssertTrue(ready.nextCheckText(pausedReason: nil).contains("每 15 分钟"))
    }

    @MainActor func testBothAutomaticChecksCanRunWithoutBlockingDisconnectOrStartingManualRequests() async throws {
        let f = try MenuBarFixture(); defer { f.close() }
        f.coreModel.running = true; f.store.startOnce()
        await menuWait { f.coreModel.channels.contains("native:startup-connect") && f.store.busy == nil }
        let payload = #"""
        {"automatic":true,"connectivity":{"state":"running","source":"automatic","staleResult":true,"checkedAt":"2026-10-29T00:00:00Z","result":{"connectivity":{"domesticOk":true,"foreignOk":true,"latency":{"domesticMs":15,"foreignMs":23}}}},"websites":{"state":"running","source":"automatic","staleResult":true,"checkedAt":"2026-10-29T00:00:00Z","result":{"proxyName":"fixture-node","results":[{"id":"google","label":"Google","url":"https://example.test","delay":20,"ok":true}]}}}
        """#
        f.core.onEvent?("diagnostics:updated", try JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)))
        f.store.checkConnectivity(); f.store.testWebsites()
        await Task.yield()
        XCTAssertTrue(f.store.diagnostics?.connectivity.stale == true)
        XCTAssertTrue(f.store.diagnostics?.websites.stale == true)
        XCTAssertNotNil(f.store.connectivity)
        XCTAssertEqual(f.store.websites?.results.count, 1)
        XCTAssertNil(f.store.busy)
        XCTAssertTrue(f.store.canDisconnect)
        XCTAssertFalse(f.coreModel.channels.contains("connectivity:check"))
        XCTAssertFalse(f.coreModel.channels.contains("connectivity:test-website-speeds"))
    }

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
