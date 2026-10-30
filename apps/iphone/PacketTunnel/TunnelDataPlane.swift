import Foundation
import NetworkExtension

enum TunnelDataPlaneError: LocalizedError {
    case providerReleased
    case missingCore
    case missingGeneratedConfig
    case missingSingBoxConfig

    var errorDescription: String? {
        switch self {
        case .providerReleased:
            return "Packet Tunnel Provider 已释放"
        case .missingCore:
            return "iOS 数据面核心尚未接入：需要 Mihomo / sing-box / tun2socks framework 后才能真正转发 iPhone 流量"
        case .missingGeneratedConfig:
            return "缺少生成后的隧道配置，请先在主 App 更新订阅或保存规则"
        case .missingSingBoxConfig:
            return "缺少 generated/sing-box.json，无法启动 iOS 数据面核心"
        }
    }
}

protocol PacketTunnelCore {
    func start(options: PacketTunnelCoreStartOptions) throws
    func restart(options: PacketTunnelCoreStartOptions) throws
    func updatePower(sleeping: Bool, lowPower: Bool)
    func stop()
}

extension PacketTunnelCore {
    func updatePower(sleeping: Bool, lowPower: Bool) {}

    func restart(options: PacketTunnelCoreStartOptions) throws {
        stop()
        try start(options: options)
    }
}

struct PacketTunnelCoreStartOptions {
    let packetFlow: NEPacketTunnelFlow
    let configPath: URL
    let workingDirectory: URL
    let selectedProxy: String
    let diagnosticsSettings: DiagnosticsSettings
    let onTrafficUpdate: @Sendable (RuntimeTrafficSnapshot) -> Void
    let onLogMessage: @Sendable (String) -> Void
}

final class MissingPacketTunnelCore: PacketTunnelCore {
    func start(options: PacketTunnelCoreStartOptions) throws {
        _ = options
        throw TunnelDataPlaneError.missingCore
    }

    func stop() {
    }
}

enum PacketTunnelCoreFactory {
    static func makeDefault() -> PacketTunnelCore {
        #if canImport(Libbox)
        return LibboxPacketTunnelCore()
        #else
        return MissingPacketTunnelCore()
        #endif
    }
}

final class TunnelDataPlane {
    private let packetFlow: NEPacketTunnelFlow
    private var config: GeneratedTunnelConfig?
    private let selectedProxy: String
    private let store: AppGroupStore
    private let core: PacketTunnelCore
    private let diagnosticsSettings: DiagnosticsSettings
    private let onTrafficUpdate: @Sendable (RuntimeTrafficSnapshot) -> Void
    private let onLogMessage: @Sendable (String) -> Void

    init(
        packetFlow: NEPacketTunnelFlow,
        config: GeneratedTunnelConfig?,
        selectedProxy: String,
        diagnosticsSettings: DiagnosticsSettings,
        onTrafficUpdate: @escaping @Sendable (RuntimeTrafficSnapshot) -> Void,
        onLogMessage: @escaping @Sendable (String) -> Void,
        store: AppGroupStore = .shared,
        core: PacketTunnelCore = PacketTunnelCoreFactory.makeDefault()
    ) {
        self.packetFlow = packetFlow
        self.config = config
        self.selectedProxy = selectedProxy
        self.diagnosticsSettings = diagnosticsSettings
        self.onTrafficUpdate = onTrafficUpdate
        self.onLogMessage = onLogMessage
        self.store = store
        self.core = core
    }

    func start() throws {
        try core.start(options: makeStartOptions())
    }

    var desiredMTU: Int { store.readGeneratedConfig()?.packetTunnelMTU ?? store.readSettings().packetTunnelMTU }
    var configurationRevision: String? { config?.runtimeRevision }

    func restart() throws {
        let previous = config
        config = store.readGeneratedConfig() ?? config
        do { try core.restart(options: makeStartOptions()) }
        catch {
            config = previous
            // A rejected candidate must not silently become the active profile.
            try? core.restart(options: makeStartOptions())
            throw error
        }
    }

    func updatePower(sleeping: Bool, lowPower: Bool) {
        core.updatePower(sleeping: sleeping, lowPower: lowPower)
    }

    private func makeStartOptions() throws -> PacketTunnelCoreStartOptions {
        guard let config else {
            throw TunnelDataPlaneError.missingGeneratedConfig
        }
        guard let singBoxJSON = config.singBoxJSON, !singBoxJSON.isEmpty else {
            throw TunnelDataPlaneError.missingSingBoxConfig
        }

        let configURL = try store.saveActiveTunnelConfig(singBoxJSON)

        return PacketTunnelCoreStartOptions(
            packetFlow: packetFlow,
            configPath: configURL,
            workingDirectory: store.url("runtime"),
            selectedProxy: config.selectedProxy,
            diagnosticsSettings: diagnosticsSettings,
            onTrafficUpdate: onTrafficUpdate,
            onLogMessage: onLogMessage
        )
    }

    func stop() {
        core.stop()
    }
}
