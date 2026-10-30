import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum AppBrand {
    static let name = "轻舟"
}

/// iOS 版轻舟配色，与 macOS 版 `VPNTheme` 保持一致。
enum VPNTheme {
    static let background = adaptive(light: 0xF5F5F2, dark: 0x121B1D)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x1B272A)
    static let text = adaptive(light: 0x203632, dark: 0xE9F1ED)
    static let secondary = adaptive(light: 0x61736F, dark: 0xA5B8B2)
    static let border = adaptive(light: 0xE1E7E2, dark: 0x324440)
    static let selection = adaptive(light: 0xE1ECE5, dark: 0x29443C)
    static let accent = adaptive(light: 0x216650, dark: 0x97DABB)
    static let buttonAccent = adaptive(light: 0x216650, dark: 0x276D53)
    static let destructive = adaptive(light: 0xAC4148, dark: 0xF29AA0)
    static let destructiveFill = adaptive(light: 0xAC4148, dark: 0xA74148)
    static let green = adaptive(light: 0x24785C, dark: 0x87D9AE)
    static let warning = adaptive(light: 0xA65B12, dark: 0xF0B36D)

    static let heroInk = Color(red: 0.08, green: 0.22, blue: 0.18)
    static let heroText = Color(red: 0.94, green: 0.97, blue: 0.91)
    static let heroMuted = Color(red: 0.67, green: 0.80, blue: 0.73)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        #if canImport(UIKit)
        Color(UIColor { traits in
            uiColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
        #else
        Color(NSColor(name: nil) { appearance in
            nsColor(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
        #endif
    }

    #if canImport(UIKit)
    private static func uiColor(_ hex: UInt32) -> UIColor {
        UIColor(red: channel(hex, 16), green: channel(hex, 8), blue: channel(hex, 0), alpha: 1)
    }
    #else
    private static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: channel(hex, 16), green: channel(hex, 8), blue: channel(hex, 0), alpha: 1)
    }
    #endif

    private static func channel(_ hex: UInt32, _ shift: UInt32) -> CGFloat {
        CGFloat((hex >> shift) & 0xFF) / 255
    }
}

struct VPNButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        MobileButtonSurface(label: configuration.label, prominent: prominent,
                            destructive: destructive || configuration.role == .destructive, pressed: configuration.isPressed)
    }
}

private struct MobileButtonSurface<Label: View>: View {
    let label: Label
    let prominent: Bool
    let destructive: Bool
    let pressed: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var fill: Color { prominent ? (destructive ? VPNTheme.destructiveFill : VPNTheme.buttonAccent) : VPNTheme.surface }
    var body: some View {
        label.font(.body.weight(.semibold))
            .foregroundStyle(prominent ? Color.white : destructive ? VPNTheme.destructive : VPNTheme.accent)
            .padding(.horizontal, 17).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(fill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(prominent ? .clear : VPNTheme.border))
            .opacity(enabled ? (pressed ? 0.8 : 1) : 0.45)
            .scaleEffect(pressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
    }
}

func subscriptionStatusTitle(_ status: String) -> String {
    switch status {
    case "ready": return "可用"
    case "error": return "更新失败"
    case "updating": return "更新中"
    case "saved": return "待更新"
    default: return "未配置"
    }
}

struct StatusPill: View {
    let title: String
    let color: Color

    init(title: String, passed: Bool) {
        self.title = title
        self.color = passed ? VPNTheme.green : VPNTheme.secondary
    }

    init(title: String, color: Color) {
        self.title = title
        self.color = color
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.09), in: Capsule())
    }
}

struct CardHeading: View {
    let title: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(VPNTheme.accent)
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(VPNTheme.text)
        }
    }
}

struct VPNCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VPNTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(VPNTheme.border, lineWidth: 1)
        )
    }
}

extension View {
    /// 让 List / Form 使用轻舟背景色，而不是系统分组灰。
    func vpnListStyle() -> some View {
        scrollContentBackground(.hidden)
            .background(VPNTheme.background)
    }
}
