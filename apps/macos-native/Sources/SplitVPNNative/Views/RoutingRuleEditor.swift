import SwiftUI

struct RoutingRuleEditor: View {
    @ObservedObject var store: VPNStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var addressFocused: Bool
    @State private var draft: RoutingRuleDraft
    @State private var normalized: NormalizedRoutingRule?
    @State private var inputError: String?
    @State private var saveError: String?
    @State private var saving = false
    var onSaved: () -> Void

    init(store: VPNStore, draft: RoutingRuleDraft, normalized: NormalizedRoutingRule? = nil, onSaved: @escaping () -> Void = {}) {
        self.store = store
        _draft = State(initialValue: draft)
        _normalized = State(initialValue: normalized)
        self.onSaved = onSaved
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(draft.original == nil ? "添加分流规则" : "编辑分流规则").font(.title2.bold())
            VStack(alignment: .leading, spacing: 8) {
                Text("这些地址走哪里？").font(.headline)
                Picker("出口", selection: $draft.outlet) {
                    ForEach(RoutingOutlet.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Text(draft.outlet.detail).font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                Picker("匹配方式", selection: $draft.kind) {
                    ForEach(RoutingMatchKind.allCases) { Text($0.title).tag($0) }
                }
                TextField(draft.kind.example, text: $draft.address)
                    .textFieldStyle(.roundedBorder).focused($addressFocused).accessibilityLabel("地址或规则")
                Text(draft.kind.hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                if let normalized {
                    Label("\(normalized.matchTitle)：\(normalized.value) → \(draft.outlet.title)", systemImage: "checkmark.circle")
                        .foregroundStyle(.primary).textSelection(.enabled)
                } else if let inputError {
                    Label(inputError, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                } else {
                    Text(draft.address.isEmpty ? "填写后会显示匹配范围。" : "正在检查地址…").foregroundStyle(.secondary)
                }
                if let saveError { Text(saveError).foregroundStyle(.red) }
            }.font(.callout).fixedSize(horizontal: false, vertical: true).frame(minHeight: 42, alignment: .topLeading)
            Text("每条规则填一个地址。相同规则改出口会替换原设置；不同范围重叠时直连优先。局域网、Tailscale 与私有网络仍按接入设置处理。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                Button(saving ? "保存中…" : "保存规则") { save() }
                    .buttonStyle(VPNButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    .disabled(normalized == nil || saving || !store.canMutate)
            }
        }.padding(24).frame(width: 550).buttonStyle(VPNButtonStyle()).disabled(saving)
            .onAppear { addressFocused = true }.task(id: draft.validationID) { await validate() }
    }
    private func validate() async {
        guard !store.previewOnly else { return }
        normalized = nil; inputError = nil; saveError = nil
        guard !draft.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let validationID = draft.validationID
        do {
            try await Task.sleep(for: .milliseconds(250))
            let result: NormalizedRoutingRule = try await store.core.request("routing:normalize-rule", payload: ["rule": draft.address, "kind": draft.kind.rawValue])
            guard !Task.isCancelled, validationID == draft.validationID else { return }
            normalized = result
        } catch {
            guard !Task.isCancelled, validationID == draft.validationID else { return }
            inputError = error.localizedDescription
        }
    }
    private func save() {
        saving = true; saveError = nil
        Task {
            defer { saving = false }
            do { try await store.saveRoutingRule(draft); onSaved(); dismiss() }
            catch { saveError = error.localizedDescription }
        }
    }
}
