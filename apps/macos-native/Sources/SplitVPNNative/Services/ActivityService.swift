import AppKit

struct DesktopActivity: Equatable {
    var visible = false
    var lowPower = false
    var sleeping = false

    func pollingInterval(statusKnown: Bool, running: Bool) -> Duration? {
        guard !sleeping else { return nil }
        if !statusKnown { return .seconds(visible ? 5 : 30) }
        guard visible, running else { return nil }
        return .seconds(lowPower ? 5 : 2)
    }
}

/// Notifications only: no repeating visibility, battery, or sleep timer.
@MainActor
final class NativeActivityService {
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var activity = DesktopActivity()
    private var onChange: ((DesktopActivity) -> Void)?
    private let center: NotificationCenter
    private let workspace: NotificationCenter
    private let readState: () -> (visible: Bool, lowPower: Bool)

    init(center: NotificationCenter = .default,
         workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         readState: (() -> (visible: Bool, lowPower: Bool))? = nil) {
        self.center = center; self.workspace = workspace
        self.readState = readState ?? {
            (NSApp?.isHidden != true && (NSApp?.windows.contains {
                $0.isVisible && !$0.isMiniaturized && $0.canBecomeKey && $0.occlusionState.contains(.visible)
            } ?? false), ProcessInfo.processInfo.isLowPowerModeEnabled)
        }
    }

    func start(onChange: @escaping (DesktopActivity) -> Void) {
        stop(); self.onChange = onChange
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                     NSApplication.didBecomeActiveNotification, .NSProcessInfoPowerStateDidChange] {
            observe(center, name) { [weak self] in self?.refresh() }
        }
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] in
            self?.activity.sleeping = true; self?.refresh(force: true)
        }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in
            self?.activity.sleeping = false; self?.refresh(force: true)
        }
        refresh(force: true)
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor () -> Void) {
        observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { _ in
            Task { @MainActor in action() }
        }))
    }
    private func refresh(force: Bool = false) {
        var next = activity
        let state = readState()
        next.lowPower = state.lowPower; next.visible = state.visible
        // Sleep was set by the workspace callback, so always deliver that event.
        if force || next != activity { activity = next; onChange?(next) }
    }
    func stop() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll(); onChange = nil
    }
}
