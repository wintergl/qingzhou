import Foundation

/// Presentation guards prevent partial or unrelated observations being phrased
/// as a final recommendation. Ranking stays in the Rust core.
struct ChainRecommendationPresentation {
    var title: String
    var detail: String
    var node: ChainScanRow?
    init(_ state: ChainScanState) {
        node = nil
        let cached = state.canUseCachedResults == true
        if state.running, let waiting = state.waitingReason {
            title = waiting == "sleeping" ? "等待电脑唤醒，测试会自动继续" : "等待网络恢复，测试会自动继续"
            detail = "已完成的测量已保留；等待期间不采样，也不会把网络中断记成节点失败。"
        } else if state.cancelled && state.stopReason == "configuration-changed" {
            title = "配置或订阅已变化，测试已停止"
            detail = "历史记录已保留。请确认新配置后重新开始，避免混用不同链路的测量。"
        } else if state.running && !cached {
            title = "正在比较链路，还没有最终结果"
            detail = "已测 \(state.completed) / \(state.total)，找到完整通过的线路就可以先使用。"
        } else if state.stopReason == "error" {
            title = "测试遇到错误，已停止"
            detail = state.error ?? "已完成的历史记录仍保留，请重试。"
        } else if state.cancelled && !cached {
            title = state.stopReason == "user-paused" ? "测试已暂停" : "扫描已取消"
            detail = "尚无完整通过的线路，可继续查找；无需测完全部订阅。"
        } else if state.id.isEmpty {
            title = "先扫描，再给你推荐链路"
            detail = "软件会比较机场与 ISP 的组合，完成后告诉你该选哪条。"
        } else if state.stale {
            title = "上次结果来自其他环境"
            detail = "上次性能成绩仍保留；兼容的常用线路可先复核连通性和出口，再决定是否重新比较。"
        } else if let error = state.error {
            title = "这次扫描没有完成"
            detail = error
        } else if let recommended = state.recommended {
            node = recommended
            title = state.connectedIdentityKey == recommended.id ? "已连接：\(recommended.nodeName) → ISP" : cached && state.mode != "full" ? "当前推荐：\(recommended.nodeName) → ISP" : "本轮推荐：\(recommended.nodeName) → ISP"
            detail = state.recommendationSummary ?? "这条链路已完整通过响应、下载和出口核对，按当前方式排名第一。"
            if recommended.requiresRefresh == true {
                title = "上次已测推荐：\(recommended.nodeName) → ISP"
                detail += " 性能测量时间较早，原成绩保留；使用前会复核连通性和出口。"
            }
            if state.running && cached { detail += " 后台继续测试，推荐会随有效结果更新。" }
            else if state.cancelled && cached { detail += " 后台已暂停，测试记录已保留。" }
        } else {
            title = "这次没有找到可推荐的链路"
            detail = "没有链路完整通过测试，请检查机场与 ISP 配置后重试。"
        }
    }
}
