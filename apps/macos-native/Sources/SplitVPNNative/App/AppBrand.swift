import AppKit
import Foundation

enum AppBrand {
    static let name = "轻舟"

    @MainActor static let icon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "qingzhou-icon", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
}
