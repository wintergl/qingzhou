import SwiftUI

struct MoreScreen: View {
    @EnvironmentObject private var appState: SplitVpnAppState

    var body: some View {
        NavigationStack {
            List {
                Section("诊断") {
                    LabeledContent(
                        "采集模式",
                        value: appState.diagnosticsSettings.mode == .deep ? "深度诊断" : "标准低功耗"
                    )
                    if appState.diagnosticsSettings.mode == .deep,
                       let expiresAt = appState.diagnosticsSettings.expiresAt {
                        LabeledContent(
                            "自动结束",
                            value: expiresAt.formatted(date: .omitted, time: .shortened)
                        )
                        Button("结束深度诊断") {
                            appState.disableDeepDiagnostics()
                        }
                    } else {
                        Button("开启 10 分钟深度诊断") {
                            appState.enableDeepDiagnostics()
                        }
                    }
                    Text(appState.isTunnelRunning ? "诊断模式变更会在 VPN 断开并重新连接后生效。" : "标准模式不持续采集连接事件；深度诊断会临时采集连接级信息。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    NavigationLink("真机预检") {
                        PhoneTestDetail()
                    }
                    NavigationLink("连接检测") {
                        ConnectivityProbeDetail(
                            title: "连接检测",
                            targets: ConnectivityProbeTarget.defaultTargets
                        )
                    }
                    NavigationLink("Google 连通性") {
                        ConnectivityProbeDetail(
                            title: "Google 连通性",
                            targets: [.google]
                        )
                    }
                    NavigationLink("流量统计") {
                        TrafficDetail()
                    }
                    NavigationLink("导出诊断日志") {
                        DiagnosticReportDetail()
                    }
                    NavigationLink("节点风险") {
                        PlaceholderDetail(title: "节点风险", lines: ["后续复用桌面端 IP 风险语义"])
                    }
                }

                Section("日志") {
                    if appState.logs.isEmpty {
                        Text("暂无日志")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.logs) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("[\(entry.level)] \(entry.message)")
                                Text(entry.createdAt.formatted(date: .abbreviated, time: .standard))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("调试信息") {
                    LabeledContent("Bundle ID", value: SplitVpnConstants.appBundleIdentifier)
                    LabeledContent("App Group", value: SplitVpnConstants.appGroupIdentifier)
                    LabeledContent("Extension", value: SplitVpnConstants.providerBundleIdentifier)
                    LabeledContent("共享容器", value: appState.usesAppGroupContainer ? "App Group" : "Fallback")
                    LabeledContent("签名占位", value: SplitVpnConstants.usesPlaceholderSigning ? "是" : "否")
                    LabeledContent("数据面核心", value: appState.packetTunnelCoreMode)
                    LabeledContent("sing-box 配置", value: appState.generatedConfigReady ? "已生成" : "未生成")
                    LabeledContent("Packet Tunnel MTU", value: "\(appState.settings.packetTunnelMTU)")
                    LabeledContent("节点 DNS", value: appState.settings.proxyServerDomainResolver)
                    LabeledContent("已转换节点", value: "\(appState.convertedOutboundCount)")
                    LabeledContent("暂不支持节点", value: "\(appState.unsupportedNodeCount)")
                }
            }
            .navigationTitle("更多")
            .vpnListStyle()
            .refreshable {
                appState.refreshFromDisk()
            }
        }
    }
}

private struct ConnectivityProbeDetail: View {
    let title: String
    let targets: [ConnectivityProbeTarget]

    @State private var results: [ConnectivityProbeResult] = []
    @State private var isRunning = false
    @State private var lastRunAt: Date?

    private let probeService = ConnectivityProbeService()

    var body: some View {
        List {
            Section {
                Button {
                    Task {
                        await runProbes()
                    }
                } label: {
                    Label(isRunning ? "检测中..." : "开始 5 轮检测", systemImage: "network")
                }
                .disabled(isRunning)

                if isRunning {
                    ProgressView()
                }

                if let lastRunAt {
                    LabeledContent("上次检测", value: lastRunAt.formatted(date: .abbreviated, time: .standard))
                }
                LabeledContent("轮次", value: "每目标 \(ConnectivityProbeService.defaultRoundCount) 轮")
            }

            Section("目标") {
                ForEach(targets) { target in
                    LabeledContent(target.name, value: target.url.host ?? target.url.absoluteString)
                }
            }

            Section("汇总") {
                if resultStats.isEmpty {
                    Text("尚未检测")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(resultStats) { stat in
                        ConnectivityProbeStatsRow(stat: stat)
                    }
                }
            }

            Section("结果") {
                if results.isEmpty {
                    Text("尚未检测")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(results) { result in
                        ConnectivityProbeResultRow(result: result)
                    }
                }
            }
        }
        .navigationTitle(title)
        .vpnListStyle()
    }

    private var resultStats: [ConnectivityProbeTargetStats] {
        ConnectivityProbeStatsCalculator.summarize(results.map(\.record))
    }

    @MainActor
    private func runProbes() async {
        guard !isRunning else {
            return
        }

        isRunning = true
        defer {
            isRunning = false
        }

        let probeResults = await probeService.runAll(targets: targets)
        results = probeResults
        lastRunAt = Date()
        try? AppGroupStore.shared.saveConnectivityProbeResults(probeResults.map(\.record))
    }
}

private struct ConnectivityProbeStatsRow: View {
    let stat: ConnectivityProbeTargetStats

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(stat.targetName)
                Spacer()
                Text("\(stat.successCount)/\(stat.count)")
                    .font(.caption)
                    .foregroundStyle(stat.successCount == stat.count ? VPNTheme.green : VPNTheme.warning)
            }

            HStack {
                Text("p50 \(stat.p50Milliseconds) ms")
                Text("max \(stat.maxMilliseconds) ms")
                Text("slow>=3s \(stat.slow3sCount)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !stat.timingSummaryText.isEmpty {
                Text(stat.timingSummaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let latestErrorMessage = stat.latestErrorMessage {
                Text(latestErrorMessage)
                    .font(.caption)
                    .foregroundStyle(VPNTheme.destructive)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct ConnectivityProbeResultRow: View {
    let result: ConnectivityProbeResult

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(result.targetName)
                } icon: {
                    Image(systemName: result.isReachable ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(result.isReachable ? VPNTheme.green : VPNTheme.destructive)
                }

                Spacer()

                Text("#\(result.roundIndex)/\(result.roundCount)  \(result.durationMilliseconds) ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(result.urlString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack {
                Text(result.isReachable ? "可达" : "失败")
                    .foregroundStyle(result.isReachable ? VPNTheme.green : VPNTheme.destructive)
                if let statusCode = result.statusCode {
                    Text("HTTP \(statusCode)")
                }
                if result.responseBytes > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(result.responseBytes), countStyle: .binary))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let timingText = result.timingSummaryText {
                Text(timingText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let bodyPreview = result.bodyPreview {
                Text(bodyPreview)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            if let errorMessage = result.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(VPNTheme.destructive)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 3)
    }
}

private extension ConnectivityProbeResult {
    var record: ConnectivityProbeRecord {
        ConnectivityProbeRecord(
            targetID: targetID,
            targetName: targetName,
            urlString: urlString,
            startedAt: startedAt,
            roundIndex: roundIndex,
            roundCount: roundCount,
            durationMilliseconds: durationMilliseconds,
            firstByteMilliseconds: firstByteMilliseconds,
            dnsMilliseconds: dnsMilliseconds,
            connectMilliseconds: connectMilliseconds,
            tlsMilliseconds: tlsMilliseconds,
            requestMilliseconds: requestMilliseconds,
            serverWaitMilliseconds: serverWaitMilliseconds,
            responseTransferMilliseconds: responseTransferMilliseconds,
            networkProtocolName: networkProtocolName,
            reusedConnection: reusedConnection,
            proxyConnection: proxyConnection,
            statusCode: statusCode,
            responseBytes: responseBytes,
            bodyPreview: bodyPreview,
            errorMessage: errorMessage
        )
    }
}

private extension ConnectivityProbeResult {
    var timingSummaryText: String? {
        let fields = [
            timingField("ttfb", firstByteMilliseconds),
            timingField("dns", dnsMilliseconds),
            timingField("connect", connectMilliseconds),
            timingField("tls", tlsMilliseconds),
            timingField("request", requestMilliseconds),
            timingField("server", serverWaitMilliseconds),
            timingField("response", responseTransferMilliseconds),
            networkProtocolName.map { "proto \($0)" },
            reusedConnection.map { "reused \($0)" },
            proxyConnection.map { "proxy \($0)" }
        ].compactMap { $0 }
        guard !fields.isEmpty else {
            return nil
        }
        return fields.joined(separator: "  ")
    }

    private func timingField(_ label: String, _ value: Int?) -> String? {
        value.map { "\(label) \($0) ms" }
    }
}

private struct PlaceholderDetail: View {
    var title: String
    var lines: [String]

    var body: some View {
        List(lines, id: \.self) { line in
            Text(line)
        }
        .navigationTitle(title)
        .vpnListStyle()
    }
}

private struct TrafficDetail: View {
    @EnvironmentObject private var appState: SplitVpnAppState

    var body: some View {
        List {
            LabeledContent("上行", value: ByteCountFormatter.string(fromByteCount: Int64(appState.runtimeStatus.bytesOut), countStyle: .binary))
            LabeledContent("下行", value: ByteCountFormatter.string(fromByteCount: Int64(appState.runtimeStatus.bytesIn), countStyle: .binary))
        }
        .navigationTitle("流量统计")
        .vpnListStyle()
    }
}

private struct DiagnosticReportDetail: View {
    @EnvironmentObject private var appState: SplitVpnAppState

    @State private var reportText = ""
    @State private var reportURL: URL?
    @State private var exportError: String?
    @State private var statusMessage: String?
    @State private var showingClearConfirmation = false

    var body: some View {
        List {
            Section {
                Button {
                    refreshReport()
                } label: {
                    Label("刷新报告", systemImage: "arrow.clockwise")
                }

                if let reportURL {
                    ShareLink(item: reportURL) {
                        Label("导出诊断报告", systemImage: "square.and.arrow.up")
                    }
                }

                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Label("清理并重新生成", systemImage: "trash")
                }

                if let exportError {
                    Text(exportError)
                        .font(.caption)
                        .foregroundStyle(VPNTheme.destructive)
                        .textSelection(.enabled)
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("报告") {
                Text(reportText.isEmpty ? "尚未生成" : reportText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("导出诊断日志")
        .vpnListStyle()
        .confirmationDialog("清理诊断数据？", isPresented: $showingClearConfirmation, titleVisibility: .visible) {
            Button("清理并重新生成", role: .destructive) {
                clearAndRefreshReport()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会清理日志和连接检测结果，不影响订阅、节点和规则设置。")
        }
        .task {
            if reportText.isEmpty {
                refreshReport()
            }
        }
    }

    private func refreshReport() {
        let nextReportText = AppGroupStore.shared.makeDiagnosticReport()
        reportText = nextReportText
        do {
            reportURL = try writeReportFile(nextReportText)
            exportError = nil
        } catch {
            reportURL = nil
            exportError = "诊断报告文件生成失败：\(error.localizedDescription)"
        }
    }

    private func clearAndRefreshReport() {
        do {
            try AppGroupStore.shared.clearDiagnosticData()
            removeTemporaryReportFiles()
            appState.refreshFromDisk()
            reportText = ""
            reportURL = nil
            exportError = nil
            statusMessage = "诊断数据已清理"
            refreshReport()
        } catch {
            exportError = "诊断数据清理失败：\(error.localizedDescription)"
        }
    }

    private func writeReportFile(_ text: String) throws -> URL {
        let directory = temporaryReportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("split-vpn-diagnostic-report-\(Int(Date().timeIntervalSince1970)).txt")
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func removeTemporaryReportFiles() {
        try? FileManager.default.removeItem(at: temporaryReportDirectory())
    }

    private func temporaryReportDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("split-vpn-diagnostics", isDirectory: true)
    }
}

private struct PhoneTestDetail: View {
    @EnvironmentObject private var appState: SplitVpnAppState

    var body: some View {
        List {
            Section("预检") {
                ForEach(appState.readinessItems) { item in
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: iconName(for: item.severity))
                            .foregroundStyle(color(for: item.severity))
                    }
                }
            }

            Section("签名") {
                LabeledContent("Bundle ID", value: SplitVpnConstants.appBundleIdentifier)
                LabeledContent("Extension", value: SplitVpnConstants.providerBundleIdentifier)
                LabeledContent("App Group", value: SplitVpnConstants.appGroupIdentifier)
                LabeledContent("共享容器", value: appState.usesAppGroupContainer ? "App Group" : "Fallback")
                LabeledContent("占位值", value: SplitVpnConstants.usesPlaceholderSigning ? "是" : "否")
            }

            Section("配置") {
                LabeledContent("数据面核心", value: appState.packetTunnelCoreMode)
                LabeledContent("sing-box", value: appState.generatedConfigReady ? "已生成" : "未生成")
                LabeledContent("TUN 地址", value: TunnelAddressing.singBoxTunAddress)
                LabeledContent("TUN 对端", value: TunnelAddressing.remoteAddress)
                LabeledContent("Packet Tunnel MTU", value: "\(appState.settings.packetTunnelMTU)")
                LabeledContent("节点数量", value: "\(appState.subscription.nodeCount)")
                LabeledContent("已转换", value: "\(appState.convertedOutboundCount)")
                LabeledContent("暂不支持", value: "\(appState.unsupportedNodeCount)")
                LabeledContent("手选状态", value: appState.selectedProxyStatus)
                LabeledContent("实际出站", value: appState.selectedOutboundTag)
                LabeledContent("未知流量", value: appState.settings.unknownTrafficPolicy == "vpn" ? "未匹配代理" : "默认直连")
            }

            Section("手选节点说明") {
                Text(appState.selectedProxyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if !appState.runtimeStatus.lastError.isEmpty {
                Section("最近错误") {
                    Text(appState.runtimeStatus.lastError)
                        .foregroundStyle(VPNTheme.destructive)
                }
            }
        }
        .navigationTitle("真机预检")
        .vpnListStyle()
        .refreshable {
            appState.refreshFromDisk()
        }
    }

    private func iconName(for severity: ReadinessSeverity) -> String {
        switch severity {
        case .ok:
            return "checkmark.circle"
        case .warning:
            return "exclamationmark.triangle"
        case .blocking:
            return "xmark.octagon"
        }
    }

    private func color(for severity: ReadinessSeverity) -> Color {
        switch severity {
        case .ok:
            return VPNTheme.green
        case .warning:
            return VPNTheme.warning
        case .blocking:
            return VPNTheme.destructive
        }
    }
}
