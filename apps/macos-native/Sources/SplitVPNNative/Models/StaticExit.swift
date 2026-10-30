import Foundation

struct StaticExitConfiguration: Codable, Equatable {
    var enabled = false
    var `protocol` = "socks5"
    var server = ""
    var port = 0
    var username = ""
    var expectedIp = ""
    var configured: Bool { !server.isEmpty && (1...65535).contains(port) }
    var payload: [String: Any] {
        ["enabled": enabled, "protocol": self.protocol, "server": server, "port": port,
         "username": username, "expectedIp": expectedIp]
    }
}
struct StaticExitInput: Decodable {
    var configuration: StaticExitConfiguration
    var password: String
}
struct StaticExitTestResult: Decodable {
    var ip: String
    var expectedIp: String
    var matchesExpected: Bool?
    var elapsedMs: Double
}
enum StaticExitKeychain {
    static let origin = "https://static-exit.invalid"
    static let vault = KeychainCompanyCredentialVault(service: "dev.split-vpn.static-exit")
    static func load() async throws -> StaticExitInput? {
        guard let saved = try await vault.load(origin: origin),
              let data = saved.domain.data(using: .utf8) else { return nil }
        return try StaticExitInput(configuration: JSONDecoder().decode(StaticExitConfiguration.self, from: data), password: saved.password)
    }
    static func save(_ configuration: StaticExitConfiguration, password: String) async throws {
        let metadata = String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self)
        try await vault.save(CompanyCredentials(origin: origin, domain: metadata, username: configuration.username, password: password))
    }
}

struct ChainScanRow: Decodable, Identifiable {
    var identityKey: String
    var nodeName: String
    var status: String
    var latencyMs: Double?
    var jitterMs: Double?
    var downloadMbps: Double?
    var latencySuccesses: Int
    var latencyAttempts: Int
    var downloadSuccesses: Int
    var downloadAttempts: Int
    var exitIp: String?
    var errors: [String]
    var balancedScore: Double? = nil
    var observationCount: Int? = nil
    var testedAt: String? = nil
    var requiresRefresh: Bool? = nil
    var nextRetryAt: String? = nil
    var lastVerifiedAt: String? = nil
    var lastVerificationAt: String? = nil
    var lastVerificationStatus: String? = nil
    var otherEnvironment: Bool? = nil
    var connectionEligible: Bool? = nil
    var environmentUncertain: Bool? = nil
    var rank: Int? = nil
    var comparisonReason: String? = nil
    var subscriptionId: String? = nil
    var subscriptionName: String? = nil
    var id: String { identityKey }
}
struct ChainScanState: Decodable {
    var id = ""
    var running = false
    var cancelled = false
    var completed = 0
    var total = 0
    var currentNode: String?
    var results: [ChainScanRow] = []
    var stale = true
    var error: String?
    var recommendedIdentityKey: String?
    var connectedIdentityKey: String?
    var recommendationExplanation: String?
    var recommendationSummary: String?
    var mode: String? = nil
    var testing: Bool? = nil
    var nextTestAt: String? = nil
    var canUseCachedResults: Bool? = nil
    var waitingReason: String? = nil
    var stopReason: String? = nil
    var networkRestarts: Int? = nil
    var leaders: ChainLeaders? = nil
    var queuedIdentityKeys: [String]? = nil
    var candidateIdentityKeys: [String]? = nil
    var workerActive: Bool? = nil
    var view: ChainScanScopeView? = nil
    var progress: ChainScanProgress? = nil
    var automatic: Bool? = nil
    var autoRefresh: ChainAutoRefreshState? = nil
    var routine: ChainRoutineState? = nil
    var recommended: ChainScanRow? { results.first { $0.id == recommendedIdentityKey } }
}

struct ChainRoutineState: Decodable {
    var connectionState = "disconnected"
    var currentSelectionConfirmed = false
    var currentIdentityKey: String? = nil
    var currentNodeName: String? = nil
    var preferredIdentityKey: String? = nil
    var verification = ChainVerificationState()
    var performanceTestedAt: String? = nil
    var performanceOtherEnvironment = false
    var maintenanceIdentityKeys: [String] = []
    var backupIdentityKeys: [String] = []
    var quickIdentityKeys: [String] = []
}

struct ChainVerificationState: Decodable {
    var status = "pending"
    var checkedAt: String? = nil
}

struct ChainScanActivity: Decodable {
    var running: Bool
    var mode: String?
    var testing: Bool?
    var completed: Int
    var total: Int
}

struct ChainHistoryRecord: Decodable, Identifiable {
    var recordId: String
    var scanId: String
    var sameEnvironment: Bool
    var environmentKnown: Bool? = nil
    var observation: ChainScanRow
    var id: String { recordId }
}
struct ChainHistoryPage: Decodable {
    var records: [ChainHistoryRecord]
    var nextBefore: String?
    var hasMore: Bool
}

struct ChainLeaders: Decodable {
    var balanced: String?
    var download: String?
    var latency: String?
}

struct ChainScanScopeView: Decodable {
    var subscriptionId: String
    var results: [ChainScanRow]
    var leaders: ChainLeaders?
    var recommendedIdentityKey: String?
    var recommendationSummary: String?
    var progress: ChainScanProgress?
}
struct ChainScanProgress: Decodable {
    var total = 0
    var completed = 0
    var remaining = 0
    var estimatedSeconds: Int? = nil
    var sampleCount: Int? = nil
    var stage: String? = nil
    var stageAttempt: Int? = nil
    var stageTotal: Int? = nil
    var currentNode: String? = nil
    var testingOtherScope: Bool? = nil
    var nextTestAt: String? = nil
    var earliestRetryAt: String? = nil
}

extension ChainScanState {
    func scoped(to subscriptionID: String) -> ChainScanState {
        var display = self
        if let view, view.subscriptionId == subscriptionID {
            display.results = view.results; display.leaders = view.leaders
            display.recommendedIdentityKey = view.recommendedIdentityKey
            display.recommendationSummary = view.recommendationSummary; display.progress = view.progress
        } else if !subscriptionID.isEmpty {
            display.results = []; display.leaders = nil; display.recommendedIdentityKey = nil; display.progress = nil
        }
        return display
    }
}

struct ChainAutoRefreshState: Decodable {
    var enabled = false
    var intervalMinutes = 30
    var paused = false
    var status = "disabled"
    var title: String { !enabled ? "开启省电维护" : paused ? "维护已暂停" : "省电维护已开" }
    var message: String {
        switch status {
        case "paused": return "已暂停。恢复后继续后台维护；暂停状态会保留。"
        case "sleeping": return "电脑睡眠中，唤醒后自动继续。"
        case "low-power": return "低电量模式暂缓自动测试，退出后继续。"
        case "on-battery": return "电池供电或供电状态未知，自动测试暂缓。"
        case "network-settling": return "网络刚发生变化，等待稳定后再安排测试。"
        case "network-uncertain": return "连续测试失败，可能是本机网络波动；暂缓到下一批再复核。"
        case "needs-baseline": return "先验证一条可用线路，就能开启常用线路维护，无需测完全部订阅。"
        case "needs-configuration": return "先保存 ISP 配置，再验证一条可用线路。"
        case "needs-credential": return "等待 ISP 账号就绪，不会回退到其他出口。"
        case "waiting-network": return "等待网络恢复，已有成绩保留。"
        case "running": return "正在维护当前线路和各订阅的已验证备选，每批最多三条。"
        case "manual-running": return "正在完成手动测试，结束后自动接续日常维护。"
        case "retrying": return "自动刷新暂未启动，稍后会重试；已有记录保留。"
        case "ready": return "已开启，24 小时内的成功成绩会跳过，到期后再少量刷新。"
        default: return "开启一次后随轻舟运行，无需再打开测试页。"
        }
    }
}
