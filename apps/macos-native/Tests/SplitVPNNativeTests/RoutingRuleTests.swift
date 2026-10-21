import XCTest
@testable import SplitVPNNative

final class RoutingRuleTests: XCTestCase {
    @MainActor func testSavingAnOutletChangeUsesOneCoreEditAndRefreshesOnlyAfterSuccess() async throws {
        let fixture = try MenuBarFixture(); defer { fixture.close() }
        await fixture.store.refresh()
        var captured: [String: Any] = [:]
        fixture.coreModel.intercept = { channel, payload in
            guard channel == "routing:edit-rule" else { return nil }
            captured = payload
            XCTAssertEqual(fixture.store.busy, "保存分流规则")
            return .object([:])
        }
        var draft = RoutingRuleDraft(original: RoutingRule(raw: "DOMAIN-SUFFIX,example.test", outlet: .vpn))
        draft.outlet = .direct
        try await fixture.store.saveRoutingRule(draft)
        XCTAssertEqual(captured["target"] as? String, "direct")
        XCTAssertEqual(captured["originalTarget"] as? String, "vpn")
        XCTAssertEqual(captured["originalRule"] as? String, "DOMAIN-SUFFIX,example.test")
        XCTAssertEqual(captured["rule"] as? String, "example.test")
        XCTAssertEqual(fixture.coreModel.channels.suffix(2), ["routing:edit-rule", "native:bootstrap"])
        XCTAssertNil(fixture.store.busy)
    }

    @MainActor func testSaveFailureIsReturnedToTheEditorWithoutLosingInput() async throws {
        let fixture = try MenuBarFixture(); defer { fixture.close() }
        await fixture.store.refresh()
        fixture.coreModel.failure = ("routing:add-rule", CoreService.CoreError.message("fixture rejected rule"))
        var draft = RoutingRuleDraft(); draft.address = "192.0.2.8"; draft.outlet = .direct
        do { try await fixture.store.saveRoutingRule(draft); XCTFail("Expected a save failure") }
        catch { XCTAssertEqual(error.localizedDescription, "fixture rejected rule") }
        XCTAssertEqual(draft.address, "192.0.2.8")
        XCTAssertEqual(draft.outlet, .direct)
        XCTAssertEqual(fixture.coreModel.channels.last, "routing:add-rule")
        XCTAssertNil(fixture.store.busy)
        XCTAssertNil(fixture.store.message)
    }

    func testExistingIpv6AndGeoRulesRemainEditable() {
        let ip = RoutingRuleDraft(original: RoutingRule(raw: "IP-CIDR6,2001:db8::/32", outlet: .direct))
        XCTAssertEqual(ip.kind, .ip); XCTAssertEqual(ip.address, "2001:db8::/32")
        let geo = RoutingRuleDraft(original: RoutingRule(raw: "GEOSITE,netflix", outlet: .vpn))
        XCTAssertEqual(geo.kind, .raw); XCTAssertEqual(geo.address, "GEOSITE,netflix")
    }
}
