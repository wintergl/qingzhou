import Foundation
import Network
import NetworkExtension

#if canImport(Libbox)
import Darwin
import Libbox

enum LibboxPacketTunnelCoreError: LocalizedError {
    case setupFailed
    case commandServerUnavailable
    case configValidationFailed
    case tunnelFileDescriptorUnavailable
    case unsupportedPlatformFeature(String)

    var errorDescription: String? {
        switch self {
        case .setupFailed:
            return "Libbox setup failed"
        case .commandServerUnavailable:
            return "Libbox command server unavailable"
        case .configValidationFailed:
            return "Libbox config validation failed"
        case .tunnelFileDescriptorUnavailable:
            return "Libbox 未能获取 Network Extension 的 utun 文件描述符"
        case .unsupportedPlatformFeature(let name):
            return "iOS Packet Tunnel 暂不支持 Libbox 平台能力：\(name)"
        }
    }
}

final class LibboxPacketTunnelCore: NSObject, PacketTunnelCore {
    private var commandServer: LibboxCommandServer?
    private var commandClient: LibboxCommandClient?
    private var commandClientHandler: LibboxDiagnosticsCommandClientHandler?
    private var platformInterface: SplitVpnLibboxPlatformInterface?
    private let store = AppGroupStore.shared
    private let diagnosticsQueue = DispatchQueue(label: "split-vpn.libbox.diagnostics", qos: .utility)
    private var deepDiagnosticsExpiry: DispatchWorkItem?
    private var activeOptions: PacketTunnelCoreStartOptions?
    // These power fields are confined to diagnosticsQueue.
    private var sleeping = false
    private var lowPower = false
    private let callbackLock = NSLock()
    private var serviceStopped: (@Sendable (String) -> Void)?

    func start(options: PacketTunnelCoreStartOptions) throws {
        activeOptions = options
        callbackLock.lock()
        serviceStopped = options.onLogMessage
        callbackLock.unlock()
        let configContent = try String(contentsOf: options.configPath, encoding: .utf8)
        store.appendLog(
            level: "info",
            message: "Libbox starting with \(configContent.utf8.count) config bytes"
        )

        LibboxPrepareCrashSignalHandlers()

        try FileManager.default.createDirectory(
            at: options.workingDirectory,
            withIntermediateDirectories: true
        )
        let tempDirectory = options.workingDirectory.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let setupOptions = LibboxSetupOptions()
        setupOptions.basePath = options.workingDirectory.path
        setupOptions.workingPath = options.workingDirectory.path
        setupOptions.tempPath = tempDirectory.path
        let commandServerListenPort = Int32.random(in: 49_152...65_535)
        setupOptions.commandServerListenPort = commandServerListenPort
        setupOptions.commandServerSecret = UUID().uuidString
        setupOptions.logMaxLines = 50
        setupOptions.debug = false

        store.appendLog(
            level: "info",
            message: "Libbox diagnostics configured transport=tcp host=127.0.0.1 port=\(commandServerListenPort)"
        )

        try callLibboxBool({ LibboxSetup(setupOptions, $0) }, fallback: LibboxPacketTunnelCoreError.setupFailed)
        store.appendLog(level: "info", message: "Libbox setup completed")

        let platformInterface = SplitVpnLibboxPlatformInterface(packetFlow: options.packetFlow)
        var serverError: NSError?
        guard let commandServer = LibboxNewCommandServer(self, platformInterface, &serverError) else {
            throw serverError ?? LibboxPacketTunnelCoreError.commandServerUnavailable
        }
        store.appendLog(level: "info", message: "Libbox command server created")
        // Retain partially started resources so the failure path can close them.
        self.platformInterface = platformInterface
        self.commandServer = commandServer

        try validateConfig(configContent, commandServer: commandServer)

        let overrideOptions = LibboxOverrideOptions()
        try commandServer.startOrReloadService(configContent, options: overrideOptions)
        store.appendLog(level: "info", message: "Libbox service started")

        startDiagnosticsClient(
            commandServer: commandServer,
            settings: options.diagnosticsSettings,
            onTrafficUpdate: options.onTrafficUpdate,
            onLogMessage: options.onLogMessage
        )
    }

    func restart(options: PacketTunnelCoreStartOptions) throws {
        guard let commandServer else {
            try start(options: options)
            return
        }

        let configContent = try String(contentsOf: options.configPath, encoding: .utf8)
        store.appendLog(level: "info", message: "Libbox restarting service after network change")
        try validateConfig(configContent, commandServer: commandServer)
        try commandServer.closeService()
        let overrideOptions = LibboxOverrideOptions()
        try commandServer.startOrReloadService(configContent, options: overrideOptions)
        store.appendLog(level: "info", message: "Libbox service restarted")
        activeOptions = options
    }

    func updatePower(sleeping: Bool, lowPower: Bool) {
        guard let commandServer, let options = activeOptions else { return }
        diagnosticsQueue.async { [weak self, weak commandServer] in
            guard let self, let commandServer else { return }
            self.sleeping = sleeping
            self.lowPower = lowPower
            self.connectDiagnosticsClient(
                commandServer: commandServer,
                settings: options.diagnosticsSettings,
                onTrafficUpdate: options.onTrafficUpdate,
                onLogMessage: options.onLogMessage
            )
        }
    }

    func stop() {
        callbackLock.lock()
        serviceStopped = nil
        callbackLock.unlock()
        store.appendLog(level: "info", message: "Libbox stopping")
        diagnosticsQueue.sync {
            deepDiagnosticsExpiry?.cancel()
            deepDiagnosticsExpiry = nil
            try? commandClient?.disconnect()
            commandClient = nil
            commandClientHandler = nil
        }
        try? commandServer?.closeService()
        commandServer?.close()
        commandServer = nil
        platformInterface = nil
        activeOptions = nil
        store.appendLog(level: "info", message: "Libbox stopped")
        store.flushLogs()
    }

    private func callLibboxBool(
        _ call: (_ error: NSErrorPointer) -> Bool,
        fallback: Error
    ) throws {
        var error: NSError?
        guard call(&error) else {
            throw error ?? fallback
        }
    }

    private func validateConfig(_ configContent: String, commandServer: LibboxCommandServer) throws {
        do {
            try commandServer.checkConfig(configContent)
            store.appendLog(level: "info", message: "Libbox config validation passed")
        } catch {
            store.appendLog(level: "error", message: "Libbox config validation failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func startDiagnosticsClient(
        commandServer: LibboxCommandServer,
        settings: DiagnosticsSettings,
        onTrafficUpdate: @escaping @Sendable (RuntimeTrafficSnapshot) -> Void,
        onLogMessage: @escaping @Sendable (String) -> Void
    ) {
        diagnosticsQueue.async { [weak self, weak commandServer] in
            guard let self, let commandServer else {
                return
            }
            do {
                try commandServer.start()
                self.store.appendLog(level: "info", message: "Libbox command server started")
            } catch {
                self.store.appendLog(level: "warn", message: "Libbox command server diagnostics unavailable: \(error.localizedDescription)")
                return
            }
            self.connectDiagnosticsClient(
                commandServer: commandServer,
                settings: settings,
                onTrafficUpdate: onTrafficUpdate,
                onLogMessage: onLogMessage
            )
        }
    }

    private func connectDiagnosticsClient(
        commandServer: LibboxCommandServer,
        settings: DiagnosticsSettings,
        onTrafficUpdate: @escaping @Sendable (RuntimeTrafficSnapshot) -> Void,
        onLogMessage: @escaping @Sendable (String) -> Void
    ) {
        let effectiveSettings = settings.normalized()
        let mode = effectiveSettings.mode
        let interval = LibboxDiagnosticsPolicy.statusIntervalNanoseconds(for: mode)

        deepDiagnosticsExpiry?.cancel()
        deepDiagnosticsExpiry = nil
        try? commandClient?.disconnect()
        commandClient = nil
        commandClientHandler = nil

        // Let the OS sleep. Keep the tunnel itself available for system traffic.
        guard !sleeping else { return }

        let options = LibboxCommandClientOptions()
        options.statusInterval = lowPower ? max(interval, 60_000_000_000) : interval
        options.addCommand(LibboxCommandLog)
        options.addCommand(LibboxCommandStatus)
        if !lowPower && LibboxDiagnosticsPolicy.includesConnectionEvents(for: mode) {
            options.addCommand(LibboxCommandConnections)
        }

        let handler = LibboxDiagnosticsCommandClientHandler(
            store: store,
            onTrafficUpdate: onTrafficUpdate,
            onLogMessage: onLogMessage
        )
        guard let client = LibboxNewCommandClient(handler, options) else {
            store.appendLog(level: "error", message: "Libbox diagnostics client unavailable")
            return
        }

        do {
            try client.connect()
            commandClientHandler = handler
            commandClient = client
            store.appendLog(
                level: "info",
                message: "Libbox diagnostics client connected mode=\(mode.rawValue) status_interval_ns=\(interval) connections=\(LibboxDiagnosticsPolicy.includesConnectionEvents(for: mode))"
            )
            scheduleDeepDiagnosticsExpiryIfNeeded(
                settings: effectiveSettings,
                commandServer: commandServer,
                onTrafficUpdate: onTrafficUpdate,
                onLogMessage: onLogMessage
            )
        } catch {
            store.appendLog(level: "error", message: "Libbox diagnostics client failed: \(error.localizedDescription)")
        }
    }

    private func scheduleDeepDiagnosticsExpiryIfNeeded(
        settings: DiagnosticsSettings,
        commandServer: LibboxCommandServer,
        onTrafficUpdate: @escaping @Sendable (RuntimeTrafficSnapshot) -> Void,
        onLogMessage: @escaping @Sendable (String) -> Void
    ) {
        guard settings.mode == .deep else {
            return
        }
        let remaining = settings.remainingDuration()
        guard remaining > 0 else {
            connectDiagnosticsClient(
                commandServer: commandServer,
                settings: .standard,
                onTrafficUpdate: onTrafficUpdate,
                onLogMessage: onLogMessage
            )
            return
        }

        let workItem = DispatchWorkItem { [weak self, weak commandServer] in
            guard let self, let commandServer else {
                return
            }
            try? self.store.saveDiagnosticsSettings(.standard)
            self.store.appendLog(level: "info", message: "Deep diagnostics expired; returning to standard low-power mode")
            self.connectDiagnosticsClient(
                commandServer: commandServer,
                settings: .standard,
                onTrafficUpdate: onTrafficUpdate,
                onLogMessage: onLogMessage
            )
        }
        deepDiagnosticsExpiry = workItem
        diagnosticsQueue.asyncAfter(deadline: .now() + remaining, execute: workItem)
    }
}

final class LibboxDiagnosticsCommandClientHandler: NSObject, LibboxCommandClientHandlerProtocol {
    private let store: AppGroupStore
    private let onTrafficUpdate: @Sendable (RuntimeTrafficSnapshot) -> Void
    private let onLogMessage: @Sendable (String) -> Void
    private let connectionEventLock = NSLock()
    private var lastConnectionEventAtByKey: [String: Date] = [:]
    private static let connectionEventSamplingInterval: TimeInterval = 10
    private static let connectionEventKeyLimit = 128

    init(
        store: AppGroupStore,
        onTrafficUpdate: @escaping @Sendable (RuntimeTrafficSnapshot) -> Void,
        onLogMessage: @escaping @Sendable (String) -> Void
    ) {
        self.store = store
        self.onTrafficUpdate = onTrafficUpdate
        self.onLogMessage = onLogMessage
        super.init()
    }

    func clearLogs() {
        store.appendLog(level: "debug", message: "Libbox stream cleared logs")
    }

    func connected() {
        store.appendLog(level: "info", message: "Libbox diagnostics stream connected")
    }

    func disconnected(_ message: String?) {
        store.appendLog(level: "warn", message: "Libbox diagnostics stream disconnected: \(message ?? "-")")
    }

    func initializeClashMode(_ modeList: (any LibboxStringIteratorProtocol)?, currentMode: String?) {
        _ = (modeList, currentMode)
    }

    func setDefaultLogLevel(_ level: Int32) {
        store.appendLog(level: "debug", message: "Libbox default log level=\(level)")
    }

    func updateClashMode(_ newMode: String?) {
        _ = newMode
    }

    func write(_ events: LibboxConnectionEvents?) {
        guard let iterator = events?.iterator() else {
            return
        }
        while iterator.hasNext() {
            guard let event = iterator.next() else {
                continue
            }
            appendConnectionEvent(event)
        }
    }

    func writeGroups(_ message: (any LibboxOutboundGroupIteratorProtocol)?) {
        _ = message
    }

    func writeLogs(_ messageList: (any LibboxLogIteratorProtocol)?) {
        guard let messageList else {
            return
        }
        while messageList.hasNext() {
            guard let entry = messageList.next() else {
                continue
            }
            let level = logLevelName(entry.level)
            store.appendLog(level: level, message: "sing-box: \(entry.message)")
            if entry.message.contains("connection: open connection to ") {
                onLogMessage(entry.message)
            }
        }
    }

    func writeOutbounds(_ message: (any LibboxOutboundGroupItemIteratorProtocol)?) {
        _ = message
    }

    func writeStatus(_ message: LibboxStatusMessage?) {
        guard let message else {
            return
        }
        onTrafficUpdate(RuntimeTrafficSnapshot(
            bytesIn: UInt64(max(0, message.downlinkTotal)),
            bytesOut: UInt64(max(0, message.uplinkTotal))
        ))
        store.appendLog(
            level: "debug",
            message: "Libbox status connections_in=\(message.connectionsIn) connections_out=\(message.connectionsOut) up=\(message.uplinkTotal) down=\(message.downlinkTotal) traffic=\(message.trafficAvailable)"
        )
    }

    private func appendConnectionEvent(_ event: LibboxConnectionEvent) {
        switch Int64(event.type) {
        case LibboxConnectionEventNew:
            break
        case LibboxConnectionEventClosed, LibboxConnectionEventUpdate:
            return
        default:
            return
        }

        let connection = event.connection
        let destination = connection?.displayDestination() ?? connection?.destination ?? "-"
        let domain = connection?.domain ?? "-"
        let network = connection?.network ?? "-"
        let outbound = connection?.outbound ?? "-"
        let outboundType = connection?.outboundType ?? "-"
        let rule = connection?.rule ?? "-"
        guard shouldPersistConnectionEvent(
            network: network,
            domain: domain,
            outbound: outbound,
            rule: rule
        ) else {
            return
        }
        store.appendLog(
            level: "info",
            message: "Libbox connection new id=\(event.id_) network=\(network) destination=\(destination) domain=\(domain) outbound=\(outbound) outbound_type=\(outboundType) rule=\(rule)"
        )
    }

    private func shouldPersistConnectionEvent(
        network: String,
        domain: String,
        outbound: String,
        rule: String
    ) -> Bool {
        let domainKey = domain.isEmpty || domain == "-" ? "<ip>" : domain
        let key = "\(network)|\(domainKey)|\(outbound)|\(rule)"
        let now = Date()

        connectionEventLock.lock()
        defer {
            connectionEventLock.unlock()
        }

        if let lastEventAt = lastConnectionEventAtByKey[key],
           now.timeIntervalSince(lastEventAt) < Self.connectionEventSamplingInterval {
            return false
        }
        if lastConnectionEventAtByKey.count >= Self.connectionEventKeyLimit,
           lastConnectionEventAtByKey[key] == nil,
           let oldestKey = lastConnectionEventAtByKey.min(by: { $0.value < $1.value })?.key {
            lastConnectionEventAtByKey.removeValue(forKey: oldestKey)
        }
        lastConnectionEventAtByKey[key] = now
        return true
    }

    private func logLevelName(_ level: Int32) -> String {
        switch level {
        case 0:
            return "debug"
        case 1:
            return "info"
        case 2:
            return "warn"
        case 3:
            return "error"
        default:
            return "debug"
        }
    }
}

extension LibboxPacketTunnelCore: LibboxCommandServerHandlerProtocol {
    func connectSSHAgent(_ ret0_: UnsafeMutablePointer<Int32>?) throws {
        ret0_?.pointee = -1
        throw LibboxPacketTunnelCoreError.unsupportedPlatformFeature("SSH agent")
    }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        LibboxSystemProxyStatus()
    }

    func serviceReload() throws {
    }

    func serviceStop() throws {
        // Never close the Go service synchronously from its own callback.
        callbackLock.lock()
        let callback = serviceStopped
        callbackLock.unlock()
        callback?("qingzhou: service-stopped")
    }

    func setSystemProxyEnabled(_ enabled: Bool) throws {
        _ = enabled
        throw LibboxPacketTunnelCoreError.unsupportedPlatformFeature("system proxy")
    }

    func triggerNativeCrash() throws {
        throw LibboxPacketTunnelCoreError.unsupportedPlatformFeature("native crash trigger")
    }

    func writeDebugMessage(_ message: String?) {
        guard let message, !message.isEmpty else {
            return
        }
        store.appendLog(level: "debug", message: "Libbox: \(message)")
    }
}

final class SplitVpnLibboxPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol {
    private weak var packetFlow: NEPacketTunnelFlow?
    private let store = AppGroupStore.shared
    private var defaultInterfaceMonitor: Network.NWPathMonitor?

    init(packetFlow: NEPacketTunnelFlow) {
        self.packetFlow = packetFlow
        super.init()
    }

    func autoDetectControl(_ fd: Int32) throws {
        _ = fd
    }

    func checkPlatformShell() throws {
        throw LibboxPacketTunnelCoreError.unsupportedPlatformFeature("platform shell")
    }

    func clearDNSCache() {
    }

    func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        _ = listener
        defaultInterfaceMonitor?.cancel()
        defaultInterfaceMonitor = nil
        store.appendLog(level: "info", message: "Libbox default interface monitor stopped")
    }

    func closeNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {
        _ = listener
    }

    func findConnectionOwner(
        _ ipProtocol: Int32,
        sourceAddress: String?,
        sourcePort: Int32,
        destinationAddress: String?,
        destinationPort: Int32
    ) throws -> LibboxConnectionOwner {
        _ = (ipProtocol, sourceAddress, sourcePort, destinationAddress, destinationPort)
        throw LibboxPacketTunnelCoreError.unsupportedPlatformFeature("connection owner lookup")
    }

    func getInterfaces() throws -> any LibboxNetworkInterfaceIteratorProtocol {
        let interfaces = NetworkInterfaceSnapshot.load()
        let summary = interfaces
            .prefix(8)
            .map { "\($0.name):\($0.index)" }
            .joined(separator: ", ")
        store.appendLog(level: "info", message: "Libbox getInterfaces count=\(interfaces.count) sample=[\(summary)]")
        return ArrayLibboxNetworkInterfaceIterator(interfaces)
    }

    func includeAllNetworks() -> Bool {
        true
    }

    func localDNSTransport() -> LibboxLocalDNSTransportProtocol? {
        nil
    }

    func lookupSFTPServer(_ error: NSErrorPointer) -> String {
        error?.pointee = LibboxPacketTunnelCoreError.unsupportedPlatformFeature("SFTP server").localizedNSError
        return ""
    }

    func lookupUser(_ username: String?) throws -> LibboxPlatformUser {
        _ = username
        throw LibboxPacketTunnelCoreError.unsupportedPlatformFeature("user lookup")
    }

    func openShellSession(
        _ user: LibboxPlatformUser?,
        command: String?,
        environ: LibboxStringIteratorProtocol?,
        term: String?,
        rows: Int32,
        cols: Int32
    ) throws -> any LibboxShellSessionProtocol {
        _ = (user, command, environ, term, rows, cols)
        throw LibboxPacketTunnelCoreError.unsupportedPlatformFeature("shell session")
    }

    func openTun(_ options: (any LibboxTunOptionsProtocol)?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        _ = (options, packetFlow)
        let fd = LibboxGetTunnelFileDescriptor()
        guard fd >= 0 else {
            store.appendLog(level: "error", message: "Libbox openTun could not find utun fd")
            throw LibboxPacketTunnelCoreError.tunnelFileDescriptorUnavailable
        }
        store.appendLog(level: "info", message: "Libbox openTun using fd \(fd)")
        ret0_?.pointee = fd
    }

    func readSystemSSHHostKey(_ error: NSErrorPointer) -> String {
        error?.pointee = LibboxPacketTunnelCoreError.unsupportedPlatformFeature("system SSH host key").localizedNSError
        return ""
    }

    func readWIFIState() -> LibboxWIFIState? {
        nil
    }

    func registerMyInterface(_ name: String?) {
        _ = name
    }

    func send(_ notification: LibboxNotification?) throws {
        _ = notification
    }

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        defaultInterfaceMonitor?.cancel()

        // Match the provider monitor: utun must never become its own upstream.
        let monitor = Network.NWPathMonitor(prohibitedInterfaceTypes: [.other, .loopback])
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else {
                return
            }
            let snapshot = NetworkInterfaceSnapshot.defaultCandidate(for: path)
            listener?.updateDefaultInterface(
                snapshot.name,
                interfaceIndex: snapshot.index,
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained
            )
            self.store.appendLog(
                level: "info",
                message: "Libbox default interface update name=\(snapshot.name) index=\(snapshot.index) type=\(snapshot.type) addressCount=\(snapshot.addresses.count) expensive=\(path.isExpensive) constrained=\(path.isConstrained)"
            )
        }
        monitor.start(queue: DispatchQueue(label: "split-vpn.libbox.default-interface"))
        defaultInterfaceMonitor = monitor
        store.appendLog(level: "info", message: "Libbox default interface monitor started")
    }

    func startNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {
        _ = listener
    }

    func systemCertificates() -> LibboxStringIteratorProtocol? {
        nil
    }

    func tailscaleHostname() -> String {
        ""
    }

    func underNetworkExtension() -> Bool {
        true
    }

    func usePlatformAutoDetectControl() -> Bool {
        false
    }

    func usePlatformShell() -> Bool {
        false
    }

    func useProcFS() -> Bool {
        false
    }
}

private extension Error {
    var localizedNSError: NSError {
        self as NSError
    }
}

private struct NetworkInterfaceSnapshot {
    var index: Int32
    var mtu: Int32
    var name: String
    var addresses: [String]
    var flags: Int32
    var type: Int32

    static func defaultCandidate(for path: Network.NWPath) -> NetworkInterfaceSnapshot {
        guard path.status == .satisfied else { return emptyCandidate() }
        let snapshots = loadSnapshots()
        if let snapshot = pathCandidate(for: path, snapshots: snapshots, requireUsableIPv4: true) {
            return snapshot
        }
        if let snapshot = pathCandidate(for: path, snapshots: snapshots, requireUsableIPv4: false) {
            return snapshot
        }

        let preferredTypes = [
            LibboxInterfaceTypeWIFI,
            LibboxInterfaceTypeCellular,
            LibboxInterfaceTypeEthernet
        ]
        for type in preferredTypes {
            if let snapshot = snapshots.first(where: { $0.type == type && $0.hasUsableIPv4Address }) {
                return snapshot
            }
        }
        for type in preferredTypes {
            if let snapshot = snapshots.first(where: { $0.type == type }) {
                return snapshot
            }
        }
        return snapshots.first ?? NetworkInterfaceSnapshot(
            index: 0,
            mtu: 1500,
            name: "",
            addresses: [],
            flags: 0,
            type: LibboxInterfaceTypeOther
        )
    }

    private static func pathCandidate(
        for path: Network.NWPath,
        snapshots: [NetworkInterfaceSnapshot],
        requireUsableIPv4: Bool
    ) -> NetworkInterfaceSnapshot? {
        let activeInterfaces = activePathInterfaces(for: path)
        for activeInterface in activeInterfaces {
            if let snapshot = snapshots.first(where: {
                $0.name == activeInterface.name &&
                    $0.type == activeInterface.type &&
                    (!requireUsableIPv4 || $0.hasUsableIPv4Address)
            }) {
                return snapshot
            }
        }

        let activeTypes = activeInterfaceTypes(for: path)
        for type in activeTypes {
            if let snapshot = snapshots.first(where: {
                $0.type == type &&
                    (!requireUsableIPv4 || $0.hasUsableIPv4Address)
            }) {
                return snapshot
            }
        }

        return nil
    }

    private static func activePathInterfaces(for path: Network.NWPath) -> [(name: String, type: Int32)] {
        var seen = Set<String>()
        return path.availableInterfaces.compactMap { interface in
            guard path.usesInterfaceType(interface.type),
                  let type = libboxInterfaceType(for: interface.type) else {
                return nil
            }
            let key = "\(interface.name):\(type)"
            guard !seen.contains(key) else {
                return nil
            }
            seen.insert(key)
            return (name: interface.name, type: type)
        }
    }

    private static func activeInterfaceTypes(for path: Network.NWPath) -> [Int32] {
        [
            (.wifi, LibboxInterfaceTypeWIFI),
            (.cellular, LibboxInterfaceTypeCellular),
            (.wiredEthernet, LibboxInterfaceTypeEthernet)
        ].compactMap { nwType, libboxType in
            path.usesInterfaceType(nwType) ? libboxType : nil
        }
    }

    private static func libboxInterfaceType(for type: Network.NWInterface.InterfaceType) -> Int32? {
        switch type {
        case .wifi:
            return LibboxInterfaceTypeWIFI
        case .cellular:
            return LibboxInterfaceTypeCellular
        case .wiredEthernet:
            return LibboxInterfaceTypeEthernet
        default:
            return nil
        }
    }

    private static func emptyCandidate() -> NetworkInterfaceSnapshot {
        NetworkInterfaceSnapshot(
            index: 0,
            mtu: 1500,
            name: "",
            addresses: [],
            flags: 0,
            type: LibboxInterfaceTypeOther
        )
    }

    private static func loadSnapshots() -> [NetworkInterfaceSnapshot] {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else {
            return []
        }
        defer {
            freeifaddrs(firstAddress)
        }

        return snapshots(from: firstAddress)
    }

    private static func snapshots(from firstAddress: UnsafeMutablePointer<ifaddrs>) -> [NetworkInterfaceSnapshot] {
        var snapshots: [String: NetworkInterfaceSnapshot] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let current = cursor {
            defer {
                cursor = current.pointee.ifa_next
            }

            let flags = current.pointee.ifa_flags
            guard (flags & UInt32(IFF_UP)) != 0,
                  let namePointer = current.pointee.ifa_name else {
                continue
            }

            let name = String(cString: namePointer)
            guard !isSystemTunnel(name) else {
                continue
            }

            var snapshot = snapshots[name] ?? NetworkInterfaceSnapshot(
                index: Int32(if_nametoindex(namePointer)),
                mtu: mtu(from: current.pointee.ifa_data),
                name: name,
                addresses: [],
                flags: Int32(bitPattern: flags),
                type: interfaceType(for: name)
            )

            if let address = formattedAddress(
                address: current.pointee.ifa_addr,
                netmask: current.pointee.ifa_netmask
            ), !snapshot.addresses.contains(address) {
                snapshot.addresses.append(address)
            }

            snapshots[name] = snapshot
        }

        return snapshots.values.sorted { $0.name < $1.name }
    }

    static func load() -> [LibboxNetworkInterface] {
        loadSnapshots().map(\.libboxInterface)
    }

    private var libboxInterface: LibboxNetworkInterface {
        let value = LibboxNetworkInterface()
        value.index = index
        value.mtu = mtu
        value.name = name
        value.addresses = ArrayLibboxStringIterator(addresses)
        value.flags = flags
        value.type = type
        value.dnsServer = ArrayLibboxStringIterator([])
        return value
    }

    private var hasUsableIPv4Address: Bool {
        addresses.contains { address in
            let host = address.split(separator: "/", maxSplits: 1).first.map(String.init) ?? address
            guard host.contains(".") else {
                return false
            }
            return !host.hasPrefix("0.") &&
                !host.hasPrefix("127.") &&
                !host.hasPrefix("169.254.")
        }
    }

    private static func interfaceType(for name: String) -> Int32 {
        if name.hasPrefix("pdp_ip") {
            return LibboxInterfaceTypeCellular
        }
        if name.hasPrefix("en") {
            return LibboxInterfaceTypeWIFI
        }
        if name.hasPrefix("bridge") || name.hasPrefix("llw") || name.hasPrefix("awdl") {
            return LibboxInterfaceTypeOther
        }
        return LibboxInterfaceTypeOther
    }

    private static func isSystemTunnel(_ name: String) -> Bool {
        name.hasPrefix("utun") || name.hasPrefix("ipsec")
    }

    private static func mtu(from data: UnsafeMutableRawPointer?) -> Int32 {
        guard let data else {
            return 1500
        }
        return Int32(data.assumingMemoryBound(to: if_data.self).pointee.ifi_mtu)
    }

    private static func formattedAddress(
        address: UnsafeMutablePointer<sockaddr>?,
        netmask: UnsafeMutablePointer<sockaddr>?
    ) -> String? {
        guard let address else {
            return nil
        }

        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            var addr = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                return nil
            }
            return "\(String(cString: buffer))/\(prefixLengthIPv4(netmask))"

        case AF_INET6:
            var addr = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                return nil
            }
            return "\(String(cString: buffer))/\(prefixLengthIPv6(netmask))"

        default:
            return nil
        }
    }

    private static func prefixLengthIPv4(_ netmask: UnsafeMutablePointer<sockaddr>?) -> Int {
        guard let netmask else {
            return 32
        }
        let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
        }
        return mask.nonzeroBitCount
    }

    private static func prefixLengthIPv6(_ netmask: UnsafeMutablePointer<sockaddr>?) -> Int {
        guard let netmask else {
            return 128
        }
        let mask = netmask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
            $0.pointee.sin6_addr
        }
        return withUnsafeBytes(of: mask.__u6_addr.__u6_addr8) { bytes in
            bytes.reduce(0) { total, byte in
                total + byte.nonzeroBitCount
            }
        }
    }
}

final class ArrayLibboxNetworkInterfaceIterator: NSObject, LibboxNetworkInterfaceIteratorProtocol {
    private let values: [LibboxNetworkInterface]
    private var index = 0

    init(_ values: [LibboxNetworkInterface]) {
        self.values = values
    }

    func hasNext() -> Bool {
        index < values.count
    }

    func next() -> LibboxNetworkInterface? {
        guard hasNext() else {
            return nil
        }
        defer {
            index += 1
        }
        return values[index]
    }
}

final class ArrayLibboxStringIterator: NSObject, LibboxStringIteratorProtocol {
    private let values: [String]
    private var index = 0

    init(_ values: [String]) {
        self.values = values
    }

    func hasNext() -> Bool {
        index < values.count
    }

    func len() -> Int32 {
        Int32(values.count)
    }

    func next() -> String {
        guard hasNext() else {
            return ""
        }
        defer {
            index += 1
        }
        return values[index]
    }
}
#endif
