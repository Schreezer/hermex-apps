import SwiftUI
import HermexAppKit

@main
struct __TARGET__App: App {
    @State private var store = Store()
    @State private var router = Router()

    var body: some Scene {
        WindowGroup {
            RootView(store: store, router: router)
                .task {
                    // Every route listed in the app's record (apps_create routes).
                    HermexAppKit.registerRoutes(["home", "item/{id}"])
                    HermexAppKit.onOpen { route in router.open(route, store: store) }
                    HermexAppKit.onRefresh { _ in Task { await store.load() } }
                    await store.load()
                }
        }
    }
}

/// Where the app is. Hermes opens routes through it.
@MainActor
@Observable
final class Router {
    var path: [String] = []

    /// Handles `home` and `item/{id}`.
    func open(_ route: String, store: Store) -> Bool {
        let parts = route.split(separator: "/").map(String.init)
        switch parts.first {
        case "home":
            path = []
        case "item" where parts.count == 2:
            path = [parts[1]]
        default:
            return false
        }
        return true
    }
}
