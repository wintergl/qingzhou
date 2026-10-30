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
            let completion = ProviderReply<Result<Data?, Error>> { continuation.resume(with: $0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                completion.finish(.failure(CoreError(code: "STATUS_TIMEOUT", message: "隧道状态读取超时，请检查连接")))
            }
            do {
                try session.sendProviderMessage(Data("runtime-status".utf8)) { responseData in completion.finish(.success(responseData)) }
            } catch { completion.finish(.failure(error)) }
        }
        guard let data else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RuntimeStatus.self, from: data)
    }

    func companyMessage(_ message: [String: Any]) async throws -> [String: Any] {
        let manager = try await loadOrCreateManager()
        guard let session = manager.connection as? NETunnelProviderSession else { throw CoreError(code: "NO_TUNNEL", message: "请先连接共享 VPN 隧道") }
        let request = try JSONSerialization.data(withJSONObject: message)
        let data: Data? = try await withCheckedThrowingContinuation { continuation in
            let completion = ProviderReply<Result<Data?, Error>> { continuation.resume(with: $0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { completion.finish(.failure(CoreError(code: "COMPANY_TIMEOUT", message: "接入控制消息超时，请检查连接"))) }
            do { try session.sendProviderMessage(request) { completion.finish(.success($0)) } } catch { completion.finish(.failure(error)) }
        }
        guard let data, let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CoreError(code: "COMPANY_BAD_REPLY", message: "接入控制结果无效") }
        guard response["ok"] as? Bool == true else { throw CoreError(code: "COMPANY_FAILED", message: response["error"] as? String ?? "接入操作失败") }
        return response
    }

    func reloadConfiguration() async throws {
        let manager = try await loadOrCreateManager()
        guard let session = manager.connection as? NETunnelProviderSession else { return }
        try session.sendProviderMessage(Data("reload-config".utf8)) { _ in }
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


/// NEProvider callbacks may arrive after the deadline. Resume the waiter once.
private final class ProviderReply<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Value) -> Void)?
    init(_ completion: @escaping (Value) -> Void) { self.completion = completion }
    func finish(_ value: Value) {
        lock.lock(); let callback = completion; completion = nil; lock.unlock()
        callback?(value)
    }
}
