import AppKit
import SwiftUI

struct LogsView: View {
    @ObservedObject var store: VPNStore
    var initializeOnAppear = true
    @State private var kind = "app"
    @State private var query = ""
    @State private var lines: [String] = []
    @State private var following = true
    @State private var failure: String?
    var visible: [String] { lines.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "日志", subtitle: "保留运行的线索，导出时自动隐藏敏感信息")
            HStack {
                Picker("来源", selection: $kind) { Text("应用").tag("app"); Text("Mihomo 内核").tag("mihomo") }.pickerStyle(.segmented).frame(width: 230)
                TextField("搜索日志", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Spacer(); Toggle("跟随更新", isOn: $following).toggleStyle(.checkbox).help("自动显示最新一屏；关闭后可停留在旧日志。")
            }
            LogOutputView(lines: visible, following: following).tableCard()
                .overlay { if visible.isEmpty { ContentUnavailableView(query.isEmpty ? "暂无日志" : "没有匹配的日志", systemImage: "text.alignleft", description: Text(query.isEmpty ? "新的运行记录会在这里显示。" : "试试其他关键词。")) } }
            HStack {
                Button("复制当前显示") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(visible.joined(separator: "\n"), forType: .string) }
                Button("清空显示") { following = false; lines = [] }
                Button("导出脱敏诊断") { export() }
                Spacer(); Text("最近 \(lines.count) 行").foregroundStyle(.secondary)
            }
            if let failure { Text(failure).foregroundStyle(VPNTheme.warning) }
        }.padding(28)
        .task(id: "\(kind)|\(following)|\(store.activity)") {
            guard initializeOnAppear, store.activity.visible, !store.activity.sleeping else { return }
            await read()
            while !Task.isCancelled && following {
                do { try await Task.sleep(for: .seconds(store.activity.lowPower ? 5 : 2), tolerance: .milliseconds(500)) }
                catch { return }
                if !Task.isCancelled && following { await read() }
            }
        }
    }
    private func read() async { do { lines = try await store.core.request("logs:get", payload: ["kind": kind]); failure = nil } catch { failure = error.localizedDescription } }
    private func export() {
        Task {
            do {
                let content: String = try await store.core.request("logs:export-redacted", payload: ["includeMihomoSummary": true])
                let panel = NSSavePanel(); panel.nameFieldStringValue = "轻舟-诊断.txt"
                if panel.runModal() == .OK, let url = panel.url { try content.write(to: url, atomically: true, encoding: .utf8) }
            } catch { failure = error.localizedDescription }
        }
    }
}
