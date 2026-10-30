import SwiftUI

struct ChainScannerView: View {
    @ObservedObject var store: VPNStore
    @Environment(\.dismiss) private var dismiss
    private let preview: Bool
    private let standalone: Bool
    @State private var state: ChainScanState
    @State private var strategy = "balanced"
    @State private var selection: String?
    @State private var scope = "all"
    @State private var subscriptionID = ""
    @State private var search = ""
    @State private var working = false
    @State private var pausing = false
    @State private var readError: String?
    @State private var note: String?
    @State private var failed = false
    @State private var modal: Modal?
    @State private var connectionTarget: ChainScanRow?
    @State private var tableEpoch = 0
    @State private var comparisonExpanded = false
    private enum Modal: String, Identifiable {
        case configuration, connection, history, information, automatic
        var id: String { rawValue }
    }
    init(store: VPNStore, preview: ChainScanState? = nil, detailsExpanded: Bool = false, standalone: Bool = false, subscriptionID: String = "") {
        self.store = store; self.preview = preview != nil; self.standalone = standalone
        _state = State(initialValue: preview ?? ChainScanState())
        _selection = State(initialValue: nil)
        _comparisonExpanded = State(initialValue: detailsExpanded)
        _subscriptionID = State(initialValue: subscriptionID)
    }
    private var displayState: ChainScanState { state.scoped(to: subscriptionID) }
    private var comparison: ChainComparisonPresentation { ChainComparisonPresentation(state: displayState) }
    private var candidates: [VPNNode] { store.providerNodes.filter { $0.identityAmbiguous != true } }
    private var subscriptionScope: ChainSubscriptionScope { ChainSubscriptionScope(subscriptionID: subscriptionID, nodes: candidates) }
    private var subscriptions: [Subscription] { store.status?.subscription.entries.filter(\.enabled) ?? [] }
    private var scopedRows: [ChainScanRow] {
        let measured = Set(displayState.results.map(\.id))
        return displayState.results + allRows.filter { $0.status == "pending" && !measured.contains($0.id) && subscriptionScope.contains($0.id) }
    }
    private var allRows: [ChainScanRow] {
        let measured = Set(state.results.map(\.id))
        let pending = candidates.compactMap { node -> ChainScanRow? in
            guard let id = node.identityKey, !measured.contains(id) else { return nil }
            return ChainScanRow(identityKey: id, nodeName: node.name, status: "pending", latencyMs: nil, jitterMs: nil, downloadMbps: nil,
                                latencySuccesses: 0, latencyAttempts: 3, downloadSuccesses: 0, downloadAttempts: 2, exitIp: nil, errors: [])
        }
        return state.results + pending
    }
    private var untestedRows: [ChainScanRow] { scopedRows.filter { $0.status == "pending" } }
    private var filtered: [ChainScanRow] {
        scopedRows.filter { row in
            (scope == "all" || scope == "passed" && row.status == "available" || scope == "issues" && row.status != "available" && row.status != "pending" || scope == "pending" && row.status == "pending") &&
            (search.isEmpty || row.nodeName.localizedCaseInsensitiveContains(search))
        }
    }
    private var selected: ChainScanRow? {
        if let row = scopedRows.first(where: { $0.id == selection }) { return row }
        if !comparisonExpanded, let id = state.routine?.currentIdentityKey ?? state.routine?.preferredIdentityKey ?? currentIdentity,
           let row = scopedRows.first(where: { $0.id == id && $0.status == "available" && $0.connectionEligible != false }) { return row }
        return scopedRows.first { $0.id == displayState.recommendedIdentityKey } ?? scopedRows.first
    }
    private var selectionHeading: String {
        if selection != nil { return "所选线路" }
        if let id = state.routine?.currentIdentityKey ?? currentIdentity, selected?.id == id { return "当前线路" }
        if selected?.otherEnvironment == true { return "上次测量" }
        return comparison.comparisonReady && displayState.recommended?.id == selected?.id ? "已测推荐" : "线路详情"
    }
    private var canStart: Bool { !working && !state.running && store.canMutate && !subscriptionScope.candidates.isEmpty && store.status?.settings.staticExit?.configured == true }
    private var currentIdentity: String? {
        guard store.running, store.status?.settings.staticExit?.enabled == true else { return nil }
        return candidates.first { $0.name == store.selectedProxy }?.identityKey
    }
    private var workflow: ChainWorkflowPresentation {
        ChainWorkflowPresentation(state: displayState, row: selected, strategy: strategy,
            configured: store.status?.settings.staticExit?.configured == true, candidateCount: subscriptionScope.candidates.count,
            selectedExists: selected.map { row in candidates.contains { $0.identityKey == row.id } } ?? true,
            canMutate: store.canMutate, working: working || pausing, vpnRunning: store.running,
            ispEnabled: store.status?.settings.staticExit?.enabled == true,
            protectedConnection: store.connectionProtected, recoveryRequired: store.status?.mihomo.state == "error", currentIdentity: currentIdentity)
    }
    private var setupReady: Bool { store.status?.settings.staticExit?.configured == true && !candidates.isEmpty }
    private var pollingID: String {
        let activity = store.activity
        return [strategy, subscriptionID, String(state.running), String(activity.visible),
                String(activity.sleeping), String(activity.lowPower), String(activity.onBattery != false)].joined(separator: "|")
    }
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 760
            VStack(alignment: .leading, spacing: compact ? 8 : 12) {
                header(compact: compact)
                OverviewISPCard(store: store, showsRouteLink: false, showsSwitchStatus: false)
                if let use = store.chainUse {
                    ChainUseStatusView(state: use, cancel: { Task { await store.cancelChainUse() } }, refresh: { Task { await store.refreshChainUse() } },
                        retry: { Task { await store.retryChainUse() } }, dismiss: store.dismissChainUse)
                }
                if comparisonExpanded {
                    controls
                    subscriptionControls
                    ChainLeaderCards(state: displayState, compact: compact, activeStrategy: strategy, selectedID: selection) { strategy, row in
                        self.strategy = strategy; selection = row.id; scope = "all"; search = ""; tableEpoch += 1
                    }
                    rankingControls
                    phaseStrip
                    ChainComparisonTable(rows: filtered, state: displayState, selection: $selection,
                        downloadMaximum: comparison.successful.compactMap(\.downloadMbps).filter { $0.isFinite && $0 > 0 }.max() ?? 1,
                        latencyMinimum: comparison.successful.compactMap(\.latencyMs).filter { $0.isFinite && $0 > 0 }.min() ?? 1)
                        .id([strategy, subscriptionID, scope, search, String(tableEpoch)])
                        .frame(minHeight: 105, maxHeight: .infinity)
                    if store.chainUse?.active != true { selectedRoute }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ChainDailyStatusView(state: state, fallbackCurrent: store.running ? store.selectedProxy : nil,
                                fallbackConnected: store.running && store.status?.settings.staticExit?.enabled == true, pending: store.chainUse,
                                runtimeUncertain: store.status?.mihomo.state == "error", canSwitch: !working && store.canMutate && !store.connectionProtected,
                                switchRoute: switchBackup) { id in
                                subscriptionID = ""; selection = id; scope = "all"; search = ""; tableEpoch += 1
                            }
                            if store.chainUse?.active != true && (state.routine == nil || selection != nil || state.routine?.connectionState != "connected") { selectedRoute }
                            controls
                            if state.running { phaseStrip }
                        }.padding(.bottom, 4)
                    }.frame(maxHeight: .infinity)
                }
                footer
                if let message = readError ?? note {
                    Text(message).font(.system(size: 11)).foregroundStyle(readError != nil || failed ? VPNTheme.destructive : VPNTheme.accent)
                        .lineLimit(2).help(message).textSelection(.enabled)
                }
            }.padding(compact ? 16 : 22)
        }.frame(minWidth: 740, idealWidth: 920, maxWidth: .infinity, minHeight: 600, idealHeight: 760, maxHeight: .infinity)
            .background(VPNTheme.background).foregroundStyle(VPNTheme.text)
            .buttonStyle(VPNButtonStyle()).tint(VPNTheme.accent)
            .onChange(of: subscriptionID) { _, id in
                if !id.isEmpty { selection = nil }
                scope = "all"; search = ""; tableEpoch += 1
            }
            .onChange(of: store.chainUse) { _, value in
                guard let value, value.finished else { return }
                if value.result?.connected == true { selection = nil }
                failed = value.error != nil
                note = value.error ?? value.result.map { "已连接：\($0.nodeName) → ISP；实际出口 \($0.exitIp)。" }
                Task { await store.refresh(); await refresh() }
            }
            .sheet(item: $modal) { modal in
                switch modal {
                case .configuration: StaticExitConfigurationSheet(store: store)
                case .automatic:
                    ChainAutomaticRefreshView(configuration: state.autoRefresh ?? ChainAutoRefreshState(), working: working,
                        close: { self.modal = nil }, save: { enabled, minutes in Task { await configureAutomatic(enabled: enabled, minutes: minutes) } })
                case .connection:
                    if let target = connectionTarget {
                        ChainConnectionPreparationView(store: store, target: target,
                            verificationReady: comparison.canApply(state.results.first { $0.id == target.id }, strategy: strategy),
                            verificationReason: state.waitingReason != nil ? "等待网络恢复后再复核，已完成的准备会保留。" : "测量环境或线路结果已变化，请返回重新测试。", close: { self.modal = nil }, apply: {
                            self.modal = nil
                            Task { await connect(target) }
                        })
                    }
                case .history:
                    VStack(alignment: .leading, spacing: 16) {
                        HStack { Text("长期测试记录").font(.system(size: 22, weight: .semibold)); Spacer(); Button("关闭") { self.modal = nil } }
                        ChainHistoryView(store: store, preview: preview)
                    }.padding(24).frame(minWidth: 720, idealWidth: 820, minHeight: 380)
                        .background(VPNTheme.background)
                case .information: information
                }
            }
            .task(id: pollingID) {
                guard !preview, !store.previewOnly, store.activity.visible, !store.activity.sleeping else { return }
                while !Task.isCancelled {
                    await refresh()
                    guard let interval = store.activity.chainPollingInterval(running: state.running) else { return }
                    do { try await Task.sleep(for: interval) } catch { return }
                }
            }
    }
    private func header(compact: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(comparisonExpanded ? "ISP 性能比较" : "ISP 日常线路").font(.system(size: compact ? 22 : 26, weight: .semibold))
                if !compact { Text(comparisonExpanded ? "比较已测范围内的表现，测量时间单独标注" : "先验证一条线路，再按需维护常用线路").font(.system(size: 12)).foregroundStyle(VPNTheme.secondary) }
            }
            Spacer()
            Button((state.autoRefresh ?? ChainAutoRefreshState()).title) { modal = .automatic }
                .disabled(working || !store.canMutate).accessibilityIdentifier("isp-auto-refresh-settings")
                .help("按需维护当前线路和每个订阅各两条已验证备选，不自动全量扫描")
            if !standalone { Button("关闭") { dismiss() }.disabled(working).help("离开页面不会停止后台测试") }
        }
    }
    private var controls: some View {
        HStack(spacing: 10) {
            if state.running {
                Text(state.automatic == true ? "省电维护 · 本批最多三条常用线路" : state.mode == "quick" ? "正在查找可用线路，测通后即可使用" : state.mode == "continuous" ? "持续测试 · 最多约 60 MiB/小时" : "正在比较，已测通的线路可以先使用")
                    .font(.system(size: 12)).foregroundStyle(VPNTheme.secondary).lineLimit(1)
                Spacer(minLength: 6)
                Button(pausing ? "正在暂停…" : "暂停测试") { Task { await pause() } }
                    .disabled(pausing || working).accessibilityIdentifier("isp-pause-scan")
            } else {
                Button(working ? "处理中…" : !setupReady ? store.status?.settings.staticExit?.configured != true ? "配置 ISP" : "添加订阅" : "测试并推荐") {
                    if store.status?.settings.staticExit?.configured != true { modal = .configuration }
                    else if candidates.isEmpty { store.page = .subscriptions; if !standalone { dismiss() } }
                    else { Task { await start("quick") } }
                }.buttonStyle(VPNButtonStyle(prominent: true))
                    .disabled(working || !store.canMutate || setupReady && subscriptionScope.candidates.isEmpty)
                    .accessibilityIdentifier("isp-start-scan")
                    .help("优先当前、收藏及上次成功的少量线路；找到完整通过者即结束，不切换连接")
                if !comparison.successful.isEmpty {
                    Button("重新比较") { Task { await start("accumulate", recompare: true) } }
                        .disabled(!canStart).accessibilityIdentifier("isp-recompare")
                        .help("重新测量当前订阅范围，比较结果不会自动切换连接")
                }
                Spacer(minLength: 4)
            }
            Menu("高级测试") {
                Button("补测未测与旧成绩") { Task { await start("accumulate") } }.disabled(!canStart)
                if !untestedRows.isEmpty {
                    Button("只补测未测 \(untestedRows.count) 条") { Task { await start("accumulate", onlyUntested: true) } }.disabled(!canStart)
                }
                Button("全部重新测试") { Task { await start("full") } }.disabled(!canStart)
                Button("持续后台测试") { Task { await start("continuous") } }.disabled(!canStart)
                Divider()
                Button(comparisonExpanded ? "收起性能比较" : "展开性能比较") { comparisonExpanded.toggle() }
                Divider()
                Button("分步准备所选线路…") {
                    if let selected { connectionTarget = selected; modal = .connection }
                }.disabled(selected == nil || !comparison.canApply(selected, strategy: strategy) || !store.canMutate || store.connectionProtected)
            }.fixedSize().disabled(working || store.chainUse?.active == true).accessibilityIdentifier("isp-advanced-tests")
        }
    }
    private var subscriptionControls: some View {
        ChainSubscriptionControls(subscriptions: subscriptions, selection: $subscriptionID,
            candidateCount: subscriptionScope.candidates.count, running: state.running, busy: working || pausing,
            canRetest: store.canMutate && setupReady && !subscriptionScope.candidates.isEmpty,
            retest: { Task { await retestSubscription() } })
    }
    private var rankingControls: some View {
        HStack(spacing: 8) {
            Picker("排名方式", selection: $strategy) {
                Text("综合表现").tag("balanced")
                Text("下载快优先").tag("download")
                Text("响应快优先").tag("latency")
            }.labelsHidden().pickerStyle(.segmented).frame(minWidth: 250, maxWidth: 330)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(VPNTheme.secondary)
                TextField("搜索线路", text: $search).textFieldStyle(.plain).accessibilityIdentifier("isp-search")
                    .onExitCommand { search = "" }
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("清除搜索") }
            }.font(.system(size: 11)).padding(8).frame(width: 142)
                .background(VPNTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            Picker("结果范围", selection: $scope) {
                Text("全部线路").tag("all")
                Text("完整通过").tag("passed")
                Text("需关注").tag("issues")
                Text("尚未测试").tag("pending")
            }.labelsHidden().frame(width: 110)
        }
    }
    private var phaseStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            ChainScanProgressView(state: displayState, rowCount: scopedRows.count,
                measuredCount: scopedRows.filter { $0.status != "pending" }.count,
                passedCount: scopedRows.filter { $0.status == "available" }.count, pausing: pausing)
            if let selection, !filtered.contains(where: { $0.id == selection }) {
                Button("定位所选") { search = ""; scope = "all"; tableEpoch += 1 }.buttonStyle(.plain).font(.system(size: 12))
            }
        }
    }
    private var footer: some View {
        HStack {
            Text("测试不会自动切换当前连接")
                .font(.system(size: 11)).foregroundStyle(VPNTheme.secondary)
            Spacer()
            Button(comparisonExpanded ? "返回日常" : "性能比较") { comparisonExpanded.toggle() }.buttonStyle(.plain)
            Button("历史记录") { modal = .history }.buttonStyle(.plain)
            Text("·").foregroundStyle(VPNTheme.secondary)
            Button("测试说明") { modal = .information }.buttonStyle(.plain)
        }.font(.system(size: 11))
    }
    private var selectedRoute: some View {
        ChainSelectedRouteView(row: selected, heading: selectionHeading, restriction: workflow.guidance, guidanceWarning: workflow.action == .blocked || workflow.action == .configure || workflow.action == .subscriptions, primaryTitle: workflow.title, retestTitle: workflow.retestTitle, showRetest: workflow.showSecondaryRetest,
            canConnect: workflow.primaryEnabled, canRetest: workflow.retestAvailable, working: working,
            connect: performPrimary, retest: { if let selected { Task { await retest(selected) } } })
    }
    private func switchBackup(_ row: ChainScanRow) {
        guard !working, store.canMutate, !store.connectionProtected else { return }
        subscriptionID = ""; selection = row.id; scope = "all"; search = ""; strategy = "balanced"
        Task { await connect(row) }
    }
    private var information: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("如何看测试结果").font(.system(size: 22, weight: .semibold)); Spacer(); Button("关闭") { modal = nil } }
            Text("下载速率越大，短样本下载越快；8 Mbps 约为 1 MB/s。响应耗时越小，请求反馈越快。两者是不同指标，下载快的线路不一定响应快。")
            Text("综合分兼顾下载 45%、响应 45%、波动 10%。排名只代表已测范围，测量时间不会单独改变名次；比较切换收益时，需要当前线路和备选都有同一轮测量。")
            Text("条形只用于相对比较：下载条按最高速率归一，响应条按最低耗时归一，越长越快。同一环境下，成绩超过 24 小时才提示刷新，保留原分数；连接前会复核连通性和出口。")
            Text("每条线路下载约 1 MiB，全部约 \(candidates.count) MiB。持续模式每次采样后等待约 1 分钟，最多约 60 MiB/小时；可随时暂停。波动、成功次数和出口可在选中线路后查看。")
            Text("测试无需连接 VPN 或开启“走 ISP”，也不会切换正在使用的线路。点击“使用这条线路”后，软件会先复核目标，再准备 ISP 和 VPN，并确认实际出口；需要时会弹出系统授权。短样本不代表持续带宽上限。")
        }.font(.system(size: 13)).foregroundStyle(VPNTheme.text).padding(26)
            .frame(width: 650).background(VPNTheme.background)
    }
    private func configureAutomatic(enabled: Bool, minutes: Int) async {
        guard !working, !preview, store.canMutate else { return }
        working = true; failed = false; note = nil
        defer { working = false }
        do {
            state.autoRefresh = try await store.core.request("chain-scan:auto-configure", payload: ["enabled": enabled, "intervalMinutes": minutes])
            note = enabled ? "日常自动刷新已开启；随轻舟运行，无需保持此页打开。" : "已关闭日常自动刷新；已有成绩和历史保留。"
            await refresh()
        } catch { failed = true; note = error.localizedDescription }
    }
    private func performPrimary() {
        guard workflow.primaryEnabled else { return }
        switch workflow.action {
        case .recover: store.page = .overview; if !standalone { dismiss() }
        case .configure: modal = .configuration
        case .subscriptions: store.page = .subscriptions; if !standalone { dismiss() }
        case .start: Task { await start("quick") }
        case .retest, .queue: if let selected { Task { await retest(selected) } }
        case .prepare, .connect: if let selected { Task { await connect(selected) } }
        case .current, .blocked: break
        }
    }
    private func retest(_ row: ChainScanRow) async {
        guard workflow.retestAvailable, !preview else { return }
        selection = row.id
        if state.running {
            working = true; failed = false; note = nil
            defer { working = false }
            do {
                let reply = try await store.core.requestValue("chain-scan:prioritize", payload: ["identityKey": row.id])
                if case .object(let fields) = reply, case .bool(true)? = fields["alreadyTesting"] { note = "这条线路已经在测试中。" }
                else { note = "已优先安排 \(row.nodeName)，当前采样结束后会测试；其他线路继续。" }
                await refresh()
            } catch { note = error.localizedDescription; failed = true }
        } else { await start("accumulate", row: row) }
    }
    private func refresh() async {
        let requestedStrategy = strategy
        let requestedSubscription = subscriptionID
        do {
            var payload: [String: Any] = ["strategy": requestedStrategy]
            if !requestedSubscription.isEmpty { payload["subscriptionId"] = requestedSubscription }
            let snapshot: ChainScanState = try await store.core.request("chain-scan:get", payload: payload, timeout: .seconds(8))
            guard !Task.isCancelled, requestedStrategy == strategy, requestedSubscription == subscriptionID else { return }
            state = snapshot; readError = nil
            if let selectedID = selection, !allRows.contains(where: { $0.id == selectedID }) { selection = nil }
            if !snapshot.running { pausing = false }
        } catch { if !Task.isCancelled { readError = "读取结果失败，保留上次显示：\(error.localizedDescription)" } }
    }
    private func start(_ mode: String, row: ChainScanRow? = nil, onlyUntested: Bool = false, recompare: Bool = false) async {
        guard canStart, !preview else { return }
        working = true; note = nil; failed = false
        defer { working = false }
        do {
            var payload = subscriptionScope.payload(mode: mode)
            if let row { payload.removeValue(forKey: "subscriptionId"); payload["identityKeys"] = [row.id]; payload["forceRetest"] = true }
            else if onlyUntested {
                let keys = untestedRows.map(\.id)
                guard !keys.isEmpty else { return }
                payload.removeValue(forKey: "subscriptionId")
                payload["identityKeys"] = keys
            }
            if recompare {
                payload["mode"] = "accumulate"; payload["forceRetest"] = true
                if subscriptionID.isEmpty { payload["identityKeys"] = subscriptionScope.candidates.compactMap(\.identityKey) }
            }
            _ = try await store.core.requestValue("chain-scan:start", payload: payload)
            await refresh()
        } catch { note = error.localizedDescription; failed = true }
    }
    private func retestSubscription() async {
        guard !working, !pausing, !preview, store.canMutate, setupReady,
              !subscriptionID.isEmpty, !subscriptionScope.candidates.isEmpty else { return }
        let request = subscriptionScope.payload(mode: "full")
        working = true; note = nil; failed = false
        defer { working = false; pausing = false }
        do {
            if state.running {
                pausing = true; note = "正在暂停当前测试，随后全量重测所选订阅…"
                _ = try await store.core.requestValue("chain-scan:cancel")
                let deadline = Date().addingTimeInterval(20)
                repeat {
                    try Task.checkCancellation()
                    var scopePayload: [String: Any] = ["strategy": strategy]
                    if !subscriptionID.isEmpty { scopePayload["subscriptionId"] = subscriptionID }
                    state = try await store.core.request("chain-scan:get", payload: scopePayload, timeout: .seconds(8))
                    if !state.running && state.workerActive != true { break }
                    try await Task.sleep(for: .milliseconds(200))
                } while Date() < deadline
                guard !state.running && state.workerActive != true else { throw CoreService.CoreError.message("当前采样尚未结束，请稍后重试；没有启动另一轮测试。") }
            }
            _ = try await store.core.requestValue("chain-scan:start", payload: request)
            note = "已开始重测所选订阅的全部可测节点；其他订阅成绩和历史保留。"
            await refresh()
        } catch { note = error.localizedDescription; failed = true }
    }
    private func pause() async {
        guard state.running, !preview, !pausing else { return }
        pausing = true; note = nil
        do { _ = try await store.core.requestValue("chain-scan:cancel"); await refresh() }
        catch { pausing = false; failed = true; note = error.localizedDescription }
    }
    private func connect(_ row: ChainScanRow) async {
        guard !preview else { return }
        guard !working, comparison.canApply(state.results.first { $0.id == row.id }, strategy: strategy), store.canMutate,
              !store.connectionProtected else {
            failed = true; note = "连接条件已变化，未应用所选线路；请检查状态后重试。"; return
        }
        selection = row.id
        note = nil; failed = false
        await store.useChainRoute(row, scanID: state.id, strategy: strategy)
        note = store.chainUse?.error ?? store.error ?? store.message; failed = store.chainUse?.error != nil || store.error != nil
        await refresh()
    }
}
