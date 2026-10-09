import XCTest
@testable import HermexAppKit

final class BridgeTests: XCTestCase {
    func testContextRoundTripsThroughJSON() throws {
        let context = HermexContext(
            route: "lift/back-squat",
            breadcrumb: ["Today", "Legs", "Back squat"],
            entities: [HermexEntity(type: "lift", id: "back-squat", title: "Back squat")]
        )
        let data = try HermexBridge.encoder.encode(context)
        XCTAssertEqual(try HermexBridge.decoder.decode(HermexContext.self, from: data), context)
    }

    func testRegistrationRoundTripsThroughJSON() throws {
        let registration = HermexRegistration(bundleIdentifier: "dev.hermex.liftlog", version: "4", routes: ["today", "lift/{id}"])
        let data = try HermexBridge.encoder.encode(registration)
        XCTAssertEqual(try HermexBridge.decoder.decode(HermexRegistration.self, from: data), registration)
    }

    func testInterfacesNameBothProtocols() {
        XCTAssertEqual(NSStringFromProtocol(HermexBridge.hostInterface().protocol), NSStringFromProtocol(HermexHostXPC.self))
        XCTAssertEqual(NSStringFromProtocol(HermexBridge.guestInterface().protocol), NSStringFromProtocol(HermexGuestXPC.self))
    }

    @MainActor
    func testCallsAreNoOpsOutsideHermex() {
        XCTAssertFalse(HermexAppKit.isHosted)
        HermexAppKit.registerRoutes(["today"])
        HermexAppKit.reportContext(route: "today")
    }

    @MainActor
    func testHighlightsClearAfterTheirDuration() async throws {
        HermexHighlights.shared.flash(["a", "b"], for: .milliseconds(50))
        XCTAssertEqual(HermexHighlights.shared.ids, ["a", "b"])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(HermexHighlights.shared.ids.isEmpty)
    }
}
