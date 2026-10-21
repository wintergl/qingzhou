import Foundation
import Security

struct CompanyCredentials: Codable, Equatable, Sendable {
    let origin: String
    let domain: String
    let username: String
    let password: String
    static func gatewayKey(_ origin: String) throws -> String {
        guard let url = URL(string: origin.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host, url.user == nil, url.password == nil else {
            throw CredentialError.message("请先填写有效的 HTTPS 接入网关。")
        }
        return "https://\(host.lowercased())\(url.port.map { $0 == 443 ? "" : ":\($0)" } ?? "")"
    }
}
enum CredentialError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
protocol CompanyCredentialVault: Sendable {
    func load(origin: String) async throws -> CompanyCredentials?
    func save(_ credentials: CompanyCredentials) async throws
    func remove(origin: String) async throws
}

/// All SecItem operations execute on this actor, away from the main actor.
actor KeychainCompanyCredentialVault: CompanyCredentialVault {
    private let service: String
    init(service: String = "dev.split-vpn.company.credentials") { self.service = service }
    private func query(_ origin: String) throws -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: try CompanyCredentials.gatewayKey(origin),
         kSecAttrSynchronizable as String: false]
    }
    func load(origin: String) throws -> CompanyCredentials? {
        var attributes = try query(origin)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = item as? Data else { throw CredentialError.message("钥匙串中的接入账号无法读取。") }
        return try JSONDecoder().decode(CompanyCredentials.self, from: data)
    }
    func save(_ credentials: CompanyCredentials) throws {
        let key = try query(credentials.origin)
        let fields: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(credentials),
                                   kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let updated = SecItemUpdate(key as CFDictionary, fields as CFDictionary)
        if updated == errSecItemNotFound {
            try check(SecItemAdd(key.merging(fields) { _, new in new } as CFDictionary, nil))
        } else { try check(updated) }
    }
    func remove(origin: String) throws {
        let status = SecItemDelete(try query(origin) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "错误 \(status)"
        throw CredentialError.message("接入账号钥匙串操作未完成：\(detail)")
    }
}
