import AppKit
import SwiftUI

struct ChallengeSheet: View {
    let challenge: AuthChallenge
    let onSubmit: ([String: Any]) -> Void
    let onCancel: () -> Void
    @State private var code = ""
    @State private var points: [ChallengePoint] = []

    private var image: NSImage? {
        guard let encoded = challenge.imageBase64, let data = Data(base64Encoded: encoded) else { return nil }
        return NSImage(data: data)
    }
    private var pixelSize: CGSize {
        guard let image else { return .zero }
        if let representation = image.representations.first {
            return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }
        return image.size
    }
    private var displayedSize: CGSize {
        let size = pixelSize
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(1, min(460 / size.width, 330 / size.height))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
    private var canSubmit: Bool {
        challenge.kind == "click" ? !points.isEmpty : !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(challenge.title).font(.title2.weight(.semibold))
            Text(challenge.message).foregroundStyle(.secondary)
            if let image {
                if challenge.kind == "click" {
                    captchaImage(image)
                    HStack {
                        Text("已点选 \(points.count) 个位置").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("撤销") { if !points.isEmpty { points.removeLast() } }.disabled(points.isEmpty)
                        Button("清空") { points.removeAll() }.disabled(points.isEmpty)
                    }
                } else {
                    Image(nsImage: image).resizable().frame(width: displayedSize.width, height: displayedSize.height)
                }
            } else if challenge.kind == "click" || challenge.kind == "text" {
                Text("验证码图片无法显示，请取消后重试。")
                    .foregroundStyle(VPNTheme.warning)
            }
            if challenge.kind == "external" {
                if let raw = challenge.url, let url = URL(string: raw), ["https", "http"].contains(url.scheme ?? "") {
                    Link("打开私有网络认证页面", destination: url)
                }
                TextField("粘贴完成认证后的回调地址", text: $code).textFieldStyle(.roundedBorder)
            } else if challenge.kind != "click" {
                TextField("输入验证码", text: $code).textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
            }
            HStack {
                Button("取消测试", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("提交", action: submit).buttonStyle(VPNButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction).disabled(!canSubmit)
            }
        }
        .padding(24).frame(width: 510).buttonStyle(VPNButtonStyle())
        .interactiveDismissDisabled()
    }

    private func captchaImage(_ image: NSImage) -> some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: image).resizable().frame(width: displayedSize.width, height: displayedSize.height)
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                Text("\(index + 1)").font(.caption.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 23, height: 23).background(.blue, in: Circle())
                    .position(x: CGFloat(point.x) * displayedSize.width / pixelSize.width,
                              y: CGFloat(point.y) * displayedSize.height / pixelSize.height)
            }
        }
        .frame(width: displayedSize.width, height: displayedSize.height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onEnded { gesture in
            guard displayedSize.width > 0, displayedSize.height > 0 else { return }
            let x = Int((gesture.location.x / displayedSize.width * pixelSize.width).rounded())
            let y = Int((gesture.location.y / displayedSize.height * pixelSize.height).rounded())
            points.append(ChallengePoint(x: min(max(x, 0), Int(pixelSize.width) - 1), y: min(max(y, 0), Int(pixelSize.height) - 1)))
        })
        .accessibilityLabel("按提示依次点选验证码图片")
    }

    private func submit() {
        guard canSubmit else { return }
        if challenge.kind == "click" {
            onSubmit(["points": points.map { ["x": $0.x, "y": $0.y] }, "width": Int(pixelSize.width), "height": Int(pixelSize.height)])
        } else {
            onSubmit([challenge.kind == "external" ? "callbackURL" : "code": code.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        code = ""
        points = []
    }
}
