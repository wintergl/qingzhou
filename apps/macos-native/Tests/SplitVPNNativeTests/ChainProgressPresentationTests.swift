import XCTest
@testable import SplitVPNNative

final class ChainProgressPresentationTests: XCTestCase {
    func test_scoped_core_snapshot_supplies_its_own_winners_and_ranks() {
        let row = ChainScanRow(identityKey: "a", nodeName: "示例 A", status: "available", latencySuccesses: 3, latencyAttempts: 3, downloadSuccesses: 2, downloadAttempts: 2, errors: [], rank: 1, comparisonReason: "相对当前线路：下载快 35%")
        var state = ChainScanState(recommendedIdentityKey: "outside")
        state.view = ChainScanScopeView(subscriptionId: "one", results: [row], leaders: ChainLeaders(balanced: "a", download: "a", latency: "a"), recommendedIdentityKey: "a")
        XCTAssertEqual(state.scoped(to: "one").results.first?.rank, 1)
        XCTAssertEqual(state.scoped(to: "one").recommendedIdentityKey, "a")
        XCTAssertEqual(state.scoped(to: "one").results.first?.comparisonReason, "相对当前线路：下载快 35%")
        XCTAssertTrue(state.scoped(to: "two").results.isEmpty)
        XCTAssertNil(state.scoped(to: "two").leaders)
        XCTAssertEqual(state.scoped(to: "").recommendedIdentityKey, "outside")
    }
    func test_finite_progress_and_real_stage_are_formatted_without_using_saved_row_count() {
        var state = ChainScanState(running: true, mode: "accumulate")
        state.progress = ChainScanProgress(total: 30, completed: 12, remaining: 18, estimatedSeconds: 95, stage: "download", stageAttempt: 1, stageTotal: 2, currentNode: "示例 A")
        let model = ChainProgressPresentation(state: state)
        XCTAssertEqual(model.title, "已处理 12/30 条 · 剩余 18 条")
        XCTAssertEqual(model.timing, "预计还需约 2 分钟")
        XCTAssertEqual(model.phase, "下载采样 1/2 · 示例 A")
        state.waitingReason = "network-unavailable"
        XCTAssertNil(ChainProgressPresentation(state: state).timing)
        XCTAssertTrue(ChainProgressPresentation(state: state).phase.contains("自动继续"))
    }
    func test_continuous_coverage_does_not_claim_an_end_time_and_other_scope_is_explicit() {
        var state = ChainScanState(running: true, mode: "continuous")
        state.progress = ChainScanProgress(total: 3, completed: 3, remaining: 0, estimatedSeconds: 10)
        XCTAssertTrue(ChainProgressPresentation(state: state).title.contains("已覆盖"))
        XCTAssertEqual(ChainProgressPresentation(state: state).timing, "持续复测 · 可随时暂停")
        state.progress?.testingOtherScope = true
        XCTAssertEqual(ChainProgressPresentation(state: state).phase, "后台正在测试其他订阅")
        state.running = false; state.stopReason = "user-paused"
        XCTAssertNil(ChainProgressPresentation(state: state).timing)
        XCTAssertEqual(ChainProgressPresentation(state: state).phase, "已暂停")
    }
    func test_automatic_maintenance_has_no_false_completion_deadline_and_pause_is_explicit() {
        var state = ChainScanState(running: true, mode: "continuous")
        state.automatic = true; state.progress = ChainScanProgress(total: 10, completed: 0, remaining: 10)
        XCTAssertEqual(ChainProgressPresentation(state: state).title, "日常自动刷新 · 少量抽测")
        XCTAssertEqual(ChainProgressPresentation(state: state).phase, "正在安排本批线路")
        state.waitingReason = "low-power"
        XCTAssertTrue(ChainProgressPresentation(state: state).phase.contains("低电量"))
        XCTAssertNil(ChainProgressPresentation(state: state).timing)
        let paused = ChainAutoRefreshState(enabled: true, intervalMinutes: 30, paused: true, status: "paused")
        XCTAssertEqual(paused.title, "维护已暂停")
        XCTAssertTrue(paused.message.contains("保留"))
        XCTAssertTrue(ChainAutoRefreshState(status: "needs-credential").message.contains("账号"))
    }

}
