import Foundation
import Security

enum MobileSecretVault {
    static func load(_ account: String) throws -> Data? {
        var query = base(account); query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw vaultError(status) }
        return result as? Data
    }
    static func save(_ account: String, data: Data?) throws {
        let query = base(account)
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw vaultError(status) }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query; attributes.forEach { insert[$0.key] = $0.value }
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw vaultError(added) }
        } else if status != errSecSuccess { throw vaultError(status) }
    }
    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.splitvpn.iphone.secrets", kSecAttrAccount as String: account]
    }
    private static func vaultError(_ status: OSStatus) -> NSError {
        NSError(domain: "MobileSecretVault", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "安全存储暂不可用，请解锁设备后重试。"])
    }
}
