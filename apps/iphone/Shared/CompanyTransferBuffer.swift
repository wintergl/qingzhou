import Foundation

/// A bounded, ordered, expiring transfer over provider IPC; never a disk file.
struct CompanyTransferBuffer {
    private(set) var id = ""
    private var parts = 0
    private var next = 0
    private var data = Data()
    private var lastPart: Data?
    private var deadline: TimeInterval = 0
    mutating func begin(id: String, parts: Int, now: TimeInterval) throws {
        guard !id.isEmpty, (1...4096).contains(parts) else { throw failure() }
        self.id = id; self.parts = parts; next = 0; data = Data(); lastPart = nil; deadline = now + 30
    }
    mutating func append(id: String, index: Int, base64: String, now: TimeInterval) throws {
        guard self.id == id, now <= deadline, base64.utf8.count <= 2300, let part = Data(base64Encoded: base64), !part.isEmpty else { throw failure() }
        if index == next - 1, part == lastPart { return }
        guard index == next, next < parts, data.count + part.count <= 4 * 1024 * 1024 else { throw failure() }
        data.append(part); lastPart = part; next += 1
    }
    mutating func finish(id: String, now: TimeInterval) throws -> String {
        guard self.id == id, now <= deadline, next == parts, let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw failure() }
        clear(); return value
    }
    mutating func clear() { id = ""; parts = 0; next = 0; data = Data(); lastPart = nil; deadline = 0 }
    private func failure() -> NSError { NSError(domain: "CompanyTransfer", code: 1, userInfo: [NSLocalizedDescriptionKey: "接入会话传输无效或已过期，请重试"] ) }
}
