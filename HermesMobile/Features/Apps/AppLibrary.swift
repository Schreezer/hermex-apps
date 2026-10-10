import Foundation
import Observation
import UIKit
import LiveContainerSwiftUI

/// The Apps tab's model: the Mac's registry joined with the container's
/// installs. Installed apps the registry does not know still show, with plain
/// metadata. New apps install when the user taps Install; updates install by
/// themselves (BUILD_SPEC §3.5), except for the app that is open, which updates
/// when it restarts.
@MainActor
@Observable
final class AppLibrary {
    enum Status: Equatable {
        case loading
        case ready
        /// The webui needs the user's OK to proxy Hermex Apps.
        case needsAccess
        case notSetUp
        case serviceDown
        case failed(String)
    }

    struct InstallFailure: Equatable {
        let appID: String
        let message: String
    }

    private(set) var entries: [HermexAppEntry] = []
    private(set) var status: Status = .loading
    /// Download progress (0…1) by app id while installing.
    private(set) var installing: [String: Double] = [:]
    var installFailure: InstallFailure?
    /// Newer builds for the open app, installed when it restarts.
    private(set) var updatesWaitingForRestart: Set<String> = []
    /// The app open full screen. It can't be replaced while it runs.
    var runningAppID: String?
    /// Hermes changed the open app's data or asked to show a route in it (a
    /// `refresh` or `open` event for `runningAppID`).
    @ObservationIgnored var onRunningAppEvent: (@MainActor (AppsEvent) -> Void)?
    /// What the Mac reported about each app's latest build, by app id.
    private(set) var builds: [String: BuildProgress] = [:]
    /// An app the user asked to open from somewhere else (a build card in chat).
    var openRequest: OpenRequest?
    /// Build cards on screen; while there are any, the library follows events.
    private(set) var visibleBuildCards = 0
    /// For each app, when the newest build call that shows a card started.
    private(set) var buildCardAnchors: [String: Double] = [:]
    /// Hermes' recent requests to open an app (`apps_open`), oldest first.
    private(set) var handoffs: [Handoff] = []
    /// Which request each `apps_open` call in chat made, by tool-call id.
    private(set) var handoffClaims: [String: Int] = [:]
    /// Opening cards in chat on screen; while there are any, the library
    /// follows events so Hermes' request reaches them.
    private(set) var visibleOpenCards = 0
    /// Of those, the ones showing the pending request's countdown.
    private(set) var visibleHandoffCards = 0
    /// Set when the "Opened by Hermes" banner's Chat button asks for Chats.
    var chatRequest: UUID?

    private var remote: [HermexApp] = []
    private var installed: [String: LCHostApp] = [:]
    private var cursor: Int?
    private var countdown: Task<Void, Never>?
    private let backend: AppLibraryBackend

    init(backend: AppLibraryBackend = .offline) {
        self.backend = backend
    }

    convenience init(server: URL) {
        self.init(backend: .live(AppsService(server: server)))
    }

    /// The newest app built in the last day, featured as "Just built".
    var justBuilt: HermexAppEntry? {
        entries
            .filter { $0.app.builtAt > Date.now.addingTimeInterval(-24 * 60 * 60) }
            .max { $0.app.builtAt < $1.app.builtAt }
    }

    /// Rejoins the last registry with what is installed, without asking the Mac.
    func refresh() {
        let hostApps = backend.installedApps()
        installed = Dictionary(hostApps.map { ($0.bundleIdentifier, $0) }, uniquingKeysWith: { first, _ in first })

        var records = remote
        var known = Set(records.map(\.bundleIdentifier))
        for sample in backend.samples() where !known.contains(sample.bundleIdentifier) {
            records.append(sample)
            known.insert(sample.bundleIdentifier)
        }
        records += hostApps.filter { !known.contains($0.bundleIdentifier) }.map(AppRegistry.record(forUnlisted:))
        entries = records
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { app in
                let hostApp = installed[app.bundleIdentifier]
                return HermexAppEntry(
                    app: app,
                    installedBundlePath: hostApp?.relativeBundlePath,
                    installedVersion: hostApp.flatMap { Int($0.version.split(separator: ".").first ?? "") }
                )
            }
    }

    /// Fetches the Mac's registry, then installs updates.
    func reload() async {
        do {
            remote = try await backend.registry().apps.map(AppRegistry.record(from:))
            status = .ready
        } catch {
            status = Self.status(for: error)
        }
        refresh()
        await installUpdates()
    }

    /// Records the user's OK for the webui to reach Hermex Apps, then loads.
    func allowAccess() async {
        do {
            try await backend.allowAccess()
            await reload()
        } catch {
            status = Self.status(for: error)
        }
    }

    func hostApp(for entry: HermexAppEntry) -> LCHostApp? {
        installed[entry.app.bundleIdentifier]
    }

    /// Downloads the Mac's newest build and installs it into the container.
    func install(_ entry: HermexAppEntry) async {
        guard let download = entry.app.download, installing[entry.id] == nil else { return }
        let appID = entry.id
        installing[appID] = 0
        installFailure = nil
        defer { installing[appID] = nil }
        do {
            let file = try await backend.download(download, appID) { [weak self] fraction in
                Task { @MainActor in
                    if self?.installing[appID] != nil { self?.installing[appID] = fraction }
                }
            }
            defer { try? FileManager.default.removeItem(at: file) }
            _ = try await backend.installIPA(file)
            updatesWaitingForRestart.remove(appID)
            refresh()
        } catch {
            installFailure = InstallFailure(appID: appID, message: error.localizedDescription)
        }
    }

    /// Installs every newer build, except the open app's, which waits for a restart.
    func installUpdates() async {
        for entry in entries where entry.hasUpdate && entry.downloadFitsThisDevice {
            if entry.id == runningAppID {
                updatesWaitingForRestart.insert(entry.id)
            } else {
                await install(entry)
            }
        }
    }

    /// Installs the open app's waiting update. Returns whether it is installed;
    /// the caller relaunches the app.
    func installWaitingUpdate(for appID: String) async -> Bool {
        guard let entry = entries.first(where: { $0.id == appID }) else { return false }
        await install(entry)
        return installFailure?.appID != appID
    }

    /// Deletes the app and its on-device data from this iPhone. A registry app
    /// stays listed, ready to install again; its data on the Mac stays.
    func remove(_ entry: HermexAppEntry) throws {
        if let hostApp = hostApp(for: entry) {
            try backend.removeApp(hostApp)
        }
        refresh()
    }

    // MARK: - Build cards

    struct OpenRequest: Equatable {
        let id = UUID()
        let appID: String
        var route: String? = nil
        var highlight: [String] = []
        var note: String? = nil
        /// Hermes opened it: the app shows the "Opened by Hermes" banner.
        var byHermes = false
    }

    /// Whether the library should follow the Mac's events for a card in chat.
    var wantsEventsForCards: Bool { visibleBuildCards > 0 || visibleOpenCards > 0 }

    func buildCardAppeared(appID: String, callStartedAt: Double) {
        visibleBuildCards += 1
        if callStartedAt > buildCardAnchors[appID] ?? -1 {
            buildCardAnchors[appID] = callStartedAt
        }
    }

    func buildCardDisappeared() {
        visibleBuildCards = max(0, visibleBuildCards - 1)
    }

    /// Only the newest build call for an app shows a card.
    func isNewestBuildCard(appID: String, callStartedAt: Double) -> Bool {
        callStartedAt >= buildCardAnchors[appID] ?? -1
    }

    /// Opens the app full screen in the Apps tab, installing it first if it is
    /// new (the tap is the user's OK).
    func open(_ request: OpenRequest) async {
        if entries.first(where: { $0.id == request.appID }) == nil {
            await reload()
        }
        if let entry = entries.first(where: { $0.id == request.appID }), !entry.isInstalled {
            await install(entry)
        }
        guard entries.first(where: { $0.id == request.appID })?.isInstalled == true else { return }
        openRequest = request
    }

    func open(appID: String) async {
        await open(OpenRequest(appID: appID))
    }

    func cancelBuild(appID: String) async {
        do {
            try await backend.cancelBuild(appID)
        } catch {
            installFailure = InstallFailure(appID: appID, message: error.localizedDescription)
        }
    }

    // MARK: - Hermes opens apps

    /// Hermes asked to open an app (`apps_open`). It opens after a short
    /// countdown unless the user taps Stay here; an app that isn't installed
    /// waits for the user's OK instead.
    struct Handoff: Equatable, Identifiable {
        enum Outcome: Equatable {
            case pending
            case opened
            case stayed
            /// The user was already in the app: it just went to the route.
            case alreadyOpen
        }

        /// The event's sequence number.
        let id: Int
        let appID: String
        let route: String
        let highlight: [String]
        let note: String?
        let preview: [AppsEvent.PreviewRow]
        let requestedAt: Date
        /// When it opens by itself; nil when it waits for a tap (the app isn't
        /// installed yet, or VoiceOver is running).
        let opensAt: Date?
        var outcome: Outcome = .pending

        var request: OpenRequest {
            OpenRequest(appID: appID, route: route, highlight: highlight, note: note, byHermes: true)
        }
    }

    /// Seconds before Hermes' request opens the app by itself.
    @ObservationIgnored var handoffCountdown = 2.0
    /// Requests older than this when they arrive were missed; they don't open.
    static let handoffFreshness = 20.0

    var pendingHandoff: Handoff? {
        handoffs.last { $0.outcome == .pending }
    }

    /// The request a chat's `apps_open` call made. A live call finds it by
    /// time (same app, arriving soon after) and claims it, because the call's
    /// settled copy from the server carries no time.
    func handoff(appID: String, callIDs: [String], callStartedAt: Double) -> Handoff? {
        if let id = callIDs.lazy.compactMap({ self.handoffClaims[$0] }).first {
            return handoffs.first { $0.id == id }
        }
        return handoffs.last {
            $0.appID == appID
                && $0.requestedAt.timeIntervalSince1970 >= callStartedAt - 5
                && $0.requestedAt.timeIntervalSince1970 <= callStartedAt + 120
        }
    }

    func claimHandoff(_ id: Int, callIDs: [String]) {
        for callID in callIDs where handoffClaims[callID] == nil {
            handoffClaims[callID] = id
        }
    }

    func openCardAppeared() {
        visibleOpenCards += 1
    }

    func openCardDisappeared() {
        visibleOpenCards = max(0, visibleOpenCards - 1)
    }

    func handoffCardAppeared() {
        visibleHandoffCards += 1
    }

    func handoffCardDisappeared() {
        visibleHandoffCards = max(0, visibleHandoffCards - 1)
    }

    func openHandoff(_ id: Int) async {
        guard let index = handoffs.firstIndex(where: { $0.id == id }), handoffs[index].outcome == .pending else { return }
        countdown?.cancel()
        handoffs[index].outcome = .opened
        await open(handoffs[index].request)
    }

    func stay(_ id: Int) {
        guard let index = handoffs.firstIndex(where: { $0.id == id }), handoffs[index].outcome == .pending else { return }
        countdown?.cancel()
        handoffs[index].outcome = .stayed
    }

    private func receiveOpen(_ event: AppsEvent) {
        guard let appID = event.app else { return }
        let requestedAt = event.at.flatMap(BuildProgress.parseDate) ?? .now
        guard Date.now.timeIntervalSince(requestedAt) < Self.handoffFreshness else { return }
        // A newer request replaces one still counting down.
        countdown?.cancel()
        for index in handoffs.indices where handoffs[index].outcome == .pending {
            handoffs[index].outcome = .stayed
        }
        let isInstalled = entries.first { $0.id == appID }?.isInstalled == true
        let autoOpens = isInstalled && !backend.isVoiceOverRunning()
        var handoff = Handoff(
            id: event.seq,
            appID: appID,
            route: event.route ?? "",
            highlight: event.highlight ?? [],
            note: event.note,
            preview: event.preview ?? [],
            requestedAt: requestedAt,
            opensAt: autoOpens ? Date.now.addingTimeInterval(handoffCountdown) : nil
        )
        if appID == runningAppID {
            handoff.outcome = .alreadyOpen
            onRunningAppEvent?(event)
        }
        handoffs = Array((handoffs + [handoff]).suffix(20))
        guard handoff.outcome == .pending, autoOpens else { return }
        let id = handoff.id
        let seconds = handoffCountdown
        countdown = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.openHandoff(id)
        }
    }

    // MARK: - Events

    /// Follows the Mac's events while the Apps tab or an app is on screen.
    func watchEvents() async {
        while !Task.isCancelled {
            await pollEvents()
            try? await Task.sleep(for: status == .ready ? .seconds(2) : .seconds(10))
        }
    }

    /// One poll: a finished build reloads the registry (and installs it if it
    /// is an update); a data change reaches the open app.
    func pollEvents() async {
        do {
            // The first poll reads the day's history only to catch up on builds.
            let page = try await backend.events(cursor ?? 0)
            let isFirstPoll = cursor == nil
            cursor = page.events.last?.seq ?? page.last
            for event in page.events where event.kind == "build" || event.kind == "ready" {
                apply(buildEvent: event)
            }
            if status != .ready {
                await reload()
            }
            guard !isFirstPoll else {
                // A chat's opening card can start the first poll; its request is fresh.
                for event in page.events where event.kind == "open" {
                    receiveOpen(event)
                }
                return
            }
            var needsReload = false
            for event in page.events {
                switch event.kind {
                case "ready":
                    needsReload = true
                case "refresh" where event.app == runningAppID:
                    onRunningAppEvent?(event)
                case "open":
                    receiveOpen(event)
                default:
                    break
                }
            }
            if needsReload { await reload() }
        } catch {
            status = Self.status(for: error)
        }
    }

    private func apply(buildEvent event: AppsEvent) {
        guard let appID = event.app, let version = event.version else { return }
        var progress = builds[appID] ?? BuildProgress(version: version, isNew: event.isNew ?? false)
        if version != progress.version || (event.step == "check" && event.state == "running") {
            // A new attempt starts over.
            progress = BuildProgress(version: version, isNew: event.isNew ?? false)
        }
        let at = event.at.flatMap(BuildProgress.parseDate)
        if event.kind == "ready" {
            progress.isReady = true
            progress.failure = nil
        } else if let step = event.step, let state = event.state {
            progress.steps[step] = state
            if step == "build" && state == "running" { progress.compileStartedAt = at }
            if step == "build" && state == "done" { progress.compileFinishedAt = at }
            if state == "failed" || state == "cancelled" {
                progress.failure = state == "cancelled" ? .cancelled : .failed(event.detail ?? "")
            }
            if step == "package" && state == "done" { progress.packageDetail = event.detail }
        }
        builds[appID] = progress
    }

    private static func status(for error: Error) -> Status {
        switch error as? AppsServiceError {
        case .needsAccess: .needsAccess
        case .notSetUp: .notSetUp
        case .serviceDown: .serviceDown
        default: .failed(error.localizedDescription)
        }
    }
}

/// One app's latest build as the Mac reported it.
struct BuildProgress: Equatable {
    enum Failure: Equatable {
        case failed(String)
        case cancelled
    }

    let version: Int
    let isNew: Bool
    /// "check", "build", "package" → "running", "done", "failed", "cancelled".
    var steps: [String: String] = [:]
    var compileStartedAt: Date?
    var compileFinishedAt: Date?
    var packageDetail: String?
    var failure: Failure?
    var isReady = false

    var isRunning: Bool {
        !isReady && failure == nil && steps.values.contains("running")
    }

    static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

/// What the library needs from the Mac and the container; tests replace it.
struct AppLibraryBackend {
    var registry: @Sendable () async throws -> AppsRegistry
    var download: @Sendable (RemoteApp.IPA, String, @escaping @Sendable (Double) -> Void) async throws -> URL
    var events: @Sendable (Int) async throws -> AppsEventPage
    var allowAccess: @Sendable () async throws -> Void
    var cancelBuild: @Sendable (String) async throws -> Void = { _ in }
    var installedApps: @MainActor () -> [LCHostApp]
    var installIPA: @MainActor (URL) async throws -> LCHostApp
    var removeApp: @MainActor (LCHostApp) throws -> Void
    var samples: @MainActor () -> [HermexApp]
    var isVoiceOverRunning: @MainActor () -> Bool = { UIAccessibility.isVoiceOverRunning }

    static func live(_ service: AppsService) -> AppLibraryBackend {
        AppLibraryBackend(
            registry: { try await service.registry() },
            download: { ipa, appID, progress in try await service.downloadIPA(ipa, appID: appID, progress: progress) },
            events: { try await service.events(after: $0) },
            allowAccess: { try await service.allowAccess() },
            cancelBuild: { try await service.cancelBuild(appID: $0) },
            installedApps: { LCHostRuntime.installedApps() },
            installIPA: { try await LCHostRuntime.installIPA(at: $0) },
            removeApp: { try LCHostRuntime.removeApp($0) },
            samples: { AppRegistry.sampleRecords() }
        )
    }

    /// No Mac: only what is installed (and Debug samples).
    static var offline: AppLibraryBackend {
        AppLibraryBackend(
            registry: { throw AppsServiceError.notSetUp },
            download: { _, _, _ in throw AppsServiceError.notSetUp },
            events: { _ in throw AppsServiceError.notSetUp },
            allowAccess: { throw AppsServiceError.notSetUp },
            installedApps: { LCHostRuntime.installedApps() },
            installIPA: { try await LCHostRuntime.installIPA(at: $0) },
            removeApp: { try LCHostRuntime.removeApp($0) },
            samples: { AppRegistry.sampleRecords() }
        )
    }
}
