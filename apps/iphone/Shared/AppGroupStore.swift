import Foundation
import OSLog

enum AppGroupStoreError: LocalizedError {
    case missingManagedRuleSet(String)
    case invalidRuleSetFile(String)
    case ruleSetTooLarge(String, Int, Int)
    case ruleSetLibraryTooLarge(Int, Int)

    var errorDescription: String? {
        switch self {
        case .missingManagedRuleSet(let tag):
            return "规则集缺失：\(tag)"
        case .invalidRuleSetFile(let tag):
            return "规则集文件无效：\(tag)"
        case .ruleSetTooLarge(let tag, let bytes, let limit):
            return "规则集过大：\(tag) \(bytes) bytes，限制 \(limit) bytes"
        case .ruleSetLibraryTooLarge(let bytes, let limit):
            return "规则集库过大：\(bytes) bytes，限制 \(limit) bytes"
        }
    }
}

final class AppGroupStore {
    static let shared = AppGroupStore()

    let rootURL: URL
    let isUsingAppGroupContainer: Bool

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let runtimeLogger = Logger(subsystem: "split-vpn", category: "runtime")
    private let logPersistenceQueue = DispatchQueue(label: "split-vpn.app-group.logs", qos: .utility)
    private var pendingLogs: [LogEntry] = []
    private var pendingLogFlush: DispatchWorkItem?
    private static let logBatchSize = 20
    private static let logFlushInterval: TimeInterval = 30

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let appGroupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: SplitVpnConstants.appGroupIdentifier) {
            self.rootURL = appGroupURL
            self.isUsingAppGroupContainer = true
        } else {
            self.rootURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.isUsingAppGroupContainer = false
        }

        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        ensureDirectories()
    }

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootURL = rootURL
        self.isUsingAppGroupContainer = false

        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        ensureDirectories()
    }

    func readSubscription() -> SubscriptionRecord {
        read("subscription.json", default: .empty)
    }

    func saveSubscription(_ value: SubscriptionRecord) throws {
        try write(value, to: "subscription.json")
    }

    func readSettings() -> AppSettings {
        var settings: AppSettings = read("settings.json", default: .defaults)
        if settings.routingDefaultsVersion < AppSettings.currentRoutingDefaultsVersion {
            settings.unknownTrafficPolicy = AppSettings.defaults.unknownTrafficPolicy
            settings.routingDefaultsVersion = AppSettings.currentRoutingDefaultsVersion
            try? saveSettings(settings)
        }
        return settings
    }

    func saveSettings(_ value: AppSettings) throws {
        var normalized = value
        if normalized.unknownTrafficPolicy != "vpn" {
            normalized.unknownTrafficPolicy = "direct"
        }
        normalized.packetTunnelMTU = TunnelAddressing.normalizedMTU(normalized.packetTunnelMTU)
        normalized.proxyServerDomainResolver = ProxyServerDomainResolver.normalized(normalized.proxyServerDomainResolver)
        normalized.routingDefaultsVersion = AppSettings.currentRoutingDefaultsVersion
        try write(normalized, to: "settings.json")
    }

    func readDiagnosticsSettings(now: Date = Date()) -> DiagnosticsSettings {
        let settings: DiagnosticsSettings = read("diagnostics/settings.json", default: DiagnosticsSettings.standard)
        return settings.normalized(now: now)
    }

    func saveDiagnosticsSettings(_ value: DiagnosticsSettings, now: Date = Date()) throws {
        try write(value.normalized(now: now), to: "diagnostics/settings.json")
    }

    func readDomains() -> VpnDomainList {
        var domains: VpnDomainList = read("vpn-domains.json", default: .defaults)
        if domains.defaultsVersion < VpnDomainList.currentDefaultsVersion {
            domains.domains = normalizeDomains(domains.domains + DefaultRules.vpnDomains)
            domains.defaultsVersion = VpnDomainList.currentDefaultsVersion
            try? saveDomains(domains)
        }
        return domains
    }

    func saveDomains(_ value: VpnDomainList) throws {
        let cleaned = VpnDomainList(
            domains: normalizeDomains(value.domains),
            defaultsVersion: VpnDomainList.currentDefaultsVersion
        )
        try write(cleaned, to: "vpn-domains.json")
    }

    func readRuntimeStatus() -> RuntimeStatus {
        read("runtime-status.json", default: .disconnected)
    }

    func saveRuntimeStatus(_ value: RuntimeStatus) throws {
        try write(value, to: "runtime-status.json")
    }

    // A separate atomic file keeps manual stop intent visible across processes.
    // Missing means a legacy installation; preserve its system VPN behavior.
    func isTunnelRequested() -> Bool { read("tunnel-requested.json", default: true) }

    func setTunnelRequested(_ requested: Bool) throws {
        try write(requested, to: "tunnel-requested.json")
    }

    func readNodes() -> [ProviderNode] {
        read("providers/nodes.json", default: [])
    }

    func saveNodes(_ value: [ProviderNode]) throws {
        try write(value, to: "providers/nodes.json")
    }

    func readGeneratedConfig() -> GeneratedTunnelConfig? {
        readOptional("generated/config.json")
    }

    func saveActiveTunnelConfig(_ raw: String) throws -> URL {
        let destination = url("runtime/active-sing-box.json")
        try writeProtected(Data(raw.utf8), to: destination)
        return destination
    }

    func saveGeneratedConfig(_ value: GeneratedTunnelConfig) throws {
        try write(value, to: "generated/config.json")
        if let singBoxJSON = value.singBoxJSON {
            try writeProtected(Data(singBoxJSON.utf8), to: url("generated/sing-box.json"))
        }
    }

    func installBundledGeoRoutingResources() throws -> GeoRoutingResources? {
        var bundledResources: [(resource: ManagedRuleSetResource, url: URL)] = []
        for resource in RuleSetLibrary.managedResources {
            guard let bundledURL = bundledResourceURL(named: resource.bundledResourceName, extension: "srs") else {
                return nil
            }
            bundledResources.append((resource, bundledURL))
        }

        let rulesDirectory = url("rules")
        try fileManager.createDirectory(at: rulesDirectory, withIntermediateDirectories: true)
        for entry in bundledResources {
            try copyBundledRuleIfMissing(
                from: entry.url,
                to: rulesDirectory.appendingPathComponent(entry.resource.fileName)
            )
        }
        try pruneRuleSetLibrary()
        var record = readRuleSetLibrary()
        if record.status != "updated" && record.status != "error" {
            record.status = record.hasAllManagedFiles ? "installed" : "partial"
            record.lastError = ""
            try saveRuleSetLibrary(record)
        }
        return currentGeoRoutingResources()
    }

    func readRuleSetLibrary() -> RuleSetLibraryRecord {
        mergedRuleSetLibraryRecord(status: nil, lastError: nil)
    }

    func saveDownloadedRuleSetLibrary(
        _ downloadedRuleSets: [String: Data],
        attemptedAt: Date
    ) throws -> RuleSetLibraryRecord {
        let expectedTags = Set(RuleSetLibrary.managedResources.map(\.tag))
        guard Set(downloadedRuleSets.keys) == expectedTags else {
            let missingTag = RuleSetLibrary.managedResources.first { downloadedRuleSets[$0.tag] == nil }?.tag ?? "-"
            throw AppGroupStoreError.missingManagedRuleSet(missingTag)
        }

        var totalBytes = 0
        for resource in RuleSetLibrary.managedResources {
            guard let data = downloadedRuleSets[resource.tag] else {
                throw AppGroupStoreError.missingManagedRuleSet(resource.tag)
            }
            try validateRuleSetData(data, for: resource)
            totalBytes += data.count
        }
        if totalBytes > RuleSetLibrary.maxTotalBytes {
            throw AppGroupStoreError.ruleSetLibraryTooLarge(totalBytes, RuleSetLibrary.maxTotalBytes)
        }

        let rulesDirectory = url("rules")
        try fileManager.createDirectory(at: rulesDirectory, withIntermediateDirectories: true)
        for resource in RuleSetLibrary.managedResources {
            let destinationURL = rulesDirectory.appendingPathComponent(resource.fileName)
            try downloadedRuleSets[resource.tag]!.write(to: destinationURL, options: .atomic)
        }
        try pruneRuleSetLibrary()

        let record = RuleSetLibraryRecord(
            updatedAt: attemptedAt,
            lastAttemptAt: attemptedAt,
            status: "updated",
            lastError: "",
            totalBytes: totalBytes,
            files: RuleSetLibrary.managedResources.map { resource in
                RuleSetFileRecord(
                    tag: resource.tag,
                    fileName: resource.fileName,
                    sourceURL: resource.sourceURLString,
                    bytes: downloadedRuleSets[resource.tag]?.count ?? 0,
                    updatedAt: attemptedAt,
                    source: "remote"
                )
            }
        )
        try saveRuleSetLibrary(record)
        return record
    }

    func saveRuleSetLibraryUpdateFailure(_ message: String, attemptedAt: Date) throws -> RuleSetLibraryRecord {
        var record = readRuleSetLibrary()
        record.lastAttemptAt = attemptedAt
        record.status = "error"
        record.lastError = Redaction.message(message)
        try saveRuleSetLibrary(record)
        return record
    }

    func appendLog(level: String, message: String) {
        guard shouldPersistLog(level) else {
            return
        }
        let entry = LogEntry(level: level, message: Redaction.message(message))
        writeSystemLog(entry)
        logPersistenceQueue.sync {
            pendingLogs.append(entry)
            let normalizedLevel = level.lowercased()
            if normalizedLevel == "error" || normalizedLevel == "warn" || normalizedLevel == "warning" || pendingLogs.count >= Self.logBatchSize {
                flushLogsLocked()
            } else {
                scheduleLogFlushLocked()
            }
        }
    }

    func readLogs() -> [LogEntry] {
        logPersistenceQueue.sync {
            let clearedAt: Date = read("diagnostics/log-cleared-at.json", default: .distantPast)
            let persisted: [LogEntry] = read("logs/latest.json", default: [])
            return Array((persisted + pendingLogs).filter { $0.createdAt > clearedAt }.suffix(200))
        }
    }

    func flushLogs() {
        logPersistenceQueue.sync {
            flushLogsLocked()
        }
    }

    func readConnectivityProbeResults() -> [ConnectivityProbeRecord] {
        read("diagnostics/connectivity-probes.json", default: [])
    }

    func saveConnectivityProbeResults(_ value: [ConnectivityProbeRecord]) throws {
        try write(value, to: "diagnostics/connectivity-probes.json")
    }

    func clearDiagnosticData() throws {
        try logPersistenceQueue.sync {
            pendingLogFlush?.cancel()
            pendingLogFlush = nil
            pendingLogs.removeAll()
            try write(Date(), to: "diagnostics/log-cleared-at.json")
            try removeIfExists("logs/latest.json")
        }
        try removeIfExists("diagnostics/connectivity-probes.json")
    }

    func makeDiagnosticReport() -> String {
        flushLogs()
        let subscription = readSubscription()
        let settings = readSettings()
        let diagnosticsSettings = readDiagnosticsSettings()
        let domains = readDomains()
        let runtimeStatus = readRuntimeStatus()
        let nodes = readNodes()
        let generatedConfig = readGeneratedConfig()
        let probeResults = readConnectivityProbeResults()
        let logs = readLogs().sorted { $0.createdAt < $1.createdAt }
        let geoResources = currentGeoRoutingResources()
        let ruleSetLibrary = readRuleSetLibrary()
        let formatter = ISO8601DateFormatter()
        let summaryLines = diagnosticSummary(
            settings: settings,
            generatedConfig: generatedConfig,
            nodes: nodes,
            probeResults: probeResults,
            logs: logs
        )

        var lines: [String] = [
            "split-vpn iPhone diagnostic report",
            "generated_at: \(formatter.string(from: Date()))",
            "",
            "[diagnostic_summary]"
        ] + summaryLines + [
            "",
            "[signing]",
            "app_bundle_id: \(SplitVpnConstants.appBundleIdentifier)",
            "provider_bundle_id: \(SplitVpnConstants.providerBundleIdentifier)",
            "app_group_id: \(SplitVpnConstants.appGroupIdentifier)",
            "uses_placeholder_signing: \(SplitVpnConstants.usesPlaceholderSigning)",
            "using_app_group_container: \(isUsingAppGroupContainer)",
            "app_profile: \(provisioningSummary(for: Bundle.main.bundleURL))",
            "extension_profile: \(extensionProvisioningSummary())",
            "",
            "[runtime]",
            "state: \(runtimeStatus.state.rawValue)",
            "started_at: \(runtimeStatus.startedAt.map { formatter.string(from: $0) } ?? "-")",
            "last_error: \(Redaction.message(runtimeStatus.lastError))",
            "bytes_in: \(runtimeStatus.bytesIn)",
            "bytes_out: \(runtimeStatus.bytesOut)",
            "",
            "[diagnostics_mode]",
            "mode: \(diagnosticsSettings.mode.rawValue)",
            "expires_at: \(diagnosticsSettings.expiresAt.map { formatter.string(from: $0) } ?? "-")",
            "status_interval_ns: \(LibboxDiagnosticsPolicy.statusIntervalNanoseconds(for: diagnosticsSettings.mode))",
            "connection_events_enabled: \(LibboxDiagnosticsPolicy.includesConnectionEvents(for: diagnosticsSettings.mode))",
            "",
            "[subscription]",
            "url: \(Redaction.subscriptionURL(subscription.url))",
            "status: \(subscription.status)",
            "updated_at: \(subscription.updatedAt.map { formatter.string(from: $0) } ?? "-")",
            "node_count_recorded: \(subscription.nodeCount)",
            "node_count_stored: \(nodes.count)",
            "node_type_counts: \(nodeTypeCounts(nodes))",
            "last_error: \(Redaction.message(subscription.lastError))",
            "",
            "[settings]",
            "selected_proxy: \(settings.selectedProxy)",
            "unknown_traffic_policy: \(settings.unknownTrafficPolicy)",
            "packet_tunnel_mtu: \(settings.packetTunnelMTU)",
            "proxy_server_domain_resolver: \(settings.proxyServerDomainResolver)",
            "routing_defaults_version: \(settings.routingDefaultsVersion)",
            "vpn_domain_count: \(domains.domains.count)",
            "vpn_domain_defaults_version: \(domains.defaultsVersion)",
            "builtin_direct_domain_count: \(DefaultRules.directDomainSuffixes.count)",
            "selected_node: \(selectedNodeSummary(settings: settings, generatedConfig: generatedConfig, nodes: nodes))",
            "",
            "[rule_set_library]",
            "status: \(ruleSetLibrary.status)",
            "updated_at: \(ruleSetLibrary.updatedAt.map { formatter.string(from: $0) } ?? "-")",
            "last_attempt_at: \(ruleSetLibrary.lastAttemptAt.map { formatter.string(from: $0) } ?? "-")",
            "last_error: \(Redaction.message(ruleSetLibrary.lastError))",
            "total_bytes: \(ruleSetLibrary.totalBytes)",
            "files: \(ruleSetLibrarySummary(ruleSetLibrary))",
            "",
            "[generated_config]",
            "exists: \(generatedConfig != nil)",
            "generated_at: \(generatedConfig.map { formatter.string(from: $0.generatedAt) } ?? "-")",
            "selected_proxy: \(generatedConfig?.selectedProxy ?? "-")",
            "provider_node_count: \(generatedConfig?.providerNodeCount ?? 0)",
            "converted_outbound_count: \(generatedConfig?.convertedOutboundCount ?? 0)",
            "unsupported_node_count: \(generatedConfig?.unsupportedNodeCount ?? 0)",
            "selected_outbound_tag: \(generatedConfig?.selectedOutboundTag ?? "-")",
            "selected_proxy_status: \(generatedConfig?.selectedProxyStatus ?? "-")",
            "selected_proxy_message: \(Redaction.message(generatedConfig?.selectedProxyMessage ?? "-"))",
            "packet_tunnel_mtu: \(generatedConfig?.packetTunnelMTU ?? settings.packetTunnelMTU)",
            "yaml_bytes: \(generatedConfig?.yaml.utf8.count ?? 0)",
            "sing_box_json_bytes: \(generatedConfig?.singBoxJSON?.utf8.count ?? 0)",
            "selected_outbound: \(selectedOutboundSummary(generatedConfig))",
            "proxy_selector: \(proxySelectorSummary(generatedConfig))",
            "outbounds: \(outboundCollectionSummary(generatedConfig))",
            "dns_servers: \(dnsServerSummary(generatedConfig))",
            "dns_rules: \(dnsRuleSummary(generatedConfig))",
            "route: \(routeSummary(generatedConfig))",
            "route_rules: \(routeRuleSummary(generatedConfig))",
            "",
            "[geo_routing]",
            "geoip_cn: \(geoResourceSummary(geoResources?.geoipCNPath))",
            "geosite_cn: \(geoResourceSummary(geoResources?.geositeCNPath))",
            "geosite_non_cn: \(geoResourceSummary(geoResources?.geositeNonCNPath))",
            "",
            "[connectivity_probe]",
            "result_count: \(probeResults.count)",
            "summary: \(connectivityProbeStats(probeResults))",
            "results: \(connectivityProbeSummary(probeResults, formatter: formatter))",
            "",
            "[route_decision]",
            "openai.com: \(routeDecisionSummary(for: "openai.com", domains: domains, settings: settings))",
            "chat.openai.com: \(routeDecisionSummary(for: "chat.openai.com", domains: domains, settings: settings))",
            "www.google.com: \(routeDecisionSummary(for: "www.google.com", domains: domains, settings: settings))",
            "www.youtube.com: \(routeDecisionSummary(for: "www.youtube.com", domains: domains, settings: settings))",
            "r1---sn-test.googlevideo.com: \(routeDecisionSummary(for: "r1---sn-test.googlevideo.com", domains: domains, settings: settings))",
            "www.baidu.com: \(routeDecisionSummary(for: "www.baidu.com", domains: domains, settings: settings))",
            "www.qq.com: \(routeDecisionSummary(for: "www.qq.com", domains: domains, settings: settings))",
            "unmatched.example: \(routeDecisionSummary(for: "unmatched.example", domains: domains, settings: settings))",
            "",
            "[tunnel_addressing]",
            "interface_address: \(TunnelAddressing.interfaceAddress)",
            "remote_address: \(TunnelAddressing.remoteAddress)",
            "sing_box_tun_address: \(TunnelAddressing.singBoxTunAddress)",
            "default_mtu: \(TunnelAddressing.defaultMTU)",
            "active_config_mtu: \(generatedConfig?.packetTunnelMTU ?? settings.packetTunnelMTU)",
            "supported_mtu_values: \(TunnelAddressing.supportedMTUs.map(String.init).joined(separator: ", "))",
            "direct_ipv4_routes: \(DefaultRules.directIPv4Routes.map(\.cidr).joined(separator: ", "))",
            "",
            "[recent_connection_events]",
            logSummary(
                logs,
                formatter: formatter,
                matching: ["Libbox connection "],
                limit: 30
            ),
            "",
            "[recent_network_path_events]",
            logSummary(
                logs,
                formatter: formatter,
                matching: ["Network path baseline", "Network path changed", "Network path update"],
                limit: 20
            ),
            "",
            "[recent_interface_events]",
            logSummary(
                logs,
                formatter: formatter,
                matching: [
                    "Packet tunnel applying network settings",
                    "Libbox openTun",
                    "Libbox getInterfaces",
                    "Libbox default interface"
                ],
                limit: 30
            ),
            "",
            "[logs]"
        ]

        if logs.isEmpty {
            lines.append("no logs")
        } else {
            lines.append(contentsOf: logs.map { entry in
                "\(formatter.string(from: entry.createdAt)) [\(entry.level)] \(entry.message)"
            })
        }

        return lines.joined(separator: "\n")
    }

    func url(_ relativePath: String) -> URL {
        rootURL.appendingPathComponent(relativePath)
    }

    private func currentGeoRoutingResources() -> GeoRoutingResources? {
        let geoIPURL = url("rules/geoip-cn.srs")
        let geositeURL = url("rules/geosite-cn.srs")
        let geositeNonCNURL = url("rules/geosite-geolocation-!cn.srs")
        guard isValidRuleSetFile(at: geoIPURL),
              isValidRuleSetFile(at: geositeURL),
              isValidRuleSetFile(at: geositeNonCNURL) else {
            return nil
        }
        return GeoRoutingResources(
            geoipCNPath: geoIPURL.path,
            geositeCNPath: geositeURL.path,
            geositeNonCNPath: geositeNonCNURL.path
        )
    }

    private func read<T: Decodable>(_ relativePath: String, default defaultValue: T) -> T {
        readOptional(relativePath) ?? defaultValue
    }

    private func readOptional<T: Decodable>(_ relativePath: String) -> T? {
        let fileURL = url(relativePath)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode(T.self, from: data)
        } catch {
            return nil
        }
    }

    private func write<T: Encodable>(_ value: T, to relativePath: String) throws {
        let fileURL = url(relativePath)
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(value)
        try writeProtected(data, to: fileURL)
    }

    private func writeProtected(_ data: Data, to fileURL: URL) throws {
        #if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: fileURL, options: .atomic)
        #endif
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func removeIfExists(_ relativePath: String) throws {
        let fileURL = url(relativePath)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
    }

    private func ensureDirectories() {
        ["providers", "generated", "logs", "runtime", "rules", "diagnostics"].forEach { path in
            try? fileManager.createDirectory(at: url(path), withIntermediateDirectories: true)
        }
    }

    private func bundledResourceURL(named name: String, extension pathExtension: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: pathExtension) ??
            Bundle.main.url(forResource: name, withExtension: pathExtension, subdirectory: "geodata")
    }

    private func saveRuleSetLibrary(_ value: RuleSetLibraryRecord) throws {
        try write(value, to: "rules/manifest.json")
    }

    private func mergedRuleSetLibraryRecord(status: String?, lastError: String?) -> RuleSetLibraryRecord {
        var record: RuleSetLibraryRecord = read("rules/manifest.json", default: .empty)
        let previousByTag = Dictionary(uniqueKeysWithValues: record.files.map { ($0.tag, $0) })
        var files: [RuleSetFileRecord] = []
        var totalBytes = 0

        for resource in RuleSetLibrary.managedResources {
            let fileURL = url("rules/\(resource.fileName)")
            let bytes = Int(fileSize(at: fileURL))
            guard bytes > 0, isValidRuleSetFile(at: fileURL) else {
                continue
            }
            totalBytes += bytes
            let previous = previousByTag[resource.tag]
            files.append(
                RuleSetFileRecord(
                    tag: resource.tag,
                    fileName: resource.fileName,
                    sourceURL: resource.sourceURLString,
                    bytes: bytes,
                    updatedAt: previous?.updatedAt,
                    source: previous?.source ?? "bundled"
                )
            )
        }

        record.files = files
        record.totalBytes = totalBytes
        if let status {
            record.status = status
        } else if record.status == "not-installed", !files.isEmpty {
            record.status = files.count == RuleSetLibrary.managedResources.count ? "installed" : "partial"
        }
        if let lastError {
            record.lastError = lastError
        }
        return record
    }

    private func pruneRuleSetLibrary() throws {
        let rulesDirectory = url("rules")
        let allowedFileNames = RuleSetLibrary.managedFileNames.union(["manifest.json"])
        let contents = (try? fileManager.contentsOfDirectory(
            at: rulesDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for fileURL in contents {
            let fileName = fileURL.lastPathComponent
            let shouldRemove = (fileURL.pathExtension == "srs" && !allowedFileNames.contains(fileName)) ||
                fileName.hasSuffix(".download")
            if shouldRemove {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    private func validateRuleSetData(_ data: Data, for resource: ManagedRuleSetResource) throws {
        if data.count < RuleSetLibrary.minFileBytes {
            throw AppGroupStoreError.invalidRuleSetFile(resource.tag)
        }
        if data.count > resource.maxBytes {
            throw AppGroupStoreError.ruleSetTooLarge(resource.tag, data.count, resource.maxBytes)
        }
        let magic = Array(data.prefix(3))
        if magic != [0x53, 0x52, 0x53] {
            throw AppGroupStoreError.invalidRuleSetFile(resource.tag)
        }
    }

    private func copyBundledRuleIfMissing(from sourceURL: URL, to destinationURL: URL) throws {
        if isValidRuleSetFile(at: destinationURL) {
            return
        }
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private func isValidRuleSetFile(at fileURL: URL) -> Bool {
        guard fileSize(at: fileURL) >= UInt64(RuleSetLibrary.minFileBytes),
              let data = try? Data(contentsOf: fileURL) else {
            return false
        }
        return Array(data.prefix(3)) == [0x53, 0x52, 0x53]
    }

    private func shouldPersistLog(_ level: String) -> Bool {
        level.lowercased() != "debug"
    }

    private func scheduleLogFlushLocked() {
        guard pendingLogFlush == nil else {
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.pendingLogFlush = nil
            self.flushLogsLocked()
        }
        pendingLogFlush = workItem
        logPersistenceQueue.asyncAfter(
            deadline: .now() + Self.logFlushInterval,
            execute: workItem
        )
    }

    private func flushLogsLocked() {
        pendingLogFlush?.cancel()
        pendingLogFlush = nil
        guard !pendingLogs.isEmpty else {
            return
        }

        let clearedAt: Date = read("diagnostics/log-cleared-at.json", default: .distantPast)
        let nextPending = pendingLogs.filter { $0.createdAt > clearedAt }
        pendingLogs.removeAll { $0.createdAt <= clearedAt }
        guard !nextPending.isEmpty else {
            return
        }
        var entries: [LogEntry] = read("logs/latest.json", default: [])
        entries.removeAll { $0.createdAt <= clearedAt }
        entries.append(contentsOf: nextPending)
        entries = Array(entries.suffix(200))
        do {
            try write(entries, to: "logs/latest.json")
            pendingLogs.removeFirst(nextPending.count)
        } catch {
            scheduleLogFlushLocked()
        }
    }

    private func writeSystemLog(_ entry: LogEntry) {
        let message = "[\(entry.level)] \(entry.message)"
        switch entry.level.lowercased() {
        case "error":
            runtimeLogger.error("\(message, privacy: .public)")
        case "warn", "warning":
            runtimeLogger.warning("\(message, privacy: .public)")
        case "debug":
            runtimeLogger.debug("\(message, privacy: .public)")
        default:
            runtimeLogger.info("\(message, privacy: .public)")
        }
    }

    private func extensionProvisioningSummary() -> String {
        let pluginsURL = Bundle.main.bundleURL.appendingPathComponent("PlugIns", isDirectory: true)
        guard let pluginURLs = try? fileManager.contentsOfDirectory(
            at: pluginsURL,
            includingPropertiesForKeys: nil
        ) else {
            return "missing PlugIns directory"
        }
        guard let extensionURL = pluginURLs.first(where: { $0.pathExtension == "appex" }) else {
            return "missing appex"
        }
        return provisioningSummary(for: extensionURL)
    }

    private func provisioningSummary(for bundleURL: URL) -> String {
        let profileURL = bundleURL.appendingPathComponent("embedded.mobileprovision")
        guard let data = try? Data(contentsOf: profileURL) else {
            return "missing embedded.mobileprovision"
        }
        let text = String(decoding: data, as: UTF8.self)
        let hasPacketTunnel = text.contains("packet-tunnel-provider")
        let hasAppGroup = text.contains(SplitVpnConstants.appGroupIdentifier)
        let hasProviderBundleID = text.contains(SplitVpnConstants.providerBundleIdentifier)
        let hasAppBundleID = text.contains(SplitVpnConstants.appBundleIdentifier)
        return "bytes=\(data.count) packet_tunnel=\(hasPacketTunnel) app_group=\(hasAppGroup) app_id=\(hasAppBundleID) provider_id=\(hasProviderBundleID)"
    }

    private func nodeTypeCounts(_ nodes: [ProviderNode]) -> String {
        let counts = Dictionary(grouping: nodes, by: \.type)
            .mapValues(\.count)
        guard !counts.isEmpty else {
            return "-"
        }
        return counts.keys.sorted()
            .map { "\($0)=\(counts[$0] ?? 0)" }
            .joined(separator: ", ")
    }

    private func diagnosticSummary(
        settings: AppSettings,
        generatedConfig: GeneratedTunnelConfig?,
        nodes: [ProviderNode],
        probeResults: [ConnectivityProbeRecord],
        logs: [LogEntry]
    ) -> [String] {
        let selectedProxy = generatedConfig?.selectedProxy ?? settings.selectedProxy
        let selectedStatus = generatedConfig?.selectedProxyStatus ?? "-"
        let selectedOutboundTag = generatedConfig?.selectedOutboundTag ?? "-"
        let manual = isManualProxy(selectedProxy)
        let selectedNode = nodes.first(where: { $0.name == selectedProxy })
        let selectedServerKind = selectedNode.map { serverKind($0.server) } ?? "-"
        let selectedUDP = selectedNode.map { diagnosticSupportsUDP(node: $0) }
        let json = parsedSingBoxJSON(generatedConfig)
        let route = json?["route"] as? [String: Any]
        let routeRules = route?["rules"] as? [[String: Any]] ?? []
        let defaultResolver = route?["default_domain_resolver"] as? String ?? "-"
        let expectedResolver = ProxyServerDomainResolver.normalized(settings.proxyServerDomainResolver)
        let quicBlocked = routeRules.contains {
            stringList($0["protocol"]).contains("quic") && $0["outbound"] as? String == "block"
        }
        let probeHint = connectivityProbeHint(probeResults)
        let connectionEventCount = logCount(logs, matching: ["Libbox connection "])
        let pathEventCount = logCount(logs, matching: ["Network path baseline", "Network path changed", "Network path update"])
        let interfaceEventCount = logCount(logs, matching: [
            "Packet tunnel applying network settings",
            "Libbox openTun",
            "Libbox getInterfaces",
            "Libbox default interface"
        ])
        let nextAction = diagnosticNextAction(
            manual: manual,
            selectedStatus: selectedStatus,
            probeHint: probeHint,
            connectionEventCount: connectionEventCount,
            pathEventCount: pathEventCount,
            interfaceEventCount: interfaceEventCount
        )

        return [
            "manual_selection=\(manual) selected_proxy=\(selectedProxy.ifEmpty("-")) status=\(selectedStatus) selected_outbound_tag=\(selectedOutboundTag)",
            "selected_server_kind=\(selectedServerKind) selected_udp_capable=\(selectedUDP.map(String.init) ?? "-")",
            "default_domain_resolver=\(defaultResolver) resolver_expected=\(expectedResolver) resolver_ok=\(defaultResolver == expectedResolver)",
            "quic_blocked=\(quicBlocked) packet_tunnel_mtu=\(generatedConfig?.packetTunnelMTU ?? settings.packetTunnelMTU)",
            "connectivity_probe=\(probeHint.summary)",
            "event_counts connection=\(connectionEventCount) path=\(pathEventCount) interface=\(interfaceEventCount)",
            "next_action=\(nextAction)"
        ]
    }

    private func isManualProxy(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalized.isEmpty && normalized != "auto" && normalized != "balance" && normalized != "direct"
    }

    private func logCount(_ logs: [LogEntry], matching patterns: [String]) -> Int {
        logs.filter { entry in
            patterns.contains { entry.message.contains($0) }
        }.count
    }

    private struct ConnectivityProbeHint {
        var summary: String
        var suspectedStage: String
    }

    private func connectivityProbeHint(_ records: [ConnectivityProbeRecord]) -> ConnectivityProbeHint {
        let stats = ConnectivityProbeStatsCalculator.summarize(records)
        guard let slowest = stats.max(by: { $0.p50Milliseconds < $1.p50Milliseconds }) else {
            return ConnectivityProbeHint(summary: "missing run_more_connectivity_probe=true", suspectedStage: "missing")
        }

        let stage = suspectedProbeStage(slowest)
        return ConnectivityProbeHint(
            summary: [
                "slowest_target=\(slowest.targetName)",
                "target=\(slowest.targetID)",
                "success=\(slowest.successCount)/\(slowest.count)",
                "p50_ms=\(slowest.p50Milliseconds)",
                optionalTiming("ttfb_p50_ms", slowest.p50FirstByteMilliseconds),
                optionalTiming("dns_p50_ms", slowest.p50DNSMilliseconds),
                optionalTiming("connect_p50_ms", slowest.p50ConnectMilliseconds),
                optionalTiming("tls_p50_ms", slowest.p50TLSMilliseconds),
                optionalTiming("server_wait_p50_ms", slowest.p50ServerWaitMilliseconds),
                "max_ms=\(slowest.maxMilliseconds)",
                "slow_3s=\(slowest.slow3sCount)",
                "suspected_stage=\(stage)"
            ]
            .compactMap { $0 }
            .joined(separator: " "),
            suspectedStage: stage
        )
    }

    private func suspectedProbeStage(_ stat: ConnectivityProbeTargetStats) -> String {
        let stageCandidates: [(String, Int)] = [
            ("dns", stat.p50DNSMilliseconds ?? 0),
            ("tcp_connect", stat.p50ConnectMilliseconds ?? 0),
            ("tls", stat.p50TLSMilliseconds ?? 0),
            ("server_wait", stat.p50ServerWaitMilliseconds ?? 0)
        ]
        if let maxStage = stageCandidates.max(by: { $0.1 < $1.1 }), maxStage.1 >= 1_000 {
            return maxStage.0
        }
        if stat.p50Milliseconds >= ConnectivityProbeStatsCalculator.slowThresholdMilliseconds {
            return "total_without_stage_breakdown"
        }
        if stat.successCount < stat.count {
            return "intermittent_failures"
        }
        return "normal"
    }

    private func diagnosticNextAction(
        manual: Bool,
        selectedStatus: String,
        probeHint: ConnectivityProbeHint,
        connectionEventCount: Int,
        pathEventCount: Int,
        interfaceEventCount: Int
    ) -> String {
        if manual && selectedStatus != "manual-converted" {
            return "fix_selected_node_conversion_or_missing_node"
        }
        if probeHint.suspectedStage == "missing" {
            return "run_more_connectivity_probe_then_export_report"
        }
        switch probeHint.suspectedStage {
        case "dns":
            return "inspect_dns_resolution_and_default_domain_resolver"
        case "tcp_connect", "tls":
            return "inspect_selected_outbound_protocol_and_node_handshake"
        case "server_wait", "total_without_stage_breakdown":
            return "compare_mtu_1280_1400_1500_then_inspect_data_plane"
        case "intermittent_failures":
            return "check_path_events_and_selected_node_stability"
        default:
            break
        }
        if pathEventCount > 0 {
            return "inspect_network_path_change_reconnect_window"
        }
        if connectionEventCount == 0 || interfaceEventCount == 0 {
            return "collect_runtime_connection_and_interface_events"
        }
        return "if_user_still_feels_laggy_inspect_libbox_packet_tunnel_data_plane"
    }

    private func selectedNodeSummary(
        settings: AppSettings,
        generatedConfig: GeneratedTunnelConfig?,
        nodes: [ProviderNode]
    ) -> String {
        let selectedName = generatedConfig?.selectedProxy ?? settings.selectedProxy
        guard !selectedName.isEmpty else {
            return "-"
        }
        if selectedName == "AUTO" || selectedName == "BALANCE" {
            return "name=\(selectedName) automatic=true"
        }
        guard let node = nodes.first(where: { $0.name == selectedName }) else {
            return "name=\(selectedName) missing"
        }
        let metadata = node.metadata ?? [:]
        let network = firstDiagnosticValue(metadata, keys: ["network", "type"]) ?? "-"
        let security = firstDiagnosticValue(metadata, keys: ["security", "tls"]) ?? "-"
        let alpn = splitDiagnosticList(metadata["alpn"])
        let supportsUDP = diagnosticSupportsUDP(node: node)
        return [
            "name=\(node.name)",
            "type=\(node.type)",
            "server=\(serverKind(node.server))",
            "port=\(node.port.map(String.init) ?? "-")",
            "raw_uri=\(node.rawURI != nil)",
            "network=\(network)",
            "security=\(security)",
            "udp_capable=\(supportsUDP)",
            "flow=\(hasAnyValue(metadata, keys: ["flow"]))",
            "server_name=\(hasAnyValue(metadata, keys: ["server_name", "sni", "servername", "host"]))",
            "alpn=\(alpn.count)",
            "fingerprint=\(hasAnyValue(metadata, keys: ["fingerprint", "fp", "client-fingerprint", "client_fingerprint"]))",
            "reality_public_key=\(hasAnyValue(metadata, keys: ["public_key", "public-key", "publicKey", "pbk"]))",
            "reality_short_id=\(hasAnyValue(metadata, keys: ["short_id", "short-id", "shortId", "sid"]))",
            "grpc_service_name=\(hasAnyValue(metadata, keys: ["serviceName", "service_name", "service-name", "grpc-service-name", "grpc_service_name", "grpcServiceName"]))",
            "ws_path=\(hasAnyValue(metadata, keys: ["path"]))",
            "ws_host=\(hasAnyValue(metadata, keys: ["host"]))"
        ].joined(separator: " ")
    }

    private func selectedOutboundSummary(_ generatedConfig: GeneratedTunnelConfig?) -> String {
        let json = parsedSingBoxJSON(generatedConfig)
        let outbounds = outboundList(json)
        guard let selector = outbounds.first(where: { $0["tag"] as? String == "proxy" }) else {
            return "-"
        }
        let selectedTag = (selector["default"] as? String) ?? "-"
        guard let outbound = outbounds.first(where: { $0["tag"] as? String == selectedTag }) else {
            return "tag=\(selectedTag) missing"
        }
        return sanitizedOutboundSummary(outbound, fallbackTag: selectedTag)
    }

    private func proxySelectorSummary(_ generatedConfig: GeneratedTunnelConfig?) -> String {
        let outbounds = outboundList(parsedSingBoxJSON(generatedConfig))
        guard let selector = outbounds.first(where: { $0["tag"] as? String == "proxy" }) else {
            return "-"
        }
        let selectedTag = selector["default"] as? String ?? "-"
        let choices = stringList(selector["outbounds"])
        let preview = choices.prefix(8).joined(separator: ",")
        return "default=\(selectedTag) choices=\(choices.count) preview=[\(preview)]"
    }

    private func outboundCollectionSummary(_ generatedConfig: GeneratedTunnelConfig?) -> String {
        let outbounds = outboundList(parsedSingBoxJSON(generatedConfig))
        guard !outbounds.isEmpty else {
            return "-"
        }
        let groupedByType = Dictionary(grouping: outbounds, by: { $0["type"] as? String ?? "unknown" })
        let typeCounts = groupedByType
            .mapValues(\.count)
            .keys
            .sorted()
            .map { "\($0)=\(groupedByType[$0]?.count ?? 0)" }
            .joined(separator: ",")
        return "count=\(outbounds.count) types={\(typeCounts)}"
    }

    private func dnsServerSummary(_ generatedConfig: GeneratedTunnelConfig?) -> String {
        guard let dns = parsedSingBoxJSON(generatedConfig)?["dns"] as? [String: Any],
              let servers = dns["servers"] as? [[String: Any]] else {
            return "-"
        }
        return servers.map { server in
            let tag = server["tag"] as? String ?? "-"
            let type = server["type"] as? String ?? "-"
            let detour = server["detour"] as? String ?? "-"
            let serverKind = serverKind(server["server"] as? String)
            return "\(tag){type=\(type) server=\(serverKind) detour=\(detour)}"
        }.joined(separator: " ")
    }

    private func dnsRuleSummary(_ generatedConfig: GeneratedTunnelConfig?) -> String {
        guard let dns = parsedSingBoxJSON(generatedConfig)?["dns"] as? [String: Any],
              let rules = dns["rules"] as? [[String: Any]] else {
            return "-"
        }
        let ali = rules.filter { $0["server"] as? String == "ali" }.count
        let cloudflare = rules.filter { $0["server"] as? String == "cloudflare" }.count
        let fakeip = rules.filter { $0["server"] as? String == "fakeip" }.count
        let predefined = rules.filter { $0["action"] as? String == "predefined" }.count
        let aFakeIP = rules.filter { stringList($0["query_type"]).contains("A") && $0["server"] as? String == "fakeip" }.count
        let aaaaNoError = rules.filter { stringList($0["query_type"]).contains("AAAA") && $0["rcode"] as? String == "NOERROR" }.count
        let httpsNoError = rules.filter {
            let types = stringList($0["query_type"])
            return types.contains("HTTPS") && types.contains("SVCB") && $0["rcode"] as? String == "NOERROR"
        }.count
        return "count=\(rules.count) ali=\(ali) cloudflare=\(cloudflare) fakeip=\(fakeip) predefined=\(predefined) a_fakeip=\(aFakeIP) aaaa_noerror=\(aaaaNoError) https_svcb_noerror=\(httpsNoError)"
    }

    private func routeSummary(_ generatedConfig: GeneratedTunnelConfig?) -> String {
        guard let route = parsedSingBoxJSON(generatedConfig)?["route"] as? [String: Any] else {
            return "-"
        }
        let autoDetect = route["auto_detect_interface"] as? Bool ?? false
        let resolver = route["default_domain_resolver"] as? String ?? "-"
        let final = route["final"] as? String ?? "-"
        let ruleSets = (route["rule_set"] as? [[String: Any]] ?? [])
            .compactMap { $0["tag"] as? String }
            .joined(separator: ",")
        return "auto_detect_interface=\(autoDetect) default_domain_resolver=\(resolver) final=\(final) rule_sets=[\(ruleSets)]"
    }

    private func routeRuleSummary(_ generatedConfig: GeneratedTunnelConfig?) -> String {
        guard let route = parsedSingBoxJSON(generatedConfig)?["route"] as? [String: Any],
              let rules = route["rules"] as? [[String: Any]] else {
            return "-"
        }
        let dnsHijack = rules.contains { stringList($0["network"]) == ["udp", "tcp"] && intList($0["port"]) == [53] && $0["action"] as? String == "hijack-dns" }
        let udp443Block = rules.contains { stringList($0["network"]) == ["udp"] && intList($0["port"]) == [443] && $0["outbound"] as? String == "block" }
        let quicBlock = rules.contains { stringList($0["protocol"]).contains("quic") && $0["outbound"] as? String == "block" }
        let domainProxy = rules.filter { $0["domain_suffix"] != nil && $0["outbound"] as? String == "proxy" }.count
        let domainDirect = rules.filter { $0["domain_suffix"] != nil && $0["outbound"] as? String == "direct" }.count
        let ruleSetProxy = rules.filter { $0["rule_set"] != nil && $0["outbound"] as? String == "proxy" }.count
        let ruleSetDirect = rules.filter { $0["rule_set"] != nil && $0["outbound"] as? String == "direct" }.count
        return "count=\(rules.count) dns_hijack=\(dnsHijack) udp443_block=\(udp443Block) quic_block=\(quicBlock) domain_proxy=\(domainProxy) domain_direct=\(domainDirect) rule_set_proxy=\(ruleSetProxy) rule_set_direct=\(ruleSetDirect)"
    }

    private func parsedSingBoxJSON(_ generatedConfig: GeneratedTunnelConfig?) -> [String: Any]? {
        guard let singBoxJSON = generatedConfig?.singBoxJSON,
              let data = singBoxJSON.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func outboundList(_ json: [String: Any]?) -> [[String: Any]] {
        json?["outbounds"] as? [[String: Any]] ?? []
    }

    private func sanitizedOutboundSummary(_ outbound: [String: Any], fallbackTag: String) -> String {
        let tag = outbound["tag"] as? String ?? fallbackTag
        let type = outbound["type"] as? String ?? "-"
        let port = outbound["server_port"].map { "\($0)" } ?? "-"
        let network = outbound["network"] as? String ?? "-"
        let transport = transportSummary(outbound["transport"] as? [String: Any])
        let tls = tlsSummary(outbound["tls"] as? [String: Any])
        let hasUsername = !((outbound["username"] as? String) ?? "").isEmpty
        let hasPassword = !((outbound["password"] as? String) ?? "").isEmpty
        let hasUUID = !((outbound["uuid"] as? String) ?? "").isEmpty
        let hasFlow = !((outbound["flow"] as? String) ?? "").isEmpty
        let hasObfs = outbound["obfs"] != nil
        let hasUpMbps = outbound["up_mbps"] != nil
        let hasDownMbps = outbound["down_mbps"] != nil
        let congestionControl = !((outbound["congestion_control"] as? String) ?? "").isEmpty
        let udpRelayMode = !((outbound["udp_relay_mode"] as? String) ?? "").isEmpty
        let udpOverStream = outbound["udp_over_stream"] as? Bool ?? false
        let zeroRTT = outbound["zero_rtt_handshake"] as? Bool ?? false
        let heartbeat = !((outbound["heartbeat"] as? String) ?? "").isEmpty
        return "tag=\(tag) type=\(type) server=\(serverKind(outbound["server"] as? String)) port=\(port) network=\(network) transport=\(transport) tls=\(tls) username=\(hasUsername) password=\(hasPassword) uuid=\(hasUUID) flow=\(hasFlow) obfs=\(hasObfs) up_mbps=\(hasUpMbps) down_mbps=\(hasDownMbps) congestion_control=\(congestionControl) udp_relay_mode=\(udpRelayMode) udp_over_stream=\(udpOverStream) zero_rtt=\(zeroRTT) heartbeat=\(heartbeat)"
    }

    private func tlsSummary(_ tls: [String: Any]?) -> String {
        guard let tls else {
            return "false"
        }
        let enabled = tls["enabled"] as? Bool ?? true
        let hasServerName = !((tls["server_name"] as? String) ?? "").isEmpty
        let insecure = tls["insecure"] as? Bool ?? false
        let alpn = stringList(tls["alpn"])
        let hasUTLS = tls["utls"] != nil
        let reality = tls["reality"] as? [String: Any]
        let hasReality = reality != nil
        let hasRealityPublicKey = !((reality?["public_key"] as? String) ?? "").isEmpty
        let hasRealityShortID = !((reality?["short_id"] as? String) ?? "").isEmpty
        return "enabled=\(enabled),server_name=\(hasServerName),insecure=\(insecure),alpn=\(alpn.count),utls=\(hasUTLS),reality=\(hasReality),reality_public_key=\(hasRealityPublicKey),reality_short_id=\(hasRealityShortID)"
    }

    private func transportSummary(_ transport: [String: Any]?) -> String {
        guard let transport else {
            return "-"
        }
        let type = transport["type"] as? String ?? "-"
        let hasPath = !((transport["path"] as? String) ?? "").isEmpty
        let hasHeaders = transport["headers"] != nil
        let hasServiceName = !((transport["service_name"] as? String) ?? "").isEmpty
        return "type=\(type),path=\(hasPath),headers=\(hasHeaders),service_name=\(hasServiceName)"
    }

    private func serverKind(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return "-"
        }
        if value.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil {
            return "ipv4"
        }
        if value.contains(":") {
            return "ipv6-or-literal"
        }
        return "domain"
    }

    private func stringList(_ value: Any?) -> [String] {
        if let values = value as? [String] {
            return values
        }
        if let value = value as? String {
            return [value]
        }
        return []
    }

    private func intList(_ value: Any?) -> [Int] {
        if let values = value as? [Int] {
            return values
        }
        if let values = value as? [NSNumber] {
            return values.map(\.intValue)
        }
        if let value = value as? Int {
            return [value]
        }
        if let value = value as? NSNumber {
            return [value.intValue]
        }
        return []
    }

    private func connectivityProbeSummary(
        _ records: [ConnectivityProbeRecord],
        formatter: ISO8601DateFormatter
    ) -> String {
        guard !records.isEmpty else {
            return "-"
        }
        return records.map { record in
            let status = record.statusCode.map { "HTTP \($0)" } ?? "no-status"
            let error = Redaction.message(record.errorMessage ?? "")
                .replacingOccurrences(of: "\n", with: " ")
            let preview = Redaction.message(record.bodyPreview ?? "")
                .replacingOccurrences(of: "\n", with: " ")
            let timing = connectivityProbeTimingSummary(record)
            let timingText = timing.isEmpty ? "" : " \(timing)"
            return "{time=\(formatter.string(from: record.startedAt)) target=\(record.targetName) round=\(record.roundIndex ?? 1)/\(record.roundCount ?? 1) status=\(status) ms=\(record.durationMilliseconds)\(timingText) bytes=\(record.responseBytes) error=\(error.ifEmpty("-")) preview=\(preview.ifEmpty("-"))}"
        }.joined(separator: " ")
    }

    private func connectivityProbeTimingSummary(_ record: ConnectivityProbeRecord) -> String {
        [
            optionalTiming("ttfb_ms", record.firstByteMilliseconds),
            optionalTiming("dns_ms", record.dnsMilliseconds),
            optionalTiming("connect_ms", record.connectMilliseconds),
            optionalTiming("tls_ms", record.tlsMilliseconds),
            optionalTiming("request_ms", record.requestMilliseconds),
            optionalTiming("server_wait_ms", record.serverWaitMilliseconds),
            optionalTiming("response_ms", record.responseTransferMilliseconds),
            record.networkProtocolName.map { "protocol=\($0)" },
            record.reusedConnection.map { "reused=\($0)" },
            record.proxyConnection.map { "proxy_connection=\($0)" }
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    private func optionalTiming(_ key: String, _ value: Int?) -> String? {
        value.map { "\(key)=\($0)" }
    }

    private func connectivityProbeStats(_ records: [ConnectivityProbeRecord]) -> String {
        let stats = ConnectivityProbeStatsCalculator.summarize(records)
        guard !stats.isEmpty else {
            return "-"
        }
        return stats.map { stat in
            "\(stat.targetName){target=\(stat.targetID) \(stat.summaryText)}"
        }.joined(separator: " ")
    }

    private func geoResourceSummary(_ path: String?) -> String {
        guard let path, !path.isEmpty else {
            return "missing"
        }
        let bytes = fileSize(at: URL(fileURLWithPath: path))
        guard bytes > 0 else {
            return "missing path=\(path)"
        }
        return "path=\(path) bytes=\(bytes)"
    }

    private func ruleSetLibrarySummary(_ record: RuleSetLibraryRecord) -> String {
        guard !record.files.isEmpty else {
            return "-"
        }
        return record.files
            .sorted { $0.tag < $1.tag }
            .map { file in
                "\(file.tag){bytes=\(file.bytes) source=\(file.source)}"
            }
            .joined(separator: " ")
    }

    private func logSummary(
        _ logs: [LogEntry],
        formatter: ISO8601DateFormatter,
        matching patterns: [String],
        limit: Int
    ) -> String {
        let matched = logs.filter { entry in
            patterns.contains { entry.message.contains($0) }
        }
        guard !matched.isEmpty else {
            return "count=0"
        }
        let recent = matched.suffix(limit)
        let entries = recent.map { entry in
            "\(formatter.string(from: entry.createdAt)) [\(entry.level)] \(entry.message)"
        }
        return "count=\(matched.count) showing=\(entries.count)\n\(entries.joined(separator: "\n"))"
    }

    private func diagnosticSupportsUDP(node: ProviderNode) -> Bool {
        let metadata = node.metadata ?? [:]
        if let explicit = diagnosticBoolean(firstDiagnosticValue(
            metadata,
            keys: ["udp", "udp-relay", "udp_relay", "udpRelay"]
        )) {
            return explicit
        }
        if let relayMode = firstDiagnosticValue(metadata, keys: ["udp-relay-mode", "udp_relay_mode"]),
           !["", "none", "disabled", "false", "0"].contains(relayMode.lowercased()) {
            return true
        }
        if let networkSupportsUDP = diagnosticNetworkSupportsUDP(firstDiagnosticValue(metadata, keys: ["network"])) {
            return networkSupportsUDP
        }
        switch node.type {
        case "hysteria2", "tuic":
            return true
        default:
            return false
        }
    }

    private func diagnosticBoolean(_ value: String?) -> Bool? {
        guard let value else {
            return nil
        }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y", "on", "enable", "enabled":
            return true
        case "0", "false", "no", "n", "off", "disable", "disabled":
            return false
        default:
            return nil
        }
    }

    private func firstDiagnosticValue(_ metadata: [String: String], keys: [String]) -> String? {
        keys.compactMap { key in
            let value = metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }.first
    }

    private func hasAnyValue(_ metadata: [String: String], keys: [String]) -> Bool {
        firstDiagnosticValue(metadata, keys: keys) != nil
    }

    private func splitDiagnosticList(_ value: String?) -> [String] {
        guard let value else {
            return []
        }
        return value
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func diagnosticNetworkSupportsUDP(_ network: String?) -> Bool? {
        let parts = splitDiagnosticList(network?.replacingOccurrences(of: " ", with: ",").lowercased())
        guard !parts.isEmpty else {
            return nil
        }
        if parts.contains("udp") {
            return true
        }
        if parts.allSatisfy({ $0 == "tcp" || $0 == "ws" || $0 == "grpc" || $0 == "http" }) {
            return false
        }
        return nil
    }

    private func fileSize(at url: URL) -> UInt64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.uint64Value
    }

    private func routeDecisionSummary(
        for target: String,
        domains: VpnDomainList,
        settings: AppSettings
    ) -> String {
        let decision = DefaultRules.routeDecision(
            for: target,
            vpnDomains: domains.domains,
            unknownTrafficPolicy: settings.unknownTrafficPolicy
        )
        return "target=\(decision.normalizedTarget) outbound=\(decision.outbound) rule=\(decision.matchedRule)"
    }

    private func normalizeDomains(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }))
            .sorted()
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
