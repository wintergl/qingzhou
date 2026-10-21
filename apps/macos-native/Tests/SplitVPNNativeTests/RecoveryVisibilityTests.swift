import XCTest
@testable import SplitVPNNative

final class RecoveryVisibilityTests: XCTestCase {
    func testUptimeUsesProcessTimeAndHandlesMissingOrFutureValues() throws {
        let start = try XCTUnwrap(RuntimeTime.parse("2026-10-13T12:00:00Z"))
        XCTAssertEqual(RuntimeTime.uptime("2026-10-13T12:00:00Z", at: start.addingTimeInterval(8280)), "2 小时 18 分钟")
        XCTAssertEqual(RuntimeTime.uptime(nil, at: start), "时长暂不可读取")
        XCTAssertEqual(RuntimeTime.uptime("2026-10-13T12:00:00Z", at: start.addingTimeInterval(-60)), "不足 1 分钟")
        XCTAssertEqual(RuntimeTime.uptime("2026-10-13T12:00:00Z", at: start.addingTimeInterval(90000)), "1 天 1 小时 0 分钟")
    }
    func testOldCoreDecodingAndRecoveredDoesNotMeanVerified() throws {
        let old = try JSONDecoder().decode(NetworkRecoveryStatus.self, from: Data(#"{"state":"ready","attempts":0}"#.utf8))
        XCTAssertNil(old.history)
        let current = try JSONDecoder().decode(NetworkRecoveryStatus.self, from: Data(#"{"state":"ready","history":[{"id":1,"startedAt":"2026-10-13T12:00:00Z","finishedAt":"2026-10-13T12:00:05Z","durationMs":5000,"reason":"wake","outcome":"unverified","attempts":0}]}"#.utf8))
        XCTAssertEqual(current.latest?.title, "分流已恢复 · 代理访问尚未确认")
        XCTAssertEqual(current.latest?.durationText, "5 秒")
    }
}
