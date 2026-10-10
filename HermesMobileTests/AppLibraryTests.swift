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

    private func installed(_ bundle: String, version: String = "2.1.0") -> LCHostApp {
        LCHostApp(bundleIdentifier: bundle, displayName: "Installed \(bundle)", version: version, relativeBundlePath: "\(bundle).app")
    }

    /// A library over fixed local records (no Mac).
    private func library(
        records: @escaping @MainActor () -> [HermexApp],
        installed: @escaping @MainActor () -> [LCHostApp],
        removeApp: @escaping @MainActor (LCHostApp) throws -> Void = { _ in }
    ) -> AppLibrary {
        var backend = AppLibraryBackend.offline
        backend.samples = records
        backend.installedApps = installed
        backend.removeApp = removeApp
        return AppLibrary(backend: backend)
    }

    func testRegistryAppsJoinInstallsByBundleIdentifier() {
        let library = library(
            records: { [self.record("lift", bundle: "dev.lift"), self.record("fuel", bundle: "dev.fuel")] },
            installed: { [self.installed("dev.lift")] }
        )
        library.refresh()

        let lift = library.entries.first { $0.id == "lift" }
        let fuel = library.entries.first { $0.id == "fuel" }
        XCTAssertEqual(lift?.installedBundlePath, "dev.lift.app")
        XCTAssertEqual(lift?.installedVersion, 2)
        XCTAssertEqual(fuel?.isInstalled, false)
        XCTAssertEqual(lift.flatMap(library.hostApp(for:))?.bundleIdentifier, "dev.lift")
    }

    func testInstalledAppMissingFromRegistryStillShows() {
        let library = library(records: { [] }, installed: { [self.installed("dev.other")] })
        library.refresh()

        XCTAssertEqual(library.entries.count, 1)
        XCTAssertEqual(library.entries.first?.app.name, "Installed dev.other")
        XCTAssertEqual(library.entries.first?.app.version, 2)
        XCTAssertEqual(library.entries.first?.isInstalled, true)
    }

    func testEntriesSortByMostRecentlyUpdated() {
        let library = library(
            records: {
                [
                    self.record("old", bundle: "dev.old", updatedAt: self.now.addingTimeInterval(-3_600)),
                    self.record("new", bundle: "dev.new", updatedAt: self.now)
                ]
            },
            installed: { [] }
        )
        library.refresh()

        XCTAssertEqual(library.entries.map(\.id), ["new", "old"])
    }

    func testJustBuiltIsTheNewestAppBuiltInTheLastDay() {
        let library = library(
            records: {
                [
                    self.record("week", bundle: "dev.week", builtAt: self.now.addingTimeInterval(-7 * 86_400)),
                    self.record("hour", bundle: "dev.hour", builtAt: self.now.addingTimeInterval(-3_600)),
                    self.record("minute", bundle: "dev.minute", builtAt: self.now.addingTimeInterval(-60))
                ]
            },
            installed: { [] }
        )
        library.refresh()

        XCTAssertEqual(library.justBuilt?.id, "minute")
    }

    func testNothingIsJustBuiltWhenEveryAppIsOlderThanADay() {
        let library = library(
            records: { [self.record("week", bundle: "dev.week", builtAt: self.now.addingTimeInterval(-7 * 86_400))] },
            installed: { [] }
        )
        library.refresh()

        XCTAssertNil(library.justBuilt)
    }

    func testRemoveDeletesTheInstallAndKeepsTheRegistryEntry() throws {
        var installs = [installed("dev.lift")]
        var removed: [String] = []
        let library = library(
            records: { [self.record("lift", bundle: "dev.lift")] },
            installed: { installs },
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

/// The library against a fake Mac: registry, installs, updates and events.
@MainActor
final class AppLibraryMacTests: XCTestCase {
    private final class FakeMac: @unchecked Sendable {
        private let lock = NSLock()
        private var _registry: Result<AppsRegistry, AppsServiceError>
        private var _events: [AppsEventPage]
        private(set) var downloads: [String] = []

        init(registry: Result<AppsRegistry, AppsServiceError>, events: [AppsEventPage] = []) {
            _registry = registry
            _events = events
        }

        var registry: Result<AppsRegistry, AppsServiceError> {
            get { lock.withLock { _registry } }
            set { lock.withLock { _registry = newValue } }
        }

        func nextEvents() -> AppsEventPage {
            lock.withLock { _events.isEmpty ? AppsEventPage(events: [], last: 0) : _events.removeFirst() }
        }

        func recordDownload(_ appID: String) -> URL {
            lock.withLock { downloads.append(appID) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString).ipa")
            FileManager.default.createFile(atPath: url.path, contents: Data("ipa".utf8))
            return url
        }
    }

    private var installs: [LCHostApp] = []
    private var installedFiles: [URL] = []

    private static func remoteApp(_ id: String, version: Int, platform: String = "simulator") throws -> RemoteApp {
        let json = """
        {"id": "\(id)", "name": "Chores", "tagline": "Who does what", "summary": "House chores",
         "bundle_id": "dev.hermex.\(id)", "symbol": "checklist", "color": "#4AA3F2", "ink": "#04121E",
         "version": \(version), "built_at": "2026-10-10T06:58:32Z", "updated_at": "2026-10-10T06:58:32Z",
         "origin": null, "routes": ["home", "item/{id}"], "api": {"tools": 3, "changes": 2},
         "versions": [{"number": \(version), "change": "Add notes", "reason": null, "at": "2026-10-10T06:58:32Z"}],
         "ipa": {"version": \(version), "size": 3, "sha256": "x", "platform": "\(platform)", "parts": 1}}
        """
        return try AppsService.decoder.decode(RemoteApp.self, from: Data(json.utf8))
    }

    private func library(_ mac: FakeMac) -> AppLibrary {
        AppLibrary(backend: AppLibraryBackend(
            registry: { try mac.registry.get() },
            download: { _, appID, progress in
                progress(1)
                return mac.recordDownload(appID)
            },
            events: { _ in mac.nextEvents() },
            allowAccess: { mac.registry = .success(AppsRegistry(apps: [], platform: "simulator")) },
            installedApps: { self.installs },
            installIPA: { url in
                self.installedFiles.append(url)
                let app = LCHostApp(bundleIdentifier: "dev.hermex.chores", displayName: "Chores", version: "2", relativeBundlePath: "dev.hermex.chores.app")
                self.installs = [app]
                return app
            },
            removeApp: { _ in },
            samples: { [] }
        ))
    }

    func testRegistryRecordsBecomeAppsWithCapabilities() throws {
        let app = AppRegistry.record(from: try Self.remoteApp("chores", version: 2))
        XCTAssertEqual(app.color, 0x4AA3F2)
        XCTAssertEqual(app.ink, 0x04121E)
        XCTAssertEqual(app.capabilities.map(\.kind), [.api, .link, .tap])
        XCTAssertEqual(app.capabilities[1].detail, "home · item/{id}")
        XCTAssertEqual(app.routes, ["home", "item/{id}"])
        XCTAssertEqual(app.download?.version, 2)
        XCTAssertEqual(app.versions.first?.change, "Add notes")
        XCTAssertFalse(app.versions.first?.reason.isEmpty ?? true, "a missing reason falls back to the date")
    }

    func testNewAppsWaitForInstallAndInstallOnRequest() async throws {
        let mac = FakeMac(registry: .success(AppsRegistry(apps: [try Self.remoteApp("chores", version: 1)], platform: "simulator")))
        let library = library(mac)

        await library.reload()
        XCTAssertEqual(library.status, .ready)
        let entry = try XCTUnwrap(library.entries.first)
        XCTAssertFalse(entry.isInstalled)
        XCTAssertTrue(entry.downloadFitsThisDevice)
        XCTAssertEqual(mac.downloads, [], "a new app needs the user's OK")

        await library.install(entry)
        XCTAssertEqual(mac.downloads, ["chores"])
        XCTAssertEqual(library.entries.first?.isInstalled, true)
        XCTAssertTrue(library.installing.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(installedFiles.first).path), "the download is deleted")
    }

    func testUpdatesInstallByThemselvesExceptForTheOpenApp() async throws {
        installs = [LCHostApp(bundleIdentifier: "dev.hermex.chores", displayName: "Chores", version: "1", relativeBundlePath: "dev.hermex.chores.app")]
        let mac = FakeMac(registry: .success(AppsRegistry(apps: [try Self.remoteApp("chores", version: 2)], platform: "simulator")))
        let library = library(mac)

        library.runningAppID = "chores"
        await library.reload()
        XCTAssertEqual(mac.downloads, [])
        XCTAssertEqual(library.updatesWaitingForRestart, ["chores"])

        let installed = await library.installWaitingUpdate(for: "chores")
        XCTAssertTrue(installed)
        XCTAssertEqual(mac.downloads, ["chores"])
        XCTAssertEqual(library.updatesWaitingForRestart, [])
        XCTAssertEqual(library.entries.first?.installedVersion, 2)
    }

    func testBuildsForAnotherKindOfDeviceDontInstall() async throws {
        let mac = FakeMac(registry: .success(AppsRegistry(apps: [try Self.remoteApp("chores", version: 1, platform: "device")], platform: "device")))
        let library = library(mac)
        await library.reload()
        XCTAssertFalse(try XCTUnwrap(library.entries.first).downloadFitsThisDevice)
    }

    func testSetupProblemsBecomeStatuses() async throws {
        for (error, status) in [
            (AppsServiceError.needsAccess, AppLibrary.Status.needsAccess),
            (.notSetUp, .notSetUp),
            (.serviceDown, .serviceDown),
            (.failed("boom"), .failed("boom"))
        ] {
            let library = library(FakeMac(registry: .failure(error)))
            await library.reload()
            XCTAssertEqual(library.status, status)
        }
    }

    func testAllowingAccessLoadsTheApps() async {
        let library = library(FakeMac(registry: .failure(.needsAccess)))
        await library.reload()
        await library.allowAccess()
        XCTAssertEqual(library.status, .ready)
    }

    func testEventsRefreshTheOpenAppAndReloadAfterABuild() async throws {
        func event(_ seq: Int, _ kind: String, app: String, route: String? = nil) -> AppsEvent {
            AppsEvent(seq: seq, kind: kind, app: app, route: route, highlight: ["a1"], step: nil, state: nil, detail: nil, version: nil, isNew: nil)
        }
        let mac = FakeMac(
            registry: .success(AppsRegistry(apps: [], platform: "simulator")),
            events: [
                AppsEventPage(events: [event(1, "refresh", app: "chores")], last: 1),
                AppsEventPage(events: [event(2, "refresh", app: "chores", route: "home"), event(3, "refresh", app: "other")], last: 3),
                AppsEventPage(events: [event(4, "ready", app: "chores")], last: 4)
            ]
        )
        let library = library(mac)
        await library.reload()
        var received: [AppsEvent] = []
        library.runningAppID = "chores"
        library.onRunningAppEvent = { received.append($0) }

        await library.pollEvents()
        XCTAssertEqual(received, [], "the first poll only finds the end of the feed")

        await library.pollEvents()
        XCTAssertEqual(received.map(\.seq), [2])
        XCTAssertEqual(received.first?.route, "home")

        mac.registry = .success(AppsRegistry(apps: [try Self.remoteApp("chores", version: 1)], platform: "simulator"))
        await library.pollEvents()
        XCTAssertEqual(library.entries.map(\.id), ["chores"], "a finished build reloads the registry")
    }

    func testServiceErrorsMapFromTheProxyAnswers() {
        func body(_ message: String) -> Data { Data(#"{"error": "\#(message)"}"#.utf8) }
        XCTAssertEqual(AppsService.error(status: 403, body: body("Extension sidecar proxy consent required")), .needsAccess)
        XCTAssertEqual(AppsService.error(status: 404, body: body("Extensions are not configured")), .notSetUp)
        XCTAssertEqual(AppsService.error(status: 409, body: body("Extension manifest is not loaded")), .notSetUp)
        XCTAssertEqual(AppsService.error(status: 502, body: body("Failed to reach extension sidecar")), .serviceDown)
        XCTAssertEqual(AppsService.error(status: 404, body: body("No app with id ghost.")), .failed("No app with id ghost."))
    }

    func testBuildEventsTrackEachAttempt() async throws {
        func build(_ seq: Int, _ step: String, _ state: String, detail: String? = nil, at: String? = nil) -> AppsEvent {
            AppsEvent(seq: seq, at: at, kind: "build", app: "chores", route: nil, highlight: nil, step: step, state: state, detail: detail, version: 2, isNew: false)
        }
        let mac = FakeMac(
            registry: .success(AppsRegistry(apps: [], platform: "simulator")),
            events: [
                AppsEventPage(events: [
                    build(1, "check", "running"),
                    build(2, "build", "running", at: "2026-10-10T07:00:00.000Z"),
                    build(3, "build", "failed", detail: "The build failed: x")
                ], last: 3),
                AppsEventPage(events: [
                    build(4, "check", "running"),
                    build(5, "build", "running", at: "2026-10-10T07:01:00.000Z"),
                    build(6, "build", "done", at: "2026-10-10T07:01:41.000Z"),
                    AppsEvent(seq: 7, kind: "ready", app: "chores", route: nil, highlight: nil, step: nil, state: nil, detail: nil, version: 2, isNew: false)
                ], last: 7)
            ]
        )
        let library = library(mac)
        await library.pollEvents()
        XCTAssertEqual(library.builds["chores"]?.failure, .failed("The build failed: x"))
        XCTAssertEqual(library.builds["chores"]?.isRunning, false)

        await library.pollEvents()
        let progress = try XCTUnwrap(library.builds["chores"])
        XCTAssertNil(progress.failure, "a new attempt starts over")
        XCTAssertTrue(progress.isReady)
        XCTAssertEqual(progress.compileFinishedAt?.timeIntervalSince(try XCTUnwrap(progress.compileStartedAt)), 41)
    }

    func testOpeningANewAppInstallsItFirst() async throws {
        let mac = FakeMac(registry: .success(AppsRegistry(apps: [try Self.remoteApp("chores", version: 1)], platform: "simulator")))
        let library = library(mac)
        await library.reload()
        await library.open(appID: "chores")
        XCTAssertEqual(mac.downloads, ["chores"])
        XCTAssertEqual(library.openRequest?.appID, "chores")
    }

    func testOnlyTheNewestBuildCallShowsACard() {
        let library = library(FakeMac(registry: .failure(.notSetUp)))
        library.buildCardAppeared(appID: "chores", callStartedAt: 10)
        library.buildCardAppeared(appID: "chores", callStartedAt: 20)
        XCTAssertFalse(library.isNewestBuildCard(appID: "chores", callStartedAt: 10))
        XCTAssertTrue(library.isNewestBuildCard(appID: "chores", callStartedAt: 20))
        XCTAssertTrue(library.wantsEventsForCards)
        library.buildCardDisappeared()
        library.buildCardDisappeared()
        XCTAssertFalse(library.wantsEventsForCards)
    }
}

final class AppBuildCallTests: XCTestCase {
    func testDirectFactoryCallsAreRead() {
        let call = ToolCall(
            name: "mcp__hermex_apps__apps_create",
            preview: nil,
            args: ["app_id": .string("hyrox-noida"), "name": .string("HYROX Noida"), "color": .string("#DDF53A"),
                   "routes": .array([.string("today"), .string("progress")])],
            isCompleted: true,
            startedAt: 5
        )
        let parsed = AppBuildCall(call)
        XCTAssertEqual(parsed?.kind, .create)
        XCTAssertEqual(parsed?.appID, "hyrox-noida")
        XCTAssertEqual(parsed?.name, "HYROX Noida")
        XCTAssertEqual(parsed?.routes, 2)
    }

    func testDeferredCallsCarryTheirArgumentsAsText() {
        // Settled `tool_call` wrappers keep Python-style, cut-short argument text.
        let call = ToolCall(
            name: "tool_call",
            preview: nil,
            args: ["name": .string("mcp__hermex_apps__apps_build"),
                   "arguments": .string("{'app_id': 'hyrox-noida', 'change': 'First vers...")],
            isCompleted: true
        )
        let parsed = AppBuildCall(call)
        XCTAssertEqual(parsed?.kind, .build)
        XCTAssertEqual(parsed?.appID, "hyrox-noida")
        XCTAssertNil(parsed?.name)
    }

    func testOtherToolsAreIgnored() {
        XCTAssertNil(AppBuildCall(ToolCall(name: "mcp__hermex_apps__apps_list", preview: nil, args: ["app_id": .string("x")])))
        XCTAssertNil(AppBuildCall(ToolCall(name: "web_search", preview: nil, args: nil)))
        XCTAssertNil(AppBuildCall(ToolCall(name: "mcp__hermex_apps__apps_build", preview: nil, args: [:])))
    }

    func testTheNewestCallPerAppWins() {
        let calls = [
            ToolCall(name: "mcp__hermex_apps__apps_create", preview: nil, args: ["app_id": .string("a")], startedAt: 1),
            ToolCall(name: "mcp__hermex_apps__apps_build", preview: nil, args: ["app_id": .string("a")], startedAt: 2),
            ToolCall(name: "mcp__hermex_apps__apps_build", preview: nil, args: ["app_id": .string("b")], startedAt: 3)
        ]
        let parsed = AppBuildCall.calls(in: calls)
        XCTAssertEqual(parsed.map(\.appID), ["a", "b"])
        XCTAssertEqual(parsed.first?.kind, .build)
    }
}
