import Foundation
@main struct CompanyTransferSmoke {
    static func rejected(_ body: () throws -> Void) { do { try body(); fatalError("accepted invalid transfer") } catch {} }
    static func main() throws {
        var buffer = CompanyTransferBuffer()
        let chunk = Data("opaque-session".utf8).base64EncodedString()
        try buffer.begin(id: "one", parts: 2, now: 10)
        rejected { try buffer.append(id: "other", index: 0, base64: chunk, now: 11) }
        rejected { try buffer.append(id: "one", index: 1, base64: chunk, now: 11) }
        try buffer.append(id: "one", index: 0, base64: chunk, now: 11)
        try buffer.append(id: "one", index: 0, base64: chunk, now: 11) // Retry is idempotent.
        rejected { _ = try buffer.finish(id: "one", now: 11) }
        try buffer.append(id: "one", index: 1, base64: chunk, now: 11)
        let result = try buffer.finish(id: "one", now: 11)
        precondition(result == "opaque-sessionopaque-session" && buffer.id.isEmpty)
        rejected { _ = try buffer.finish(id: "one", now: 11) }
        try buffer.begin(id: "expired", parts: 1, now: 10)
        rejected { try buffer.append(id: "expired", index: 0, base64: chunk, now: 41) }
        rejected { try buffer.begin(id: "oversize", parts: 4097, now: 10) }
        try buffer.begin(id: "bounded", parts: 4096, now: 10)
        rejected { try buffer.append(id: "bounded", index: 0, base64: String(repeating: "A", count: 2304), now: 11) }
        let full = Data(repeating: 65, count: 1536).base64EncodedString()
        for i in 0..<2730 { try buffer.append(id: "bounded", index: i, base64: full, now: 11) }
        rejected { try buffer.append(id: "bounded", index: 2730, base64: full, now: 11) }
        buffer.clear(); precondition(buffer.id.isEmpty)
        print("CompanyTransferSmoke: ordered transfer, retry, replay, expiry, size and clearing passed")
    }
}
