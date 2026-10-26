import SwiftUI

/// The core retains a rolling tail, so new records can arrive without changing
/// the number of lines. Observe the content, rather than just its count.
struct LogOutputView: View {
    let lines: [String]
    let following: Bool
    private enum Anchor: Hashable { case bottom }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 13, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(20)
                    Color.clear.frame(height: 1).id(Anchor.bottom).accessibilityHidden(true)
                }
            }
            .defaultScrollAnchor(following ? .bottom : nil)
            .onChange(of: lines, initial: true) { _, _ in
                if following { scrollToLatest(proxy) }
            }
            .onChange(of: following) { _, enabled in
                if enabled { scrollToLatest(proxy) }
            }
        }
    }
    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo(Anchor.bottom, anchor: .bottom) }
    }
}
