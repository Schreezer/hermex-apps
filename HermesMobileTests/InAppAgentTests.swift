import XCTest
import HermexAppKit
@testable import HermesMobile

final class AgentButtonPlacementTests: XCTestCase {
    private let size = CGSize(width: 402, height: 756)

    func testDefaultSitsBottomRightAboveTheTabBar() {
        let placement = AgentButtonPlacement()
        XCTAssertEqual(placement.side, .trailing)
        XCTAssertEqual(placement.slot, AgentButtonPlacement.slotCount - 1)
        XCTAssertFalse(placement.isTucked)
        let center = AgentButtonPlacement.center(side: .trailing, slot: placement.slot, in: size)
        XCTAssertEqual(center.x, size.width - 48)
        XCTAssertEqual(center.y, size.height - 112 - 30)
    }

    func testReleaseSnapsToTheNearestSpotOnThatSide() {
        let top = AgentButtonPlacement.center(side: .leading, slot: 0, in: size)
        let landing = AgentButtonPlacement.landing(at: CGPoint(x: 120, y: top.y + 20), in: size)
        XCTAssertEqual(landing, AgentButtonPlacement(side: .leading, slot: 0, isTucked: false))

        let second = AgentButtonPlacement.center(side: .trailing, slot: 2, in: size)
        let right = AgentButtonPlacement.landing(at: CGPoint(x: 300, y: second.y - 15), in: size)
        XCTAssertEqual(right, AgentButtonPlacement(side: .trailing, slot: 2, isTucked: false))
    }

    func testThrowPastAnEdgeTucks() {
        XCTAssertTrue(AgentButtonPlacement.landing(at: CGPoint(x: -40, y: 300), in: size).isTucked)
        XCTAssertTrue(AgentButtonPlacement.landing(at: CGPoint(x: size.width + 10, y: 300), in: size).isTucked)
        XCTAssertFalse(AgentButtonPlacement.landing(at: CGPoint(x: 30, y: 300), in: size).isTucked)
    }

    func testPlacementIsRememberedPerApp() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AgentButtonPlacementTests"))
        defer { defaults.removePersistentDomain(forName: "AgentButtonPlacementTests") }
        let tucked = AgentButtonPlacement(side: .leading, slot: 1, isTucked: true)
        tucked.save(appID: "lift-log", defaults: defaults)

        XCTAssertEqual(AgentButtonPlacement.load(appID: "lift-log", defaults: defaults), tucked)
        XCTAssertEqual(AgentButtonPlacement.load(appID: "fuel", defaults: defaults), AgentButtonPlacement())
    }
}

final class InAppChatContextTests: XCTestCase {
    private let app = HermexApp(
        id: "lift-log", name: "Lift Log", tagline: "", summary: "", bundleIdentifier: "dev.hermex.liftlog",
        symbol: "dumbbell.fill", color: 0, ink: 0, version: 4, builtAt: .distantPast, updatedAt: .distantPast,
        origin: nil,
        capabilities: [.init(kind: .api, title: "", detail: ""), .init(kind: .tap, title: "", detail: "")],
        versions: []
    )
    private let context = HermexContext(
        route: "today",
        breadcrumb: ["Today", "Legs"],
        entities: [HermexEntity(type: "session", id: "2026-10-07-legs", title: "Legs")]
    )

    func testFirstMessageCarriesTheSpecPayload() throws {
        let sent = InAppChatContext.message("did legs", with: .init(app: app, context: context))
        let parts = sent.components(separatedBy: InAppChatContext.marker)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0], "did legs")

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any])
        XCTAssertEqual(json["surface"] as? String, "in_app")
        XCTAssertEqual(json["route"] as? String, "today")
        XCTAssertEqual(json["sees"] as? [String], ["Today", "Legs"])
        let appJSON = try XCTUnwrap(json["app"] as? [String: Any])
        XCTAssertEqual(appJSON["id"] as? String, "lift-log")
        XCTAssertEqual(appJSON["name"] as? String, "Lift Log")
        XCTAssertEqual(appJSON["version"] as? Int, 4)
        XCTAssertEqual(appJSON["has_api"] as? Bool, true)
        let entities = try XCTUnwrap(json["entities"] as? [[String: String]])
        XCTAssertEqual(entities.first?["id"], "2026-10-07-legs")
    }

    func testDisplayHidesTheContextBlock() {
        let sent = InAppChatContext.message("did legs", with: .init(app: app, context: context))
        XCTAssertEqual(InAppChatContext.displayText(sent), "did legs")
        XCTAssertEqual(InAppChatContext.displayText("plain message"), "plain message")
    }

    func testSeesLineLeadsWithTheAppName() {
        XCTAssertEqual(InAppChatContext.seesLine(appName: "Lift Log", context: context), "Lift Log › Today › Legs")
        XCTAssertEqual(InAppChatContext.seesLine(appName: "Lift Log", context: nil), "Lift Log")
    }

    func testSessionsRememberTheirApp() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "InAppChatContextTests"))
        defer { defaults.removePersistentDomain(forName: "InAppChatContextTests") }
        InAppChatSessions.record(sessionID: "abc", appID: "lift-log", defaults: defaults)
        XCTAssertEqual(InAppChatSessions.appID(forSession: "abc", defaults: defaults), "lift-log")
        XCTAssertNil(InAppChatSessions.appID(forSession: "other", defaults: defaults))
    }
}
