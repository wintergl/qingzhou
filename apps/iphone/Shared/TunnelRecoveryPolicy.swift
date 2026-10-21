import Foundation

/// Platform lifecycle only. Configuration and node selection remain in Rust.
/// Called on the provider's serial control queue; time is injected for tests.
struct TunnelRecoveryPolicy {
    private(set) var wanted = false
    private(set) var sleeping = false
    private(set) var networkAvailable = true
    private(set) var inFlight = false
    private(set) var pending = false
    private(set) var generation = 0
    private(set) var attempts = 0
    private(set) var retryAt: TimeInterval?
    private(set) var connectedAt: TimeInterval?
    private(set) var heartbeatAt: TimeInterval?
    private var networkIdentity: String?
    private var attemptedNetworkIdentity: String?
    private var inFlightNetworkIdentity: String?
    var lowPower = false

    var watchdogInterval: TimeInterval { lowPower ? 120 : 30 }
    var heartbeatTimeout: TimeInterval { lowPower ? 240 : 90 }
    var canRecover: Bool { wanted && !sleeping && networkAvailable && !inFlight && pending }

    mutating func start(now: TimeInterval) {
        let nextGeneration = generation + 1
        self = TunnelRecoveryPolicy()
        wanted = true
        generation = nextGeneration
        connectedAt = now
        heartbeatAt = now
    }

    mutating func stop() {
        wanted = false
        generation += 1
        pending = false
        inFlight = false
        retryAt = nil
    }

    mutating func heartbeat(now: TimeInterval) {
        guard wanted, !sleeping, !inFlight, !pending else { return }
        heartbeatAt = now
        if let connectedAt, now - connectedAt >= 120 {
            attempts = 0
        }
    }

    func heartbeatExpired(now: TimeInterval) -> Bool {
        guard wanted, !sleeping, networkAvailable, !inFlight, !pending,
              let heartbeatAt else { return false }
        return now - heartbeatAt >= heartbeatTimeout
    }

    mutating func request(now: TimeInterval, networkChange: Bool = false) {
        guard wanted else { return }
        pending = true
        connectedAt = nil
        // Repeated errors on the same path retain the existing failure backoff.
        let delay = networkChange && attempts == 0 ? 0.5 : Self.retryDelay(attempts, lowPower: lowPower)
        retryAt = max(retryAt ?? 0, now + delay)
    }

    mutating func setNetwork(available: Bool, changed: Bool, identity: String? = nil, now: TimeInterval) {
        let duplicate = identity != nil && available == networkAvailable && identity == networkIdentity
        networkAvailable = available
        networkIdentity = identity
        guard wanted, changed else { return }
        // Keep the original deadline/backoff and do not queue another restart
        // behind an in-flight attempt for the same upstream state.
        if duplicate && (pending || inFlight) { return }
        requestNetworkRecovery(now: now)
    }

    private mutating func requestNetworkRecovery(now: TimeInterval) {
        guard wanted else { return }
        if networkAvailable, let networkIdentity, networkIdentity != attemptedNetworkIdentity {
            // The new Wi-Fi gets one prompt attempt instead of inheriting a
            // cellular path's 60/120-second retry. Identity stays in memory.
            pending = true
            connectedAt = nil
            retryAt = now + 0.5
        } else {
            request(now: now, networkChange: true)
        }
    }

    mutating func sleep() { sleeping = true }

    @discardableResult
    mutating func wake(now: TimeInterval) -> Bool {
        guard wanted else { return false }
        let wasSleeping = sleeping
        sleeping = false
        heartbeatAt = now
        if !wasSleeping && (pending || inFlight) { return false }
        requestNetworkRecovery(now: now)
        return true
    }

    mutating func begin(now: TimeInterval) -> Int? {
        guard canRecover, now >= (retryAt ?? now) else { return nil }
        pending = false
        inFlight = true
        inFlightNetworkIdentity = networkIdentity
        attemptedNetworkIdentity = networkIdentity
        retryAt = nil
        generation += 1
        attempts += 1
        return generation
    }

    @discardableResult
    mutating func finish(token: Int, success: Bool, now: TimeInterval) -> Bool {
        guard wanted, inFlight, token == generation else { return false }
        inFlight = false
        if success {
            connectedAt = now
            heartbeatAt = now
            if !pending { attemptedNetworkIdentity = nil }
        } else {
            // Failure from the old path cannot postpone an already queued handover.
            let changedPath = pending && networkAvailable && networkIdentity != nil
                && networkIdentity != inFlightNetworkIdentity
            if !changedPath { request(now: now) }
        }
        inFlightNetworkIdentity = nil
        return true
    }

    static func retryDelay(_ attempts: Int, lowPower: Bool) -> TimeInterval {
        let delays: [TimeInterval] = [2, 5, 10, 20, 30, 60]
        if lowPower && attempts >= delays.count { return 120 }
        return delays[min(max(0, attempts), delays.count - 1)]
    }
}

/// Completes a system callback exactly once, including when a native call hangs.
final class TunnelCompletion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Value) -> Void)?

    init(_ callback: @escaping (Value) -> Void) { self.callback = callback }

    func finish(_ value: Value) {
        lock.lock()
        let callback = self.callback
        self.callback = nil
        lock.unlock()
        callback?(value)
    }
}
