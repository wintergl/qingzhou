import Foundation

enum GatewayCertificateState: Equatable {
    case pending, systemTrusted, remembered, requiresConfirmation, changed, invalid

    var approved: Bool { self == .systemTrusted || self == .remembered }
    var requiresUserConfirmation: Bool { self == .requiresConfirmation || self == .changed }
    var title: String {
        switch self {
        case .pending: return "正在自动核验证书"
        case .systemTrusted: return "证书已自动核验 · 系统信任"
        case .remembered: return "证书已自动核验 · 与已确认网关一致"
        case .requiresConfirmation: return "首次遇到此证书 · 需要确认一次"
        case .changed: return "网关证书已变化 · 需要重新确认"
        case .invalid: return "证书信息无效或已过期"
        }
    }
}

/// Store only public SHA-256 pins, scoped to the HTTPS host and port. A public
/// probe alone never establishes trust in an unknown self-signed certificate.
struct CompanyGatewayTrust {
    private let preferences: UserDefaults
    private let preferenceKey = "companyConfirmedGatewayCertificates"
    init(preferences: UserDefaults) { self.preferences = preferences }

    func rememberedFingerprint(origin: String) -> String? {
        guard let key = try? CompanyCredentials.gatewayKey(origin),
              let value = preferences.dictionary(forKey: preferenceKey)?[key] as? String else { return nil }
        return Self.normalizedFingerprint(value)
    }

    func evaluate(_ probe: ProbeInfo, now: Date = Date()) -> GatewayCertificateState {
        guard isCurrent(probe, now: now), let fingerprint = Self.normalizedFingerprint(probe.fingerprint) else { return .invalid }
        if let previous = rememberedFingerprint(origin: probe.origin) {
            return previous == fingerprint ? .remembered : .changed
        }
        return probe.systemTrusted == true && probe.nameMatches ? .systemTrusted : .requiresConfirmation
    }

    func isCurrent(_ probe: ProbeInfo, now: Date = Date()) -> Bool {
        guard (try? CompanyCredentials.gatewayKey(probe.origin)) != nil,
              Self.normalizedFingerprint(probe.fingerprint) != nil,
              let expiry = Self.date(probe.validTo), expiry > now else { return false }
        if let raw = probe.validFrom {
            guard let start = Self.date(raw), start <= now else { return false }
        }
        return true
    }

    func remember(_ probe: ProbeInfo, now: Date = Date()) throws {
        guard isCurrent(probe, now: now), let fingerprint = Self.normalizedFingerprint(probe.fingerprint) else {
            throw CredentialError.message("证书信息无效或不在有效期内，请重新检测入口。")
        }
        let key = try CompanyCredentials.gatewayKey(probe.origin)
        var pins = preferences.dictionary(forKey: preferenceKey) as? [String: String] ?? [:]
        pins[key] = fingerprint
        preferences.set(pins, forKey: preferenceKey)
    }

    static func normalizedFingerprint(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ":", with: "").uppercased()
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else { return nil }
        return value
    }
    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let parsed = formatter.date(from: value) { return parsed }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
