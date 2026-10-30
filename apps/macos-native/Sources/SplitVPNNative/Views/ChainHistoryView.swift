import SwiftUI

func chainDate(_ value: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    return date?.formatted(date: .abbreviated, time: .standard) ?? value
}

struct ChainHistoryView: View {
    @ObservedObject var store: VPNStore
    var preview = false
    @State private var records: [ChainHistoryRecord] = []
    @State private var before: String?
    @State private var hasMore = false
    @State private var loading = false
    @State private var error: String?

    init(store: VPNStore, preview: Bool = false, records: [ChainHistoryRecord] = []) {
        self.store = store; self.preview = preview
        _records = State(initialValue: records)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("每次实际测量单独保存；重测、失败或环境变化不会删除旧记录。")
                    .font(.system(size: 11)).foregroundStyle(VPNTheme.secondary)
                Spacer()
                Button("刷新记录") { Task { await load(reset: true) } }.disabled(loading)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(records) { record in
                        let row = record.observation
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(row.nodeName).fontWeight(.medium)
                                Spacer()
                                Text(record.environmentKnown == false ? "网络待确认" : record.sameEnvironment ? "当前环境" : "其他环境").foregroundStyle(VPNTheme.secondary)
                            }
                            Text("\(chainDate(row.testedAt ?? "时间未知")) · \(row.status == "available" ? "测试通过" : row.status == "unstable" ? "部分通过" : "未连通")")
                            Text("响应 \(row.latencyMs.map { String(format: "%.0f ms", $0) } ?? "—") · 下载 \(row.downloadMbps.map { String(format: "%.2f Mbps", $0) } ?? "—") · 综合分 \(row.balancedScore.map { String(format: "%.1f", $0) } ?? "—")")
                                .foregroundStyle(VPNTheme.secondary)
                        }.font(.system(size: 11))
                        Divider()
                    }
                    if records.isEmpty && !loading { Text("还没有测试记录。").foregroundStyle(VPNTheme.secondary) }
                }
            }.frame(height: 220)
            if let error { Text(error).foregroundStyle(VPNTheme.destructive) }
            if hasMore { Button(loading ? "读取中…" : "加载更早记录") { Task { await load(reset: false) } }.disabled(loading) }
        }.task { await load(reset: true) }
    }
    private func load(reset: Bool) async {
        guard !preview, !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            var payload: [String: Any] = ["limit": 50]
            if !reset, let before { payload["before"] = before }
            let page: ChainHistoryPage = try await store.core.request("chain-scan:history", payload: payload)
            guard !Task.isCancelled else { return }
            if reset { records = page.records }
            else { records.append(contentsOf: page.records) }
            before = page.nextBefore; hasMore = page.hasMore
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
