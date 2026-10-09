import SwiftUI
import HermexAppKit
import LiveContainerSwiftUI

/// Screen 07: a built app full screen in its own style under a thin Hermex
/// bar. The floating Hermes button joins in build step 5.
struct RunningAppView: View {
    let entry: HermexAppEntry
    let hostApp: LCHostApp
    let showDetails: () -> Void
    let close: () -> Void

    @State private var launch = UUID()
    @State private var errorMessage: String?
    /// The app's HermexAppKit connection; one per screen, reused across restarts.
    @State private var bridge = GuestBridge()
    #if DEBUG
    @State private var isShowingBridgeInspector = false
    #endif

    private typealias Theme = HermexAppsTheme

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(entry.app.name)
                    .font(Theme.body(13, weight: .medium, relativeTo: .footnote))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 100)
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

            ContainerAppHost(hostApp: hostApp, launchInfo: bridge.launchInfo, onExit: close) { error in
                errorMessage = error.localizedDescription
            }
            .id(launch)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22))
            .ignoresSafeArea(edges: .bottom)
        }
        .background(Theme.background.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .statusBarHidden(false)
        .onDisappear { bridge.invalidate() }
        #if DEBUG
        .sheet(isPresented: $isShowingBridgeInspector) {
            BridgeInspector(bridge: bridge)
                .presentationDetents([.medium, .large])
        }
        #endif
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
