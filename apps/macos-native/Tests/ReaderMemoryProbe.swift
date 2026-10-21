import Darwin
import Foundation

/// A command-line fixture compiled with the production services, never the app.
@main
struct ReaderMemoryProbe {
    static let count = 5000

    @MainActor static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        precondition(environment["SPLITVPN_ISOLATED"] == "1")
        let fixtureDirectory = environment["QZ_READER_FIXTURE_DIR"].map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }
        precondition(fixtureDirectory != nil && Bundle.main.resourceURL?.resolvingSymlinksInPath().path == fixtureDirectory,
                     "Probe must use its temporary fixture resources")
        let mode = CommandLine.arguments[1]
        if mode.hasPrefix("core") { try await core(oversize: mode.hasSuffix("oversize")) }
        else { try await helper(oversize: mode.hasSuffix("oversize")) }
    }

    static func measure(_ stage: String) {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        print("{\"stage\":\"\(stage)\",\"mallocInUse\":\(stats.size_in_use)}")
        fflush(stdout)
    }

    @MainActor static func wait(timeout: Duration = .seconds(10), until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            precondition(ContinuousClock.now < deadline, "Fixture did not finish")
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @MainActor static func core(oversize: Bool) async throws {
        let core = CoreService()
        defer { core.close() }
        if oversize {
            do {
                _ = try await core.requestValue("fixture:oversize", timeout: .seconds(60))
                preconditionFailure("Oversized unterminated message was accepted")
            } catch CoreService.CoreError.message {
                precondition(core.pendingRequestCount == 0)
                if case .unavailable = core.availability {} else {
                    preconditionFailure("Oversized stream did not close the core")
                }
            }
            return
        }
        var events: [JSONValue] = []
        core.onEvent = { name, value in
            precondition(name == "fixture:event")
            if let value { events.append(value) }
        }
        for index in 1...count {
            let value = try await core.requestValue("fixture:echo")
            guard case .object(let fields) = value,
                  case .string(let padding) = fields["padding"],
                  case .number(let sequence) = fields["sequence"] else {
                preconditionFailure("Invalid fixture reply")
            }
            precondition(padding == String(repeating: "x", count: 4096))
            precondition(Int(sequence) == index)
            if index == 1000 { measure("warm") }
        }
        try await Task.sleep(for: .milliseconds(100))
        precondition(core.pendingRequestCount == 0)
        precondition(events.count == 2, "Coalesced events were lost")
        for event in events {
            guard case .string(let text) = event else { preconditionFailure("Invalid event") }
            precondition(text == String(repeating: "x", count: 4096), "Event did not survive pool drain")
        }
        measure("active") // Measure while the reader is still blocked in its next read.
        do {
            _ = try await core.requestValue("fixture:finish", timeout: .seconds(5))
            preconditionFailure("EOF unexpectedly returned a reply")
        } catch {
            if case .unavailable = core.availability {} else { preconditionFailure("EOF did not reach didExit") }
            precondition(core.pendingRequestCount == 0)
        }
        core.close()
        try await Task.sleep(for: .milliseconds(250))
        measure("closed")
    }

    @MainActor static func helper(oversize: Bool) async throws {
        let helper = HelperService()
        defer { helper.stop() }
        var received = 0, errors = 0
        var first: HelperEvent?
        var exit: Int32?
        try helper.start(command: ["type": oversize ? "fixture:oversize" : "fixture:echo"], onEvent: { event in
            if event.type == "error" {
                errors += 1
                precondition(event.stage == "local")
                return
            }
            precondition(event.type == "fixture")
            received += 1
            precondition(event.id == String(received), "Helper events arrived out of order")
            precondition(event.message == String(repeating: "x", count: 4096))
            if first == nil { first = event }
            if received == 1000 { measure("warm") }
            // The fixture waits for an acknowledgement, keeping reads separate.
            if received < count { try! helper.send(["type": "fixture:echo"]) }
        }, onExit: { exit = $0 })
        if oversize {
            try await wait(timeout: .seconds(60)) { exit != nil }
            precondition(exit != 0 && received == 0 && errors == 0)
            return
        }
        try await wait { received == count }
        try await Task.sleep(for: .milliseconds(100))
        precondition(errors == 1, "Malformed line changed subsequent event handling")
        precondition(first?.message == String(repeating: "x", count: 4096), "Event did not survive pool drain")
        precondition(helper.processID != nil, "Reader exited before memory was measured")
        measure("active")
        try helper.send(["type": "fixture:finish"])
        try await wait { exit != nil }
        precondition(exit == 0, "Clean EOF did not reach onExit")
        measure("closed")
    }
}
