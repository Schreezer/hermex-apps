import Foundation
import Observation
import HermexAppKit

struct Item: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var done: Bool
}

/// The app's data, read from and written to its API on the Mac (server.py).
@MainActor
@Observable
final class Store {
    private(set) var items: [Item] = []
    private(set) var error: String?
    private(set) var isLoaded = false

    func load() async {
        do {
            items = try await HermexAppKit.fetch("items")
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isLoaded = true
    }

    func add(_ title: String) async {
        await change { try await HermexAppKit.perform("add_item", ["title": title]) }
    }

    func toggle(_ item: Item) async {
        // Show the change at once; the reload corrects it if the Mac disagrees.
        if let index = items.firstIndex(of: item) { items[index].done.toggle() }
        await change { try await HermexAppKit.perform("set_done", SetDone(id: item.id, done: !item.done)) }
    }

    private func change(_ work: () async throws -> Void) async {
        do {
            try await work()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await load()
    }
}

private struct SetDone: Encodable {
    let id: String
    let done: Bool
}
