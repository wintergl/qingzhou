import Foundation

/// Maps existing capabilities to the next visible action; never changes networking itself.
struct ChainWorkflowPresentation {
    enum Action { case configure, subscriptions, start, retest, queue, prepare, connect, current, recover, blocked }
    var state: ChainScanState
    var row: ChainScanRow?
    var strategy = "balanced"
    var configured = true
    var candidateCount = 1
    var selectedExists = true
    var canMutate = true
    var working = false
    var vpnRunning = true
    var ispEnabled = true
    var protectedConnection = false
    var recoveryRequired = false
    var currentIdentity: String?
    private var comparison: ChainComparisonPresentation { ChainComparisonPresentation(state: state) }
    var queued: Bool { row.map { state.queuedIdentityKeys?.contains($0.id) == true } ?? false }
    var testingSelected: Bool { state.running && state.testing == true && row?.nodeName == state.currentNode }
    var untested: Bool { row?.status == "pending" }
    private var inScanScope: Bool { row.map { state.candidateIdentityKeys?.contains($0.id) ?? true } ?? false }
    var retestAvailable: Bool {
        row != nil && selectedExists && configured && candidateCount > 0 && canMutate && !working && !queued && !testingSelected && state.waitingReason == nil &&
        (!state.running || inScanScope && (state.mode == "continuous" || untested))
    }
    var action: Action {
        if working || !canMutate { return .blocked }
        if recoveryRequired { return .recover }
        if !configured { return state.running ? .blocked : .configure }
        if candidateCount == 0 { return .subscriptions }
        if state.waitingReason != nil { return .blocked }
        guard let row else { return state.running ? .blocked : .start }
        if !selectedExists { return state.running ? .blocked : .start }
        if !comparison.canApply(row, strategy: strategy) {
            if state.running { return state.mode == "continuous" || untested ? .queue : .blocked }
            return .retest
        }
        if protectedConnection { return .blocked }
        if !vpnRunning || !ispEnabled { return .prepare }
        if currentIdentity == row.id && state.connectedIdentityKey == row.id && (state.routine == nil || state.routine?.verification.status == "passed") { return .current }
        return .connect
    }
    var primaryEnabled: Bool {
        switch action {
        case .blocked, .current: return false
        case .queue, .retest: return retestAvailable
        default: return true
        }
    }
    var title: String {
        switch action {
        case .recover: return "检查连接"
        case .configure: return "配置 ISP"
        case .subscriptions: return "添加订阅"
        case .start: return "开始比较"
        case .retest: return "测试这条线路"
        case .queue: return queued ? "已加入测试队列" : testingSelected ? "正在测试这条" : untested ? "优先测试这条" : "优先重测这条"
        case .prepare: return "使用这条线路"
        case .connect: return currentIdentity == row?.id ? "复核当前线路" : "使用这条线路"
        case .current: return "正在使用"
        case .blocked: return working || !canMutate ? "处理中…" : state.waitingReason != nil ? "等待恢复…" : protectedConnection ? "其他客户端维护中" : "本轮比较中…"
        }
    }
    var retestTitle: String { queued ? "已排队" : testingSelected ? "正在测试…" : state.running ? "优先重测" : "重新测试" }
    var showSecondaryRetest: Bool { action == .connect || action == .prepare || action == .current }
    var guidance: String {
        switch action {
        case .recover: return "当前连接尚未确认，先到连接页检查并恢复；不会继续切换线路。"
        case .configure: return "先保存 ISP 地址和账号，保存时可以保持关闭，然后直接开始比较。"
        case .subscriptions: return "先添加并启用机场订阅，之后在这里比较 ISP 链路。"
        case .start: return selectedExists ? "开始比较后会保留每条测量；不会自动切换当前连接。" : "这条线路已不在当前订阅中，重新比较可以更新列表。"
        case .retest: return "先验证这条线路，完成后即可继续准备连接；其他结果和历史都会保留。"
        case .queue:
            if !inScanScope { return "这条线路不在本轮范围内；暂停后可单独测试，或继续测试全部未测节点。" }
            return queued ? "这条线路已排队，当前采样结束后会优先测试；其他线路继续按计划测试。" : "当前采样结束后优先测试这一条，无需暂停；已有成绩和其他待测线路都会保留。"
        case .prepare: return "点击后先复核目标，再自动开启 ISP、连接 VPN 并确认出口；需要授权时按系统提示操作。"
        case .connect:
            if row?.otherEnvironment == true || state.stale { return "网络环境已变化，先复核当前连通性和出口；上次性能成绩继续保留。" }
            return row?.requiresRefresh == true ? "性能测量时间较早，先复核连通性和出口，通过后仍可使用。" : "先复核连通性和出口，通过后才使用；测试本身不会改变连接。"
        case .current: return "当前正在使用这条线路；重新测试不会切换连接。"
        case .blocked:
            if state.waitingReason != nil { return "等待网络或电脑恢复后会自动继续，已经测到的成绩仍保留。" }
            if protectedConnection { return "当前连接由其他客户端维护，请先在原客户端断开。" }
            return working || !canMutate ? "正在处理操作，请稍候。" : "本轮比较完成后可使用结果；需要时也可在上方暂停。"
        }
    }
}
