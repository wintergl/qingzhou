import AppKit
import Network
import SystemConfiguration

/// Ignore initial/duplicate snapshots and TUN-only changes caused by our own
/// reloads. IP/gateway changes are still checked by the shared Rust core.
struct PhysicalPathChanges {
    private var previous: String?
    mutating func update(available: Bool, interfaces: [String]) -> Bool {
        // A satisfied path exposing only a tunnel says nothing new about the
        // underlying physical interface; System Configuration remains observed.
        guard !available || !interfaces.isEmpty else { return false }
        let signature = "\(available)|\(interfaces.sorted().joined(separator: ","))"
        defer { previous = signature }
        return previous != nil && previous != signature
    }
}

/// Only physical addressing/link identities are relevant. DNS and utun updates
/// made by our own reload must never trigger another reload. Kept in memory only.
struct PhysicalConfigurationChanges {
    private var previous: Data?
    private var physicalGlobals: [String: [String: Any]] = [:]
    mutating func update(_ values: [String: [String: Any]]) -> Bool {
        var stable = values.filter { !$0.key.hasPrefix("State:/Network/Global/") }
        for (key, value) in values where key.hasPrefix("State:/Network/Global/") {
            if let name = value["PrimaryInterface"] as? String, name.hasPrefix("en") || name.hasPrefix("eth") {
                physicalGlobals[key] = value
            }
        }
        // A temporary utun primary route during reload is not a physical change.
        stable.merge(physicalGlobals) { _, latest in latest }
        let current = Self.fingerprint(stable)
        defer { previous = current }
        return previous != nil && previous != current
    }
    static func fingerprint(_ values: [String: [String: Any]]) -> Data {
        var selected: [String: [String: Any]] = [:]
        for (key, value) in values {
            let parts = key.split(separator: "/").map(String.init)
            guard let entity = parts.last, ["IPv4", "IPv6", "Link", "AirPort"].contains(entity) else { continue }
            let name = value["InterfaceName"] as? String ?? value["PrimaryInterface"] as? String
                ?? (parts.count == 5 && parts[2] == "Interface" ? parts[3] : "")
            guard name.hasPrefix("en") || name.hasPrefix("eth") else { continue }
            var fields: [String: Any] = ["InterfaceName": name]
            for field in ["Addresses", "SubnetMasks", "Router", "Active", "SSID_STR", "BSSID", "NetworkID"] {
                if let bytes = value[field] as? Data { fields[field] = bytes.base64EncodedString() }
                else if let list = value[field] as? [String] { fields[field] = list.sorted() }
                else if let text = value[field] as? String { fields[field] = text }
                else if let number = value[field] as? NSNumber { fields[field] = number }
            }
            selected[key] = fields
        }
        return (try? JSONSerialization.data(withJSONObject: selected, options: [.sortedKeys])) ?? Data()
    }
}

private final class ConfigurationCallback {
    let changed: () -> Void
    init(_ changed: @escaping () -> Void) { self.changed = changed }
}

@MainActor
final class NativeNetworkChangeService {
    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "dev.split-vpn.physical-network", qos: .utility)
    private var changes = PhysicalPathChanges()
    private var configurationChanges = PhysicalConfigurationChanges()
    private var configuration: SCDynamicStore?
    private var delivery: Task<Void, Never>?
    private var available: Bool?
    private var generation = UUID()
    private var onChange: ((Bool?) -> Void)?
    private static let patterns = ["State:/Network/Global/IPv[46]",
                                   "State:/Network/Service/[^/]+/IPv[46]",
                                   "State:/Network/Interface/[^/]+/(IPv[46]|Link|AirPort)"]

    @discardableResult func start(onChange: @escaping (Bool?) -> Void) -> Bool {
        stop()
        changes = PhysicalPathChanges(); configurationChanges = PhysicalConfigurationChanges()
        self.onChange = onChange
        let generation = self.generation
        let monitor = NWPathMonitor(); self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let interfaces = path.availableInterfaces.filter {
                [.wifi, .wiredEthernet, .cellular].contains($0.type) && path.usesInterfaceType($0.type)
            }.map(\.name)
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.available = available
                if self.changes.update(available: available, interfaces: interfaces) { self.scheduleChange() }
            }
        }
        monitor.start(queue: queue)
        let callback = ConfigurationCallback { [weak self] in
            Task { @MainActor [weak self] in self?.configurationChanged() }
        }
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { pointer in
                _ = Unmanaged<ConfigurationCallback>.fromOpaque(pointer).retain(); return pointer
            }, release: { pointer in
                Unmanaged<ConfigurationCallback>.fromOpaque(pointer).release()
            }, copyDescription: nil)
        guard let configuration = SCDynamicStoreCreate(nil, "dev.split-vpn.network" as CFString, { _, _, info in
            guard let info else { return }
            Unmanaged<ConfigurationCallback>.fromOpaque(info).takeUnretainedValue().changed()
        }, &context), SCDynamicStoreSetNotificationKeys(configuration, nil, Self.patterns as CFArray),
              SCDynamicStoreSetDispatchQueue(configuration, .main) else { return false }
        self.configuration = configuration
        configurationChanged()
        return true
    }
    private func configurationChanged() {
        guard let configuration else { return }
        let values = SCDynamicStoreCopyMultiple(configuration, nil, Self.patterns as CFArray) as? [String: [String: Any]] ?? [:]
        if configurationChanges.update(values) { scheduleChange() }
    }
    private func scheduleChange() {
        delivery?.cancel()
        delivery = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250), tolerance: .milliseconds(100)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.onChange?(self.available)
        }
    }

    func stop() {
        generation = UUID()
        onChange = nil
        delivery?.cancel(); delivery = nil
        monitor?.cancel(); monitor = nil
        if let configuration { SCDynamicStoreSetDispatchQueue(configuration, nil) }
        configuration = nil; available = nil
    }
}
