import Foundation

protocol CompanyHelper: AnyObject {
    var processID: Int32? { get }
    func start(command: [String: Any], onEvent: @escaping (HelperEvent) -> Void, onExit: @escaping (Int32) -> Void) throws
    func send(_ command: [String: Any]) throws
    func stop()
    func stopAndWait(timeout: TimeInterval) async throws
}
extension CompanyHelper {
    func stopAndWait(timeout: TimeInterval) async throws {
        stop()
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while processID != nil {
            guard clock.now < deadline else { throw HelperService.ServiceError.stopTimeout }
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(20))))
        }
    }
}

/// A private pipe carries credentials to the helper. Neither arguments nor
/// environment variables carry passwords, and helper output has a fixed schema.
final class HelperService: CompanyHelper {
    private var process: Process?
    private var stopping: [Process] = []
    var processID: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }
    private var input: FileHandle?
    private let reader = DispatchQueue(label: "company-account-helper.reader", qos: .userInitiated)

    func start(command: [String: Any], onEvent: @escaping (HelperEvent) -> Void,
               onExit: @escaping (Int32) -> Void) throws {
        stop()
        guard let executable = Bundle.main.url(forResource: "company-account-helper", withExtension: nil) else {
            throw ServiceError.missingHelper
        }
        let task = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        task.executableURL = executable
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = FileHandle.nullDevice
        // Do not inherit an unrelated certificate pin from a terminal session.
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SPLITVPN_ATRUST_CERT_SHA256")
        task.environment = environment
        try task.run()
        process = task
        input = stdin.fileHandleForWriting
        reader.async {
            let handle = stdout.fileHandleForReading
            var buffer = Data()
            while true {
                // A queue-level pool would only drain when this whole loop
                // returns; release read and decode temporaries each iteration.
                let keepReading = autoreleasepool { () -> Bool in
                    let data = handle.availableData
                    if data.isEmpty { return false }
                    buffer.append(data)
                    if buffer.count > 8 * 1024 * 1024 {
                        task.terminate()
                        return false
                    }
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<newline])
                        buffer.removeSubrange(...newline)
                        guard let event = try? JSONDecoder().decode(HelperEvent.self, from: line) else {
                            let error = HelperEvent(type: "error", stage: "local", message: "认证内核返回了无法识别的消息。",
                                                    username: nil, probe: nil, resources: nil, tunnel: nil, challenge: nil)
                            DispatchQueue.main.async { onEvent(error) }
                            continue
                        }
                        DispatchQueue.main.async { onEvent(event) }
                    }
                    return true
                }
                if !keepReading { break }
            }
            try? handle.close()
            task.waitUntilExit()
            let status = task.terminationStatus
            DispatchQueue.main.async { onExit(status) }
        }
        do { try send(command) }
        catch { stop(); throw error }
    }

    func send(_ command: [String: Any]) throws {
        guard let input, process?.isRunning == true else { throw ServiceError.sessionEnded }
        var data = try JSONSerialization.data(withJSONObject: command)
        data.append(10)
        try input.write(contentsOf: data)
    }

    func stop() {
        try? input?.close()
        input = nil
        stopping.removeAll { !$0.isRunning }
        if let process, process.isRunning { stopping.append(process); process.terminate() }
        process = nil
    }

    func stopAndWait(timeout: TimeInterval = 10) async throws {
        stop()
        let children = stopping
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while children.contains(where: \.isRunning) {
            guard clock.now < deadline else { throw ServiceError.stopTimeout }
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(20))))
        }
        stopping.removeAll { !$0.isRunning }
    }

    deinit { stop() }

    enum ServiceError: LocalizedError {
        case missingHelper, sessionEnded, stopTimeout
        var errorDescription: String? {
            switch self {
            case .missingHelper: return "应用中缺少认证内核，请重新构建测试应用。"
            case .sessionEnded: return "测试会话已结束，请重新登录。"
            case .stopTimeout: return "私有网络连接服务尚未退出，应用继续运行，请稍后重试。"
            }
        }
    }
}
