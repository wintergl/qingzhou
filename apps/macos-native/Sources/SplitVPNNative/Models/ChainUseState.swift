import Foundation

struct ChainUseState: Codable, Equatable {
    var operationId: String
    var identityKey: String?
    var nodeName: String?
    var phase: String
    var finished = false
    var cancelRequested = false
    var error: String?
    var result: ChainUseResult?
    var automatic: Bool? = nil
    var previousNodeName: String? = nil
    var active: Bool { !finished }
    var title: String {
        if cancelRequested && active { return "正在取消并恢复…" }
        switch phase {
        case "verifying", "waiting": return automatic == true ? "线路不稳定，正在复核备用…" : "正在复核目标线路…"
        case "authorizing": return "正在准备连接，可能需要系统授权…"
        case "applying": return "正在应用 ISP 线路…"
        case "confirming": return "正在确认实际出口…"
        case "restoring": return "正在恢复原配置…"
        case "connected": return previousNodeName != nil ? "已切换，ISP 出口已确认" : "线路已连接，出口已确认"
        case "cancelled": return "连接已取消"
        case "failed": return "切换未完成"
        default: return "连接结果待确认"
        }
    }
}

struct ChainUseResult: Codable, Equatable {
    var connected: Bool
    var nodeName: String
    var identityKey: String
    var exitIp: String
    var verifiedAt: String
    var operationId: String
}
