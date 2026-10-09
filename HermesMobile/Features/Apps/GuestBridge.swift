import Foundation
import Observation
import HermexAppKit

/// Hermex's end of one running app's bridge (BUILD_SPEC §3.2). The guest's
/// HermexAppKit connects to `endpoint`, which reaches it through the
/// LiveProcess launch info, and reports its routes and current screen. Hermex
/// calls back to open a route, refresh data, or highlight what changed.
@MainActor
@Observable
final class GuestBridge {
    private(set) var registration: HermexRegistration?
    private(set) var context: HermexContext?
    private(set) var isConnected = false

    @ObservationIgnored private let listener = NSXPCListener.anonymous()
    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private lazy var host = GuestBridgeHost(bridge: self)

    var endpoint: NSXPCListenerEndpoint { listener.endpoint }

    /// What the runtime passes to LiveProcess so the guest can find us.
    var launchInfo: [String: Any] { [HermexBridge.endpointKey: endpoint] }

    init() {
        listener.delegate = host
        listener.resume()
    }

    /// Navigates the app to a route. Returns whether the app handled it.
    func open(_ route: String) async -> Bool {
        guard let guest else { return false }
        return await withCheckedContinuation { continuation in
            guest.open(route) { continuation.resume(returning: $0) }
        }
    }

    /// Tells the app to reload after its data changed; nil means "wherever you are".
    func refresh(_ route: String? = nil) async {
        guard let guest else { return }
        await withCheckedContinuation { continuation in
            guest.refresh(route ?? "") { continuation.resume() }
        }
    }

    /// Outlines these entities in the app for a few seconds.
    func highlight(_ ids: [String]) async {
        guard let guest, let data = try? HermexBridge.encoder.encode(ids) else { return }
        await withCheckedContinuation { continuation in
            guest.highlight(data) { continuation.resume() }
        }
    }

    func invalidate() {
        connection?.invalidate()
        listener.invalidate()
    }

    private var guest: HermexGuestXPC? {
        connection?.remoteObjectProxyWithErrorHandler { _ in } as? HermexGuestXPC
    }

    fileprivate func attach(_ newConnection: NSXPCConnection) {
        // A restart reconnects; the newest connection is the live app.
        connection?.invalidate()
        connection = newConnection
        isConnected = true
        registration = nil
        context = nil
    }

    fileprivate func detach(_ oldConnection: NSXPCConnection) {
        guard connection === oldConnection else { return }
        connection = nil
        isConnected = false
    }

    fileprivate func receive(registration data: Data) {
        registration = try? HermexBridge.decoder.decode(HermexRegistration.self, from: data)
    }

    fileprivate func receive(context data: Data) {
        context = try? HermexBridge.decoder.decode(HermexContext.self, from: data)
    }
}

/// Accepts the guest's connection and receives its calls on the XPC queue.
/// Every hop to the bridge goes through the main queue, which is FIFO, so the
/// attach lands before the guest's first message.
private final class GuestBridgeHost: NSObject, NSXPCListenerDelegate, HermexHostXPC, @unchecked Sendable {
    private weak var bridge: GuestBridge?

    init(bridge: GuestBridge) {
        self.bridge = bridge
    }

    private func onMain(_ work: @escaping @MainActor (GuestBridge) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                if let bridge = self?.bridge { work(bridge) }
            }
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = HermexBridge.hostInterface()
        connection.exportedObject = self
        connection.remoteObjectInterface = HermexBridge.guestInterface()
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let connection else { return }
            self?.onMain { $0.detach(connection) }
        }
        onMain { $0.attach(connection) }
        connection.resume()
        return true
    }

    func guestDidRegister(_ registration: Data) {
        onMain { $0.receive(registration: registration) }
    }

    func guestDidReportContext(_ context: Data) {
        onMain { $0.receive(context: context) }
    }
}
