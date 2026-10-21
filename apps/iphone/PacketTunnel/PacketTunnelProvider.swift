import Foundation
import Darwin
import Network
import NetworkExtension

// Mutable lifecycle state is confined to networkChangeQueue; status uses a lock.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let store = AppGroupStore.shared
    private let networkChangeQueue = DispatchQueue(label: "split-vpn.packet-tunnel.control", qos: .utility)
    // A stuck native operation must not prevent stop, deadlines or OS callbacks.
    private let coreQueue = DispatchQueue(label: "split-vpn.packet-tunnel.core", qos: .utility)
    private var dataPlane: TunnelDataPlane?
    private var networkChangeMonitor: Network.NWPathMonitor?
    private var pendingNetworkRecovery: DispatchWorkItem?
    private var operationDeadline: DispatchWorkItem?
    private var watchdog: DispatchSourceTimer?
    private var powerObserver: NSObjectProtocol?
    private var startCompletion: TunnelCompletion<Error?>?
    private var recovery = TunnelRecoveryPolicy()
    private var sessionID = UUID()
    private var lastWatchdogAt: TimeInterval = 0
    private var dataPlaneHealthMonitor = DataPlaneHealthMonitor(cooldown: 0)
    private let runtimeStatusLock = NSLock()
    private var latestRuntimeStatus: RuntimeStatus = .disconnected
    private var lastCheckpointStatus: RuntimeStatus?
    private var lastCheckpointAt: Date?
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        networkChangeQueue.async { [weak self] in
            guard let self else { completionHandler(TunnelDataPlaneError.providerReleased); return }
            guard self.store.isTunnelRequested() else {
                completionHandler(NSError(domain: "dev.splitvpn.tunnel", code: 2, userInfo: [NSLocalizedDescriptionKey: "已手动断开，请在轻舟中重新连接"]))
                return
            }
            self.sessionID = UUID()
            let session = self.sessionID
            self.recovery.start(now: self.now)
            self.recovery.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            self.reasserting = false
            self.dataPlaneHealthMonitor = DataPlaneHealthMonitor(cooldown: 0)
            self.startCompletion = TunnelCompletion(completionHandler)
            self.updateRuntimeStatus(RuntimeStatus(state: .connecting, startedAt: Date(), lastError: "", bytesIn: 0, bytesOut: 0), forceCheckpoint: true)
            let settings = self.store.readSettings()
            let config = self.resolveGeneratedConfig(from: options)
            let plane = TunnelDataPlane(
                packetFlow: self.packetFlow,
                config: config,
                selectedProxy: config?.selectedProxy ?? settings.selectedProxy,
                diagnosticsSettings: self.resolveDiagnosticsSettings(from: options),
                onTrafficUpdate: { [weak self] snapshot in
                    self?.networkChangeQueue.async { [weak self] in
                        guard let self, self.sessionID == session, self.recovery.wanted else { return }
                        self.recovery.heartbeat(now: self.now)
                        self.updateTraffic(snapshot)
                    }
                },
                onLogMessage: { [weak self] message in
                    self?.networkChangeQueue.async { [weak self] in
                        guard let self, self.sessionID == session else { return }
                        self.observeDataPlaneLog(message)
                    }
                }
            )
            self.dataPlane = plane
            self.armDeadline(seconds: 25) { [weak self] in self?.handoffToSystem(reason: "start_timeout") }
            self.setTunnelNetworkSettings(self.makeNetworkSettings(mtu: config?.packetTunnelMTU ?? settings.packetTunnelMTU)) { [weak self] error in
                guard let self else { return }
                self.networkChangeQueue.async {
                    guard self.sessionID == session, self.recovery.wanted else { return }
                    if let error { self.finishStart(error: error); return }
                    self.coreQueue.async {
                        let result = Result { try plane.start() }
                        self.networkChangeQueue.async {
                            guard self.sessionID == session, self.recovery.wanted else { return }
                            switch result {
                            case .success: self.finishStart(error: nil)
                            case .failure(let error): self.finishStart(error: error)
                            }
                        }
                    }
                }
            }
        }
    }

    private func finishStart(error: Error?) {
        operationDeadline?.cancel()
        operationDeadline = nil
        if let error {
            recovery.stop()
            updateState(.error, message: "隧道启动失败，请检查节点或配置")
            store.appendLog(level: "error", message: "Packet tunnel start failed; inspect node and configuration readiness")
            if let plane = dataPlane { coreQueue.async { plane.stop() } }
            dataPlane = nil
        } else {
            recovery.heartbeat(now: now)
            updateState(.connected)
            startNetworkChangeMonitor()
            observePowerChanges()
            applyPowerState()
            startWatchdog()
        }
        startCompletion?.finish(error)
        startCompletion = nil
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let completion = TunnelCompletion<Void> { _ in completionHandler() }
        networkChangeQueue.async {
            self.recovery.stop()
            self.sessionID = UUID()
            self.stopMonitors()
            self.startCompletion?.finish(TunnelDataPlaneError.providerReleased)
            self.startCompletion = nil
            self.reasserting = false
            let plane = self.dataPlane
            self.dataPlane = nil
            self.updateRuntimeStatus(.disconnected, forceCheckpoint: true)
            self.store.appendLog(level: "info", message: "Packet tunnel stopped: \(reason.rawValue)")
            self.store.flushLogs()
            self.coreQueue.async {
                plane?.stop()
                completion.finish(())
            }
            // Completing teardown lets Network Extension retire an unresponsive core.
            self.networkChangeQueue.asyncAfter(deadline: .now() + 3) { completion.finish(()) }
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        networkChangeQueue.async {
            self.recovery.sleep()
            self.pendingNetworkRecovery?.cancel()
            self.pendingNetworkRecovery = nil
            self.watchdog?.cancel()
            self.watchdog = nil
            if self.startCompletion == nil { self.operationDeadline?.cancel() }
            // Native work may finish while asleep; its result cannot schedule a retry.
            self.applyPowerState()
            self.store.flushLogs()
            completionHandler()
        }
    }

    override func wake() {
        networkChangeQueue.async { [self] in
            guard self.recovery.wanted else { return }
            guard self.recovery.wake(now: self.now) else { return }
            self.dataPlaneHealthMonitor.resetSamples()
            self.applyPowerState()
            self.updateState(.connecting, message: "正在恢复网络连接")
            self.startWatchdog()
            if self.recovery.inFlight {
                self.armDeadline(seconds: 20) { [weak self] in self?.handoffToSystem(reason: "core_unresponsive_after_wake") }
            }
            self.scheduleRecovery()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        completionHandler?(try? encoder.encode(currentRuntimeStatus()))
    }

    private func makeNetworkSettings(mtu: Int) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: TunnelAddressing.remoteAddress)

        let ipv4 = NEIPv4Settings(
            addresses: [TunnelAddressing.interfaceAddress],
            subnetMasks: [TunnelAddressing.ipv4SubnetMask]
        )
        ipv4.includedRoutes = [NEIPv4Route.default()]
        ipv4.excludedRoutes = DefaultRules.networkExtensionExcludedIPv4Routes.map { route in
            NEIPv4Route(destinationAddress: route.destinationAddress, subnetMask: route.subnetMask)
        }
        settings.ipv4Settings = ipv4

        // Without IPv6 settings iOS sends IPv6 straight out of the physical
        // interface, bypassing every rule. Link-local and multicast stay local.
        let ipv6 = NEIPv6Settings(
            addresses: [TunnelAddressing.interfaceAddress6],
            networkPrefixLengths: [NSNumber(value: TunnelAddressing.ipv6PrefixLength)]
        )
        ipv6.includedRoutes = [NEIPv6Route.default()]
        ipv6.excludedRoutes = [
            NEIPv6Route(destinationAddress: "fe80::", networkPrefixLength: 10),
            NEIPv6Route(destinationAddress: "ff00::", networkPrefixLength: 8),
        ]
        settings.ipv6Settings = ipv6

        let dns = NEDNSSettings(servers: ["223.5.5.5", "1.1.1.1"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        settings.mtu = NSNumber(value: TunnelAddressing.normalizedMTU(mtu))

        return settings
    }

    private func resolveGeneratedConfig(from options: [String: NSObject]?) -> GeneratedTunnelConfig? {
        let storedConfig = store.readGeneratedConfig()
        guard let configContent = options?["configContent"] as? String, !configContent.isEmpty else {
            return storedConfig
        }

        return GeneratedTunnelConfig(
            selectedProxy: storedConfig?.selectedProxy ?? store.readSettings().selectedProxy,
            providerNodeCount: storedConfig?.providerNodeCount ?? store.readNodes().count,
            convertedOutboundCount: storedConfig?.convertedOutboundCount,
            unsupportedNodeCount: storedConfig?.unsupportedNodeCount,
            selectedOutboundTag: storedConfig?.selectedOutboundTag,
            selectedProxyStatus: storedConfig?.selectedProxyStatus,
            selectedProxyMessage: storedConfig?.selectedProxyMessage,
            unknownTrafficPolicy: storedConfig?.unknownTrafficPolicy ?? store.readSettings().unknownTrafficPolicy,
            packetTunnelMTU: storedConfig?.packetTunnelMTU ?? store.readSettings().packetTunnelMTU,
            vpnDomains: storedConfig?.vpnDomains ?? store.readDomains().domains,
            generatedAt: Date(),
            yaml: storedConfig?.yaml ?? "",
            singBoxJSON: configContent
        )
    }

    private func resolveDiagnosticsSettings(from options: [String: NSObject]?) -> DiagnosticsSettings {
        let stored = store.readDiagnosticsSettings()
        guard let rawMode = options?["diagnosticsMode"] as? String,
              let mode = DiagnosticsMode(rawValue: rawMode) else {
            return stored
        }
        let expiresAt = (options?["diagnosticsExpiresAt"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue)
        }
        return DiagnosticsSettings(mode: mode, expiresAt: expiresAt).normalized()
    }

    private func startNetworkChangeMonitor() {
        networkChangeMonitor?.cancel()
        // Do not observe our own utun as a new upstream network.
        let monitor = Network.NWPathMonitor(prohibitedInterfaceTypes: [.other, .loopback])
        var baseline: NetworkPathSignature?
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self, self.recovery.wanted else { return }
            let next = NetworkPathSignature(path: path)
            let changed = baseline.map { $0.requiresTunnelRecovery(to: next) } ?? !next.isSatisfied
            baseline = next
            self.recovery.setNetwork(available: next.isSatisfied, changed: changed,
                                     identity: next.recoveryIdentity, now: self.now)
            guard changed else { return }
            // Only the transport is logged, never local IP/interface fingerprints.
            self.store.appendLog(level: "info", message: "Upstream changed: \(next.summary)")
            self.dataPlaneHealthMonitor.resetSamples()
            self.updateState(.connecting, message: next.isSatisfied ? "正在恢复网络连接" : "等待网络恢复")
            self.startWatchdog()
            self.scheduleRecovery()
        }
        networkChangeMonitor = monitor
        monitor.start(queue: networkChangeQueue)
    }

    private func requestRecovery(reason: String) {
        guard recovery.wanted, !recovery.inFlight, !recovery.pending, !recovery.sleeping else { return }
        store.appendLog(level: "warn", message: "Tunnel recovery requested: \(reason)")
        recovery.request(now: now)
        updateState(.connecting, message: recovery.networkAvailable ? "正在自动重连" : "等待网络恢复")
        scheduleRecovery()
    }

    private func scheduleRecovery() {
        pendingNetworkRecovery?.cancel()
        pendingNetworkRecovery = nil
        guard recovery.canRecover else { return }
        let item = DispatchWorkItem { [weak self] in self?.performRecovery() }
        pendingNetworkRecovery = item
        networkChangeQueue.asyncAfter(deadline: .now() + max(0, (recovery.retryAt ?? now) - now), execute: item)
    }

    private func performRecovery() {
        pendingNetworkRecovery = nil
        guard store.isTunnelRequested() else {
            recovery.stop()
            stopMonitors()
            cancelTunnelWithError(nil)
            return
        }
        guard let token = recovery.begin(now: now), let plane = dataPlane else { return }
        let session = sessionID
        reasserting = true
        updateState(.connecting, message: "正在自动重连（第 \(recovery.attempts) 次）")
        dataPlaneHealthMonitor.resetSamples()
        armDeadline(seconds: 20) { [weak self] in self?.handoffToSystem(reason: "core_unresponsive") }
        coreQueue.async {
            let result = Result { try plane.restart() }
            self.networkChangeQueue.async {
                guard self.sessionID == session,
                      self.recovery.finish(token: token, success: (try? result.get()) != nil, now: self.now) else { return }
                self.operationDeadline?.cancel()
                self.operationDeadline = nil
                switch result {
                case .success:
                    self.store.appendLog(level: "info", message: "Tunnel core restarted")
                    if !self.recovery.pending && self.recovery.networkAvailable {
                        self.reasserting = false
                        self.updateState(.connected)
                    }
                    self.applyPowerState()
                case .failure:
                    // Avoid recording config-bearing native exception strings.
                    self.store.appendLog(level: "warn", message: "Tunnel restart failed; retry scheduled")
                    self.updateState(.connecting, message: "连接暂不可用，稍后自动重试")
                }
                self.scheduleRecovery()
            }
        }
    }

    private func observeDataPlaneLog(_ message: String) {
        guard recovery.wanted, !recovery.inFlight, !recovery.pending, !recovery.sleeping else { return }
        if message == "qingzhou: service-stopped" {
            requestRecovery(reason: "native_service_stopped")
        } else if let incident = dataPlaneHealthMonitor.observe(logMessage: message, at: Date(timeIntervalSince1970: now)) {
            requestRecovery(reason: incident.reason)
        }
    }

    private func startWatchdog() {
        watchdog?.cancel()
        guard recovery.wanted, !recovery.sleeping, recovery.networkAvailable else { watchdog = nil; return }
        lastWatchdogAt = now
        let timer = DispatchSource.makeTimerSource(queue: networkChangeQueue)
        timer.schedule(deadline: .now() + recovery.watchdogInterval, repeating: recovery.watchdogInterval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let current = self.now
            if !self.store.isTunnelRequested() {
                self.recovery.stop()
                self.stopMonitors()
                self.cancelTunnelWithError(nil)
                return
            }
            // OS suspension can postpone timers without delivering a sleep callback.
            // Give the diagnostic stream a fresh grace period instead of a false failure.
            if current - self.lastWatchdogAt > self.recovery.watchdogInterval * 3 {
                self.recovery.heartbeat(now: current)
            } else if self.recovery.heartbeatExpired(now: current) {
                self.requestRecovery(reason: "status_heartbeat_missing")
            }
            self.lastWatchdogAt = current
        }
        watchdog = timer
        timer.resume()
    }

    private func observePowerChanges() {
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
        powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { [weak self] _ in
            self?.networkChangeQueue.async { [weak self] in
                guard let self, self.recovery.wanted else { return }
                self.recovery.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                self.recovery.heartbeat(now: self.now)
                self.applyPowerState()
                self.startWatchdog()
            }
        }
    }

    private func applyPowerState() {
        guard let plane = dataPlane else { return }
        let sleeping = recovery.sleeping
        let lowPower = recovery.lowPower
        coreQueue.async { plane.updatePower(sleeping: sleeping, lowPower: lowPower) }
    }

    private func armDeadline(seconds: TimeInterval, action: @escaping () -> Void) {
        operationDeadline?.cancel()
        let item = DispatchWorkItem(block: action)
        operationDeadline = item
        networkChangeQueue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func handoffToSystem(reason: String) {
        guard recovery.wanted else { return }
        recovery.stop()
        stopMonitors()
        let error = NSError(domain: "dev.splitvpn.tunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: "隧道无响应，交由系统重新连接"])
        store.appendLog(level: "error", message: "Tunnel watchdog handing off to system: \(reason)")
        updateState(.error, message: "隧道无响应，等待系统重新连接")
        store.flushLogs()
        if let completion = startCompletion {
            startCompletion = nil
            completion.finish(error)
        } else {
            cancelTunnelWithError(error)
        }
    }

    private func stopMonitors() {
        pendingNetworkRecovery?.cancel()
        pendingNetworkRecovery = nil
        operationDeadline?.cancel()
        operationDeadline = nil
        networkChangeMonitor?.cancel()
        networkChangeMonitor = nil
        watchdog?.cancel()
        watchdog = nil
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
        powerObserver = nil
    }

    private func updateState(_ state: TunnelConnectionState, message: String = "") {
        if state == .connecting && startCompletion == nil { reasserting = true }
        let current = currentRuntimeStatus()
        updateRuntimeStatus(RuntimeStatus(state: state, startedAt: current.startedAt, lastError: message, bytesIn: current.bytesIn, bytesOut: current.bytesOut), forceCheckpoint: true)
    }

    private func currentRuntimeStatus() -> RuntimeStatus {
        runtimeStatusLock.lock()
        defer { runtimeStatusLock.unlock() }
        return latestRuntimeStatus
    }

    private func updateTraffic(_ snapshot: RuntimeTrafficSnapshot) {
        let now = Date()
        var shouldCheckpoint = false

        runtimeStatusLock.lock()
        let next = RuntimeStatus(
            state: latestRuntimeStatus.state,
            startedAt: latestRuntimeStatus.startedAt,
            lastError: latestRuntimeStatus.lastError,
            bytesIn: snapshot.bytesIn,
            bytesOut: snapshot.bytesOut
        )
        latestRuntimeStatus = next
        shouldCheckpoint = RuntimeStatusCheckpointPolicy.shouldCheckpoint(
            previous: lastCheckpointStatus,
            next: next,
            lastCheckpointAt: lastCheckpointAt,
            now: now
        )
        if shouldCheckpoint {
            lastCheckpointStatus = next
            lastCheckpointAt = now
        }
        runtimeStatusLock.unlock()

        if shouldCheckpoint {
            try? store.saveRuntimeStatus(next)
        }
    }

    private func updateRuntimeStatus(_ status: RuntimeStatus, forceCheckpoint: Bool = false) {
        let now = Date()
        var shouldCheckpoint = forceCheckpoint

        runtimeStatusLock.lock()
        latestRuntimeStatus = status
        if !shouldCheckpoint {
            shouldCheckpoint = RuntimeStatusCheckpointPolicy.shouldCheckpoint(
                previous: lastCheckpointStatus,
                next: status,
                lastCheckpointAt: lastCheckpointAt,
                now: now
            )
        }
        if shouldCheckpoint {
            lastCheckpointStatus = status
            lastCheckpointAt = now
        }
        runtimeStatusLock.unlock()

        if shouldCheckpoint {
            try? store.saveRuntimeStatus(status)
        }
    }
}

private struct NetworkPathSignature {
    let status: String
    let isExpensive: Bool
    let isConstrained: Bool
    let usedInterfaceTypes: [String]
    let activeInterfaceFingerprints: [String]
    let capabilities: [Bool]

    var isSatisfied: Bool {
        status == "satisfied"
    }

    // Used only for recovery scheduling; never log addresses or this identity.
    var recoveryIdentity: String {
        (usedInterfaceTypes + activeInterfaceFingerprints + capabilities.map { $0 ? "1" : "0" }).joined(separator: "|")
    }

    var summary: String {
        let interfaces = usedInterfaceTypes.isEmpty ? "none" : usedInterfaceTypes.joined(separator: "+")
        return "status=\(status) used=\(interfaces) expensive=\(isExpensive) constrained=\(isConstrained)"
    }

    var detailedSummary: String {
        let fingerprints = activeInterfaceFingerprints.isEmpty ? "none" : activeInterfaceFingerprints.joined(separator: "|")
        return "\(summary) fingerprints=\(fingerprints)"
    }

    func requiresTunnelRecovery(to next: NetworkPathSignature) -> Bool {
        status != next.status
            || usedInterfaceTypes != next.usedInterfaceTypes
            || activeInterfaceFingerprints != next.activeInterfaceFingerprints
            || capabilities != next.capabilities
    }

    func hasCostAttributeChange(to next: NetworkPathSignature) -> Bool {
        isExpensive != next.isExpensive || isConstrained != next.isConstrained
    }

    init(path: Network.NWPath) {
        self.status = Self.statusName(path.status)
        self.isExpensive = path.isExpensive
        self.isConstrained = path.isConstrained
        self.capabilities = [path.supportsIPv4, path.supportsIPv6, path.supportsDNS]
        self.usedInterfaceTypes = [
            path.usesInterfaceType(.wifi) ? "wifi" : nil,
            path.usesInterfaceType(.cellular) ? "cellular" : nil,
            path.usesInterfaceType(.wiredEthernet) ? "wired" : nil,
            path.usesInterfaceType(.loopback) ? "loopback" : nil,
            path.usesInterfaceType(.other) ? "other" : nil
        ].compactMap { $0 }
        self.activeInterfaceFingerprints = Self.activeInterfaceFingerprints(for: path)
    }

    private static func statusName(_ status: Network.NWPath.Status) -> String {
        switch status {
        case .satisfied:
            return "satisfied"
        case .unsatisfied:
            return "unsatisfied"
        case .requiresConnection:
            return "requiresConnection"
        @unknown default:
            return "unknown"
        }
    }

    private static func activeInterfaceFingerprints(for path: Network.NWPath) -> [String] {
        let addressesByInterface = addressesByInterface()
        let fingerprints: [String] = path.availableInterfaces.compactMap { interface in
            guard path.usesInterfaceType(interface.type), interface.type != .other, interface.type != .loopback else {
                return nil
            }
            let addresses = addressesByInterface[interface.name, default: []].sorted().joined(separator: ",")
            return "\(interface.name):\(interfaceTypeName(interface.type)):\(addresses)"
        }
        return Array(Set(fingerprints)).sorted()
    }

    private static func addressesByInterface() -> [String: [String]] {
        var result: [String: [String]] = [:]
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else {
            return result
        }
        defer {
            freeifaddrs(firstAddress)
        }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let current = cursor {
            defer {
                cursor = current.pointee.ifa_next
            }

            guard let address = current.pointee.ifa_addr,
                  [UInt8(AF_INET), UInt8(AF_INET6)].contains(address.pointee.sa_family) else {
                continue
            }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }

            let name = String(cString: current.pointee.ifa_name)
            let value = String(cString: buffer)
            result[name, default: []].append(value)
        }

        return result
    }

    private static func interfaceTypeName(_ type: Network.NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi:
            return "wifi"
        case .cellular:
            return "cellular"
        case .wiredEthernet:
            return "wired"
        case .loopback:
            return "loopback"
        case .other:
            return "other"
        @unknown default:
            return "unknown"
        }
    }
}
