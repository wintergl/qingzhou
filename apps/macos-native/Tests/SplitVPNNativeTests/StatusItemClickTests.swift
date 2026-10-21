import XCTest
@testable import SplitVPNNative

final class StatusItemClickTests: XCTestCase {
    @MainActor func testSingleClickWaitsForSystemIntervalAndKeepsPanelVisibilityAtPress() {
        let clock = ClickClock()
        var singles: [Bool] = []
        let handler = StatusItemClickHandler(interval: { 0.5 }, schedule: clock.schedule, single: { singles.append($0) }, double: {}, secondary: {})
        handler.pressed(panelVisible: true)
        handler.released(clickCount: 1)
        clock.advance(0.49); XCTAssertTrue(singles.isEmpty)
        clock.advance(0.02); XCTAssertEqual(singles, [true])
        clock.advance(1); XCTAssertEqual(singles.count, 1)
    }
    @MainActor func testDoubleAndTripleClickToggleExactlyOnceAndNeverOpenPanel() {
        let clock = ClickClock()
        var singleCount = 0, doubleCount = 0
        let handler = StatusItemClickHandler(interval: { 0.5 }, schedule: clock.schedule, single: { _ in singleCount += 1 }, double: { doubleCount += 1 }, secondary: {})
        handler.pressed(panelVisible: false); handler.released(clickCount: 1)
        clock.advance(0.1)
        handler.released(clickCount: 2); handler.released(clickCount: 3)
        clock.advance(1)
        XCTAssertEqual(doubleCount, 1); XCTAssertEqual(singleCount, 0)
        // Even a cancelled dispatch item executing late cannot resurrect a single click.
        clock.executeCancelled(); XCTAssertEqual(singleCount, 0)
    }
    @MainActor func testSecondaryClickCancelsSingleAndShowsMenuImmediately() {
        let clock = ClickClock()
        var singles = 0, menus = 0
        let handler = StatusItemClickHandler(interval: { 0.5 }, schedule: clock.schedule, single: { _ in singles += 1 }, double: {}, secondary: { menus += 1 })
        handler.released(clickCount: 1)
        handler.released(clickCount: 1, isSecondary: true)
        XCTAssertEqual(menus, 1)
        clock.advance(1); clock.executeCancelled(); XCTAssertEqual(singles, 0)
    }
    @MainActor func testRepeatedSinglesReplacePendingActionAndTerminationCancelsIt() {
        let clock = ClickClock()
        var singles: [Bool] = []
        let handler = StatusItemClickHandler(interval: { 0.5 }, schedule: clock.schedule, single: { singles.append($0) }, double: {}, secondary: {})
        handler.pressed(panelVisible: false); handler.released(clickCount: 1)
        clock.advance(0.2)
        handler.pressed(panelVisible: true); handler.released(clickCount: 1)
        clock.advance(0.51); XCTAssertEqual(singles, [true])
        handler.released(clickCount: 1); handler.cancel()
        clock.advance(1); clock.executeCancelled(); XCTAssertEqual(singles, [true])
    }
}

@MainActor
private final class ClickClock {
    private var now = 0.0
    private var jobs: [(UUID, Double, () -> Void)] = []
    private var cancelled: Set<UUID> = []
    func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> (() -> Void) {
        let id = UUID(); jobs.append((id, now + delay, action))
        return { self.cancelled.insert(id) }
    }
    func advance(_ time: TimeInterval) {
        now += time
        for job in jobs where job.1 <= now && !cancelled.contains(job.0) { job.2() }
        jobs.removeAll { $0.1 <= now && !cancelled.contains($0.0) }
    }
    func executeCancelled() { for job in jobs where cancelled.contains(job.0) { job.2() } }
}
