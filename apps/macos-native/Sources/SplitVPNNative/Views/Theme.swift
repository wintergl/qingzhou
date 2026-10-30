import AppKit
import SwiftUI

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
    static let hero = adaptive(light: 0xEAF3F1, dark: 0x203739)
    static let heroInk = Color(red: 0.08, green: 0.22, blue: 0.18)
    static let heroText = Color(red: 0.94, green: 0.97, blue: 0.91)
    static let heroMuted = Color(red: 0.67, green: 0.80, blue: 0.73)
    static let chartBlue = adaptive(light: 0x6388B3, dark: 0x91B2DB)

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
    func makeBody(configuration: Configuration) -> some View {
        VPNButtonSurface(label: configuration.label, prominent: prominent,
                         destructive: destructive || configuration.role == .destructive, pressed: configuration.isPressed)
    }
}

private struct VPNButtonSurface<Label: View>: View {
    let label: Label
    let prominent: Bool
    let destructive: Bool
    let pressed: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovered = false
    private var color: Color { destructive ? VPNTheme.destructiveFill : VPNTheme.buttonAccent }
    var body: some View {
        label.font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 15).frame(minHeight: 36)
            .foregroundStyle(prominent ? Color.white : destructive ? VPNTheme.destructive : VPNTheme.text)
            .background(prominent ? color : hovered && enabled ? VPNTheme.selection : VPNTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(prominent ? color.opacity(0.25) : contrast == .increased ? VPNTheme.secondary : VPNTheme.border, lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(prominent && hovered && enabled ? 0.09 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: prominent && enabled ? color.opacity(0.14) : .clear, radius: 5, y: 2)
            .opacity(enabled ? (pressed ? 0.76 : 1) : 0.45)
            .scaleEffect(pressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: pressed)
            .onHover { hovered = $0 }
    }
}

struct StatusPill: View {
    let title: String
    var passed = false
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: passed ? "checkmark.circle.fill" : "circle.dotted").font(.system(size: 11, weight: .medium))
            Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }.foregroundStyle(passed ? VPNTheme.green : VPNTheme.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background((passed ? VPNTheme.green : VPNTheme.secondary).opacity(0.08), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

struct CardHeading: View {
    let title: String
    let icon: String
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(VPNTheme.accent)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(VPNTheme.text)
        }
    }
}

extension View {
    func tableCard() -> some View {
        self.alternatingRowBackgrounds(.disabled).background(VPNTheme.surface).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(VPNTheme.border, lineWidth: 1))
    }
}
