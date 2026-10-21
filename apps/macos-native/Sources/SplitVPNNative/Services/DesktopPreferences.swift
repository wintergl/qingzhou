import AppKit
import Combine

@MainActor
final class DesktopPreferences: ObservableObject {
    static let dockKey = "showDockIcon"
    let defaults: UserDefaults
    private let applyPolicy: @MainActor (Bool) -> Void
    @Published var showDockIcon: Bool {
        didSet {
            guard showDockIcon != oldValue else { return }
            defaults.set(showDockIcon, forKey: Self.dockKey)
            apply()
        }
    }
    init(defaults: UserDefaults = .standard, applyPolicy: (@MainActor (Bool) -> Void)? = nil) {
        self.defaults = defaults
        self.applyPolicy = applyPolicy ?? { NSApplication.shared.setActivationPolicy($0 ? .regular : .accessory) }
        showDockIcon = defaults.object(forKey: Self.dockKey) as? Bool ?? true
    }
    func apply() { applyPolicy(showDockIcon) }
}
