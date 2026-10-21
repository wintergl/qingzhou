import Foundation
import NetworkExtension

final class SplitVpnVPNManager {
    private var manager: NETunnelProviderManager?
    private let store: AppGroupStore

    init(store: AppGroupStore = .shared) {
        self.store = store
    }

    func installOrUpdateTunnel() async throws {
        store.appendLog(
            level: "info",
            message: "VPN install/update begin provider=\(SplitVpnConstants.providerBundleIdentifier) appGroup=\(SplitVpnConstants.appGroupIdentifier)"
        )
        let manager = try await loadOrCreateManager()
        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = SplitVpnConstants.providerBundleIdentifier
        tunnelProtocol.serverAddress = SplitVpnConstants.vpnDescription
        tunnelProtocol.disconnectOnSleep = false
        tunnelProtocol.providerConfiguration = [
            "appGroupIdentifier": SplitVpnConstants.appGroupIdentifier
        ]
        manager.protocolConfiguration = tunnelProtocol
        manager.localizedDescription = SplitVpnConstants.vpnDescription
        manager.isEnabled = true
        store.appendLog(level: "debug", message: "VPN saveToPreferences begin")
        try await save(manager)
        store.appendLog(level: "debug", message: "VPN loadFromPreferences begin")
        try await load(manager)
        self.manager = manager
        store.appendLog(
            level: "info",
            message: "VPN install/update completed enabled=\(manager.isEnabled) status=\(Self.describe(manager.connection.status))"
        )
    }

    func startTunnel() async throws {
        store.appendLog(level: "info", message: "VPN start begin")
        var manager = try await loadOrCreateManager()
        store.appendLog(
            level: "debug",
            message: "VPN loaded manager enabled=\(manager.isEnabled) status=\(Self.describe(manager.connection.status)) provider=\((manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier ?? "-")"
        )
        if !manager.isEnabled {
            try await installOrUpdateTunnel()
            manager = try await loadOrCreateManager()
        }
        try store.setTunnelRequested(true)
        manager = try await setOnDemandEnabled(true, manager: manager)
        let options = makeStartOptions()
        store.appendLog(level: "debug", message: "VPN start options \(describeStartOptions(options))")
        guard !Self.isRunning(manager.connection.status) else {
            store.appendLog(level: "info", message: "VPN start skipped status=\(Self.describe(manager.connection.status))")
            return
        }
        try manager.connection.startVPNTunnel(options: options)
        store.appendLog(level: "info", message: "VPN startVPNTunnel returned status=\(Self.describe(manager.connection.status))")
    }

    func stopTunnel() async {
        do { try store.setTunnelRequested(false) }
        catch { store.appendLog(level: "warn", message: "Unable to persist VPN stop intent") }
        manager?.connection.stopVPNTunnel()
        do {
            let manager = try await setOnDemandEnabled(false, manager: try await loadOrCreateManager())
            manager.connection.stopVPNTunnel()
            store.appendLog(level: "info", message: "VPN stop requested with on-demand disabled")
        } catch {
            store.appendLog(level: "warn", message: "VPN disable on-demand before stop failed: \(error.localizedDescription)")
            manager?.connection.stopVPNTunnel()
        }
    }

    func currentStatus() async throws -> NEVPNStatus {
        let manager = try await loadOrCreateManager()
        self.manager = manager
        return manager.connection.status
    }

    func extensionRuntimeStatus() async throws -> RuntimeStatus? {
        let manager = try await loadOrCreateManager()
        guard let session = manager.connection as? NETunnelProviderSession else {
            return nil
        }
        let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            do {
                try session.sendProviderMessage(Data("runtime-status".utf8)) { responseData in
                    continuation.resume(returning: responseData)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        guard let data else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RuntimeStatus.self, from: data)
    }

    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        let managers = try await Self.loadAll()
        if let existing = managers.first(where: { $0.localizedDescription == SplitVpnConstants.vpnDescription }) {
            self.manager = existing
            return existing
        }
        let next = NETunnelProviderManager()
        self.manager = next
        return next
    }

    private static func loadAll() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: managers ?? [])
                }
            }
        }
    }

    private func save(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func load(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func setOnDemandEnabled(
        _ enabled: Bool,
        manager: NETunnelProviderManager
    ) async throws -> NETunnelProviderManager {
        if enabled {
            manager.protocolConfiguration?.disconnectOnSleep = false
            let rule = NEOnDemandRuleConnect()
            rule.interfaceTypeMatch = .any
            manager.onDemandRules = [rule]
        } else {
            manager.onDemandRules = []
        }
        manager.isOnDemandEnabled = enabled

        try await save(manager)
        try await load(manager)
        self.manager = manager
        store.appendLog(level: "info", message: "VPN on-demand \(enabled ? "enabled" : "disabled")")
        return manager
    }

    private func makeStartOptions() -> [String: NSObject] {
        let diagnostics = store.readDiagnosticsSettings()
        var options: [String: NSObject] = [
            "appGroupIdentifier": SplitVpnConstants.appGroupIdentifier as NSString,
            "systemProxyEnabled": NSNumber(value: true),
            "includeAllNetworks": NSNumber(value: false),
            "excludeDefaultRoute": NSNumber(value: false),
            "autoRouteUseSubRangesByDefault": NSNumber(value: true),
            "excludeAPNsRoute": NSNumber(value: true),
            "diagnosticsMode": diagnostics.mode.rawValue as NSString
        ]

        if let expiresAt = diagnostics.expiresAt {
            options["diagnosticsExpiresAt"] = NSNumber(value: expiresAt.timeIntervalSince1970)
        }

        if let configContent = store.readGeneratedConfig()?.singBoxJSON, !configContent.isEmpty {
            options["configContent"] = configContent as NSString
        }

        return options
    }

    private func describeStartOptions(_ options: [String: NSObject]) -> String {
        let configBytes = (options["configContent"] as? String)?.utf8.count ?? 0
        let keys = options.keys.sorted().joined(separator: ",")
        return "keys=\(keys) config_bytes=\(configBytes)"
    }

    private static func describe(_ status: NEVPNStatus) -> String {
        switch status {
        case .connected:
            return "connected"
        case .connecting:
            return "connecting"
        case .disconnecting:
            return "disconnecting"
        case .disconnected:
            return "disconnected"
        case .invalid:
            return "invalid"
        case .reasserting:
            return "reasserting"
        @unknown default:
            return "unknown"
        }
    }

    private static func isRunning(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connected, .connecting, .reasserting:
            return true
        case .disconnecting, .disconnected, .invalid:
            return false
        @unknown default:
            return false
        }
    }
}
