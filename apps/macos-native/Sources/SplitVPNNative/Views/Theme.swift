import AppKit
import SwiftUI

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

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }
}

struct VPNButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let isDestructive = destructive || configuration.role == .destructive
        let color = isDestructive ? VPNTheme.destructiveFill : VPNTheme.buttonAccent
        let foreground = prominent ? Color.white : isDestructive ? VPNTheme.destructive : VPNTheme.text
        return configuration.label
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 17).frame(minHeight: 44)
            .foregroundStyle(foreground)
            .background(prominent ? color : VPNTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(prominent ? Color.clear : VPNTheme.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.48)
    }
}

struct StatusPill: View {
    let title: String
    var passed = false
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(passed ? VPNTheme.green : VPNTheme.secondary).frame(width: 7, height: 7)
            Text(title).font(.system(size: 14, weight: .semibold))
        }.foregroundStyle(passed ? VPNTheme.green : VPNTheme.secondary)
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background((passed ? VPNTheme.green : VPNTheme.secondary).opacity(0.09), in: Capsule())
    }
}

struct CardHeading: View {
    let title: String
    let icon: String
    var body: some View {
        Label(title, systemImage: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(VPNTheme.text)
    }
}

extension View {
    func tableCard() -> some View {
        self.background(VPNTheme.surface).clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(VPNTheme.border, lineWidth: 1))
    }
}
