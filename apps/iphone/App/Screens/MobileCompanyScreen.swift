import SwiftUI
#if canImport(UIKit)
import UIKit
import ImageIO
#endif

struct MobileCompanyScreen: View {
    @ObservedObject var company: MobileCompanyStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var origin = ""
    @State private var username = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var remember = false
    @State private var target = ""
    @State private var takeover = true
    private var methods: [[String: Any]] { company.probe["methods"] as? [[String: Any]] ?? [] }
    var body: some View {
        Form {
            Section("aTrust 接入") {
                TextField("HTTPS 接入地址", text: $origin).mobileAddressInput().disabled(company.active || company.busy)
                    .onChange(of: origin) { _ in company.certificateConfirmed = false }
                Button("检测入口与证书") { Task { await company.detect(origin: origin) } }.disabled(company.active || company.busy)
                if let fingerprint = company.probe["fingerprint"] as? String {
                    Text(fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    LabeledContent("证书名称", value: company.probe["subject"] as? String ?? "—")
                    LabeledContent("有效期至", value: company.probe["validTo"] as? String ?? "—")
                    Toggle("已核对并确认当前证书指纹", isOn: $company.certificateConfirmed)
                }
            }
            Section("认证账号") {
                TextField("接入账号", text: $username).mobileAddressInput()
                SecureField("接入密码；留空使用已记住的密码", text: $password)
                Picker("认证方式", selection: $domain) { ForEach(Array(methods.enumerated()), id: \.offset) { _, method in Text(method["authName"] as? String ?? "密码认证").tag(method["loginDomain"] as? String ?? "") } }
                Toggle("在设备钥匙串记住密码", isOn: $remember)
                if company.metadata["passwordChangeUncertain"] as? Bool == true { Text("上次改密结果尚未确认，请手动输入当前密码；不会自动读取旧密码。").font(.caption).foregroundStyle(.orange) }
                Button("登录并获取授权资源") { let input = password; password = ""; Task { await company.login(username: username, domain: domain, enteredPassword: input, remember: remember) } }.disabled(company.busy || company.active || !company.certificateConfirmed || domain.isEmpty)
                Button("清除已记住的密码", role: .destructive) { Task { await company.clearCredential(); remember = false } }
            }.disabled(company.active)
            Section("连接") {
                Text(company.message)
                if company.busy { ProgressView() }
                Toggle("接管授权资源", isOn: $takeover)
                Button("连接接入") { Task { await company.connect(takeover: takeover) } }.disabled(company.busy || company.active || (company.metadata["resources"] as? [[String: Any]] ?? []).isEmpty)
                Button("应用资源接管选择") { Task { await company.setTakeover(takeover) } }.disabled(!company.connected || company.busy)
                Button("断开并解除接管", role: .destructive) { Task { await company.disconnect() } }
                Button("取消当前操作") { Task { await company.cancel() } }
                Text("只接管网关授权的 TCP 地址和端口。接入后端未就绪或失效时，已接管资源保持阻断；明确断开后解除接管。").font(.caption).foregroundStyle(.secondary)
            }
            Section("授权资源") {
                Button("刷新资源") { Task { await company.refreshResources() } }.disabled(company.active || company.busy)
                ForEach(Array((company.metadata["resources"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row["name"] as? String ?? "资源")
                        Text("\(row["address"] as? String ?? "") · \(row["network"] as? String ?? "") · \(row["ports"] as? String ?? "")").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("指定业务验证") {
                TextField("HTTP/HTTPS 业务地址", text: $target).mobileAddressInput()
                Button("通过当前接入隧道验证") { Task { await company.verify(target: target) } }.disabled(!company.connected)
                if let result = company.verification { LabeledContent("HTTP", value: String(describing: result["httpStatus"] ?? "—")); LabeledContent("隧道发送／接收", value: "\(result["sent"] ?? "—") / \(result["received"] ?? "—") B") }
            }
        }.navigationTitle("私有网络")
            .task { await company.load(); origin = company.metadata["origin"] as? String ?? ""; username = company.metadata["username"] as? String ?? ""; remember = company.metadata["remember"] as? Bool ?? false }
            .onChange(of: company.probe["fingerprint"] as? String) { _ in domain = methods.first?["loginDomain"] as? String ?? "" }
            .onDisappear { Task { await company.leaveAuthentication() } }
            .task(id: scenePhase) { guard scenePhase == .active else { await company.leaveAuthentication(); return }; while !Task.isCancelled { await company.refresh(); try? await Task.sleep(nanoseconds: 2_000_000_000) } }
            .sheet(item: Binding(get: { company.challenge.map { CompanyChallenge(value: $0) } }, set: { if $0 == nil && company.challenge != nil { Task { await company.cancel() } } })) { CompanyChallengeScreen(company: company, challenge: $0) }
    }
}
private struct CompanyChallenge: Identifiable { let value: [String: Any]; var id: String { value["id"] as? String ?? "" } }
private struct CompanyChallengeScreen: View {
    @ObservedObject var company: MobileCompanyStore
    let challenge: CompanyChallenge
    @State private var code = ""
    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var newUsername = ""
    @State private var callback = ""
    @State private var points: [[String: Int]] = []
    @State private var imageWidth = 0
    @State private var imageHeight = 0
    private var kind: String { challenge.value["kind"] as? String ?? "" }
    var body: some View {
        NavigationStack {
            Form {
                Text(challenge.value["message"] as? String ?? "请完成认证步骤")
                if let problem = challenge.value["errorMessage"] as? String { Text(problem).foregroundStyle(.red) }
                if kind == "password_change" {
                    ForEach(challenge.value["rules"] as? [String] ?? [], id: \.self) { Text($0).font(.caption) }
                    if challenge.value["requireUsername"] as? Bool == true { TextField("新账号名", text: $newUsername).mobileAddressInput() }
                    SecureField("旧密码", text: $oldPassword); SecureField("新密码", text: $newPassword); SecureField("确认新密码", text: $confirmation)
                } else if kind == "external" {
                    if let raw = challenge.value["url"] as? String, let url = URL(string: raw), url.scheme == "https" { Link("打开统一认证页面", destination: url) }
                    TextField("完成后粘贴最终回调地址", text: $callback).mobileAddressInput()
                } else {
                    if let image = challenge.value["imageBase64"] as? String {
                        CompanyCaptcha(base64: image, clickable: kind == "click", points: $points, width: $imageWidth, height: $imageHeight)
                        if kind == "click" { Button("重新点选") { points = [] } }
                    }
                    if kind != "click" { TextField("验证码／动态口令", text: $code).mobileAddressInput() }
                }
                Button("提交") {
                    var response: [String: Any] = ["id": challenge.id]
                    if kind == "password_change" { response["oldPassword"] = oldPassword; response["newPassword"] = newPassword; response["newUsername"] = newUsername }
                    else if kind == "external" { response["callbackURL"] = callback }
                    else if kind == "click" { response["points"] = points; response["width"] = imageWidth; response["height"] = imageHeight }
                    else { response["code"] = code }
                    Task { await company.answer(response) }
                }.disabled(kind == "password_change" && (newPassword.isEmpty || newPassword != confirmation) || kind == "click" && points.isEmpty)
            }.navigationTitle(challenge.value["title"] as? String ?? "接入认证")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { Task { await company.cancel() } } } }
        }.interactiveDismissDisabled()
    }
}
private struct CompanyCaptcha: View {
    let base64: String
    let clickable: Bool
    @Binding var points: [[String: Int]]
    @Binding var width: Int
    @Binding var height: Int
    var body: some View {
        #if canImport(UIKit)
        if let data = Data(base64Encoded: base64), data.count <= 4 * 1024 * 1024,
           let source = CGImageSourceCreateWithData(data as CFData, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0, w * h <= 4_194_304, let image = UIImage(data: data) {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image).resizable().scaledToFit()
                    ForEach(Array(points.enumerated()), id: \.offset) { index, point in Text("\(index + 1)").font(.caption.bold()).padding(5).background(.blue, in: Circle()).foregroundStyle(.white).position(x: CGFloat(point["x"] ?? 0) / CGFloat(w) * geometry.size.width, y: CGFloat(point["y"] ?? 0) / CGFloat(h) * geometry.size.height) }
                }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onEnded { value in
                    guard clickable, points.count < 20 else { return }
                    points.append(["x": max(0, min(w - 1, Int(value.location.x / geometry.size.width * CGFloat(w)))), "y": max(0, min(h - 1, Int(value.location.y / geometry.size.height * CGFloat(h))))])
                })
            }.aspectRatio(CGFloat(w) / CGFloat(h), contentMode: .fit).onAppear { width = w; height = h }
        } else { Text("验证码图片无效或超过支持大小，请重新检测入口") }
        #else
        Text("图片验证码在 iPhone 中显示")
        #endif
    }
}
