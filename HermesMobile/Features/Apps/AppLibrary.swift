import Foundation
import Observation
import LiveContainerSwiftUI

/// The Apps tab's model: the registry joined with the container's installs.
/// Installed apps the registry does not know still show, with plain metadata.
@MainActor
@Observable
final class AppLibrary {
    private(set) var entries: [HermexAppEntry] = []
    private var installed: [String: LCHostApp] = [:]
    private let registry: @MainActor () -> [HermexApp]
    private let installedApps: @MainActor () -> [LCHostApp]
    private let removeApp: @MainActor (LCHostApp) throws -> Void

    init(
        registry: @escaping @MainActor () -> [HermexApp] = { AppRegistry.records() },
        installedApps: @escaping @MainActor () -> [LCHostApp] = { LCHostRuntime.installedApps() },
        removeApp: @escaping @MainActor (LCHostApp) throws -> Void = { try LCHostRuntime.removeApp($0) }
    ) {
        self.registry = registry
        self.installedApps = installedApps
        self.removeApp = removeApp
    }

    /// The newest app built in the last day, featured as "Just built".
    var justBuilt: HermexAppEntry? {
        entries
            .filter { $0.app.builtAt > Date.now.addingTimeInterval(-24 * 60 * 60) }
            .max { $0.app.builtAt < $1.app.builtAt }
    }

    func refresh() {
        let hostApps = installedApps()
        installed = Dictionary(hostApps.map { ($0.bundleIdentifier, $0) }, uniquingKeysWith: { first, _ in first })

        var records = registry()
        let known = Set(records.map(\.bundleIdentifier))
        records += hostApps.filter { !known.contains($0.bundleIdentifier) }.map(AppRegistry.record(forUnlisted:))
        entries = records
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { HermexAppEntry(app: $0, installedBundlePath: installed[$0.bundleIdentifier]?.relativeBundlePath) }
    }

    func hostApp(for entry: HermexAppEntry) -> LCHostApp? {
        installed[entry.app.bundleIdentifier]
    }

    /// Deletes the app and its data from this iPhone. A registry app stays
    /// listed, as not installed, until the registry drops it.
    func remove(_ entry: HermexAppEntry) throws {
        if let hostApp = hostApp(for: entry) {
            try removeApp(hostApp)
        }
        refresh()
    }
}
