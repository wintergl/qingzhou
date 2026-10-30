import Combine

/// High-frequency traffic changes only invalidate views that display traffic.
@MainActor
final class TrafficStore: ObservableObject {
    @Published var value: TrafficMonitor?
}
