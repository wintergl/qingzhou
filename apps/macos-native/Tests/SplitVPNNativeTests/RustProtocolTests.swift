import Foundation
import XCTest
@testable import SplitVPNNative

final class RustProtocolTests: XCTestCase {
    func testDiagnosticsDistinguishProxySuccessFromSystemAccessFailure() throws {
        let data = Data("""
        {"domesticOk":true,"foreignOk":false,"proxyOk":true,"externalIp":null,
         "error":"系统 DNS 与 VPN DNS 不一致。","latency":{"domesticMs":20,"foreignMs":30},
         "systemDns":{"ok":false,"error":"系统 DNS 与 VPN DNS 不一致。"},
         "chatgpt":{"ok":true,"httpStatus":200,"elapsedMs":40,"error":null}}
        """.utf8)
        let result = try JSONDecoder().decode(Connectivity.self, from: data)
        XCTAssertEqual(result.proxyOk, true)
        XCTAssertFalse(result.foreignOk)
        XCTAssertEqual(result.systemDns?.ok, false)
        XCTAssertEqual(result.chatgpt?.httpStatus, 200)
        let legacy = Data("""
        {"domesticOk":true,"foreignOk":true,"latency":{}}
        """.utf8)
        XCTAssertNil(try JSONDecoder().decode(Connectivity.self, from: legacy).systemDns)
    }

    func testRustBootstrapDecodesWithExistingSwiftModelsAndPreservesSettings() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = ProcessInfo.processInfo.environment["SPLITVPN_CORE_BINARY"]
            ?? root.appendingPathComponent("packages/vpn-core/target/debug/splitvpn-core").path
        guard FileManager.default.isExecutableFile(atPath: binary) else { throw XCTSkip("Build the Rust core before running its IPC contract test.") }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("splitvpn-swift-rust-\(UUID())")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let rules = (0..<5000).map { "DOMAIN-SUFFIX,fixture-\($0).invalid" }
        let settings: [String: Any] = ["settingsVersion": 10, "selectedProxy": "DIRECT", "tun": false,
            "ipv6": true, "lanDirect": false, "tailscaleDirect": false, "vpnDomainRules": rules,
            "favoriteNodeNames": ["kept"], "nodeGroups": [["id": "group", "name": "常用", "nodeNames": ["kept"]]]]
        let before = try JSONSerialization.data(withJSONObject: settings)
        let settingsURL = fixture.appendingPathComponent("settings.json")
        try before.write(to: settingsURL)
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.environment = ["SPLITVPN_DATA_DIR": fixture.path, "SPLITVPN_RESOURCES": fixture.path, "SPLITVPN_ISOLATED": "1"]
        try process.run()
        var request = try JSONSerialization.data(withJSONObject: ["id": "bootstrap", "channel": "native:bootstrap"])
        request.append(10)
        try input.fileHandleForWriting.write(contentsOf: request)
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        // Background events share this JSONL stream and have different payloads.
        // Decode the envelope first, as CoreService does, then the requested reply.
        struct Reply: Decodable { var id: String?; var ok: Bool?; var data: JSONValue? }
        let replies = try data.split(separator: 10).map { try JSONDecoder().decode(Reply.self, from: Data($0)) }
        let reply = try XCTUnwrap(replies.first { $0.id == "bootstrap" })
        XCTAssertEqual(reply.ok, true)
        let bootstrap = try JSONDecoder().decode(Bootstrap.self, from: XCTUnwrap(reply.data).encoded)
        XCTAssertFalse(bootstrap.previewOnly)
        XCTAssertEqual(bootstrap.status.settings.vpnDomainRules, rules)
        XCTAssertFalse(bootstrap.status.settings.tun)
        XCTAssertTrue(bootstrap.status.settings.ipv6)
        XCTAssertEqual(bootstrap.status.settings.favoriteNodeNames, ["kept"])
        XCTAssertEqual(bootstrap.nodes.map(\.name), ["DIRECT"])
        XCTAssertEqual(bootstrap.groups.first?.group.name, "常用")
        XCTAssertEqual(try Data(contentsOf: settingsURL), before)
    }
}
