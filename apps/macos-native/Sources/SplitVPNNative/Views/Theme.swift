import AppKit
import SwiftUI

enum VPNTheme {
    static let background = adaptive(light: 0xF4F6F6, dark: 0x141B20)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x1D272D)
    static let text = adaptive(light: 0x203238, dark: 0xE7F0F1)
    static let secondary = adaptive(light: 0x526970, dark: 0xA2B5BA)
    static let border = adaptive(light: 0xDDE6E7, dark: 0x34464D)
    static let selection = adaptive(light: 0xE0EFED, dark: 0x243F41)
    static let accent = adaptive(light: 0x126E6A, dark: 0x7ED9CD)
    static let buttonAccent = adaptive(light: 0x126E6A, dark: 0x227F78)
    static let destructive = adaptive(light: 0xAC4148, dark: 0xF29AA0)
    static let destructiveFill = adaptive(light: 0xAC4148, dark: 0xA74148)
    static let green = adaptive(light: 0x24785C, dark: 0x87D9AE)
    static let warning = adaptive(light: 0xA65B12, dark: 0xF0B36D)
    static let hero = adaptive(light: 0xEAF3F1, dark: 0x203739)
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
            .padding(.horizontal, 14).frame(minHeight: 34)
            .foregroundStyle(prominent ? Color.white : destructive ? VPNTheme.destructive : VPNTheme.text)
            .background(prominent ? color : hovered && enabled ? VPNTheme.selection : VPNTheme.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(prominent ? Color.clear : contrast == .increased ? VPNTheme.secondary : VPNTheme.border, lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(prominent && hovered && enabled ? 0.09 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 9))
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
