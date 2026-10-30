import Foundation

/// Presentation only. Ordering, ranks, scores and winners come from Rust.
struct ChainComparisonPresentation {
    let state: ChainScanState
    var successful: [ChainScanRow] { state.results.filter { $0.status == "available" } }
    var recentCount: Int { successful.filter { $0.requiresRefresh != true }.count }
    var issueCount: Int { state.results.filter { $0.status != "available" }.count }
    var comparisonReady: Bool {
        !state.stale && state.waitingReason == nil && state.error == nil &&
        (state.canUseCachedResults == true || (!state.running && !state.cancelled && !state.id.isEmpty))
    }
    func leader(_ strategy: String) -> ChainScanRow? {
        let id = strategy == "download" ? state.leaders?.download : strategy == "latency" ? state.leaders?.latency : state.leaders?.balanced
        return state.results.first { $0.id == id && $0.status == "available" }
    }
    func canApply(_ row: ChainScanRow?, strategy: String = "balanced") -> Bool {
        if let eligible = row?.connectionEligible {
            return eligible && state.waitingReason == nil && row?.status == "available" &&
                (strategy != "balanced" || row?.balancedScore != nil)
        }
        return comparisonReady && row?.status == "available" && (strategy != "balanced" || row?.balancedScore != nil)
    }
    var phase: String {
        if state.running {
            if state.waitingReason == "low-power" { return "低电量模式 · 自动刷新暂缓" }
            if state.waitingReason == "on-battery" { return "电池供电 · 自动刷新暂缓" }
            if state.waitingReason == "network-settling" { return "网络变化 · 等待稳定" }
            if state.waitingReason == "sleeping" { return "等待唤醒 · 自动继续" }
            if state.waitingReason != nil { return "等待网络 · 自动继续" }
            if state.testing == true || state.mode != "continuous" { return "正在测试：\(state.currentNode ?? "准备链路")" }
            return "后台测试中 · 等待下一次采样"
        }
        switch state.stopReason {
        case "completed": return state.mode == "quick" ? successful.isEmpty ? "本次未找到，可继续查找" : "已找到可用线路" : "本轮已完成"
        case "configuration-changed": return "配置变化 · 请重新测试"
        case "error": return "测试出错 · 已保留记录"
        case "shutdown": return "上次随应用退出结束"
        case "user-paused": return "已暂停"
        default: return state.results.isEmpty ? "尚未开始测试" : "已保存上次结果"
        }
    }
    static func number(_ value: Double?, decimals: Int = 1) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return String(format: "%.*f", decimals, value)
    }
    static func relativeTime(_ value: String?, now: Date = Date()) -> String {
        guard let value else { return "未测试" }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return "时间未知" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 0 { return "时间待确认" }
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) 小时前" }
        return "\(Int(seconds / 86400)) 天前"
    }
}
