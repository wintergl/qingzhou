import SwiftUI

struct CompanyVerificationSheet: View {
    @ObservedObject var store: CompanyStore
    var verifyOnAppear = true
    @Environment(\.dismiss) private var dismiss
    @State private var started = false
    @State private var attemptedTarget = ""
    @State private var dismissal: Task<Void, Never>?
    private var passed: Bool { store.phases["business"] == .passed }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("验证私有网络").font(.title2.weight(.semibold))
            Text("通过当前私有网络连接检查这个地址是否可访问。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            TextField("内网网址或 IP", text: $store.target)
                .textFieldStyle(.roundedBorder).disabled(store.working)
            if store.working {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("正在验证…") }
            } else if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(VPNTheme.destructive)
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            } else if passed {
                Label("验证通过", systemImage: "checkmark.circle.fill").foregroundStyle(VPNTheme.green)
                if let proof = store.routingState?.proof, store.businessVerified {
                    Text("系统访问 HTTP \(proof.httpStatus) · \(proof.elapsedMs) ms").font(.system(size: 13)).foregroundStyle(.secondary)
                } else if let proof = store.tunnelProof {
                    Text("私有网络隧道 HTTP \(proof.httpStatus) · \(proof.elapsedMs) ms").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(passed ? "重新验证" : "验证") { verify() }
                    .buttonStyle(VPNButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    .disabled(store.working || store.tunnelProof == nil || store.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 440).buttonStyle(VPNButtonStyle())
            .task {
                guard verifyOnAppear else { return }
                started = true
                verify()
            }
            .onReceive(store.$phases) { phases in
                guard verifyOnAppear, started, phases["business"] == .passed else { return }
                dismissal?.cancel()
                dismissal = Task {
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                    catch { return }
                    if !store.working && passed && store.errorMessage == nil && store.target == attemptedTarget { dismiss() }
                }
            }
            .onDisappear { dismissal?.cancel() }
    }
    private func verify() {
        dismissal?.cancel()
        attemptedTarget = store.target
        store.verifyBusiness()
    }
}
