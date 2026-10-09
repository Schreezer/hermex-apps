import XCTest
import HermexAppKit
@testable import HermesMobile

/// Drives a real GuestBridge over a real XPC connection, with an in-process
/// fake standing in for the guest app's HermexAppKit.
@MainActor
final class GuestBridgeTests: XCTestCase {
    private final class FakeGuest: NSObject, HermexGuestXPC, @unchecked Sendable {
        private let lock = NSLock()
        private var _opened: [String] = []
        private var _refreshed: [String] = []
        private var _highlighted: [[String]] = []

        var opened: [String] { lock.withLock { _opened } }
        var refreshed: [String] { lock.withLock { _refreshed } }
        var highlighted: [[String]] { lock.withLock { _highlighted } }

        func open(_ route: String, reply: @escaping (Bool) -> Void) {
            lock.withLock { _opened.append(route) }
            reply(route != "nowhere")
        }

        func refresh(_ route: String, reply: @escaping () -> Void) {
            lock.withLock { _refreshed.append(route) }
            reply()
        }

        func highlight(_ ids: Data, reply: @escaping () -> Void) {
            let decoded = (try? HermexBridge.decoder.decode([String].self, from: ids)) ?? []
            lock.withLock { _highlighted.append(decoded) }
            reply()
        }
    }

    private var connections: [NSXPCConnection] = []

    override func tearDown() async throws {
        connections.forEach { $0.invalidate() }
        connections = []
    }

    private func connect(_ guest: FakeGuest, to bridge: GuestBridge) -> HermexHostXPC {
        let connection = NSXPCConnection(listenerEndpoint: bridge.endpoint)
        connection.remoteObjectInterface = HermexBridge.hostInterface()
        connection.exportedInterface = HermexBridge.guestInterface()
        connection.exportedObject = guest
        connection.resume()
        connections.append(connection)
        let host = connection.remoteObjectProxy as! HermexHostXPC
        // XPC connects on the first message, as HermexAppKit's hello does.
        host.guestDidRegister(try! HermexBridge.encoder.encode(HermexRegistration(bundleIdentifier: "test", version: "1", routes: [])))
        return host
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    func testRegistrationAndContextReachTheHost() async throws {
        let bridge = GuestBridge()
        let host = connect(FakeGuest(), to: bridge)

        host.guestDidRegister(try HermexBridge.encoder.encode(
            HermexRegistration(bundleIdentifier: "dev.hermex.liftlog", version: "4", routes: ["today", "history"])
        ))
        host.guestDidReportContext(try HermexBridge.encoder.encode(
            HermexContext(route: "today", breadcrumb: ["Today", "Legs"], entities: [HermexEntity(type: "lift", id: "squat", title: "Back squat")])
        ))
        try await waitUntil { bridge.registration != nil && bridge.context != nil }

        XCTAssertTrue(bridge.isConnected)
        XCTAssertEqual(bridge.registration?.routes, ["today", "history"])
        XCTAssertEqual(bridge.context?.breadcrumb, ["Today", "Legs"])
        XCTAssertEqual(bridge.context?.entities.first?.id, "squat")
    }

    func testHostCallsReachTheGuest() async throws {
        let bridge = GuestBridge()
        let guest = FakeGuest()
        _ = connect(guest, to: bridge)
        try await waitUntil { bridge.isConnected }

        let handled = await bridge.open("history")
        let unhandled = await bridge.open("nowhere")
        await bridge.refresh()
        await bridge.refresh("today")
        await bridge.highlight(["squat", "deadlift"])

        XCTAssertTrue(handled)
        XCTAssertFalse(unhandled)
        XCTAssertEqual(guest.opened, ["history", "nowhere"])
        XCTAssertEqual(guest.refreshed, ["", "today"])
        XCTAssertEqual(guest.highlighted, [["squat", "deadlift"]])
    }

    func testCallsWithoutAGuestDoNothing() async {
        let bridge = GuestBridge()
        let handled = await bridge.open("today")
        await bridge.refresh()
        XCTAssertFalse(handled)
        XCTAssertFalse(bridge.isConnected)
    }

    func testInvalidatedConnectionDisconnects() async throws {
        let bridge = GuestBridge()
        _ = connect(FakeGuest(), to: bridge)
        try await waitUntil { bridge.isConnected }

        connections.forEach { $0.invalidate() }
        try await waitUntil { !bridge.isConnected }
    }
}
