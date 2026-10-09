import Foundation

/// One app Hermes built for the user, as the registry describes it.
struct HermexApp: Identifiable, Hashable {
    enum CapabilityKind: String {
        case api = "API"
        case link = "LINK"
        case tap = "TAP"
    }

    /// One way Hermes can work with the app, in order of preference.
    struct Capability: Hashable {
        let kind: CapabilityKind
        let title: String
        let detail: String
    }

    /// A version and the request that caused it.
    struct Version: Hashable {
        let number: Int
        let change: String
        let reason: String
    }

    let id: String
    let name: String
    /// Short line for list rows.
    let tagline: String
    /// Longer line for the "Just built" card.
    let summary: String
    let bundleIdentifier: String
    /// SF Symbol for the icon tile.
    let symbol: String
    let color: UInt32
    let ink: UInt32
    let version: Int
    let builtAt: Date
    let updatedAt: Date
    /// Where the app came from when it was not built from scratch, e.g. "From a GitHub repo".
    let origin: String?
    let capabilities: [Capability]
    let versions: [Version]
}

/// A registry app joined with what is installed in the container.
struct HermexAppEntry: Identifiable, Hashable {
    let app: HermexApp
    /// The container's bundle folder, when the app is installed on this iPhone.
    let installedBundlePath: String?

    var id: String { app.id }
    var isInstalled: Bool { installedBundlePath != nil }
}
