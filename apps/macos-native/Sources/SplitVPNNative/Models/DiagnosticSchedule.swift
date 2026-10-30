import Foundation

struct DiagnosticSchedule: Decodable {
    var automatic: Bool
    var pausedReason: String?
    var connectivity: DiagnosticRecord
    var websites: DiagnosticRecord
}
struct DiagnosticRecord: Decodable {
    var state: String
    var checkedAt: String?
    var startedAt: String?
    var nextCheckAt: String?
    var source: String?
    var result: JSONValue?
    var error: String?
    var intervalSeconds: Int?
    var staleResult: Bool?
    var running: Bool { state == "running" }
    var stale: Bool { state == "stale" || staleResult == true }
    var sourceLabel: String { source == "automatic" ? "自动检测" : "手动检测" }

    func nextCheckText(pausedReason: String?) -> String {
        if running {
            if stale { return "正在更新本次连接的检测结果" }
            return checkedAt.map { "上次完成 \(MeasurementTime.clock($0))" } ?? "首次检测，结果将在这里更新"
        }
        switch pausedReason {
        case "sleeping": return "休眠期间暂停自动检测"
        case "disconnected": return "连接后自动检测"
        case "recovering": return "连接恢复后自动重新检测"
        case "node-test": return "节点检测结束后继续自动检查"
        default:
            guard let nextCheckAt else { return "连接检测每 5 分钟 · 站点测速每 15 分钟" }
            if checkedAt == nil || stale { return "连接已就绪，即将自动检测" }
            return "下次 \(MeasurementTime.clock(nextCheckAt)) · 每 \((intervalSeconds ?? 300) / 60) 分钟"
        }
    }
}
struct NodeSpeedProgress: Decodable {
    var id: String
    var checked: Int
    var total: Int
    var nodeName: String?
    var phase: String?
    var finished: Bool
    var cancelled: Bool?
    var error: String?
    var result: NodeSpeedResult?
}
struct NodeSpeedResult: Decodable {
    var nodeName: String
    var status: String
    var medianDelayMs: Double?
    var testedAt: String?
    var failureReason: String?
}
enum MeasurementTime {
    static func clock(_ value: String?) -> String {
        RuntimeTime.parse(value)?.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)) ?? "尚未检测"
    }
}
