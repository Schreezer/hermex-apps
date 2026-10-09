import Foundation

/// The wire contract between the Hermex host and a guest app. Both sides link
/// this file, so selectors and payloads always agree. Payloads cross as JSON
/// `Data` to keep the XPC interfaces free of collection-class allowlists.
public enum HermexBridge {
    /// Key for the host's `NSXPCListenerEndpoint` in the LiveProcess launch info.
    public static let endpointKey = "hermexBridgeEndpoint"

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public static let decoder = JSONDecoder()

    public static func hostInterface() -> NSXPCInterface {
        NSXPCInterface(with: HermexHostXPC.self)
    }

    public static func guestInterface() -> NSXPCInterface {
        NSXPCInterface(with: HermexGuestXPC.self)
    }
}

/// Something on screen the agent can refer to, e.g. a workout session.
public struct HermexEntity: Codable, Hashable, Sendable {
    public let type: String
    public let id: String
    public let title: String

    public init(type: String, id: String, title: String) {
        self.type = type
        self.id = id
        self.title = title
    }
}

/// Sent once per connection: what the app supports.
public struct HermexRegistration: Codable, Hashable, Sendable {
    public let bundleIdentifier: String
    public let version: String
    /// Deep-link routes, e.g. `today`, `history`, `lift/{id}`.
    public let routes: [String]

    public init(bundleIdentifier: String, version: String, routes: [String]) {
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.routes = routes
    }
}

/// Sent on every screen change: where the user is and what they see.
public struct HermexContext: Codable, Hashable, Sendable {
    public let route: String
    /// Human-readable path for the chat's "Sees:" line, e.g. ["Today", "Legs"].
    public let breadcrumb: [String]
    public let entities: [HermexEntity]

    public init(route: String, breadcrumb: [String] = [], entities: [HermexEntity] = []) {
        self.route = route
        self.breadcrumb = breadcrumb
        self.entities = entities
    }
}

/// Implemented by the host; the guest calls it.
@objc public protocol HermexHostXPC {
    /// JSON `HermexRegistration`.
    func guestDidRegister(_ registration: Data)
    /// JSON `HermexContext`.
    func guestDidReportContext(_ context: Data)
}

/// Implemented by the guest; the host calls it.
@objc public protocol HermexGuestXPC {
    /// Navigates to a route. Replies whether the app handled it.
    func open(_ route: String, reply: @escaping (Bool) -> Void)
    /// Reloads data after the agent changed it. An empty route means "wherever you are".
    func refresh(_ route: String, reply: @escaping () -> Void)
    /// JSON `[String]` of entity ids to outline briefly.
    func highlight(_ ids: Data, reply: @escaping () -> Void)
}
