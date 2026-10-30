import XCTest
@testable import SplitVPNNative

final class ChainWorkflowPresentationTests: XCTestCase {
    private func sample() -> ChainWorkflowPresentation {
        let row = ChainScanRow(identityKey: "one", nodeName: "示例线路", status: "available", latencyMs: 100, jitterMs: 10, downloadMbps: 20,
            latencySuccesses: 3, latencyAttempts: 3, downloadSuccesses: 2, downloadAttempts: 2, exitIp: "203.0.113.8", errors: [], balancedScore: 60)
        let state = ChainScanState(id: "fixture", results: [row], stale: false, recommendedIdentityKey: "one", canUseCachedResults: true)
        return ChainWorkflowPresentation(state: state, row: row)
    }
    func test_missing_connection_requirements_offer_preparation_instead_of_a_disabled_dead_end() {
        var model = sample(); model.vpnRunning = false; model.ispEnabled = false
        XCTAssertEqual(model.action, .prepare); XCTAssertTrue(model.primaryEnabled)
        XCTAssertEqual(model.title, "使用这条线路")
        model.vpnRunning = true; model.ispEnabled = true
        XCTAssertEqual(model.action, .connect)
    }
    func test_missing_setup_and_untested_results_have_actionable_next_steps() {
        var model = sample(); model.configured = false
        XCTAssertEqual(model.action, .configure); XCTAssertTrue(model.primaryEnabled)
        model.configured = true; model.candidateCount = 0
        XCTAssertEqual(model.action, .subscriptions)
        model.candidateCount = 1; model.row = nil
        XCTAssertEqual(model.action, .start)
        model.row = sample().row; model.row?.status = "pending"
        XCTAssertEqual(model.action, .retest); XCTAssertTrue(model.primaryEnabled)
        XCTAssertFalse(model.showSecondaryRetest)
    }
    func test_background_retest_can_queue_without_pausing_and_cannot_be_duplicated() {
        var model = sample(); model.state.running = true; model.state.mode = "continuous"
        XCTAssertTrue(model.retestAvailable); XCTAssertEqual(model.retestTitle, "优先重测")
        model.row?.status = "unstable"
        XCTAssertEqual(model.action, .queue); XCTAssertTrue(model.primaryEnabled)
        model.state.queuedIdentityKeys = ["one"]
        XCTAssertFalse(model.primaryEnabled); XCTAssertFalse(model.retestAvailable)
        XCTAssertEqual(model.title, "已加入测试队列")
    }
    func test_finite_scan_and_waiting_never_trigger_an_implicit_cancel_or_connection() {
        var model = sample(); model.state.running = true; model.state.mode = "full"; model.state.canUseCachedResults = false
        XCTAssertEqual(model.action, .blocked); XCTAssertFalse(model.primaryEnabled)
        model.state.waitingReason = "network-unavailable"
        XCTAssertEqual(model.action, .blocked); XCTAssertFalse(model.retestAvailable)
        model.state.running = false; model.state.waitingReason = nil; model.state.canUseCachedResults = true
        model.protectedConnection = true
        XCTAssertFalse(model.primaryEnabled)
    }
    func test_applied_route_is_not_reconnected_and_legacy_applied_marker_is_checked_against_actual_route() {
        var model = sample(); model.state.connectedIdentityKey = "one"; model.currentIdentity = "one"
        XCTAssertEqual(model.action, .current); XCTAssertFalse(model.primaryEnabled); XCTAssertTrue(model.retestAvailable)
        model.currentIdentity = "other"
        XCTAssertEqual(model.action, .connect)
    }
    func test_untested_nodes_can_be_prioritized_during_finite_scans_without_enabling_connection() {
        var model = sample(); model.row?.status = "pending"
        model.state.results = []; model.state.running = true; model.state.mode = "full"
        model.state.canUseCachedResults = false; model.state.candidateIdentityKeys = ["one", "two"]
        XCTAssertEqual(model.action, .queue); XCTAssertTrue(model.primaryEnabled)
        XCTAssertEqual(model.title, "优先测试这条"); XCTAssertFalse(model.showSecondaryRetest)
        model.state.queuedIdentityKeys = ["one"]
        XCTAssertFalse(model.primaryEnabled)
        model.state.queuedIdentityKeys = []; model.state.testing = true; model.state.currentNode = "示例线路"
        XCTAssertFalse(model.primaryEnabled)
        model.state.testing = false; model.state.candidateIdentityKeys = ["two"]
        XCTAssertFalse(model.primaryEnabled); XCTAssertTrue(model.guidance.contains("本轮范围"))
        model.state.running = false
        XCTAssertEqual(model.action, .retest); XCTAssertTrue(model.primaryEnabled)
    }

    func test_current_route_with_failed_or_pending_verification_can_be_rechecked_without_a_speed_test() {
        var model = sample(); model.currentIdentity = "one"; model.state.connectedIdentityKey = "one"
        model.state.routine = ChainRoutineState(verification: ChainVerificationState(status: "failed"))
        XCTAssertEqual(model.action, .connect); XCTAssertEqual(model.title, "复核当前线路")
        XCTAssertTrue(model.primaryEnabled)
        model.state.routine?.verification.status = "pending"
        XCTAssertEqual(model.action, .connect)
        model.state.routine?.verification.status = "passed"
        XCTAssertEqual(model.action, .current)
    }

    func test_uncertain_recovery_routes_to_connection_check_instead_of_another_switch() {
        var model = sample(); model.recoveryRequired = true
        XCTAssertEqual(model.action, .recover)
        XCTAssertEqual(model.title, "检查连接")
        XCTAssertTrue(model.primaryEnabled)
        XCTAssertFalse(model.showSecondaryRetest)
    }

}
