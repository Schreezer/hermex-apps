import SwiftUI

/// The signed-in webui home: Chats (the session list) and Apps.
struct HermexHomeTabs<Chats: View>: View {
    enum HomeTab: String {
        case chats
        case apps
    }

    let server: URL
    /// True while a deep link, share, intent or push is routing to a chat;
    /// the home switches to Chats so the route lands where the user can see it.
    let chatsRequested: Bool
    /// Starts a new chat with this draft.
    let askHermes: (String) -> Void
    let chats: Chats

    @SceneStorage("hermexHome.tab") private var tab = HomeTab.chats
    @State private var library: AppLibrary

    init(server: URL, chatsRequested: Bool, askHermes: @escaping (String) -> Void, @ViewBuilder chats: () -> Chats) {
        self.server = server
        self.chatsRequested = chatsRequested
        self.askHermes = askHermes
        self.chats = chats()
        _library = State(initialValue: AppLibrary(server: server))
    }

    private var wantsEvents: Bool {
        tab == .apps || library.runningAppID != nil || library.wantsEventsForCards
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Chats", systemImage: "bubble.left", value: HomeTab.chats) {
                chats
                    // Build cards in chat read the library.
                    .environment(library)
            }
            Tab("Apps", systemImage: "square.grid.2x2", value: HomeTab.apps) {
                AppsView(library: library, server: server) { draft in
                    tab = .chats
                    askHermes(draft)
                }
                .toolbarColorScheme(.dark, for: .tabBar)
                .toolbarBackground(HermexAppsTheme.background, for: .tabBar)
            }
        }
        .onChange(of: chatsRequested) {
            if chatsRequested { tab = .chats }
        }
        // A build card's Open lands in Apps, which runs the app.
        .onChange(of: library.openRequest) {
            if library.openRequest != nil { tab = .apps }
        }
        // Follow the Mac's builds and data changes while apps or build cards are on screen.
        .task(id: wantsEvents) {
            guard wantsEvents else { return }
            await library.watchEvents()
        }
    }
}
