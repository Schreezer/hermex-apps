import SwiftUI
import HermexAppKit
import LiveContainerSwiftUI

/// Screen 07: a built app full screen in its own style under a thin Hermex
/// bar, with the floating Hermes button. The app's data calls go to the Mac
/// through `bridge`, and Hermes' changes to its data refresh it.
struct RunningAppView: View {
    let entry: HermexAppEntry
    let hostApp: LCHostApp
    let library: AppLibrary
    let showDetails: () -> Void
    let close: () -> Void

    @State private var launch = UUID()
    @State private var errorMessage: String?
    /// Installing a newer build: the app is stopped meanwhile.
    @State private var isUpdating = false
    @State private var updateError: String?
    /// The app's HermexAppKit connection; one per screen, reused across restarts.
    @State private var bridge = GuestBridge()
    @State private var buttonPlacement: AgentButtonPlacement
    @State private var isShowingChat = false
    /// The app's thread with Hermes; kept while the app is open.
    @State private var chatModel: InAppChatModel
    private let service: AppsService
    #if DEBUG
    @State private var isShowingBridgeInspector = false
    #endif

    private typealias Theme = HermexAppsTheme

    init(
        entry: HermexAppEntry,
        hostApp: LCHostApp,
        library: AppLibrary,
        server: URL,
        showDetails: @escaping () -> Void,
        close: @escaping () -> Void
    ) {
        self.entry = entry
        self.hostApp = hostApp
        self.library = library
        service = AppsService(server: server)
        self.showDetails = showDetails
        self.close = close
        _buttonPlacement = State(initialValue: AgentButtonPlacement.load(appID: entry.app.id))
        _chatModel = State(initialValue: InAppChatModel(server: server, app: entry.app))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if library.updatesWaitingForRestart.contains(entry.app.id) && !isUpdating {
                    Button { Task { await applyUpdate() } } label: {
                        Text("Restart to update")
                            .font(Theme.body(13, weight: .semibold, relativeTo: .footnote))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 28)
                            .background(Theme.accent, in: Capsule())
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Installs the new version Hermes built and reopens the app"))
                } else {
                    Text(entry.app.name)
                        .font(Theme.body(13, weight: .medium, relativeTo: .footnote))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .padding(.horizontal, 100)
                }
                HStack {
                    Button(action: close) {
                        HStack(spacing: 2) {
                            Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                            Text("Apps").font(Theme.body(13, relativeTo: .footnote))
                        }
                        .frame(minHeight: 44)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("Back to Apps"))
                    Spacer()
                    Menu {
                        Button(action: showDetails) { Label("App details", systemImage: "info.circle") }
                        Button { launch = UUID() } label: { Label("Restart app", systemImage: "arrow.clockwise") }
                        if buttonPlacement.isTucked {
                            Button { buttonPlacement.isTucked = false } label: {
                                Label("Show agent button", systemImage: "rectangle.portrait.and.arrow.forward")
                            }
                        }
                        #if DEBUG
                        Button { isShowingBridgeInspector = true } label: {
                            Label { Text(verbatim: "Bridge inspector") } icon: { Image(systemName: "point.3.connected.trianglepath.dotted") }
                        }
                        #endif
                        Button(role: .destructive, action: close) { Label("Close app", systemImage: "xmark") }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("App options"))
                    .foregroundStyle(Theme.muted)
                }
                .foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 8)

            Group {
                if isUpdating {
                    VStack(spacing: 12) {
                        ProgressView().tint(Theme.muted)
                        Text("Updating \(entry.app.name)…")
                            .font(Theme.body(14, relativeTo: .subheadline))
                            .foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.surface)
                } else {
                    ContainerAppHost(hostApp: hostApp, launchInfo: bridge.launchInfo, onExit: close) { error in
                        errorMessage = error.localizedDescription
                    }
                    .id(launch)
                }
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22))
            .overlay {
                AgentButtonLayer(appName: entry.app.name, placement: $buttonPlacement) {
                    isShowingChat = true
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .background(Theme.background.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .statusBarHidden(false)
        .onAppear(perform: connect)
        .onDisappear {
            chatModel.suspend()
            bridge.invalidate()
            library.runningAppID = nil
            library.onRunningAppEvent = nil
            Task { await library.installUpdates() }
        }
        .onChange(of: buttonPlacement) { buttonPlacement.save(appID: entry.app.id) }
        .sheet(isPresented: $isShowingChat) {
            InAppChatSheet(model: chatModel, bridge: bridge, openFullChat: openFullChat) {
                isShowingChat = false
            }
            .presentationDetents([.height(520), .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(26)
            .presentationBackground(Color(hex: 0x111315))
        }
        #if DEBUG
        .sheet(isPresented: $isShowingBridgeInspector) {
            BridgeInspector(bridge: bridge)
                .presentationDetents([.medium, .large])
        }
        #endif
        .alert(Text("Couldn't update \(entry.app.name)"), isPresented: Binding(
            get: { updateError != nil },
            set: { if !$0 { updateError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: updateError ?? "")
        }
        .alert(Text("Couldn't open \(entry.app.name)"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil; close() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: errorMessage ?? "")
        }
    }
}

extension RunningAppView {
    /// Marks this app as the open one and routes its data calls and Hermes'
    /// changes. Calls reach only this app's own tools.
    fileprivate func connect() {
        let appID = entry.app.id
        let service = service
        let bridge = bridge
        library.runningAppID = appID
        library.onRunningAppEvent = { event in
            Task {
                await bridge.refresh(event.route)
                if let ids = event.highlight, !ids.isEmpty {
                    await bridge.highlight(ids)
                }
            }
        }
        bridge.apiHandler = { tool, arguments in
            do {
                let result = try await service.call(appID: appID, tool: tool, arguments: arguments)
                return HermexAPIReply(result: result, error: nil, offline: false)
            } catch let error as AppsServiceError {
                return HermexAPIReply(result: nil, error: error.localizedDescription, offline: error.isOffline)
            } catch let error as APIError {
                if case .network = error {
                    return HermexAPIReply(result: nil, error: error.localizedDescription, offline: true)
                }
                return HermexAPIReply(result: nil, error: error.localizedDescription, offline: false)
            } catch {
                return HermexAPIReply(result: nil, error: error.localizedDescription, offline: false)
            }
        }
    }

    /// Stops the app, installs the build Hermes just made, and reopens it.
    fileprivate func applyUpdate() async {
        isUpdating = true
        // Removing the app's view terminates it; give the process a moment to go.
        try? await Task.sleep(for: .milliseconds(500))
        if !(await library.installWaitingUpdate(for: entry.app.id)) {
            updateError = library.installFailure?.message
            library.installFailure = nil
        }
        launch = UUID()
        isUpdating = false
    }

    /// Hands the in-app thread to the Chats tab and closes the app.
    fileprivate func openFullChat(_ sessionID: String) {
        chatModel.suspend()
        isShowingChat = false
        AppIntentRouter.shared.requestDeepLink(HermesDeepLink.sessionURL(sessionID: sessionID))
        close()
    }
}

/// Hosts the runtime's guest view controller. Dismissing the view terminates the guest.
struct ContainerAppHost: UIViewControllerRepresentable {
    let hostApp: LCHostApp
    var launchInfo: [String: Any] = [:]
    let onExit: () -> Void
    let onError: (Error) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        do {
            return try LCHostRuntime.makeAppViewController(for: hostApp, launchInfo: launchInfo, onExit: onExit, onError: onError)
        } catch {
            DispatchQueue.main.async { onError(error) }
            return UIViewController()
        }
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

/// The app's rounded icon tile, in its own colors.
struct AppIconTile: View {
    let app: HermexApp
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(hex: app.color))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: app.symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(Color(hex: app.ink))
            }
            .accessibilityHidden(true)
    }
}

extension HermexApp {
    /// "today", "yesterday", a weekday within the week, otherwise a short date.
    var updatedLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(updatedAt) { return String(localized: "today") }
        if calendar.isDateInYesterday(updatedAt) { return String(localized: "yesterday") }
        if let days = calendar.dateComponents([.day], from: updatedAt, to: .now).day, days < 7 {
            return updatedAt.formatted(.dateTime.weekday(.abbreviated))
        }
        return updatedAt.formatted(.dateTime.month(.abbreviated).day())
    }
}

#if DEBUG
/// Debug-only view of one app's bridge: what it registered and reports, and
/// buttons for each host-to-app call. Copy is verbatim because it never ships.
private struct BridgeInspector: View {
    let bridge: GuestBridge
    @State private var lastResult = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent { Text(verbatim: bridge.isConnected ? "Connected" : "Waiting") } label: { Text(verbatim: "Bridge") }
                    if let registration = bridge.registration {
                        LabeledContent { Text(verbatim: "\(registration.bundleIdentifier) · \(registration.version)") } label: { Text(verbatim: "App") }
                    }
                    if !lastResult.isEmpty {
                        Text(verbatim: lastResult).font(.caption.monospaced()).accessibilityIdentifier("bridge.lastResult")
                    }
                }
                Section {
                    ForEach(bridge.registration?.routes ?? [], id: \.self) { route in
                        Button {
                            Task { lastResult = "open \(route) → \(await bridge.open(route))" }
                        } label: { Text(verbatim: route).font(.body.monospaced()) }
                    }
                } header: { Text(verbatim: "Routes · tap to open") }
                Section {
                    if let context = bridge.context {
                        LabeledContent { Text(verbatim: context.route).font(.body.monospaced()) } label: { Text(verbatim: "Route") }
                        LabeledContent { Text(verbatim: context.breadcrumb.joined(separator: " › ")) } label: { Text(verbatim: "Sees") }
                        ForEach(context.entities, id: \.self) { entity in
                            Button {
                                Task {
                                    await bridge.highlight([entity.id])
                                    lastResult = "highlight \(entity.id)"
                                }
                            } label: {
                                Text(verbatim: "\(entity.type) · \(entity.title)")
                            }
                        }
                    } else {
                        Text(verbatim: "No context reported yet").foregroundStyle(.secondary)
                    }
                } header: { Text(verbatim: "Context · tap an entity to highlight it") }
                Section {
                    Button {
                        Task {
                            await bridge.refresh()
                            lastResult = "refresh → done"
                        }
                    } label: { Text(verbatim: "Refresh") }
                }
            }
            .navigationTitle(Text(verbatim: "Bridge"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif
