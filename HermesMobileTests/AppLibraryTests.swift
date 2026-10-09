import XCTest
import LiveContainerSwiftUI
@testable import HermesMobile

@MainActor
final class AppLibraryTests: XCTestCase {
    private let now = Date.now

    private func record(_ id: String, bundle: String, builtAt: Date = .distantPast, updatedAt: Date = .distantPast) -> HermexApp {
        HermexApp(
            id: id, name: id.capitalized, tagline: "", summary: "", bundleIdentifier: bundle,
            symbol: "app.fill", color: 0, ink: 0, version: 1, builtAt: builtAt, updatedAt: updatedAt,
            origin: nil, capabilities: [], versions: []
        )
    }

    private func installed(_ bundle: String) -> LCHostApp {
        LCHostApp(bundleIdentifier: bundle, displayName: "Installed \(bundle)", version: "2.1.0", relativeBundlePath: "\(bundle).app")
    }

    func testRegistryAppsJoinInstallsByBundleIdentifier() {
        let library = AppLibrary(
            registry: { [self.record("lift", bundle: "dev.lift"), self.record("fuel", bundle: "dev.fuel")] },
            installedApps: { [self.installed("dev.lift")] }
        )
        library.refresh()

        let lift = library.entries.first { $0.id == "lift" }
        let fuel = library.entries.first { $0.id == "fuel" }
        XCTAssertEqual(lift?.installedBundlePath, "dev.lift.app")
        XCTAssertEqual(fuel?.isInstalled, false)
        XCTAssertEqual(lift.flatMap(library.hostApp(for:))?.bundleIdentifier, "dev.lift")
    }

    func testInstalledAppMissingFromRegistryStillShows() {
        let library = AppLibrary(registry: { [] }, installedApps: { [self.installed("dev.other")] })
        library.refresh()

        XCTAssertEqual(library.entries.count, 1)
        XCTAssertEqual(library.entries.first?.app.name, "Installed dev.other")
        XCTAssertEqual(library.entries.first?.app.version, 2)
        XCTAssertEqual(library.entries.first?.isInstalled, true)
    }

    func testEntriesSortByMostRecentlyUpdated() {
        let library = AppLibrary(
            registry: {
                [
                    self.record("old", bundle: "dev.old", updatedAt: self.now.addingTimeInterval(-3_600)),
                    self.record("new", bundle: "dev.new", updatedAt: self.now)
                ]
            },
            installedApps: { [] }
        )
        library.refresh()

        XCTAssertEqual(library.entries.map(\.id), ["new", "old"])
    }

    func testJustBuiltIsTheNewestAppBuiltInTheLastDay() {
        let library = AppLibrary(
            registry: {
                [
                    self.record("week", bundle: "dev.week", builtAt: self.now.addingTimeInterval(-7 * 86_400)),
                    self.record("hour", bundle: "dev.hour", builtAt: self.now.addingTimeInterval(-3_600)),
                    self.record("minute", bundle: "dev.minute", builtAt: self.now.addingTimeInterval(-60))
                ]
            },
            installedApps: { [] }
        )
        library.refresh()

        XCTAssertEqual(library.justBuilt?.id, "minute")
    }

    func testNothingIsJustBuiltWhenEveryAppIsOlderThanADay() {
        let library = AppLibrary(
            registry: { [self.record("week", bundle: "dev.week", builtAt: self.now.addingTimeInterval(-7 * 86_400))] },
            installedApps: { [] }
        )
        library.refresh()

        XCTAssertNil(library.justBuilt)
    }

    func testRemoveDeletesTheInstallAndKeepsTheRegistryEntry() throws {
        var installs = [installed("dev.lift")]
        var removed: [String] = []
        let library = AppLibrary(
            registry: { [self.record("lift", bundle: "dev.lift")] },
            installedApps: { installs },
            removeApp: { app in
                removed.append(app.bundleIdentifier)
                installs.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
            }
        )
        library.refresh()

        try library.remove(try XCTUnwrap(library.entries.first))

        XCTAssertEqual(removed, ["dev.lift"])
        XCTAssertEqual(library.entries.map(\.id), ["lift"])
        XCTAssertEqual(library.entries.first?.isInstalled, false)
    }
}
