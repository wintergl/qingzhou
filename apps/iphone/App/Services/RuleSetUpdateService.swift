import Foundation

struct RuleSetUpdateResult {
    var record: RuleSetLibraryRecord
    var didUpdate: Bool
}

enum RuleSetUpdateServiceError: LocalizedError {
    case badStatus(String, Int)
    case nonHTTPResponse(String)
    case responseTooLarge(String, Int64, Int)
    case emptyResponse(String)
    case transport(String, String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let tag, let code):
            return "规则集 \(tag) 下载失败，HTTP \(code)"
        case .nonHTTPResponse(let tag):
            return "规则集 \(tag) 下载失败，服务器没有返回 HTTP 响应"
        case .responseTooLarge(let tag, let bytes, let limit):
            return "规则集 \(tag) 响应过大：\(bytes) bytes，限制 \(limit) bytes"
        case .emptyResponse(let tag):
            return "规则集 \(tag) 下载内容为空"
        case .transport(let tag, let message):
            return "规则集 \(tag) 下载网络错误：\(message)"
        }
    }
}

final class RuleSetUpdateService {
    private let store: AppGroupStore
    private let session: URLSession

    init(store: AppGroupStore = .shared, timeout: TimeInterval = 20) {
        self.store = store
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration)
    }

    func updateIfNeeded(force: Bool = false) async throws -> RuleSetUpdateResult {
        _ = try store.installBundledGeoRoutingResources()
        let current = store.readRuleSetLibrary()
        if !force, current.hasAllManagedFiles, !current.canRetryAutomaticUpdate {
            return RuleSetUpdateResult(record: current, didUpdate: false)
        }
        guard force || current.isUpdateDue || !current.hasAllManagedFiles else {
            return RuleSetUpdateResult(record: current, didUpdate: false)
        }
        return try await updateNow()
    }

    private func updateNow() async throws -> RuleSetUpdateResult {
        let attemptedAt = Date()
        do {
            var downloadedRuleSets: [String: Data] = [:]
            for resource in RuleSetLibrary.managedResources {
                downloadedRuleSets[resource.tag] = try await fetch(resource)
            }
            let record = try store.saveDownloadedRuleSetLibrary(downloadedRuleSets, attemptedAt: attemptedAt)
            return RuleSetUpdateResult(record: record, didUpdate: true)
        } catch {
            _ = try? store.saveRuleSetLibraryUpdateFailure(error.localizedDescription, attemptedAt: attemptedAt)
            throw error
        }
    }

    private func fetch(_ resource: ManagedRuleSetResource) async throws -> Data {
        var request = URLRequest(url: resource.sourceURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("split-vpn-ios-rules/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream, */*", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw RuleSetUpdateServiceError.transport(resource.tag, describe(error))
        } catch {
            throw RuleSetUpdateServiceError.transport(resource.tag, error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RuleSetUpdateServiceError.nonHTTPResponse(resource.tag)
        }
        if !(200...299).contains(http.statusCode) {
            throw RuleSetUpdateServiceError.badStatus(resource.tag, http.statusCode)
        }
        if http.expectedContentLength > Int64(resource.maxBytes) {
            throw RuleSetUpdateServiceError.responseTooLarge(
                resource.tag,
                http.expectedContentLength,
                resource.maxBytes
            )
        }
        guard !data.isEmpty else {
            throw RuleSetUpdateServiceError.emptyResponse(resource.tag)
        }
        return data
    }

    private func describe(_ error: URLError) -> String {
        if let reason = error.failingURL?.absoluteString {
            return "\(error.localizedDescription) \(reason)"
        }
        return error.localizedDescription
    }
}
