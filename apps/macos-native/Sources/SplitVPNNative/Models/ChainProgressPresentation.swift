import Foundation

/// Formats core-owned counts and estimates; does not infer completed tests from cached rows.
struct ChainProgressPresentation {
    let state: ChainScanState
    var progress: ChainScanProgress? { state.progress }
    var title: String {
        if state.automatic == true { return "日常自动刷新 · 少量抽测" }
        guard let p = progress, p.total > 0 else { return state.running ? "当前范围没有待测任务" : "本轮进度" }
        if state.mode == "continuous" { return "已覆盖 \(p.completed)/\(p.total) 条 · 待覆盖 \(p.remaining) 条" }
        return "已处理 \(p.completed)/\(p.total) 条 · 剩余 \(p.remaining) 条"
    }
    var phase: String {
        if state.waitingReason != nil || !state.running { return ChainComparisonPresentation(state: state).phase }
        guard let p = progress else { return ChainComparisonPresentation(state: state).phase }
        if p.testingOtherScope == true { return "后台正在测试其他订阅" }
        if let stage = p.stage {
            let title = stage == "latency" ? "响应检测" : stage == "download" ? "下载采样" : stage == "exit-ip" ? "核对出口" : "准备链路"
            let attempt = p.stageAttempt.flatMap { a in p.stageTotal.map { " \(a)/\($0)" } } ?? ""
            return "\(title)\(attempt) · \(p.currentNode ?? "所选线路")"
        }
        return state.automatic == true ? "正在安排本批线路" : state.mode == "continuous" ? "后台持续测试" : "正在安排下一条线路"
    }
    var timing: String? {
        guard state.running, state.waitingReason == nil, let p = progress, p.total > 0 else { return nil }
        if state.mode == "continuous" {
            return p.nextTestAt.flatMap(Self.clock).map { "\(state.automatic == true ? "下次检查" : "下次采样") \($0)" } ?? "持续复测 · 可随时暂停"
        }
        guard p.remaining > 0 else { return nil }
        guard let seconds = p.estimatedSeconds else { return "正在估算剩余时间" }
        return seconds < 60 ? "预计还需约 \(max(1, seconds)) 秒" : "预计还需约 \(Int(ceil(Double(seconds) / 60))) 分钟"
    }
    static func clock(_ raw: String) -> String? {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else { return nil }
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
