import Foundation

enum SplitVpnConstants {
    static let placeholderAppGroupIdentifier = "group.dev.splitvpn.iphone"
    static let placeholderAppBundleIdentifier = "dev.splitvpn.iphone"
    static let placeholderProviderBundleIdentifier = "dev.splitvpn.iphone.PacketTunnel"

    static var appGroupIdentifier: String {
        infoValue("SplitVpnAppGroupIdentifier", fallback: placeholderAppGroupIdentifier)
    }

    static var providerBundleIdentifier: String {
        infoValue("SplitVpnProviderBundleIdentifier", fallback: placeholderProviderBundleIdentifier)
    }

    static var appBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? placeholderAppBundleIdentifier
    }

    static var usesPlaceholderSigning: Bool {
        appGroupIdentifier == placeholderAppGroupIdentifier ||
            providerBundleIdentifier == placeholderProviderBundleIdentifier ||
            appBundleIdentifier == placeholderAppBundleIdentifier
    }

    static let vpnDescription = "split-vpn"
    static let packetTunnelCoreMode = "libbox-static"

    private static func infoValue(_ key: String, fallback: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else {
            return fallback
        }
        return value
    }
}

enum TunnelAddressing {
    static let interfaceAddress = "198.18.0.1"
    static let remoteAddress = "198.18.0.2"
    static let ipv4PrefixLength = 30
    static let ipv4SubnetMask = "255.255.255.252"
    /// Matches `singbox::TUN_ADDRESS6` in the Rust core.
    static let interfaceAddress6 = "fdfe:dcba:9876::1"
    static let ipv6PrefixLength = 126
    static let defaultMTU = 1400
    static let supportedMTUs = [1280, 1400, 1500]
    static let mtu = defaultMTU

    static var singBoxTunAddress: String {
        "\(interfaceAddress)/\(ipv4PrefixLength)"
    }

    static func normalizedMTU(_ value: Int) -> Int {
        supportedMTUs.contains(value) ? value : defaultMTU
    }
}

enum ProxyServerDomainResolver {
    static let cloudflareDirect = "cloudflare-direct"
    static let ali = "ali"
    static let supportedValues = [cloudflareDirect, ali]

    static func normalized(_ value: String) -> String {
        supportedValues.contains(value) ? value : cloudflareDirect
    }
}

enum TunnelConnectionState: String, Codable {
    case disconnected
    case connecting
    case connected
    case disconnecting
    case error
}

struct SubscriptionRecord: Codable, Equatable {
    var url: String
    var updatedAt: Date?
    var nodeCount: Int
    var status: String
    var lastError: String

    static let empty = SubscriptionRecord(
        url: "",
        updatedAt: nil,
        nodeCount: 0,
        status: "empty",
        lastError: ""
    )
}

struct ProviderNode: Codable, Equatable, Identifiable {
    var id: String { identityKey ?? name }
    var name: String
    var type: String
    var server: String
    var port: Int?
    var rawURI: String?
    var metadata: [String: String]?
    var identityKey: String? = nil
    var subscriptionId: String? = nil
    var subscriptionName: String? = nil
    var identityAmbiguous: Bool? = nil
    var iosSupported: Bool? = nil
}

struct AppSettings: Codable, Equatable {
    static let currentRoutingDefaultsVersion = 4

    var selectedProxy: String
    var unknownTrafficPolicy: String
    var packetTunnelMTU: Int
    var proxyServerDomainResolver: String
    var routingDefaultsVersion: Int

    static let defaults = AppSettings(selectedProxy: "AUTO", unknownTrafficPolicy: "direct")

    init(
        selectedProxy: String,
        unknownTrafficPolicy: String,
        packetTunnelMTU: Int = TunnelAddressing.defaultMTU,
        proxyServerDomainResolver: String = ProxyServerDomainResolver.cloudflareDirect,
        routingDefaultsVersion: Int = Self.currentRoutingDefaultsVersion
    ) {
        self.selectedProxy = selectedProxy
        self.unknownTrafficPolicy = unknownTrafficPolicy
        self.packetTunnelMTU = TunnelAddressing.normalizedMTU(packetTunnelMTU)
        self.proxyServerDomainResolver = ProxyServerDomainResolver.normalized(proxyServerDomainResolver)
        self.routingDefaultsVersion = routingDefaultsVersion
    }

    enum CodingKeys: String, CodingKey {
        case selectedProxy
        case unknownTrafficPolicy
        case packetTunnelMTU
        case proxyServerDomainResolver
        case routingDefaultsVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedProxy = try container.decodeIfPresent(String.self, forKey: .selectedProxy) ?? Self.defaults.selectedProxy
        unknownTrafficPolicy = try container.decodeIfPresent(String.self, forKey: .unknownTrafficPolicy) ?? Self.defaults.unknownTrafficPolicy
        packetTunnelMTU = TunnelAddressing.normalizedMTU(
            try container.decodeIfPresent(Int.self, forKey: .packetTunnelMTU) ?? Self.defaults.packetTunnelMTU
        )
        proxyServerDomainResolver = ProxyServerDomainResolver.normalized(
            try container.decodeIfPresent(String.self, forKey: .proxyServerDomainResolver) ?? Self.defaults.proxyServerDomainResolver
        )
        routingDefaultsVersion = try container.decodeIfPresent(Int.self, forKey: .routingDefaultsVersion) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(selectedProxy, forKey: .selectedProxy)
        try container.encode(unknownTrafficPolicy, forKey: .unknownTrafficPolicy)
        try container.encode(packetTunnelMTU, forKey: .packetTunnelMTU)
        try container.encode(proxyServerDomainResolver, forKey: .proxyServerDomainResolver)
        try container.encode(routingDefaultsVersion, forKey: .routingDefaultsVersion)
    }
}

struct RouteDecision: Equatable {
    var input: String
    var normalizedTarget: String
    var outbound: String
    var matchedRule: String
    var detail: String
}

struct GeoRoutingResources: Equatable {
    var geoipCNPath: String
    var geositeCNPath: String
    var geositeNonCNPath: String

    var isAvailable: Bool {
        !geoipCNPath.isEmpty && !geositeCNPath.isEmpty && !geositeNonCNPath.isEmpty
    }
}

struct ManagedRuleSetResource: Equatable, Identifiable {
    var id: String { tag }
    var tag: String
    var fileName: String
    var bundledResourceName: String
    var sourceURLString: String
    var maxBytes: Int

    var sourceURL: URL {
        URL(string: sourceURLString)!
    }
}

enum RuleSetLibrary {
    static let updateInterval: TimeInterval = 7 * 24 * 60 * 60
    static let retryIntervalAfterFailure: TimeInterval = 6 * 60 * 60
    static let minFileBytes = 8
    static let maxTotalBytes = 8 * 1024 * 1024

    static let managedResources = [
        ManagedRuleSetResource(
            tag: "geoip-cn",
            fileName: "geoip-cn.srs",
            bundledResourceName: "geoip-cn",
            sourceURLString: "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
            maxBytes: 2 * 1024 * 1024
        ),
        ManagedRuleSetResource(
            tag: "geosite-cn",
            fileName: "geosite-cn.srs",
            bundledResourceName: "geosite-cn",
            sourceURLString: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
            maxBytes: 4 * 1024 * 1024
        ),
        ManagedRuleSetResource(
            tag: "geosite-geolocation-!cn",
            fileName: "geosite-geolocation-!cn.srs",
            bundledResourceName: "geosite-geolocation-!cn",
            sourceURLString: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs",
            maxBytes: 4 * 1024 * 1024
        )
    ]

    static var managedFileNames: Set<String> {
        Set(managedResources.map(\.fileName))
    }
}

struct RuleSetFileRecord: Codable, Equatable, Identifiable {
    var id: String { tag }
    var tag: String
    var fileName: String
    var sourceURL: String
    var bytes: Int
    var updatedAt: Date?
    var source: String
}

struct RuleSetLibraryRecord: Codable, Equatable {
    var updatedAt: Date?
    var lastAttemptAt: Date?
    var status: String
    var lastError: String
    var totalBytes: Int
    var files: [RuleSetFileRecord]

    static let empty = RuleSetLibraryRecord(
        updatedAt: nil,
        lastAttemptAt: nil,
        status: "not-installed",
        lastError: "",
        totalBytes: 0,
        files: []
    )

    var isUpdateDue: Bool {
        guard let updatedAt else {
            return true
        }
        return Date().timeIntervalSince(updatedAt) >= RuleSetLibrary.updateInterval
    }

    var hasAllManagedFiles: Bool {
        Set(files.map(\.tag)) == Set(RuleSetLibrary.managedResources.map(\.tag))
    }

    var canRetryAutomaticUpdate: Bool {
        guard status == "error", let lastAttemptAt else {
            return true
        }
        return Date().timeIntervalSince(lastAttemptAt) >= RuleSetLibrary.retryIntervalAfterFailure
    }
}

struct VpnDomainList: Codable, Equatable {
    static let currentDefaultsVersion = 5

    var domains: [String]
    var defaultsVersion: Int

    static let defaults = VpnDomainList(domains: DefaultRules.vpnDomains)

    init(domains: [String], defaultsVersion: Int = Self.currentDefaultsVersion) {
        self.domains = domains
        self.defaultsVersion = defaultsVersion
    }

    enum CodingKeys: String, CodingKey {
        case domains
        case defaultsVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        domains = try container.decodeIfPresent([String].self, forKey: .domains) ?? Self.defaults.domains
        defaultsVersion = try container.decodeIfPresent(Int.self, forKey: .defaultsVersion) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(domains, forKey: .domains)
        try container.encode(defaultsVersion, forKey: .defaultsVersion)
    }
}

struct RuntimeStatus: Codable, Equatable {
    var state: TunnelConnectionState
    var startedAt: Date?
    var lastError: String
    var bytesIn: UInt64
    var bytesOut: UInt64
    var configurationRevision: String? = nil
    var networkEpoch: String? = nil

    static let disconnected = RuntimeStatus(
        state: .disconnected,
        startedAt: nil,
        lastError: "",
        bytesIn: 0,
        bytesOut: 0
    )
}

struct RuntimeTrafficSnapshot: Equatable {
    var bytesIn: UInt64
    var bytesOut: UInt64
}

enum RuntimeStatusCheckpointPolicy {
    static let minimumInterval: TimeInterval = 60
    static let maximumInterval: TimeInterval = 5 * 60
    static let minimumTrafficDelta: UInt64 = 256 * 1024

    static func shouldCheckpoint(
        previous: RuntimeStatus?,
        next: RuntimeStatus,
        lastCheckpointAt: Date?,
        now: Date
    ) -> Bool {
        guard let previous, let lastCheckpointAt else {
            return true
        }
        if previous.state != next.state ||
            previous.startedAt != next.startedAt ||
            previous.lastError != next.lastError || previous.configurationRevision != next.configurationRevision || previous.networkEpoch != next.networkEpoch {
            return true
        }

        let elapsed = now.timeIntervalSince(lastCheckpointAt)
        if elapsed >= maximumInterval {
            return true
        }
        guard elapsed >= minimumInterval else {
            return false
        }

        let bytesInDelta = next.bytesIn >= previous.bytesIn ? next.bytesIn - previous.bytesIn : next.bytesIn
        let bytesOutDelta = next.bytesOut >= previous.bytesOut ? next.bytesOut - previous.bytesOut : next.bytesOut
        let totalDelta = bytesInDelta.addingReportingOverflow(bytesOutDelta)
        return totalDelta.overflow || totalDelta.partialValue >= minimumTrafficDelta
    }
}

enum DiagnosticsMode: String, Codable, Equatable {
    case standard
    case deep
}

struct DiagnosticsSettings: Codable, Equatable {
    static let deepDuration: TimeInterval = 10 * 60
    static let maximumDeepDuration: TimeInterval = 30 * 60

    var mode: DiagnosticsMode
    var expiresAt: Date?

    static let standard = DiagnosticsSettings(mode: .standard, expiresAt: nil)

    static func deep(now: Date = Date()) -> DiagnosticsSettings {
        DiagnosticsSettings(mode: .deep, expiresAt: now.addingTimeInterval(deepDuration))
    }

    func normalized(now: Date = Date()) -> DiagnosticsSettings {
        guard mode == .deep, let expiresAt, expiresAt > now else {
            return .standard
        }
        return DiagnosticsSettings(
            mode: .deep,
            expiresAt: min(expiresAt, now.addingTimeInterval(Self.maximumDeepDuration))
        )
    }

    func remainingDuration(now: Date = Date()) -> TimeInterval {
        let effective = normalized(now: now)
        guard effective.mode == .deep, let expiresAt = effective.expiresAt else {
            return 0
        }
        return max(0, expiresAt.timeIntervalSince(now))
    }
}

enum LibboxDiagnosticsPolicy {
    static let minimumIntervalNanoseconds: Int64 = 1_000_000_000
    // Status is also the local health heartbeat. Thirty seconds leaves three
    // sampling intervals inside the existing 90-second failure window.
    static let standardStatusIntervalNanoseconds: Int64 = 30_000_000_000
    static let deepStatusIntervalNanoseconds: Int64 = 5_000_000_000

    static func statusIntervalNanoseconds(for mode: DiagnosticsMode) -> Int64 {
        let requested = mode == .deep ? deepStatusIntervalNanoseconds : standardStatusIntervalNanoseconds
        return max(minimumIntervalNanoseconds, requested)
    }

    static func includesConnectionEvents(for mode: DiagnosticsMode) -> Bool {
        mode == .deep
    }
}

enum ReadinessSeverity: String, Codable, Equatable {
    case ok
    case warning
    case blocking
}

struct ReadinessItem: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var detail: String
    var severity: ReadinessSeverity
}

struct LogEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var createdAt: Date
    var level: String
    var message: String

    init(level: String, message: String) {
        self.id = UUID()
        self.createdAt = Date()
        self.level = level
        self.message = message
    }
}

struct ConnectivityProbeRecord: Codable, Equatable, Identifiable {
    var id: String { "\(targetID)-\(startedAt.timeIntervalSince1970)-\(roundIndex ?? 1)" }
    var targetID: String
    var targetName: String
    var urlString: String
    var startedAt: Date
    var roundIndex: Int?
    var roundCount: Int?
    var durationMilliseconds: Int
    var firstByteMilliseconds: Int?
    var dnsMilliseconds: Int?
    var connectMilliseconds: Int?
    var tlsMilliseconds: Int?
    var requestMilliseconds: Int?
    var serverWaitMilliseconds: Int?
    var responseTransferMilliseconds: Int?
    var networkProtocolName: String?
    var reusedConnection: Bool?
    var proxyConnection: Bool?
    var statusCode: Int?
    var responseBytes: Int
    var bodyPreview: String?
    var errorMessage: String?
}

struct ConnectivityProbeTargetStats: Equatable, Identifiable {
    var id: String { targetID }
    var targetID: String
    var targetName: String
    var count: Int
    var roundCount: Int
    var successCount: Int
    var p50Milliseconds: Int
    var p50FirstByteMilliseconds: Int?
    var p50DNSMilliseconds: Int?
    var p50ConnectMilliseconds: Int?
    var p50TLSMilliseconds: Int?
    var p50ServerWaitMilliseconds: Int?
    var maxMilliseconds: Int
    var slow3sCount: Int
    var latestErrorMessage: String?

    var summaryText: String {
        [
            "count=\(count)",
            "rounds=\(roundCount)",
            "success=\(successCount)",
            "p50_ms=\(p50Milliseconds)",
            optionalSummary("ttfb_p50_ms", p50FirstByteMilliseconds),
            optionalSummary("dns_p50_ms", p50DNSMilliseconds),
            optionalSummary("connect_p50_ms", p50ConnectMilliseconds),
            optionalSummary("tls_p50_ms", p50TLSMilliseconds),
            optionalSummary("server_wait_p50_ms", p50ServerWaitMilliseconds),
            "max_ms=\(maxMilliseconds)",
            "slow_3s=\(slow3sCount)"
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    var timingSummaryText: String {
        [
            optionalSummary("ttfb p50", p50FirstByteMilliseconds),
            optionalSummary("dns p50", p50DNSMilliseconds),
            optionalSummary("connect p50", p50ConnectMilliseconds),
            optionalSummary("tls p50", p50TLSMilliseconds),
            optionalSummary("server wait p50", p50ServerWaitMilliseconds)
        ]
        .compactMap { $0 }
        .joined(separator: "  ")
    }

    private func optionalSummary(_ label: String, _ value: Int?) -> String? {
        value.map { "\(label)=\($0)" }
    }
}

enum ConnectivityProbeStatsCalculator {
    static let slowThresholdMilliseconds = 3000

    static func summarize(_ records: [ConnectivityProbeRecord]) -> [ConnectivityProbeTargetStats] {
        let groups = Dictionary(grouping: records, by: \.targetID)
        return groups.keys.sorted().compactMap { targetID in
            guard let records = groups[targetID], let first = records.first else {
                return nil
            }
            let sortedDurations = records.map(\.durationMilliseconds).sorted()
            let sortedFirstByteDurations = records.compactMap(\.firstByteMilliseconds).sorted()
            let sortedDNSDurations = records.compactMap(\.dnsMilliseconds).sorted()
            let sortedConnectDurations = records.compactMap(\.connectMilliseconds).sorted()
            let sortedTLSDurations = records.compactMap(\.tlsMilliseconds).sorted()
            let sortedServerWaitDurations = records.compactMap(\.serverWaitMilliseconds).sorted()
            let successCount = records.filter { $0.statusCode != nil && ($0.errorMessage ?? "").isEmpty }.count
            let latestError = records.reversed().compactMap { record in
                let message = record.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return message.isEmpty ? nil : message
            }.first
            return ConnectivityProbeTargetStats(
                targetID: targetID,
                targetName: first.targetName,
                count: records.count,
                roundCount: records.map { $0.roundCount ?? 1 }.max() ?? records.count,
                successCount: successCount,
                p50Milliseconds: percentile(sortedDurations, percentile: 0.5),
                p50FirstByteMilliseconds: optionalPercentile(sortedFirstByteDurations, percentile: 0.5),
                p50DNSMilliseconds: optionalPercentile(sortedDNSDurations, percentile: 0.5),
                p50ConnectMilliseconds: optionalPercentile(sortedConnectDurations, percentile: 0.5),
                p50TLSMilliseconds: optionalPercentile(sortedTLSDurations, percentile: 0.5),
                p50ServerWaitMilliseconds: optionalPercentile(sortedServerWaitDurations, percentile: 0.5),
                maxMilliseconds: sortedDurations.max() ?? 0,
                slow3sCount: sortedDurations.filter { $0 >= slowThresholdMilliseconds }.count,
                latestErrorMessage: latestError
            )
        }
    }

    private static func optionalPercentile(_ sortedValues: [Int], percentile: Double) -> Int? {
        guard !sortedValues.isEmpty else {
            return nil
        }
        return Self.percentile(sortedValues, percentile: percentile)
    }

    private static func percentile(_ sortedValues: [Int], percentile: Double) -> Int {
        guard !sortedValues.isEmpty else {
            return 0
        }
        let clamped = min(max(percentile, 0), 1)
        let index = Int((Double(sortedValues.count - 1) * clamped).rounded())
        return sortedValues[index]
    }
}

struct GeneratedTunnelConfig: Codable, Equatable {
    var selectedProxy: String
    var providerNodeCount: Int
    var convertedOutboundCount: Int?
    var unsupportedNodeCount: Int?
    var selectedOutboundTag: String?
    var selectedProxyStatus: String?
    var selectedProxyMessage: String?
    var unknownTrafficPolicy: String
    var packetTunnelMTU: Int?
    var vpnDomains: [String]
    var generatedAt: Date
    var yaml: String
    var singBoxJSON: String?
    var runtimeRevision: String? = nil
}

struct DataPlaneHealthIncident: Equatable {
    var reason: String
    var directTimeoutCount: Int
    var proxyTimeoutCount: Int
    var uniqueEndpointCount: Int
    var windowSeconds: Int

    var summary: String {
        "reason=\(reason) direct_timeouts=\(directTimeoutCount) proxy_timeouts=\(proxyTimeoutCount) unique_endpoints=\(uniqueEndpointCount) window_seconds=\(windowSeconds)"
    }
}

struct DataPlaneHealthMonitor {
    private enum RouteKind {
        case direct
        case proxy
    }

    private struct FailureSample {
        var occurredAt: Date
        var routeKind: RouteKind
        var endpoint: String
    }

    static let defaultWindow: TimeInterval = 15
    static let defaultCooldown: TimeInterval = 120
    static let mixedDirectThreshold = 6
    static let mixedProxyThreshold = 2
    static let proxyOnlyThreshold = 8
    static let directOnlyThreshold = 16
    static let minimumUniqueEndpointCount = 4

    private let window: TimeInterval
    private let cooldown: TimeInterval
    private var samples: [FailureSample] = []
    private var lastIncidentAt: Date?

    init(
        window: TimeInterval = Self.defaultWindow,
        cooldown: TimeInterval = Self.defaultCooldown
    ) {
        self.window = window
        self.cooldown = cooldown
    }

    mutating func observe(logMessage: String, at now: Date = Date()) -> DataPlaneHealthIncident? {
        guard let sample = Self.failureSample(from: logMessage, at: now) else {
            return nil
        }

        samples.append(sample)
        let cutoff = now.addingTimeInterval(-window)
        samples.removeAll { $0.occurredAt < cutoff }
        if samples.count > 128 { samples.removeFirst(samples.count - 128) }

        if let lastIncidentAt, now.timeIntervalSince(lastIncidentAt) < cooldown {
            return nil
        }

        let directSamples = samples.filter { $0.routeKind == .direct }
        let proxySamples = samples.filter { $0.routeKind == .proxy }
        let uniqueEndpointCount = Set(samples.map(\.endpoint)).count
        guard uniqueEndpointCount >= Self.minimumUniqueEndpointCount else {
            return nil
        }

        let reason: String
        if directSamples.count >= Self.mixedDirectThreshold,
           proxySamples.count >= Self.mixedProxyThreshold {
            reason = "mixed_direct_proxy_tcp_timeout_burst"
        } else if directSamples.count >= Self.directOnlyThreshold {
            reason = "direct_tcp_timeout_burst"
        } else if proxySamples.count >= Self.proxyOnlyThreshold {
            reason = "proxy_connection_failure_burst"
        } else {
            return nil
        }

        let incident = DataPlaneHealthIncident(
            reason: reason,
            directTimeoutCount: directSamples.count,
            proxyTimeoutCount: proxySamples.count,
            uniqueEndpointCount: uniqueEndpointCount,
            windowSeconds: Int(window)
        )
        lastIncidentAt = now
        samples.removeAll(keepingCapacity: true)
        return incident
    }

    mutating func resetSamples() {
        samples.removeAll(keepingCapacity: true)
    }

    private static func failureSample(from message: String, at now: Date) -> FailureSample? {
        guard message.contains("connection: open connection to "),
              message.contains(" using outbound/"),
              ["i/o timeout", "connection refused", "connection reset", "network is unreachable", "no route to host", "TLS handshake timeout"].contains(where: message.contains) else {
            return nil
        }

        let routeKind: RouteKind = message.contains(" using outbound/direct[") ? .direct : .proxy
        return FailureSample(
            occurredAt: now,
            routeKind: routeKind,
            endpoint: endpoint(from: message)
        )
    }

    private static func endpoint(from message: String) -> String {
        guard let startRange = message.range(of: "connection: open connection to ") else {
            return "unknown"
        }
        let remainder = message[startRange.upperBound...]
        guard let endRange = remainder.range(of: " using outbound/") else {
            return "unknown"
        }
        return String(remainder[..<endRange.lowerBound])
    }
}
