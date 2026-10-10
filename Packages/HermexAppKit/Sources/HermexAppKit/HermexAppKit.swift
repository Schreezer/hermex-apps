import Foundation
import Observation

/// The guest app's side of the bridge. Every call is a no-op when the app is
/// not running inside Hermex, so the same app also runs on its own.
///
///     HermexAppKit.registerRoutes(["today", "history", "lift/{id}"])
///     HermexAppKit.onOpen { route in router.go(route) }
///     HermexAppKit.onRefresh { _ in store.reload() }
///     let items: [Item] = try await HermexAppKit.fetch("items")   // the app's API on the Mac
///     // on every screen change:
///     HermexAppKit.reportContext(route: "today", breadcrumb: ["Today", "Legs"], entities: [...])
@MainActor
public enum HermexAppKit {
    /// True when the app runs inside Hermex and found the host's bridge.
    public static var isHosted: Bool { HermexGuestClient.shared.isHosted }

    public static func registerRoutes(_ routes: [String]) {
        HermexGuestClient.shared.register(routes: routes)
    }

    public static func reportContext(route: String, breadcrumb: [String] = [], entities: [HermexEntity] = []) {
        HermexGuestClient.shared.report(HermexContext(route: route, breadcrumb: breadcrumb, entities: entities))
    }

    /// Called when Hermes opens a route. Return whether the app handled it.
    public static func onOpen(_ handler: @escaping @MainActor (String) -> Bool) {
        HermexGuestClient.shared.openHandler = handler
    }

    /// Called after the agent changed the app's data. The route is nil for "wherever you are".
    public static func onRefresh(_ handler: @escaping @MainActor (String?) -> Void) {
        HermexGuestClient.shared.refreshHandler = handler
    }
}

/// Ids Hermes just changed, outlined for a few seconds (see `hermexHighlight(id:)`).
@MainActor
@Observable
public final class HermexHighlights {
    public static let shared = HermexHighlights()
    public private(set) var ids: Set<String> = []
    private var generation = 0

    public func flash(_ newIDs: [String], for duration: Duration = .seconds(4)) {
        generation += 1
        let current = generation
        ids = Set(newIDs)
        Task { @MainActor in
            try? await Task.sleep(for: duration)
            if current == generation { ids = [] }
        }
    }
}

@MainActor
final class HermexGuestClient {
    static let shared = HermexGuestClient()

    var openHandler: (@MainActor (String) -> Bool)?
    var refreshHandler: (@MainActor (String?) -> Void)?

    private let connection: NSXPCConnection?
    private var routes: [String] = []
    private var lastContext: HermexContext?

    var isHosted: Bool { connection != nil }

    private init() {
        guard let endpoint = Self.hostEndpoint() else {
            connection = nil
            return
        }
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = HermexBridge.hostInterface()
        connection.exportedInterface = HermexBridge.guestInterface()
        connection.exportedObject = HermexGuestService()
        connection.resume()
        self.connection = connection
        // XPC connects lazily on the first message, and the host can only call
        // the app once connected, so say hello right away.
        register(routes: [])
    }

    func register(routes: [String]) {
        self.routes = routes
        let info = Bundle.main.infoDictionary ?? [:]
        let registration = HermexRegistration(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            version: info["CFBundleShortVersionString"] as? String ?? "",
            routes: routes
        )
        guard let data = try? HermexBridge.encoder.encode(registration) else { return }
        host?.guestDidRegister(data)
    }

    func report(_ context: HermexContext) {
        guard context != lastContext else { return }
        lastContext = context
        guard let data = try? HermexBridge.encoder.encode(context) else { return }
        host?.guestDidReportContext(data)
    }

    private var host: HermexHostXPC? {
        connection?.remoteObjectProxyWithErrorHandler { _ in } as? HermexHostXPC
    }

    /// The host proxy for a call that waits on a reply: `onError` runs instead
    /// of the reply when the connection breaks.
    func host(onError: @escaping @Sendable (Error) -> Void) -> HermexHostXPC? {
        connection?.remoteObjectProxyWithErrorHandler(onError) as? HermexHostXPC
    }

    /// LiveProcess keeps the launch info it received from the host on its
    /// principal class; the host put its bridge endpoint there.
    private static func hostEndpoint() -> NSXPCListenerEndpoint? {
        guard let handler = NSClassFromString("LiveProcessHandler") as AnyObject?,
              handler.responds(to: NSSelectorFromString("retrievedAppInfo")),
              let info = handler.perform(NSSelectorFromString("retrievedAppInfo"))?.takeUnretainedValue() as? [String: Any]
        else { return nil }
        return info[HermexBridge.endpointKey] as? NSXPCListenerEndpoint
    }
}

/// Receives the host's calls on the XPC queue and runs them on the main actor.
final class HermexGuestService: NSObject, HermexGuestXPC {
    func open(_ route: String, reply: @escaping (Bool) -> Void) {
        Task { @MainActor in
            reply(HermexGuestClient.shared.openHandler?(route) ?? false)
        }
    }

    func refresh(_ route: String, reply: @escaping () -> Void) {
        Task { @MainActor in
            HermexGuestClient.shared.refreshHandler?(route.isEmpty ? nil : route)
            reply()
        }
    }

    func highlight(_ ids: Data, reply: @escaping () -> Void) {
        let decoded = (try? HermexBridge.decoder.decode([String].self, from: ids)) ?? []
        Task { @MainActor in
            HermexHighlights.shared.flash(decoded)
            reply()
        }
    }
}
