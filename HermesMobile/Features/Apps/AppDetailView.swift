import SwiftUI

/// Screen 06: how Hermes works with one app, and how it got here.
struct AppDetailView: View {
    let entry: HermexAppEntry
    let open: () -> Void
    /// Installs the Mac's build; the user's OK for a new app.
    let install: () -> Void
    /// Download progress while installing.
    let installProgress: Double?
    let askForChange: () -> Void
    let remove: () throws -> Void

    @State private var isConfirmingRemove = false
    @State private var removeError: String?

    private typealias Theme = HermexAppsTheme

    private var canAct: Bool {
        installProgress == nil && (entry.isInstalled || entry.downloadFitsThisDevice)
    }

    @ViewBuilder
    private var primaryLabel: some View {
        if let installProgress {
            Text(installProgress, format: .percent.precision(.fractionLength(0)))
        } else if entry.isInstalled {
            Text("Open")
        } else if entry.downloadFitsThisDevice {
            Text("Install")
        } else {
            Text("Not installed")
        }
    }

    var body: some View {
        let app = entry.app
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    AppIconTile(app: app, size: 88, cornerRadius: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: app.name)
                            .font(Theme.display(26, relativeTo: .title))
                            .foregroundStyle(Theme.text)
                            .accessibilityAddTraits(.isHeader)
                        Text(app.origin.map { "\($0) · v\(app.version)" } ?? String(localized: "Built by Hermes for you · v\(app.version)"))
                            .font(Theme.body(13, relativeTo: .footnote))
                            .foregroundStyle(Theme.muted)
                        Button(action: entry.isInstalled ? open : install) {
                            primaryLabel
                                .font(Theme.body(15, weight: .semibold))
                                .foregroundStyle(Color(hex: app.ink))
                                .padding(.horizontal, 22)
                                .frame(minHeight: 36)
                                .background(Color(hex: app.color), in: Capsule())
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canAct)
                        .opacity(canAct ? 1 : 0.5)
                        .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }

                section("How Hermes works with this app") {
                    VStack(spacing: 0) {
                        ForEach(Array(app.capabilities.enumerated()), id: \.offset) { index, capability in
                            capabilityRow(capability)
                                .overlay(alignment: .bottom) {
                                    if index < app.capabilities.count - 1 { Theme.line.frame(height: 1) }
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.line))
                }

                if !app.versions.isEmpty {
                    section("Versions") {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(app.versions, id: \.number) { version in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(verbatim: "v\(version.number)")
                                        .font(Theme.mono(13, relativeTo: .footnote))
                                        .foregroundStyle(version.number == app.version ? Theme.accent : Theme.muted)
                                        .frame(width: 28, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: version.change)
                                            .font(Theme.body(14, relativeTo: .subheadline))
                                            .foregroundStyle(Theme.text)
                                        Text(verbatim: version.reason)
                                            .font(Theme.body(12, relativeTo: .caption))
                                            .foregroundStyle(Theme.faint)
                                    }
                                }
                                .padding(.vertical, 8)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                Button(action: askForChange) {
                    Text("Ask for a change")
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                if entry.isInstalled {
                    Button { isConfirmingRemove = true } label: {
                        Text("Remove")
                            .font(Theme.body(15, weight: .medium))
                            .foregroundStyle(Theme.destructive)
                            .padding(.horizontal, 18)
                            .frame(minHeight: 48)
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .background(Theme.background)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .confirmationDialog(Text("Remove \(app.name)?"), isPresented: $isConfirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                do {
                    try remove()
                } catch {
                    removeError = error.localizedDescription
                }
            }
        } message: {
            if entry.app.download != nil {
                Text("This removes the app from this iPhone. Its data stays on your Mac, and you can install it again from Apps.")
            } else {
                Text("This deletes the app and its data from this iPhone.")
            }
        }
        .alert(Text("Couldn't remove \(app.name)"), isPresented: Binding(
            get: { removeError != nil },
            set: { if !$0 { removeError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: removeError ?? "")
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Theme.body(13, weight: .medium, relativeTo: .footnote))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(Theme.muted)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func capabilityRow(_ capability: HermexApp.Capability) -> some View {
        let isAPI = capability.kind == .api
        return HStack(alignment: .top, spacing: 12) {
            Text(verbatim: capability.kind.rawValue)
                .font(Theme.mono(11, weight: .medium, relativeTo: .caption2))
                .foregroundStyle(isAPI ? Theme.onAccent : Theme.text)
                .frame(minWidth: 38)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(isAPI ? Theme.accent : Theme.surface2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: capability.title)
                    .font(Theme.body(15, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text(verbatim: capability.detail)
                    .font(Theme.mono(12, relativeTo: .caption))
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}
