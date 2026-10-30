import Foundation
import Network

/// The Go socket binds to the physical interface, never the app's own utun.
final class CompanyUnderlay: @unchecked Sendable {
    private let monitor = Network.NWPathMonitor(prohibitedInterfaceTypes: [.other, .loopback])
    private let lock = NSLock()
    private var name = ""
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let physical = path.availableInterfaces.first { path.usesInterfaceType($0.type) && $0.type != .other && $0.type != .loopback }
            self.lock.lock(); self.name = path.status == .satisfied ? physical?.name ?? "" : ""; self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "split-vpn.company.underlay", qos: .utility))
    }
    var interfaceName: String { lock.lock(); defer { lock.unlock() }; return name }
    deinit { monitor.cancel() }
}
