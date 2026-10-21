import Foundation
import OSLog
import Darwin

struct NativeTerminationEvent: Equatable {
    enum Stage: String { case waiting, company, personal, core }
    enum Outcome: String { case started, failed, completed }
    enum Reason: String { case operationsTimeout, identityMismatch, helperTimeout, coreTimeout, coreUnavailable, cleanupUnconfirmed }
    let outcome: Outcome
    let stage: Stage
    let reason: Reason?
    let pendingRequests: Int

    static func reason(for error: Error) -> Reason {
        if error is TerminationWait.Timeout { return .operationsTimeout }
        if case HelperService.ServiceError.stopTimeout = error { return .helperTimeout }
        let message = error.localizedDescription
        if message.contains("identity_mismatch") { return .identityMismatch }
        if case CoreService.CoreError.transport = error {
            return message.contains("超时") ? .coreTimeout : .coreUnavailable
        }
        return .cleanupUnconfirmed
    }
    var message: String {
        "termination outcome=\(outcome.rawValue) stage=\(stage.rawValue) pendingRequests=\(pendingRequests)" +
        (reason.map { " reason=\($0.rawValue)" } ?? "")
    }
}

/// Keep native exit diagnostics available even when the Rust process cannot reply.
struct NativeTerminationLog {
    private static let logger = Logger(subsystem: "dev.split-vpn.desktop", category: "Termination")
    let directory: URL
    init(directory: URL? = nil) {
        let root = ProcessInfo.processInfo.environment["SPLITVPN_DATA_DIR"].map { URL(fileURLWithPath: $0) } ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/@split-vpn/desktop")
        self.directory = directory ?? root.appendingPathComponent("logs")
    }
    func record(_ event: NativeTerminationEvent) {
        // Only fixed categories and counts are logged; never an RPC payload or raw error.
        let message = event.message
        if event.outcome == .failed { Self.logger.error("\(message, privacy: .public)") }
        else { Self.logger.info("\(message, privacy: .public)") }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return }
        let file = directory.appendingPathComponent("app.log")
        let descriptor = Darwin.open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        let level = event.outcome == .failed ? "warn" : "info"
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(level)] \(message)\n"
        line.utf8CString.withUnsafeBytes { bytes in
            _ = Darwin.write(descriptor, bytes.baseAddress, bytes.count - 1)
        }
    }
}

/// Race a read-only observer against a deadline. Cancelling the observer must
/// not cancel or abandon a previously accepted VPN operation.
@MainActor
private final class TerminationWaitState {
    var continuation: CheckedContinuation<Void, Error>?
    var observer: Task<Void, Never>?
    var timer: Task<Void, Never>?
    func finish(_ error: Error? = nil) {
        guard let continuation else { return }
        self.continuation = nil
        observer?.cancel(); timer?.cancel(); observer = nil; timer = nil
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }
}

@MainActor
enum TerminationWait {
    struct Timeout: LocalizedError {
        var errorDescription: String? { "等待后台操作超时，本次退出已取消。请等操作完成后重试。" }
    }
    static func run(timeout: TimeInterval, observe: @escaping @MainActor () async -> Void) async throws {
        let state = TerminationWaitState()
        try await withCheckedThrowingContinuation { continuation in
            state.continuation = continuation
            state.observer = Task {
                await observe()
                if !Task.isCancelled { state.finish() }
            }
            state.timer = Task {
                do { try await Task.sleep(for: .seconds(max(0, timeout))) }
                catch { return }
                state.finish(Timeout())
            }
        }
    }
}
