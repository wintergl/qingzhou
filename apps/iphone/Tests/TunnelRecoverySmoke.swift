import Foundation

@main
struct TunnelRecoverySmoke {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        var policy = TunnelRecoveryPolicy()
        policy.start(now: 0)
        check(!policy.heartbeatExpired(now: 89), "Allow diagnostic stream startup")
        check(policy.heartbeatExpired(now: 90), "Silent core must be detected without logs")
        policy.heartbeat(now: 80)
        check(!policy.heartbeatExpired(now: 100), "Zero-traffic heartbeat keeps idle VPN healthy")
        policy.request(now: 100)
        check(policy.begin(now: 101) == nil, "Do not restart before backoff")
        let token = policy.begin(now: 102)!
        check(policy.begin(now: 103) == nil, "Only one native operation at a time")
        policy.setNetwork(available: false, changed: true, now: 103)
        check(policy.finish(token: token, success: true, now: 104), "Accept current operation")
        check(!policy.canRecover && policy.pending, "Offline during restart parks pending recovery")
        policy.setNetwork(available: true, changed: true, now: 110)
        check(policy.begin(now: 111) == nil, "Flapping cannot bypass failure backoff")
        let second = policy.begin(now: 115)!
        policy.finish(token: second, success: false, now: 116)
        check(policy.retryAt == 126, "Failure increases backoff")
        policy.sleep()
        check(policy.begin(now: 200) == nil, "Never retry while sleeping")
        check(!policy.heartbeatExpired(now: 900), "Sleep is not a dead core")
        policy.wake(now: 901)
        check(policy.begin(now: 902) == nil, "Wake coalesces with a fresh grace window")
        let third = policy.begin(now: 911)!
        policy.stop()
        check(!policy.finish(token: third, success: true, now: 912), "Late completion cannot undo manual stop")
        check(policy.begin(now: 1000) == nil, "Manual stop cancels retries")
        policy.request(now: 1001)
        check(!policy.pending, "Late errors after stop are ignored")
        policy.start(now: 1002)
        check(!policy.finish(token: third, success: true, now: 1003), "Previous session cannot mutate new session")
        policy.lowPower = true
        check(policy.watchdogInterval == 120 && policy.heartbeatTimeout == 240, "Low power reduces wakeups and extends grace")
        check(!policy.heartbeatExpired(now: 1241), "Low-power stream has sufficient grace")
        check(policy.heartbeatExpired(now: 1242), "Low power still detects stalled core")
        check(TunnelRecoveryPolicy.retryDelay(50, lowPower: true) == 120, "Battery-saving backoff is bounded")
        check(TunnelRecoveryPolicy.retryDelay(50, lowPower: false) == 60, "Normal backoff is bounded")
        policy.request(now: 1300)
        let recovering = policy.begin(now: 1302)!
        policy.finish(token: recovering, success: true, now: 1303)
        policy.heartbeat(now: 1310)
        check(policy.attempts == 1, "Brief recovery must not reset a crash loop")
        policy.heartbeat(now: 1423)
        check(policy.attempts == 0, "Stable recovery resets backoff")
        var completions = 0
        let once = TunnelCompletion<Int> { _ in completions += 1 }
        once.finish(1)
        once.finish(2)
        check(completions == 1, "Timeout and native completion must call OS once")

        for lowPower in [false, true] {
            var switching = TunnelRecoveryPolicy()
            switching.start(now: 0)
            switching.lowPower = lowPower
            switching.setNetwork(available: true, changed: false, identity: "cellular", now: 0)
            var clock: TimeInterval = 0
            for _ in 0..<8 {
                switching.request(now: clock)
                clock = switching.retryAt!
                let attempt = switching.begin(now: clock)!
                switching.finish(token: attempt, success: false, now: clock)
            }
            check(switching.retryAt! - clock >= 60, "Exercise long failure backoff before handover")
            switching.setNetwork(available: false, changed: true, identity: "cellular", now: clock)
            check(!switching.canRecover, "No network means no spinning retries")
            clock += 1
            switching.setNetwork(available: true, changed: true, identity: "wifi-a", now: clock)
            check(switching.retryAt == clock + 0.5, "New Wi-Fi bypasses old cellular failure delay even in low power")
            check(switching.begin(now: clock + 0.49) == nil, "Allow a short route-settling window")
            let wifiAttempt = switching.begin(now: clock + 0.5)!
            switching.finish(token: wifiAttempt, success: false, now: clock + 0.6)
            let failedWifiDeadline = switching.retryAt!
            switching.setNetwork(available: true, changed: true, identity: "wifi-a", now: clock + 0.7)
            check(switching.retryAt! >= failedWifiDeadline, "Repeated notifications on failed Wi-Fi retain backoff")
            let samePathDeadline = switching.retryAt
            switching.setNetwork(available: true, changed: false, identity: "wifi-a", now: clock + 0.8)
            check(switching.retryAt == samePathDeadline, "Duplicate path callbacks do not postpone recovery")
            switching.setNetwork(available: true, changed: true, identity: "wifi-b", now: clock + 1)
            check(switching.retryAt == clock + 1.5, "A different Wi-Fi gets a prompt attempt")
            switching.sleep()
            check(switching.begin(now: clock + 2) == nil, "New Wi-Fi cannot restart during system sleep")
            switching.wake(now: clock + 3)
            check(switching.retryAt == clock + 3.5, "Wake cannot reapply old cellular backoff to new Wi-Fi")
            switching.stop()
            switching.setNetwork(available: true, changed: true, identity: "wifi-c", now: clock + 2)
            check(!switching.pending && switching.begin(now: clock + 10) == nil, "Network events after manual stop cannot reconnect")
        }

        var duringRestart = TunnelRecoveryPolicy()
        duringRestart.start(now: 0)
        duringRestart.setNetwork(available: true, changed: false, identity: "cellular", now: 0)
        duringRestart.request(now: 0)
        let oldNetworkAttempt = duringRestart.begin(now: 2)!
        duringRestart.setNetwork(available: true, changed: true, identity: "wifi-a", now: 2.1)
        duringRestart.setNetwork(available: true, changed: true, identity: "wifi-b", now: 2.2)
        check(duringRestart.begin(now: 2.7) == nil, "Rapid network changes cannot run two native operations")
        duringRestart.finish(token: oldNetworkAttempt, success: false, now: 3)
        check(duringRestart.retryAt == 2.7, "Old cellular failure cannot delay the newest Wi-Fi")
        let latestNetworkAttempt = duringRestart.begin(now: 3)!
        duringRestart.finish(token: latestNetworkAttempt, success: true, now: 3.1)
        check(!duringRestart.pending && !duringRestart.inFlight, "Latest Wi-Fi handover completes")
        duringRestart.setNetwork(available: false, changed: true, identity: "wifi-b", now: 4)
        duringRestart.setNetwork(available: true, changed: true, identity: "wifi-b", now: 5)
        check(duringRestart.retryAt == 5.5, "Previously healthy Wi-Fi returns promptly after temporary loss")
        var duplicateEvents = TunnelRecoveryPolicy()
        duplicateEvents.start(now: 0)
        duplicateEvents.setNetwork(available: true, changed: false, identity: "wifi-a", now: 0)
        duplicateEvents.sleep()
        duplicateEvents.wake(now: 10)
        let wakeDeadline = duplicateEvents.retryAt
        duplicateEvents.wake(now: 10.1)
        duplicateEvents.setNetwork(available: true, changed: true, identity: "wifi-a", now: 10.2)
        check(duplicateEvents.retryAt == wakeDeadline, "Duplicate wake/path events must not postpone the first recovery")
        let wakeAttempt = duplicateEvents.begin(now: wakeDeadline!)!
        duplicateEvents.wake(now: 11)
        duplicateEvents.setNetwork(available: true, changed: true, identity: "wifi-a", now: 11.1)
        check(!duplicateEvents.pending, "Duplicates cannot queue a second restart behind the current attempt")
        duplicateEvents.finish(token: wakeAttempt, success: false, now: 12)
        let failureDeadline = duplicateEvents.retryAt
        duplicateEvents.wake(now: 12.1)
        duplicateEvents.setNetwork(available: true, changed: true, identity: "wifi-a", now: 12.2)
        check(duplicateEvents.retryAt == failureDeadline, "Duplicates preserve failure backoff")
        let retry = duplicateEvents.begin(now: failureDeadline!)!
        duplicateEvents.setNetwork(available: true, changed: true, identity: "wifi-b", now: failureDeadline! + 0.1)
        check(duplicateEvents.pending, "A genuine new network still queues a fresh recovery")
        let newPathDeadline = duplicateEvents.retryAt
        duplicateEvents.finish(token: retry, success: false, now: failureDeadline! + 0.2)
        check(duplicateEvents.retryAt == newPathDeadline, "Old failure cannot postpone the new path")
        let newest = duplicateEvents.begin(now: newPathDeadline!)!
        duplicateEvents.finish(token: newest, success: true, now: newPathDeadline! + 0.1)
        duplicateEvents.sleep()
        duplicateEvents.wake(now: 30)
        check(duplicateEvents.pending, "A later sleep/wake on the same network must still rebuild")
        duplicateEvents.stop()
        duplicateEvents.wake(now: 31)
        check(!duplicateEvents.pending, "Late wake after manual stop cannot reconnect")

        var sleepDuringRestart = TunnelRecoveryPolicy()
        sleepDuringRestart.start(now: 0)
        sleepDuringRestart.setNetwork(available: true, changed: true, identity: "wifi-a", now: 0)
        let beforeSleep = sleepDuringRestart.begin(now: 0.5)!
        sleepDuringRestart.sleep()
        sleepDuringRestart.wake(now: 2)
        check(sleepDuringRestart.pending, "Sleeping during a restart still requires a fresh wake recovery")
        sleepDuringRestart.finish(token: beforeSleep, success: true, now: 3)
        check(sleepDuringRestart.pending, "Pre-sleep completion cannot swallow the wake recovery")
        print("TunnelRecoverySmoke: \(checks) checks passed")
    }
}
