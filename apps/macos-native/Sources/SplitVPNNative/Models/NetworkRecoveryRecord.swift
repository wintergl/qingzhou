import Foundation

struct NetworkRecoveryRecord: Decodable, Identifiable {
    let id: UInt64
    let startedAt: String
    let finishedAt: String
    let durationMs: UInt64
    let reason: String
    let outcome: String
    let attempts: Int
    let error: String?
    var checkedAt: String? = nil
    var title: String {
        switch outcome {
        case "verified": return "分流已恢复 · 代理访问已验证"
        case "unverified": return "分流已恢复 · 代理访问尚未确认"
        case "checking": return "分流已恢复 · 正在检查代理访问"
        case "failed": return "自动恢复失败"
        case "cancelled": return "已取消恢复"
        case "interrupted": return "网络再次变化，旧检测已结束"
        case "helper-update-required": return "连接服务待更新"
        default: return "恢复结果未知"
        }
    }
    var reasonTitle: String {
        switch reason {
        case "wake": return "睡眠唤醒"
        case "health-check": return "连接异常"
        case "manual-retry": return "手动重试"
        default: return "网络变化"
        }
    }
    var timeText: String {
        guard let date = RuntimeTime.parse(finishedAt) else { return "时间未知" }
        let formatter = DateFormatter(); formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
    var durationText: String { "\(max(1, Int(durationMs / 1000))) 秒" }
}

enum RuntimeTime {
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func uptime(_ value: String?, at date: Date) -> String {
        guard let start = parse(value) else { return "时长暂不可读取" }
        let seconds = max(0, Int(date.timeIntervalSince(start)))
        if seconds < 60 { return "不足 1 分钟" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) 分钟" }
        if minutes < 1440 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟" }
        return "\(minutes / 1440) 天 \(minutes % 1440 / 60) 小时 \(minutes % 60) 分钟"
    }
}

extension NetworkRecoveryStatus {
    var active: Bool { ["waiting-network", "recovering", "failed", "helper-update-required"].contains(state) }
    var latest: NetworkRecoveryRecord? { history?.first }
    var detail: String? {
        switch state {
        case "waiting-network": return "网络暂不可用，接入网络后自动恢复"
        case "recovering": return phase == "applying" ? "正在恢复网卡、TUN 与系统 DNS" : "网络发生变化，正在等待网络稳定"
        case "failed":
            let count = attempts ?? 0, limit = maxAttempts ?? 3
            return count < limit ? "第 \(count) 次尝试未完成，将进行第 \(count + 1)/\(limit) 次尝试" : "已尝试 \(count)/\(limit) 次，请重试或查看诊断"
        case "helper-update-required": return "请更新连接服务后继续"
        default: return nil
        }
    }
}
