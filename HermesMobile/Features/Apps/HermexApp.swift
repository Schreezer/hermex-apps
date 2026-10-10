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
    /// Deep-link routes the app handles, e.g. `today`, `lift/{id}`.
    var routes: [String] = []
    /// The newest build on the Mac, when there is one to install.
    var download: RemoteApp.IPA? = nil
}

/// A registry app joined with what is installed in the container.
struct HermexAppEntry: Identifiable, Hashable {
    let app: HermexApp
    /// The container's bundle folder, when the app is installed on this iPhone.
    let installedBundlePath: String?
    /// The installed build's version, when installed.
    var installedVersion: Int? = nil

    var id: String { app.id }
    var isInstalled: Bool { installedBundlePath != nil }

    /// The Mac has a newer build than the installed one.
    var hasUpdate: Bool {
        guard let installedVersion, let download = app.download else { return false }
        return download.version > installedVersion
    }

    /// The Mac's build runs on this kind of device (Simulator builds don't run on an iPhone, and the reverse).
    var downloadFitsThisDevice: Bool {
        guard let download = app.download else { return false }
        #if targetEnvironment(simulator)
        return download.platform == "simulator"
        #else
        return download.platform == "device"
        #endif
    }
}
