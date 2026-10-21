import SwiftUI

struct CompanyPasswordChangeInput {
    var oldPassword = ""
    var newPassword = ""
    var confirmation = ""
    var newUsername = ""

    func validationMessage(requireUsername: Bool) -> String? {
        if requireUsername && newUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写新账号名。" }
        if oldPassword.isEmpty || newPassword.isEmpty || confirmation.isEmpty { return "请填写旧密码、新密码和确认密码。" }
        if newPassword != confirmation { return "两次输入的新密码不一致。" }
        if newPassword == oldPassword { return "新密码不能与旧密码相同。" }
        if oldPassword.utf16.count > 128 || newPassword.utf16.count > 128 || (requireUsername && newUsername.utf16.count > 128) {
            return "账号名和密码不能超过 128 个字符。"
        }
        return nil
    }
}

struct CompanyPasswordChangeSheet: View {
    let challenge: AuthChallenge
    let onSubmit: ([String: Any]) -> Void
    let onCancel: () -> Void
    @State private var input = CompanyPasswordChangeInput()
    @FocusState private var focused: Field?
    private enum Field { case username, oldPassword, newPassword, confirmation }
    private var requireUsername: Bool { challenge.requireUsername == true }
    private var validation: String? { input.validationMessage(requireUsername: requireUsername) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(challenge.title, systemImage: "lock.rotation").font(.title2.bold())
            Text(challenge.message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let username = challenge.username, !username.isEmpty {
                        Text("接入账号：\(username)").fontWeight(.medium).textSelection(.enabled)
                    }
                    if let error = challenge.errorMessage, !error.isEmpty {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                    if let rules = challenge.rules, !rules.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("接入密码要求").fontWeight(.medium)
                            ForEach(Array(rules.enumerated()), id: \.offset) { _, rule in
                                Text("• \(rule)").font(.system(size: 12)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if requireUsername {
                        TextField("新账号名", text: $input.newUsername).focused($focused, equals: .username)
                    }
                    SecureField("旧密码", text: $input.oldPassword).focused($focused, equals: .oldPassword)
                        .textContentType(.password)
                    SecureField("新密码", text: $input.newPassword).focused($focused, equals: .newPassword)
                        .textContentType(.newPassword)
                    SecureField("再次输入新密码", text: $input.confirmation).focused($focused, equals: .confirmation)
                        .textContentType(.newPassword).onSubmit(submit)
                    if !input.confirmation.isEmpty, let validation {
                        Text(validation).font(.system(size: 12)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.textFieldStyle(.roundedBorder).padding(.trailing, 4)
            }.frame(maxHeight: 390)
            HStack {
                Button("取消登录") { input = CompanyPasswordChangeInput(); onCancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("修改并继续登录", action: submit).keyboardShortcut(.defaultAction).disabled(validation != nil)
            }
        }.padding(24).frame(width: 510).buttonStyle(VPNButtonStyle()).interactiveDismissDisabled()
            .onAppear { focused = requireUsername ? .username : .oldPassword }
            .onDisappear { input = CompanyPasswordChangeInput() }
    }

    private func submit() {
        guard validation == nil else { return }
        var response: [String: Any] = ["oldPassword": input.oldPassword, "newPassword": input.newPassword]
        if requireUsername { response["newUsername"] = input.newUsername.trimmingCharacters(in: .whitespacesAndNewlines) }
        input = CompanyPasswordChangeInput()
        onSubmit(response)
    }
}
