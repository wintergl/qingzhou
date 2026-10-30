import XCTest
@testable import SplitVPNNative

final class ChainRecommendationPresentationTests: XCTestCase {
    private func completed() -> ChainScanState {
        ChainScanState(id: "fixture", completed: 1, total: 1,
            results: [ChainScanRow(identityKey: "best", nodeName: "示例机场", status: "available", latencyMs: 100, jitterMs: 10, downloadMbps: 20,
                                  latencySuccesses: 3, latencyAttempts: 3, downloadSuccesses: 2, downloadAttempts: 2, exitIp: "203.0.113.8", errors: [], balancedScore: 90)],
            stale: false, recommendedIdentityKey: "best", recommendationSummary: "本轮综合表现排名第一。")
    }
    func test_conclusion_names_the_recommendation_without_leading_with_score() {
        let presentation = ChainRecommendationPresentation(completed())
        XCTAssertEqual(presentation.title, "本轮推荐：示例机场 → ISP")
        XCTAssertEqual(presentation.detail, "本轮综合表现排名第一。")
        XCTAssertFalse((presentation.title + presentation.detail).contains("90"))
    }
    func test_partial_expired_cancelled_and_failed_scans_never_show_a_final_recommendation() {
        for kind in ["running", "stale", "cancelled", "error"] {
            var state = completed()
            switch kind {
            case "running": state.running = true
            case "stale": state.stale = true
            case "cancelled": state.cancelled = true
            default: state.error = "模拟失败"
            }
            let presentation = ChainRecommendationPresentation(state)
            XCTAssertNil(presentation.node)
            XCTAssertFalse(presentation.title.hasPrefix("本轮推荐"))
        }
    }
    func test_connected_recommendation_is_identified_as_connected() {
        var state = completed()
        state.connectedIdentityKey = "best"
        XCTAssertEqual(ChainRecommendationPresentation(state).title, "已连接：示例机场 → ISP")
    }
    func test_continuous_testing_can_recommend_valid_accumulated_results_while_running_or_paused() {
        var state = completed()
        state.mode = "continuous"; state.canUseCachedResults = true; state.running = true
        let running = ChainRecommendationPresentation(state)
        XCTAssertNotNil(running.node)
        XCTAssertTrue(running.title.hasPrefix("当前推荐"))
        XCTAssertTrue(running.detail.contains("后台继续测试"))
        state.running = false; state.cancelled = true
        let paused = ChainRecommendationPresentation(state)
        XCTAssertNotNil(paused.node)
        XCTAssertTrue(paused.detail.contains("后台已暂停"))
        state.stale = true
        XCTAssertNil(ChainRecommendationPresentation(state).node)
    }

    func test_old_success_remains_a_reference_with_mandatory_verification_copy() {
        var state = completed()
        state.results[0].requiresRefresh = true
        let presentation = ChainRecommendationPresentation(state)
        XCTAssertNotNil(presentation.node)
        XCTAssertTrue(presentation.title.hasPrefix("上次已测推荐"))
        XCTAssertTrue(presentation.detail.contains("复核连通性和出口"))
        state.stale = true
        let unrelated = ChainRecommendationPresentation(state)
        XCTAssertNil(unrelated.node)
        XCTAssertTrue(unrelated.detail.contains("性能成绩仍保留"))
    }

    func test_waiting_for_network_or_wake_is_not_presented_as_cancellation() {
        for reason in ["network-unavailable", "sleeping"] {
            var state = completed()
            state.running = true; state.waitingReason = reason; state.stale = true
            let presentation = ChainRecommendationPresentation(state)
            XCTAssertTrue(presentation.title.contains("自动继续"))
            XCTAssertNil(presentation.node)
        }
        var changed = completed()
        changed.cancelled = true; changed.stopReason = "configuration-changed"
        XCTAssertTrue(ChainRecommendationPresentation(changed).title.contains("配置或订阅"))
    }

}
