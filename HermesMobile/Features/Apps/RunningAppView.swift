import SwiftUI
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

            ContainerAppHost(hostApp: hostApp, onExit: close) { error in
                errorMessage = error.localizedDescription
            }
            .id(launch)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22))
            .ignoresSafeArea(edges: .bottom)
        }
        .background(Theme.background.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .statusBarHidden(false)
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
    let onExit: () -> Void
    let onError: (Error) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        do {
            return try LCHostRuntime.makeAppViewController(for: hostApp, onExit: onExit, onError: onError)
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
