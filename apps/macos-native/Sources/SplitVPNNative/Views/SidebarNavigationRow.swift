import SwiftUI

struct SidebarNavigationRow: View {
    let page: VPNPage
    let selected: Bool
    let count: String?
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: page.icon).font(.system(size: 15, weight: .medium)).frame(width: 21)
                Text(page.rawValue).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 4)
                if let count {
                    Text(count).font(.system(size: 10, weight: .medium)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(selected ? VPNTheme.accent.opacity(0.08) : .clear, in: Capsule())
                        .foregroundStyle(selected ? VPNTheme.accent : VPNTheme.secondary)
                }
            }.padding(.horizontal, 13).frame(height: 40)
                .foregroundStyle(selected ? VPNTheme.accent : VPNTheme.text)
                .background(selected ? VPNTheme.selection : hovered ? VPNTheme.secondary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selected)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
