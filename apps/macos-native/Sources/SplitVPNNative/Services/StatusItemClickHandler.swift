import AppKit

/// Keeps the delayed single click independent from AppKit, so the system's
/// double-click interval can be tested without sleeping or controlling a VPN.
@MainActor
final class StatusItemClickHandler {
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> (() -> Void)
    private let interval: () -> TimeInterval
    private let schedule: Schedule
    private let single: (Bool) -> Void
    private let double: () -> Void
    private let secondary: () -> Void
    private var cancelScheduled: (() -> Void)?
    private var pendingID: UUID?
    private var visibleAtPress = false

    init(interval: @escaping () -> TimeInterval = { NSEvent.doubleClickInterval },
         schedule: @escaping Schedule = { delay, action in
             let work = DispatchWorkItem { MainActor.assumeIsolated { action() } }
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
             return { work.cancel() }
         }, single: @escaping (Bool) -> Void, double: @escaping () -> Void, secondary: @escaping () -> Void) {
        self.interval = interval; self.schedule = schedule
        self.single = single; self.double = double; self.secondary = secondary
    }
    func pressed(panelVisible: Bool) { visibleAtPress = panelVisible }
    func released(clickCount: Int, isSecondary: Bool = false) {
        if isSecondary { cancel(); secondary(); return }
        if clickCount == 2 { cancel(); double(); return }
        guard clickCount <= 1 else { return }
        cancel()
        let id = UUID(), wasVisible = visibleAtPress
        pendingID = id
        cancelScheduled = schedule(interval()) { [weak self] in
            guard let self, self.pendingID == id else { return }
            self.pendingID = nil; self.cancelScheduled = nil
            self.single(wasVisible)
        }
    }
    func cancel() {
        pendingID = nil; cancelScheduled?(); cancelScheduled = nil
    }
}
