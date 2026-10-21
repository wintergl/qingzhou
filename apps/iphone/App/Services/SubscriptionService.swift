import Foundation

struct SubscriptionUpdateResult {
    var ok: Bool
    var error: String
    var subscription: [String: Any]
}

enum SubscriptionServiceError: LocalizedError {
    case badPlan
    case noResult

    var errorDescription: String? {
        switch self {
        case .badPlan:
            return "订阅下载计划无效"
        case .noResult:
            return "订阅下载没有得到结果"
        }
    }
}

/// Downloads with URLSession; the Rust core decides which candidate URL to
/// try next, parses the content and stores the provider.
final class SubscriptionService {
    private let session: URLSession

    init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration)
    }

    func update(id: String, core: CoreClient) async throws -> SubscriptionUpdateResult {
        let plan = try await core.object("subscription:plan", ["id": id])
        guard let urls = plan["urls"] as? [String], !urls.isEmpty,
              let token = plan["token"] as? String, !token.isEmpty else {
            throw SubscriptionServiceError.badPlan
        }
        let headers = plan["headers"] as? [String: String] ?? [:]

        var index = 0
        while index < urls.count {
            var payload: [String: Any] = ["id": id, "token": token, "index": index]
            do {
                let (status, text) = try await fetchText(from: urls[index], headers: headers)
                payload["status"] = status
                payload["content"] = text
            } catch {
                payload["error"] = describe(error)
            }

            let result = try await core.object("subscription:accept", payload)
            if result["done"] as? Bool == true {
                return SubscriptionUpdateResult(
                    ok: result["ok"] as? Bool == true,
                    error: result["error"] as? String ?? "",
                    subscription: result["subscription"] as? [String: Any] ?? [:]
                )
            }
            index = result["next"] as? Int ?? index + 1
        }
        throw SubscriptionServiceError.noResult
    }

    private func fetchText(from urlString: String, headers: [String: String]) async throws -> (Int, String) {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (http.statusCode, String(decoding: data, as: UTF8.self))
    }

    private func describe(_ error: Error) -> String {
        guard let error = error as? URLError else {
            return error.localizedDescription
        }
        switch error.code {
        case .notConnectedToInternet:
            return "设备当前没有网络连接"
        case .timedOut:
            return "请求超时"
        case .cannotFindHost:
            return "无法解析订阅域名"
        case .cannotConnectToHost:
            return "无法连接订阅服务器"
        case .badServerResponse:
            return "服务器没有返回 HTTP 响应"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return "TLS / 证书校验失败"
        default:
            return error.localizedDescription
        }
    }
}
