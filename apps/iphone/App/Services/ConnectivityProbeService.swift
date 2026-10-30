import Foundation

struct ConnectivityProbeTarget: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    let capturesBodyPreview: Bool

    static let domestic = ConnectivityProbeTarget(
        id: "domestic",
        name: "国内站点",
        url: URL(string: "https://www.baidu.com/")!,
        capturesBodyPreview: false
    )

    static let apple = ConnectivityProbeTarget(
        id: "apple",
        name: "Apple",
        url: URL(string: "https://www.apple.com/library/test/success.html")!,
        capturesBodyPreview: false
    )

    static let google = ConnectivityProbeTarget(
        id: "google",
        name: "Google",
        url: URL(string: "https://www.google.com/generate_204")!,
        capturesBodyPreview: false
    )

    static let openAI = ConnectivityProbeTarget(
        id: "openai",
        name: "OpenAI",
        url: URL(string: "https://chat.openai.com/cdn-cgi/trace")!,
        capturesBodyPreview: false
    )

    static let youtubeHome = ConnectivityProbeTarget(
        id: "youtube-home",
        name: "YouTube 首页",
        url: URL(string: "https://www.youtube.com/")!,
        capturesBodyPreview: false
    )

    static let youtubeVideo = ConnectivityProbeTarget(
        id: "youtube-video",
        name: "YouTube 视频",
        url: URL(string: "https://www.youtube.com/watch?v=jNQXAC9IVRw")!,
        capturesBodyPreview: false
    )

    static let exitIP = ConnectivityProbeTarget(
        id: "exit-ip",
        name: "出口 IP",
        url: URL(string: "https://api64.ipify.org?format=json")!,
        capturesBodyPreview: true
    )

    static let defaultTargets: [ConnectivityProbeTarget] = [
        .domestic,
        .apple,
        .google,
        .openAI,
        .youtubeHome,
        .youtubeVideo,
        .exitIP
    ]
}

struct ConnectivityProbeResult: Identifiable {
    let id = UUID()
    let targetID: String
    let targetName: String
    let urlString: String
    let startedAt: Date
    let roundIndex: Int
    let roundCount: Int
    let durationMilliseconds: Int
    let firstByteMilliseconds: Int?
    let dnsMilliseconds: Int?
    let connectMilliseconds: Int?
    let tlsMilliseconds: Int?
    let requestMilliseconds: Int?
    let serverWaitMilliseconds: Int?
    let responseTransferMilliseconds: Int?
    let networkProtocolName: String?
    let reusedConnection: Bool?
    let proxyConnection: Bool?
    let statusCode: Int?
    let responseBytes: Int
    let bodyPreview: String?
    let errorMessage: String?

    var isReachable: Bool {
        statusCode != nil && errorMessage == nil
    }
}

final class ConnectivityProbeService {
    static let defaultRoundCount = 5

    private let session: URLSession
    private let metricsCollector: ConnectivityProbeMetricsCollector
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 6) {
        self.timeout = timeout
        let metricsCollector = ConnectivityProbeMetricsCollector()
        self.metricsCollector = metricsCollector
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration, delegate: metricsCollector, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func runAll(
        targets: [ConnectivityProbeTarget],
        roundCount: Int = ConnectivityProbeService.defaultRoundCount
    ) async -> [ConnectivityProbeResult] {
        var results: [ConnectivityProbeResult] = []
        let rounds = max(1, roundCount)
        for target in targets {
            for roundIndex in 1...rounds {
                results.append(await run(target: target, roundIndex: roundIndex, roundCount: rounds))
            }
        }
        return results
    }

    private func run(
        target: ConnectivityProbeTarget,
        roundIndex: Int,
        roundCount: Int
    ) async -> ConnectivityProbeResult {
        let startedAt = Date()
        var request = URLRequest(
            url: target.url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "GET"
        request.setValue("split-vpn-ios-probe/1.0", forHTTPHeaderField: "User-Agent")
        if !target.capturesBodyPreview {
            request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        }

        do {
            let (data, response, metrics) = try await data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            let timing = Self.probeTiming(from: metrics)
            return ConnectivityProbeResult(
                targetID: target.id,
                targetName: target.name,
                urlString: target.url.absoluteString,
                startedAt: startedAt,
                roundIndex: roundIndex,
                roundCount: roundCount,
                durationMilliseconds: elapsedMilliseconds(since: startedAt),
                firstByteMilliseconds: timing.firstByteMilliseconds,
                dnsMilliseconds: timing.dnsMilliseconds,
                connectMilliseconds: timing.connectMilliseconds,
                tlsMilliseconds: timing.tlsMilliseconds,
                requestMilliseconds: timing.requestMilliseconds,
                serverWaitMilliseconds: timing.serverWaitMilliseconds,
                responseTransferMilliseconds: timing.responseTransferMilliseconds,
                networkProtocolName: timing.networkProtocolName,
                reusedConnection: timing.reusedConnection,
                proxyConnection: timing.proxyConnection,
                statusCode: statusCode,
                responseBytes: data.count,
                bodyPreview: preview(from: data, enabled: target.capturesBodyPreview),
                errorMessage: nil
            )
        } catch {
            let timing = (error as? ConnectivityProbeError).map(\.timing) ?? .empty
            return ConnectivityProbeResult(
                targetID: target.id,
                targetName: target.name,
                urlString: target.url.absoluteString,
                startedAt: startedAt,
                roundIndex: roundIndex,
                roundCount: roundCount,
                durationMilliseconds: elapsedMilliseconds(since: startedAt),
                firstByteMilliseconds: timing.firstByteMilliseconds,
                dnsMilliseconds: timing.dnsMilliseconds,
                connectMilliseconds: timing.connectMilliseconds,
                tlsMilliseconds: timing.tlsMilliseconds,
                requestMilliseconds: timing.requestMilliseconds,
                serverWaitMilliseconds: timing.serverWaitMilliseconds,
                responseTransferMilliseconds: timing.responseTransferMilliseconds,
                networkProtocolName: timing.networkProtocolName,
                reusedConnection: timing.reusedConnection,
                proxyConnection: timing.proxyConnection,
                statusCode: nil,
                responseBytes: 0,
                bodyPreview: nil,
                errorMessage: (error as? ConnectivityProbeError)?.underlying.localizedDescription ?? error.localizedDescription
            )
        }
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse, URLSessionTaskMetrics?) {
        try await withCheckedThrowingContinuation { continuation in
            let metricsCollector = self.metricsCollector
            var task: URLSessionDataTask?
            task = session.dataTask(with: request) { data, response, error in
                let taskIdentifier = task?.taskIdentifier
                Task {
                    let metrics: URLSessionTaskMetrics?
                    if let taskIdentifier {
                        metrics = await metricsCollector.takeMetrics(for: taskIdentifier)
                    } else {
                        metrics = nil
                    }
                    if let error {
                        continuation.resume(
                            throwing: ConnectivityProbeError(underlying: error, timing: Self.probeTiming(from: metrics))
                        )
                        return
                    }
                    guard let data, let response else {
                        continuation.resume(
                            throwing: ConnectivityProbeError(
                                underlying: URLError(.badServerResponse),
                                timing: Self.probeTiming(from: metrics)
                            )
                        )
                        return
                    }
                    continuation.resume(returning: (data, response, metrics))
                }
            }
            task?.resume()
        }
    }

    private static func probeTiming(from metrics: URLSessionTaskMetrics?) -> ConnectivityProbeTiming {
        guard let transaction = metrics?.transactionMetrics.last else {
            return .empty
        }
        return ConnectivityProbeTiming(
            firstByteMilliseconds: intervalMilliseconds(transaction.fetchStartDate, transaction.responseStartDate),
            dnsMilliseconds: intervalMilliseconds(transaction.domainLookupStartDate, transaction.domainLookupEndDate),
            connectMilliseconds: intervalMilliseconds(transaction.connectStartDate, transaction.connectEndDate),
            tlsMilliseconds: intervalMilliseconds(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate),
            requestMilliseconds: intervalMilliseconds(transaction.requestStartDate, transaction.requestEndDate),
            serverWaitMilliseconds: intervalMilliseconds(transaction.requestEndDate, transaction.responseStartDate),
            responseTransferMilliseconds: intervalMilliseconds(transaction.responseStartDate, transaction.responseEndDate),
            networkProtocolName: transaction.networkProtocolName,
            reusedConnection: transaction.isReusedConnection,
            proxyConnection: transaction.isProxyConnection
        )
    }

    private func elapsedMilliseconds(since startedAt: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
    }

    private static func intervalMilliseconds(_ startDate: Date?, _ endDate: Date?) -> Int? {
        guard let startDate, let endDate, endDate >= startDate else {
            return nil
        }
        return max(0, Int(endDate.timeIntervalSince(startDate) * 1000))
    }

    private func preview(from data: Data, enabled: Bool) -> String? {
        guard enabled, let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        return String(trimmed.prefix(160))
    }
}

private struct ConnectivityProbeTiming {
    static let empty = ConnectivityProbeTiming(
        firstByteMilliseconds: nil,
        dnsMilliseconds: nil,
        connectMilliseconds: nil,
        tlsMilliseconds: nil,
        requestMilliseconds: nil,
        serverWaitMilliseconds: nil,
        responseTransferMilliseconds: nil,
        networkProtocolName: nil,
        reusedConnection: nil,
        proxyConnection: nil
    )

    var firstByteMilliseconds: Int?
    var dnsMilliseconds: Int?
    var connectMilliseconds: Int?
    var tlsMilliseconds: Int?
    var requestMilliseconds: Int?
    var serverWaitMilliseconds: Int?
    var responseTransferMilliseconds: Int?
    var networkProtocolName: String?
    var reusedConnection: Bool?
    var proxyConnection: Bool?
}

private struct ConnectivityProbeError: Error {
    var underlying: Error
    var timing: ConnectivityProbeTiming
}

private final class ConnectivityProbeMetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var metricsByTaskIdentifier: [Int: URLSessionTaskMetrics] = [:]

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        lock.lock()
        metricsByTaskIdentifier[task.taskIdentifier] = metrics
        lock.unlock()
    }

    func takeMetrics(for taskIdentifier: Int) async -> URLSessionTaskMetrics? {
        for _ in 0..<10 {
            if let metrics = popMetrics(for: taskIdentifier) {
                return metrics
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return popMetrics(for: taskIdentifier)
    }

    private func popMetrics(for taskIdentifier: Int) -> URLSessionTaskMetrics? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return metricsByTaskIdentifier.removeValue(forKey: taskIdentifier)
    }
}
