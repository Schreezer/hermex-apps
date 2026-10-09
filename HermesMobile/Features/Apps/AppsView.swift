import SwiftUI

/// Screen 05: the apps Hermes built for this user.
struct AppsView: View {
    let library: AppLibrary
    /// Starts a chat with Hermes from this draft.
    let askHermes: (String) -> Void

    @State private var query = ""
    @State private var path: [String] = []
    @State private var running: HermexAppEntry?

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
            .background(Theme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { id in
                if let entry = library.entries.first(where: { $0.id == id }) {
                    AppDetailView(
                        entry: entry,
                        open: { running = entry },
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
        .onAppear { library.refresh() }
        .fullScreenCover(item: $running) { entry in
            if let hostApp = library.hostApp(for: entry) {
                RunningAppView(
                    entry: entry,
                    hostApp: hostApp,
                    showDetails: {
                        running = nil
                        path = [entry.id]
                    },
                    close: { running = nil }
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
            Button { running = entry } label: {
                Text(entry.isInstalled ? "Open" : "Not installed")
                    .font(Theme.body(15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(Color(hex: app.ink))
                    .background(Color(hex: app.color), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!entry.isInstalled)
            .opacity(entry.isInstalled ? 1 : 0.5)
            .accessibilityLabel(Text(entry.isInstalled ? "Open \(app.name)" : "\(app.name) is not installed"))
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
            Button { running = entry } label: {
                Text("Open")
                    .font(Theme.body(14, weight: .semibold, relativeTo: .subheadline))
                    .foregroundStyle(Theme.accent)
                    .frame(minWidth: 64, minHeight: 32)
                    .background(Theme.surface2, in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!entry.isInstalled)
            .opacity(entry.isInstalled ? 1 : 0.4)
            .accessibilityLabel(Text(entry.isInstalled ? "Open \(app.name)" : "\(app.name) is not installed"))
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Theme.surface2.frame(height: 1) }
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
