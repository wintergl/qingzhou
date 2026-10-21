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
    static let background = adaptive(light: 0xF5F7FB, dark: 0x151923)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x202633)
    static let text = adaptive(light: 0x202B40, dark: 0xEBEFF7)
    static let secondary = adaptive(light: 0x69768C, dark: 0xA1AEC2)
    static let border = adaptive(light: 0xE1E7F0, dark: 0x343E50)
    static let selection = adaptive(light: 0xEAF0FA, dark: 0x2D3A52)
    static let accent = adaptive(light: 0x355DAD, dark: 0x8FAEF2)
    static let buttonAccent = adaptive(light: 0x355DAD, dark: 0x456CC0)
    static let destructive = adaptive(light: 0xB7383E, dark: 0xF08F95)
    static let destructiveFill = adaptive(light: 0xB7383E, dark: 0xB84148)
    static let green = adaptive(light: 0x208463, dark: 0x7AD5B2)
    static let warning = adaptive(light: 0xB7791F, dark: 0xF2C46D)

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
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 17)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                if !prominent {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(VPNTheme.border, lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
    }

    private var foreground: Color {
        if prominent {
            return .white
        }
        return destructive ? VPNTheme.destructive : VPNTheme.accent
    }

    private var fill: Color {
        if prominent {
            return destructive ? VPNTheme.destructiveFill : VPNTheme.buttonAccent
        }
        return VPNTheme.surface
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VPNTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
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
