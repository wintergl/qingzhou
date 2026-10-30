import Foundation
import Combine

enum CoreAvailability: Equatable {
    case idle, starting, available, unavailable(String), closed
}

@MainActor
final class CoreService: ObservableObject {
    @Published private(set) var availability: CoreAvailability = .idle
    private(set) var pendingRequestCount = 0
    private let transport: ((String, [String: Any]) async throws -> JSONValue)?
    var usesSystemRuntime: Bool { transport == nil }
    init(transport: ((String, [String: Any]) async throws -> JSONValue)? = nil) { self.transport = transport }
    private var process: Process?
    private var input: FileHandle?
    private var callbacks: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private let reader = DispatchQueue(label: "split-vpn.native.core-reader", qos: .userInitiated)
    var onEvent: ((String, JSONValue?) -> Void)?

    /// Longest wait for one reply, covering an authorization prompt plus
    /// engine start. A core that never answers then fails the request.
    nonisolated static let requestTimeout: Duration = .seconds(300)

    nonisolated static func timeout(for channel: String) -> Duration {
        switch channel {
        case "diagnostics:get-state", "native:bootstrap", "vpn:get-status", "traffic:get-monitor", "traffic:get-snapshot", "nodes:list", "node-groups:list": return .seconds(8)
        case "vpn:stop": return .seconds(45)
        case "nodes:test", "nodes:test-recommended", "connectivity:check", "connectivity:test-website-speeds": return .seconds(40)
        default: return requestTimeout
        }
    }
    func start() throws {
        guard process == nil else { return }
        availability = .starting
        guard let resources = Bundle.main.resourceURL else { throw CoreError.message("应用资源缺失。") }
        // A write racing a core crash must fail with EPIPE, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        let child = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = resources.appendingPathComponent("splitvpn-core")
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        let diagnostics = DiagnosticsTail()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil } else { diagnostics.append(bytes) }
        }
        var environment = ProcessInfo.processInfo.environment
        environment["SPLITVPN_RESOURCES"] = resources.path
        child.environment = environment
        do { try child.run() }
        catch { availability = .unavailable("VPN 服务无法启动。"); throw error }
        process = child; input = stdin.fileHandleForWriting
        reader.async { [weak self] in
            var buffer = Data()
            let handle = stdout.fileHandleForReading
            while true {
                // This work item lasts for the core's lifetime, so drain
                // Foundation's temporary objects after every read.
                let keepReading = autoreleasepool { () -> Bool in
                    let bytes = handle.availableData
                    if bytes.isEmpty { return false }
                    buffer.append(bytes)
                    if buffer.count > 8 * 1024 * 1024 { child.terminate(); return false }
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                        Task { @MainActor [weak self] in self?.receive(line) }
                    }
                    return true
                }
                if !keepReading { break }
            }
            child.waitUntilExit()
            // Let the last stderr line written before exit reach the buffer.
            Thread.sleep(forTimeInterval: 0.1)
            let reason = diagnostics.lastLine()
            Task { @MainActor [weak self] in self?.didExit(child, reason: reason) }
        }
    }

    func request<T: Decodable>(_ channel: String, payload: [String: Any] = [:], as: T.Type = T.self,
                               timeout: Duration? = nil) async throws -> T {
        let value = try await requestValue(channel, payload: payload, timeout: timeout)
        return try JSONDecoder().decode(T.self, from: value.encoded)
    }
    func requestValue(_ channel: String, payload: [String: Any] = [:],
                      timeout: Duration? = nil) async throws -> JSONValue {
        guard availability != .closed else { throw CoreError.transport("VPN 服务已关闭。") }
        pendingRequestCount += 1
        defer { pendingRequestCount -= 1 }
        if let transport {
            do {
                let result = try await transport(channel, payload)
                if availability != .closed { availability = .available }
                return result
            } catch {
                if case CoreError.transport(let message) = error { availability = .unavailable(message) }
                throw error
            }
        }
        try start()
        // Re-enabling needs the saved credential even while persisted enabled
        // is false. Disabling must remain possible with a locked keychain.
        if (channel == "static-exit:set-enabled" && payload["enabled"] as? Bool == true) || ["chain-scan:start", "chain-scan:use"].contains(channel),
           let saved = try await StaticExitKeychain.load() {
            _ = try await requestValue("static-exit:credential", payload: ["configuration": saved.configuration.payload, "password": saved.password])
        }
        // Restore before any action which compiles/reloads a route. Read-only
        // snapshots and stop remain usable if the keychain is locked.
        if ["vpn:start", "native:startup-connect", "nodes:select", "nodes:select-v2",
            "routing:update", "routing:add-rule", "routing:edit-rule", "routing:delete-rule",
            "native:preferences", "static-exit:test", "chain-scan:start", "chain-scan:connect", "chain-scan:use"].contains(channel) {
            let needed = try await requestValue("static-exit:needs-credential")
            if case .bool(true) = needed, let saved = try await StaticExitKeychain.load() {
                _ = try await requestValue("static-exit:credential", payload: ["configuration": saved.configuration.payload, "password": saved.password])
            }
        }
        let timeout = timeout ?? Self.timeout(for: channel)
        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID().uuidString
            callbacks[id] = continuation
            timeouts[id] = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                guard let self, let callback = self.callbacks.removeValue(forKey: id) else { return }
                self.timeouts.removeValue(forKey: id)
                let message = "VPN 服务响应超时，操作可能仍在进行，请稍后刷新状态。"
                let snapshot = ["diagnostics:get-state", "native:bootstrap", "vpn:get-status", "traffic:get-monitor", "traffic:get-snapshot", "nodes:list", "node-groups:list"].contains(channel)
                if snapshot {
                    self.availability = .unavailable(message)
                    callback.resume(throwing: CoreError.transport(message))
                } else { callback.resume(throwing: channel == "chain-scan:use" ? CoreError.uncertain(message) : CoreError.message(message)) }
            }
            do {
                var data = try JSONSerialization.data(withJSONObject: ["id": id, "channel": channel, "payload": payload])
                data.append(10)
                guard let input else { throw CoreError.message("VPN 服务尚未启动。") }
                try input.write(contentsOf: data)
            } catch {
                availability = .unavailable("无法与 VPN 服务通信，请刷新状态。")
                timeouts.removeValue(forKey: id)?.cancel()
                callbacks.removeValue(forKey: id)?.resume(throwing: error)
            }
        }
    }
    func close() {
        try? input?.close(); input = nil; availability = .closed
        timeouts.values.forEach { $0.cancel() }; timeouts.removeAll()
        let pending = callbacks; callbacks.removeAll()
        pending.values.forEach { $0.resume(throwing: CoreError.transport("VPN 服务已关闭。")) }
    }
    func waitForPendingRequests() async {
        while pendingRequestCount > 0, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
    }
    private func receive(_ data: Data) {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return }
        guard availability != .closed else { return }
        availability = .available
        if let event = response.event { onEvent?(event, response.data); return }
        guard let id = response.id, let callback = callbacks.removeValue(forKey: id) else { return }
        timeouts.removeValue(forKey: id)?.cancel()
        if response.ok == true { callback.resume(returning: response.data ?? .null) }
        else { callback.resume(throwing: CoreError.message(response.error?.message ?? "操作未完成。")) }
    }
    private func didExit(_ child: Process, reason: String?) {
        guard process === child else { return }
        process = nil; input = nil
        let message = reason.map { "VPN 服务已结束：\($0)" } ?? "VPN 服务已结束，请重新打开应用。"
        if availability != .closed { availability = .unavailable(message) }
        let pending = callbacks; callbacks.removeAll()
        timeouts.values.forEach { $0.cancel() }; timeouts.removeAll()
        pending.values.forEach { $0.resume(throwing: CoreError.message(message)) }
    }
    private struct Response: Decodable {
        var id: String?; var ok: Bool?; var data: JSONValue?; var error: ErrorPayload?; var event: String?
    }
    private struct ErrorPayload: Decodable { var message: String? }
    enum CoreError: LocalizedError {
        case message(String), transport(String), uncertain(String)
        var errorDescription: String? {
            switch self { case .message(let message), .transport(let message), .uncertain(let message): return message }
        }
    }
}

/// Tail of the core's redacted stderr, shown when it exits unexpectedly.
private final class DiagnosticsTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(bytes)
        if data.count > 4096 { data = Data(data.suffix(4096)) }
    }
    func lastLine() -> String? {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init)
    }
}
