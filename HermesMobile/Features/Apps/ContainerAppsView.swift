#if DEBUG
import SwiftUI
import LiveContainerSwiftUI

/// Debug-only harness for the embedded LiveContainer runtime: install an IPA
/// from a URL, list installed apps, and open one full screen. The designed
/// Apps tab replaces this; copy here is verbatim because it never ships.
struct ContainerAppsView: View {
    @State private var apps: [LCHostApp] = []
    @State private var ipaURLText = ""
    @State private var isInstalling = false
    @State private var errorMessage: String?
    @State private var runningApp: LCHostApp?

    private var ipaURL: URL? {
        let text = ipaURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme != nil else { return nil }
        return url
    }

    var body: some View {
        List {
            Section {
                TextField(text: $ipaURLText, prompt: Text(verbatim: "http://localhost:8000/App.ipa")) {
                    Text(verbatim: "IPA URL")
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityIdentifier("containerApps.ipaURL")

                Button {
                    Task { await install() }
                } label: {
                    if isInstalling {
                        ProgressView()
                    } else {
                        Text(verbatim: "Install")
                    }
                }
                .disabled(isInstalling || ipaURL == nil)
                .accessibilityIdentifier("containerApps.install")
            } header: {
                Text(verbatim: "Install")
            }

            if let errorMessage {
                Section {
                    Text(verbatim: errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("containerApps.error")
                }
            }

            Section {
                if apps.isEmpty {
                    Text(verbatim: "No apps installed")
                        .foregroundStyle(.secondary)
                }
                ForEach(apps) { app in
                    Button {
                        runningApp = app
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: app.displayName)
                            Text(verbatim: "\(app.bundleIdentifier) · \(app.version)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("containerApps.app.\(app.bundleIdentifier)")
                    .swipeActions {
                        Button(role: .destructive) {
                            remove(app)
                        } label: {
                            Text(verbatim: "Remove")
                        }
                    }
                }
            } header: {
                Text(verbatim: "Installed")
            }
        }
        .navigationTitle(Text(verbatim: "Container Apps"))
        .onAppear {
            apps = LCHostRuntime.installedApps()
            // `SIMCTL_CHILD_HERMEX_DEV_IPA_URL=<url> xcrun simctl launch …`
            // prefills the field, since simulator typing drops characters.
            if ipaURLText.isEmpty, let preset = ProcessInfo.processInfo.environment["HERMEX_DEV_IPA_URL"] {
                ipaURLText = preset
            }
        }
        .fullScreenCover(item: $runningApp) { app in
            ContainerAppScreen(app: app) { runningApp = nil }
        }
    }

    private func install() async {
        guard let ipaURL else { return }
        isInstalling = true
        errorMessage = nil
        defer { isInstalling = false }
        do {
            let localURL: URL
            if ipaURL.isFileURL {
                localURL = ipaURL
            } else {
                let (downloaded, response) = try await URLSession.shared.download(from: ipaURL)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw LCHostError(message: "Download failed with HTTP \(http.statusCode).")
                }
                localURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ipa")
                try FileManager.default.moveItem(at: downloaded, to: localURL)
            }
            defer {
                if !ipaURL.isFileURL { try? FileManager.default.removeItem(at: localURL) }
            }
            _ = try await LCHostRuntime.installIPA(at: localURL)
            apps = LCHostRuntime.installedApps()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ app: LCHostApp) {
        do {
            try LCHostRuntime.removeApp(app)
        } catch {
            errorMessage = error.localizedDescription
        }
        apps = LCHostRuntime.installedApps()
    }
}

/// Runs one guest edge to edge with a small way back.
private struct ContainerAppScreen: View {
    let app: LCHostApp
    let close: () -> Void
    @State private var errorMessage: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ContainerAppHost(app: app, onExit: close) { error in
                errorMessage = error.localizedDescription
            }
            .ignoresSafeArea()

            Button(action: close) {
                Label {
                    Text(verbatim: "Apps")
                } icon: {
                    Image(systemName: "chevron.left")
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(.leading, 12)
            .accessibilityIdentifier("containerApps.close")
        }
        .alert(Text(verbatim: "Couldn't run \(app.displayName)"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil; close() } }
        )) {
            Button(role: .cancel) {} label: { Text(verbatim: "OK") }
        } message: {
            Text(verbatim: errorMessage ?? "")
        }
    }
}

private struct ContainerAppHost: UIViewControllerRepresentable {
    let app: LCHostApp
    let onExit: () -> Void
    let onError: (Error) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        do {
            return try LCHostRuntime.makeAppViewController(for: app, onExit: onExit, onError: onError)
        } catch {
            DispatchQueue.main.async { onError(error) }
            return UIViewController()
        }
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}
#endif
