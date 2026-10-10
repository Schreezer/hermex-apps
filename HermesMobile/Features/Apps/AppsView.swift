import SwiftUI

/// Screen 05: the apps Hermes built for this user.
struct AppsView: View {
    let library: AppLibrary
    let server: URL
    /// Starts a chat with Hermes from this draft.
    let askHermes: (String) -> Void

    @State private var query = ""
    @State private var path: [String] = []
    @State private var running: HermexAppEntry?
    /// What the running app was opened for: a route, highlights, Hermes' banner.
    @State private var opened: AppLibrary.OpenRequest?
    @State private var isVisible = false

    private typealias Theme = HermexAppsTheme

    private var filtered: [HermexAppEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return library.entries }
        return library.entries.filter {
            $0.app.name.localizedCaseInsensitiveContains(trimmed) || $0.app.tagline.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    statusCard
                    searchField
                    let featured = query.isEmpty ? library.justBuilt : nil
                    if let featured {
                        featuredCard(featured)
                    }
                    VStack(spacing: 0) {
                        ForEach(filtered.filter { $0.id != featured?.id }) { entry in
                            row(entry)
                        }
                    }
                    askCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await library.reload() }
            .background(Theme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { id in
                if let entry = library.entries.first(where: { $0.id == id }) {
                    AppDetailView(
                        entry: entry,
                        open: {
                            opened = nil
                            running = entry
                        },
                        install: { Task { await library.install(entry) } },
                        installProgress: library.installing[entry.id],
                        askForChange: { askHermes(String(localized: "Change \(entry.app.name): ")) },
                        remove: {
                            try library.remove(entry)
                            path.removeAll()
                        }
                    )
                }
            }
        }
        .tint(Theme.text)
        .environment(\.colorScheme, .dark)
        .task { await library.reload() }
        // The Apps tab stays alive behind Chats; it runs a requested app only
        // once it is on screen, where its full-screen cover can present.
        .onAppear {
            isVisible = true
            openRequestedApp()
        }
        .onDisappear { isVisible = false }
        .onChange(of: library.openRequest) { if isVisible || running != nil { openRequestedApp() } }
        .alert(Text("Couldn't install the app"), isPresented: Binding(
            get: { library.installFailure != nil && running == nil },
            set: { if !$0 { library.installFailure = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: library.installFailure?.message ?? "")
        }
        .fullScreenCover(item: $running) { entry in
            if let hostApp = library.hostApp(for: entry) {
                RunningAppView(
                    entry: entry,
                    hostApp: hostApp,
                    library: library,
                    server: server,
                    opened: opened?.appID == entry.id ? opened : nil,
                    showDetails: {
                        running = nil
                        path = [entry.id]
                    },
                    close: { running = nil },
                    backToChat: {
                        running = nil
                        library.chatRequest = UUID()
                    }
                )
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Apps")
                .font(Theme.display(32, relativeTo: .largeTitle))
                .tracking(-0.6)
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
            Text("\(library.entries.count) built for you by Hermes")
                .font(Theme.body(14, relativeTo: .subheadline))
                .foregroundStyle(Theme.muted)
        }
        .padding(.top, 8)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.muted)
                .accessibilityHidden(true)
            TextField("Search your apps", text: $query)
                .font(Theme.body(15))
                .foregroundStyle(Theme.text)
                .autocorrectionDisabled()
                .submitLabel(.search)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func featuredCard(_ entry: HermexAppEntry) -> some View {
        let app = entry.app
        return VStack(alignment: .leading, spacing: 14) {
            Text("Just built · \(app.builtAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))")
                .font(Theme.mono(11, relativeTo: .caption2))
                .textCase(.uppercase)
                .tracking(0.9)
                .foregroundStyle(Color(hex: app.color, over: 0xF3F2ED, amount: 0.55))
            Button { path = [entry.id] } label: {
                HStack(spacing: 14) {
                    AppIconTile(app: app, size: 64, cornerRadius: 17)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: app.name)
                            .font(Theme.display(20, relativeTo: .title3))
                            .foregroundStyle(Theme.text)
                        Text(verbatim: app.summary)
                            .font(Theme.body(13, relativeTo: .footnote))
                            .foregroundStyle(Color(hex: app.color, over: 0xF3F2ED, amount: 0.25))
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Shows app details"))
            Button { perform(entry) } label: {
                actionLabel(for: entry)
                    .font(Theme.body(15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(Color(hex: app.ink))
                    .background(Color(hex: app.color), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!isActionable(entry))
            .opacity(isActionable(entry) ? 1 : 0.5)
            .accessibilityLabel(actionAccessibilityLabel(for: entry))
        }
        .padding(16)
        .background(Color(hex: app.color, over: 0x0B0C0E, amount: 0.07), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color(hex: app.color, over: 0x0B0C0E, amount: 0.2)))
    }

    private func row(_ entry: HermexAppEntry) -> some View {
        let app = entry.app
        return HStack(spacing: 14) {
            Button { path = [entry.id] } label: {
                HStack(spacing: 14) {
                    AppIconTile(app: app, size: 52, cornerRadius: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: app.name)
                            .font(Theme.body(16, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text(verbatim: "\(app.tagline) · v\(app.version) · \(app.updatedLabel)")
                            .font(Theme.body(13, relativeTo: .footnote))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Shows app details"))
            Button { perform(entry) } label: {
                actionLabel(for: entry)
                    .font(Theme.body(14, weight: .semibold, relativeTo: .subheadline))
                    .foregroundStyle(Theme.accent)
                    .frame(minWidth: 64, minHeight: 32)
                    .padding(.horizontal, 4)
                    .background(Theme.surface2, in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isActionable(entry))
            .opacity(isActionable(entry) ? 1 : 0.4)
            .accessibilityLabel(actionAccessibilityLabel(for: entry))
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Theme.surface2.frame(height: 1) }
    }

    // MARK: - Install, open

    /// Runs the app a card in chat or Hermes asked for, in place of any other
    /// app that is open.
    private func openRequestedApp() {
        guard let request = library.openRequest else { return }
        library.openRequest = nil
        guard let entry = library.entries.first(where: { $0.id == request.appID }), entry.isInstalled else { return }
        path.removeAll()
        guard let current = running, current.id != entry.id else {
            opened = request
            running = entry
            return
        }
        // Close the open app first; one full-screen cover replaces another.
        running = nil
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            opened = request
            running = entry
        }
    }

    private enum Action {
        case open
        case install
        case installing(Double)
        case unavailable
    }

    private func action(for entry: HermexAppEntry) -> Action {
        if let progress = library.installing[entry.id] { return .installing(progress) }
        if entry.isInstalled { return .open }
        if entry.downloadFitsThisDevice { return .install }
        return .unavailable
    }

    private func isActionable(_ entry: HermexAppEntry) -> Bool {
        switch action(for: entry) {
        case .open, .install: true
        case .installing, .unavailable: false
        }
    }

    /// Open runs the app; Install is the user's OK for a new app (updates install by themselves).
    private func perform(_ entry: HermexAppEntry) {
        switch action(for: entry) {
        case .open:
            opened = nil
            running = entry
        case .install: Task { await library.install(entry) }
        case .installing, .unavailable: break
        }
    }

    @ViewBuilder
    private func actionLabel(for entry: HermexAppEntry) -> some View {
        switch action(for: entry) {
        case .open: Text("Open")
        case .install: Text("Install")
        case .installing(let progress): Text(progress, format: .percent.precision(.fractionLength(0)))
        case .unavailable: Text("Not installed")
        }
    }

    private func actionAccessibilityLabel(for entry: HermexAppEntry) -> Text {
        let name = entry.app.name
        switch action(for: entry) {
        case .open: return Text("Open \(name)")
        case .install: return Text("Install \(name)")
        case .installing: return Text("Installing \(name)")
        case .unavailable: return Text("\(name) is not installed")
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusCard: some View {
        switch library.status {
        case .loading, .ready:
            EmptyView()
        case .needsAccess:
            statusCard(
                title: Text("Connect to your Mac"),
                message: Text("Hermes builds your apps on your Mac and keeps their data there. Allow Hermex to install them and sync their data through your Hermes server."),
                button: Text("Allow")
            ) { await library.allowAccess() }
        case .notSetUp:
            statusCard(
                title: Text("Set up Hermex Apps on your Mac"),
                message: Text("Your Hermes server doesn't have the Hermex Apps extension yet. Add it on your Mac, then try again."),
                button: Text("Try again")
            ) { await library.reload() }
        case .serviceDown:
            statusCard(
                title: Text("Hermex Apps isn't running on your Mac"),
                message: Text("Start the Hermex Apps service on your Mac, then try again."),
                button: Text("Try again")
            ) { await library.reload() }
        case .failed(let message):
            statusCard(
                title: Text("Couldn't load your apps"),
                message: Text(verbatim: message),
                button: Text("Try again")
            ) { await library.reload() }
        }
    }

    private func statusCard(title: Text, message: Text, button: Text, action: @escaping () async -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            title
                .font(Theme.body(15, weight: .semibold))
                .foregroundStyle(Theme.text)
            message
                .font(Theme.body(13, relativeTo: .footnote))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button { Task { await action() } } label: {
                button
                    .font(Theme.body(14, weight: .semibold, relativeTo: .subheadline))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 36)
                    .background(Theme.accent, in: Capsule())
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line))
        .accessibilityElement(children: .contain)
    }

    private var askCard: some View {
        Button { askHermes(String(localized: "Build me an app ")) } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Ask Hermes for a new app")
                    .font(Theme.body(15, weight: .medium))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color(hex: 0x3A3F46), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
