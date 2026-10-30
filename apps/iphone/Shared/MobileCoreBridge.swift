import Foundation
import SplitVpnCore
import Darwin

/// Shared C ABI transport. The extension uses it for routing transactions only.
enum MobileCoreBridge {
    @TaskLocal static var transactionDescriptor: Int32?
    static func request(channel: String, payload: [String: Any]) throws -> Data {
        var value: [String: Any] = ["channel": channel, "payload": payload]
        if let transactionDescriptor { value["transactionFd"] = transactionDescriptor }
        return try JSONSerialization.data(withJSONObject: value)
    }
    private static func lock(root: URL) throws -> Int32 {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = Darwin.open(root.appendingPathComponent(".mobile-transaction.lock").path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        while flock(fd, LOCK_EX) != 0 { if errno != EINTR { let code = errno; Darwin.close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) } }
        return fd
    }
    private static func unlock(_ fd: Int32) { flock(fd, LOCK_UN); Darwin.close(fd) }
    static func withTransaction<T>(root: URL, operation: () throws -> T) throws -> T {
        let fd = try lock(root: root); defer { unlock(fd) }
        return try $transactionDescriptor.withValue(fd, operation: operation)
    }
    static func withTransaction<T>(root: URL, operation: () async throws -> T) async throws -> T {
        let fd = try await Task.detached { try lock(root: root) }.value
        defer { unlock(fd) }
        return try await $transactionDescriptor.withValue(fd, operation: operation)
    }
    static func invoke(root: String, request: String) -> String {
        guard let reply = qz_core_call(root, request) else { return #"{"ok":false,"error":{"message":"核心没有返回结果"}}"# }
        defer { qz_core_free(reply) }
        return String(cString: reply)
    }
    static func object(root: URL, channel: String, payload: [String: Any] = [:]) throws -> [String: Any] {
        let request = try request(channel: channel, payload: payload)
        let response = invoke(root: root.path, request: String(decoding: request, as: UTF8.self))
        guard let reply = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any], reply["ok"] as? Bool == true, let value = reply["data"] as? [String: Any] else {
            let reply = (try? JSONSerialization.jsonObject(with: Data(response.utf8))) as? [String: Any]
            throw NSError(domain: "MobileCoreBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: (reply?["error"] as? [String: Any])?["message"] as? String ?? "接入分流事务失败"])
        }
        return value
    }
}
