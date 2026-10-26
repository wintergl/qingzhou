import AppKit
import Combine

/// Owns the shared stores independently of any window's visibility.
@MainActor
final class NativeAppRuntime: ObservableObject {
    let store: VPNStore
    let company: CompanyStore
    let preferences: DesktopPreferences
    let windows: any AppWindowRouting
    @Published private(set) var terminating = false
    @Published private(set) var togglingPersonal = false
    private(set) var started = false
    private var statusBar: StatusBarController?
    private var personalOperation: Task<Void, Never>?
    private var termination: Task<Void, Never>?
    private let terminationLog: (NativeTerminationEvent) -> Void

    init(store: VPNStore, company: CompanyStore, preferences: DesktopPreferences,
         windows: (any AppWindowRouting)? = nil,
         terminationLog: @escaping (NativeTerminationEvent) -> Void = { _ in }) {
        self.store = store; self.company = company; self.preferences = preferences
        self.terminationLog = terminationLog
        self.windows = windows ?? NativeWindowRouter(store: store, company: company, preferences: preferences)
        if let nativeWindows = self.windows as? NativeWindowRouter {
            nativeWindows.onSettingsRequested = { [weak self] in self?.openSettings() }
        }
        company.configure(core: store.core)
        store.onCompanyRouting = { [weak company] state in company?.updateRouting(state) }
        company.onNeedsInteraction = { [weak self] _ in self?.openMain(page: .company) }
    }

    func start(loginLaunch: Bool, installStatusBar: Bool = true) {
        guard !started else { return }
        started = true
        preferences.apply()
        if installStatusBar { statusBar = StatusBarController(runtime: self) }
        company.initializePreferences()
        store.startOnce()
        if !loginLaunch { openMain() }
    }
    func openMain(page: VPNPage? = nil) {
        statusBar?.cancelInteractions()
        windows.openMain(page: page)
    }
    func openSettings() {
        statusBar?.cancelInteractions()
        windows.openSettings()
    }
    func openCompanyDetails() {
        company.requestedInteraction = .certificate
        openMain(page: .company)
    }
    func togglePersonal() {
        guard !terminating, (!togglingPersonal || store.canDisconnect), store.canToggleFromMenu else { return }
        togglingPersonal = true
        personalOperation = Task {
            defer { togglingPersonal = false }
            do { try await store.toggleConnection() }
            catch { if !terminating { openMain() } }
        }
    }
    func toggleCompany() {
        guard !terminating, company.canToggleFromMenu else { return }
        company.requestQuickConnection()
    }
    func refresh() {
        guard !terminating else { return }
        Task { await store.refresh() }
    }
    func checkConnectivity() {
        guard !terminating else { return }
        openMain(page: .diagnostics)
        store.checkConnectivity()
    }

    /// Reply exactly once to AppKit's deferred termination request.
    func requestTermination(helperTimeout: TimeInterval = 10, operationsTimeout: TimeInterval = 15,
                            reply: @escaping (Bool) -> Void) {
        guard !terminating else { return }
        terminating = true
        statusBar?.cancelInteractions()
        store.beginTermination(); company.beginTermination()
        termination = Task {
            var stage = NativeTerminationEvent.Stage.waiting
            @MainActor func record(_ outcome: NativeTerminationEvent.Outcome, error: Error? = nil) {
                terminationLog(NativeTerminationEvent(outcome: outcome, stage: stage,
                    reason: error.map(NativeTerminationEvent.reason), pendingRequests: store.core.pendingRequestCount))
            }
            record(.started)
            do {
                try await TerminationWait.run(timeout: operationsTimeout) {
                    await self.personalOperation?.value
                    guard !Task.isCancelled else { return }
                    await self.store.waitForOperations()
                    guard !Task.isCancelled else { return }
                    await self.company.waitForOperations()
                }
                stage = .company; record(.started)
                try await company.prepareForTermination(timeout: helperTimeout)
                stage = .personal; record(.started)
                try await store.disconnectForTermination()
                stage = .core; record(.started)
                store.close()
                record(.completed)
                reply(true)
            } catch {
                record(.failed, error: error)
                terminating = false
                store.resumeAfterTerminationFailure(); company.resumeAfterTerminationFailure()
                store.error = "退出未完成：\(error.localizedDescription)"
                openMain()
                reply(false)
            }
            termination = nil
        }
    }
    func finish() { statusBar?.remove(); statusBar = nil }
}
