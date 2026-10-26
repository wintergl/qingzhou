import SwiftUI

struct CompanyView: View {
    @ObservedObject var store: CompanyStore
    @ObservedObject var vpn: VPNStore
    @Environment(\.openURL) private var openURL
    @FocusState private var passwordFocused: Bool
    var initializeOnAppear = true
    @State private var showingDetails = false
    @State private var showingVerification = false
    private let steps = [("probe", "入口证书"), ("login", "账号认证"), ("resources", "授权资源"),
                         ("tunnel", "私有网络隧道"), ("routing", "资源接管")]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                PageHeader(title: "私有网络", subtitle: "登录、连接与资源接管，可以分别控制")
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    StatusPill(title: store.statusText, passed: store.connectionReady)
                    Button("证书与连接详情") { showingDetails = true }.buttonStyle(.plain).foregroundStyle(VPNTheme.accent).font(.caption)
                }
            }
            HStack(spacing: 12) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    let phase = store.phases[step.0] ?? .pending
                    let needsPasswordChange = step.0 == "login" && (store.loginIssue == .passwordChangeRequired || store.challenge?.kind == "password_change")
                    HStack(spacing: 6) {
                        Image(systemName: needsPasswordChange ? "exclamationmark.circle.fill" : phase == .passed ? "checkmark.circle.fill" : phase == .failed ? "xmark.circle.fill" : "\(index + 1).circle")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.1).fontWeight(.medium)
                            Text(needsPasswordChange ? "需修改密码" : step.0 == "routing" && !store.takeoverEnabled ? "未接管" : phase.rawValue).font(.system(size: 11))
                        }
                    }.font(.system(size: 12)).foregroundStyle(needsPasswordChange ? VPNTheme.warning : phaseColor(phase)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(.vertical, 4)
            if let issue = store.loginIssue { passwordChangeGuidance(issue) }
            HStack(alignment: .top, spacing: 16) {
                accountCard.frame(width: 280)
                VStack(alignment: .leading, spacing: 14) {
                    businessCard
                    resourceCard
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.frame(maxHeight: .infinity, alignment: .topLeading)
            if let message = store.errorMessage, store.errorStage != "business", store.loginIssue == nil {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle")
                    Text("\(store.errorHeading)：\(message)").lineLimit(1).help(message)
                    Spacer(minLength: 0)
                    Button("详情") { showingDetails = true }
                }.font(.system(size: 13)).foregroundStyle(VPNTheme.destructive)
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { if initializeOnAppear { store.startOnce() }; handleRequestedInteraction() }
        .onChange(of: store.requestedInteraction) { _, _ in handleRequestedInteraction() }
        .disabled(store.terminating)
        .sheet(item: $store.challenge) { challenge in
            if challenge.kind == "password_change" {
                CompanyPasswordChangeSheet(challenge: challenge, onSubmit: store.answerChallenge, onCancel: store.endTest)
            } else {
                ChallengeSheet(challenge: challenge, onSubmit: store.answerChallenge, onCancel: store.endTest)
            }
        }
        .sheet(isPresented: $showingDetails) { detailsSheet }
        .sheet(isPresented: $showingVerification) { CompanyVerificationSheet(store: store) }
    }
    private var accountCard: some View {
        ScrollView { accountFields }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).detailCard(padding: 18)
    }
    private var accountFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeading(title: "接入账号", icon: "person.crop.circle")
            TextField("HTTPS 接入网关", text: $store.origin).textFieldStyle(.roundedBorder)
                .disabled(store.working || store.hasSession)
            Button("重新检测入口") { store.detectEntry() }.disabled(store.working || store.hasSession)
            if store.probe != nil {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: store.certificateState.approved ? "checkmark.shield.fill" : "exclamationmark.shield")
                        .foregroundStyle(store.certificateState.approved ? VPNTheme.green : VPNTheme.warning)
                    Text(store.certificateState.title).font(.system(size: 11)).lineLimit(2)
                    Spacer(minLength: 0)
                    if store.certificateState.requiresUserConfirmation {
                        Button("查看") { showingDetails = true }.buttonStyle(.plain).foregroundStyle(VPNTheme.accent).font(.system(size: 11))
                    }
                }
                Picker("认证方式", selection: $store.selectedDomain) {
                    ForEach(store.passwordMethods, id: \.loginDomain) { Text($0.authName).tag($0.loginDomain) }
                }.font(.system(size: 13)).disabled(store.working || store.hasSession)
            }
            if store.hasSession {
                StatusLabel(title: "账号认证已通过", passed: true)
                Text(store.authenticatedUsername ?? store.username).font(.system(size: 18, weight: .semibold)).lineLimit(1).textSelection(.enabled)
                Button("刷新授权资源") { store.refreshResources() }.disabled(store.working || store.tunnelProof != nil)
                Button("退出接入账号") { store.endTest() }.disabled(store.working)
            } else {
                TextField("接入账号", text: $store.username).textFieldStyle(.roundedBorder).disabled(store.working)
                SecureField("接入密码", text: $store.password).textFieldStyle(.roundedBorder).disabled(store.working).focused($passwordFocused)
            }
            Toggle("记住账号和密码", isOn: Binding(get: { store.rememberCredentials }, set: store.setRememberCredentials))
                .toggleStyle(.checkbox).font(.system(size: 13)).disabled(store.working)
            HStack {
                Text("保存在 macOS 钥匙串").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if store.hasSavedCredentials {
                    Button("忘记") { store.forgetCredentials() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(VPNTheme.accent).disabled(store.working)
                }
            }
            if let message = store.credentialMessage { Text(message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).help(message) }
            if !store.hasSession {
                Button { store.login(core: vpn.core) } label: { Label("登录并获取授权", systemImage: "arrow.right.circle") }
                    .buttonStyle(VPNButtonStyle(prominent: true)).disabled(!store.canLogin)
                if store.working || store.quickConnectionID != nil { Button("取消本次连接") { store.endTest() } }
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private func passwordChangeGuidance(_ issue: CompanyLoginIssue) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label(issue.title, systemImage: "key.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(VPNTheme.warning)
                Text(issue.message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(minWidth: 300, maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 8) {
                if let url = store.passwordChangeEntryURL {
                    Button("打开接入网关") { openURL(url) }
                }
                Button("已改好，输入新密码") {
                    store.prepareAfterPasswordChange()
                    passwordFocused = true
                }
            }.fixedSize()
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).background(VPNTheme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
    private var businessCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardHeading(title: "私有网络连接", icon: "arrow.triangle.branch")
                Spacer(minLength: 6)
                Toggle("接管授权资源", isOn: Binding(get: { store.takeoverEnabled }, set: store.setTakeover))
                    .toggleStyle(.checkbox).font(.system(size: 13)).disabled(store.working)
            }
            Text(store.takeoverEnabled ? "授权资源走私有网络隧道，外网沿用现有 VPN。" : "仅连接和验证私有网络隧道，其他应用的流量不接管。")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 8) {
                Toggle("私有网络", isOn: Binding(get: { store.connectionEnabled }, set: { enabled in
                    if enabled { store.connectTunnel() } else { store.disconnectTunnel() }
                })).toggleStyle(.switch).disabled(!store.hasSession || store.resources == nil || store.working)
                Spacer(minLength: 0)
                Button("验证") { showingVerification = true }.disabled(store.tunnelProof == nil || store.working)
            }
            HStack(spacing: 12) {
                Text(store.tunnelProof != nil ? "可按需验证内网地址。" : "登录后打开开关，连接私有网络。").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if store.routingState?.recovering == true { ProgressView().controlSize(.small) }
            }.font(.system(size: 12))
            HStack(spacing: 12) {
                Button("检查 GPT 网络") { store.verifyInternet() }.disabled(store.working).font(.system(size: 12))
                if let internet = store.routingState?.internet {
                    Text(internet.result.ok ? "可达 · \(internet.result.elapsedMs) ms" : "未连通")
                        .font(.system(size: 12)).foregroundStyle(internet.result.ok ? VPNTheme.green : VPNTheme.warning)
                        .help(internet.result.error ?? dateText(internet.checkedAt))
                } else { Text("外网结果单独检测").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).detailCard(padding: 18)
    }
    private var resourceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardHeading(title: "授权资源", icon: "square.grid.2x2")
                Spacer()
                if let result = store.resources { Text("\(result.appCount) 个应用 · \(result.rows.count) 条规则").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            if let result = store.resources {
                TextField("搜索应用、地址或端口", text: $store.searchText).textFieldStyle(.roundedBorder)
                Table(store.filteredRows) {
                    TableColumn("应用") { Text($0.name).lineLimit(1).padding(.vertical, 7) }.width(min: 70, ideal: 100)
                    TableColumn("授权地址", value: \.address).width(min: 120, ideal: 170)
                    TableColumn("协议", value: \.network).width(45)
                    TableColumn("端口", value: \.ports).width(min: 50, ideal: 70)
                }.tableCard()
                Text("接入网关下发 · \(dateText(result.fetchedAt))").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            } else if store.loginIssue == .passwordChangeRequired {
                Text("修改密码并重新登录后，授权资源会显示在这里。")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "building.2").font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                    Text("登录后显示授权资源").font(.system(size: 18, weight: .semibold))
                    Text("应用、网段、域名与允许端口会显示在此。 ").font(.system(size: 14)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.top, 8)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).detailCard(padding: 18)
    }
    private var detailsSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("证书与连接详情").font(.title2.weight(.semibold)); Spacer(); Button("完成") { showingDetails = false } }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let probe = store.probe {
                        Text(probe.subject).font(.headline)
                        Text("有效期至 \(dateText(probe.validTo))")
                        Text("SHA-256\n\(probe.fingerprint)").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        Text(store.certificateState.title).foregroundStyle(store.certificateState.approved ? VPNTheme.green : VPNTheme.warning)
                        if store.certificateState.requiresUserConfirmation {
                            Text(store.certificateState == .changed ? "证书与之前确认的网关不同。确认网关管理员已更换证书后，再更新网关记录。" : "该证书尚未被系统信任。首次确认属于目标网关后，只为这个网关记住指纹；之后自动核验。")
                                .font(.system(size: 13))
                            if store.certificateState == .changed, let previous = store.previousCertificateFingerprint {
                                Text("之前的 SHA-256\n\(previous)").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            }
                            Button(store.certificateState == .changed ? "确认网关更换证书并更新" : "信任此接入网关并记住") {
                                store.confirmGatewayCertificate()
                                if store.certificateState.approved { showingDetails = false }
                            }.disabled(store.working || store.hasSession)
                        }
                    } else { Text("检测入口后可查看网关证书。") }
                    if let message = store.errorMessage { Text("\(store.errorHeading)：\(message)").foregroundStyle(VPNTheme.destructive).textSelection(.enabled) }
                    Divider()
                    ForEach(store.timeline) { item in
                        Text("\(item.time.formatted(date: .omitted, time: .standard))  \(item.message)").font(.system(size: 13)).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("复制诊断信息") { store.copyDiagnostics() }
        }.padding(24).frame(width: 620, height: 500).buttonStyle(VPNButtonStyle())
    }
    private func phaseColor(_ phase: TestPhase) -> Color {
        switch phase { case .passed: return VPNTheme.green; case .failed: return VPNTheme.destructive; case .running: return VPNTheme.accent; case .pending: return VPNTheme.secondary }
    }
    private func handleRequestedInteraction() {
        guard let interaction = store.requestedInteraction else { return }
        if interaction == .certificate { showingDetails = true }
        if interaction == .challenge { showingDetails = false }
        store.requestedInteraction = nil
    }
}
