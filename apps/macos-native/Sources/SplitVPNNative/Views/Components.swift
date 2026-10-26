import SwiftUI

struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 28, weight: .semibold)).foregroundStyle(VPNTheme.text)
            Text(subtitle).foregroundStyle(VPNTheme.secondary).font(.system(size: 13)).lineSpacing(3)
        }
    }
}
struct StatusLabel: View {
    let title: String
    var passed = false
    var body: some View {
        Label(title, systemImage: passed ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(passed ? VPNTheme.green : VPNTheme.secondary).font(.system(size: 13))
    }
}
struct Metric: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).foregroundStyle(VPNTheme.secondary).font(.system(size: 13))
            Text(value).font(.system(size: 23, weight: .semibold)).foregroundStyle(VPNTheme.text).monospacedDigit().lineLimit(2).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
func byteText(_ count: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(max(0, count)), countStyle: .binary) }
func dateText(_ value: String?) -> String {
    guard let value else { return "尚无记录" }
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    return date?.formatted(date: .abbreviated, time: .shortened) ?? value
}
extension View {
    func detailCard(padding: CGFloat = 24) -> some View {
        self.padding(padding).background(VPNTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(VPNTheme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.018), radius: 8, x: 0, y: 3)
    }
}
