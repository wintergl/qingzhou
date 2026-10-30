import XCTest
@testable import SplitVPNNative

final class ChainComparisonPresentationTests: XCTestCase {
    func test_compatible_old_network_result_can_be_rechecked_but_revoked_route_cannot() {
        var row = ChainScanRow(identityKey: "one", nodeName: "示例线路", status: "available", latencyMs: 100, jitterMs: 1, downloadMbps: 20,
            latencySuccesses: 3, latencyAttempts: 3, downloadSuccesses: 2, downloadAttempts: 2, exitIp: "203.0.113.8", errors: [], balancedScore: 60)
        row.otherEnvironment = true; row.requiresRefresh = true; row.connectionEligible = true
        let state = ChainScanState(id: "old-environment", results: [row], stale: true)
        XCTAssertTrue(ChainComparisonPresentation(state: state).canApply(row))
        row.connectionEligible = false
        XCTAssertFalse(ChainComparisonPresentation(state: state).canApply(row))
    }
    private func sample() -> ChainScanState {
        let row = ChainScanRow(identityKey: "one", nodeName: "示例线路", status: "available", latencyMs: 100, jitterMs: 10, downloadMbps: 20,
                               latencySuccesses: 3, latencyAttempts: 3, downloadSuccesses: 2, downloadAttempts: 2, exitIp: "203.0.113.8", errors: [], balancedScore: 60, requiresRefresh: true)
        return ChainScanState(id: "fixture", results: [row], stale: false, recommendedIdentityKey: "one", leaders: ChainLeaders(balanced: "one", download: "one", latency: nil))
    }
    func test_core_winners_are_used_without_inventing_a_missing_leader() {
        let model = ChainComparisonPresentation(state: sample())
        XCTAssertEqual(model.leader("download")?.id, "one")
        XCTAssertNil(model.leader("latency"))
        XCTAssertEqual(model.successful.count, 1)
        XCTAssertEqual(model.recentCount, 0)
    }
    func test_historical_success_can_be_verified_but_partial_failed_or_other_environment_cannot() {
        var state = sample()
        XCTAssertTrue(ChainComparisonPresentation(state: state).canApply(state.results[0]))
        state.running = true
        XCTAssertFalse(ChainComparisonPresentation(state: state).canApply(state.results[0]))
        state.canUseCachedResults = true
        XCTAssertTrue(ChainComparisonPresentation(state: state).canApply(state.results[0]))
        state.waitingReason = "network-unavailable"
        XCTAssertFalse(ChainComparisonPresentation(state: state).canApply(state.results[0]))
        state.waitingReason = nil; state.stale = true
        XCTAssertFalse(ChainComparisonPresentation(state: state).canApply(state.results[0]))
        state.stale = false; state.results[0].balancedScore = nil
        XCTAssertFalse(ChainComparisonPresentation(state: state).canApply(state.results[0]))
        XCTAssertTrue(ChainComparisonPresentation(state: state).canApply(state.results[0], strategy: "download"))
        state.results[0].status = "unstable"
        XCTAssertFalse(ChainComparisonPresentation(state: state).canApply(state.results[0]))
    }
    func test_units_and_age_are_explicit_and_invalid_numbers_never_look_fast() {
        XCTAssertEqual(ChainComparisonPresentation.number(.infinity), "—")
        XCTAssertEqual(ChainComparisonPresentation.number(-1), "—")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-120))
        XCTAssertEqual(ChainComparisonPresentation.relativeTime(stamp, now: now), "2 分钟前")
        XCTAssertEqual(ChainComparisonPresentation.relativeTime(nil, now: now), "未测试")
    }
    func test_waiting_and_natural_completion_have_distinct_statuses() {
        var state = sample(); state.running = true; state.waitingReason = "sleeping"
        XCTAssertTrue(ChainComparisonPresentation(state: state).phase.contains("自动继续"))
        state.running = false; state.stopReason = "completed"
        XCTAssertEqual(ChainComparisonPresentation(state: state).phase, "本轮已完成")
        state.stopReason = "user-paused"
        XCTAssertEqual(ChainComparisonPresentation(state: state).phase, "已暂停")
    }
}
