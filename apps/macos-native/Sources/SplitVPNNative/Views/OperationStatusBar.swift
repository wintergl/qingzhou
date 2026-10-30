import SwiftUI

/// Keep a constant layout slot across idle, working and completion states.
/// Inserting/removing this bar changes the table viewport and can cross the
/// node page's compact-layout breakpoint while it is already scrolled.
struct OperationStatusBar: View {
    @ObservedObject var store: VPNStore
    private var dismissible: Bool { store.busy == nil && store.message != nil }
    var body: some View {
        HStack(spacing: 10) {
            Group {
                if store.busy != nil { ProgressView().controlSize(.small) }
                else { Image(systemName: store.message == nil ? "network" : "checkmark.circle") }
            }.frame(width: 18, height: 18)
            Text(store.busy ?? store.message ?? store.menuTitle)
                .font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { store.message = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).frame(width: 24, height: 24)
                .opacity(dismissible ? 1 : 0).disabled(!dismissible)
                .accessibilityLabel("关闭完成提示").accessibilityHidden(!dismissible)
        }
        .foregroundStyle(VPNTheme.secondary).padding(.horizontal, 24)
        .frame(height: 34).background(VPNTheme.surface.opacity(0.75))
        .overlay(alignment: .top) { Rectangle().fill(VPNTheme.border).frame(height: 1) }
    }
}
