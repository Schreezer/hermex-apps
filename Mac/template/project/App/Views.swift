import SwiftUI
import HermexAppKit

struct RootView: View {
    let store: Store
    @Bindable var router: Router

    var body: some View {
        NavigationStack(path: $router.path) {
            HomeView(store: store)
                .navigationDestination(for: String.self) { id in
                    if let item = store.items.first(where: { $0.id == id }) {
                        ItemView(item: item)
                    }
                }
        }
    }
}

struct HomeView: View {
    let store: Store
    @State private var draft = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("New item", text: $draft)
                        .submitLabel(.done)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section {
                ForEach(store.items) { item in
                    HStack {
                        Button {
                            Task { await store.toggle(item) }
                        } label: {
                            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                .imageScale(.large)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.done ? "Mark not done" : "Mark done")
                        NavigationLink(value: item.id) {
                            Text(item.title).strikethrough(item.done)
                        }
                    }
                    .hermexHighlight(id: item.id, cornerRadius: 8)
                }
            }
            if let error = store.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .navigationTitle("__APP_NAME__")
        .overlay {
            if store.isLoaded && store.items.isEmpty && store.error == nil {
                ContentUnavailableView("Nothing yet", systemImage: "tray", description: Text("Add an item, or ask Hermes."))
            }
        }
        .onAppear(perform: report)
        .onChange(of: store.items) { report() }
    }

    private func add() {
        let title = draft.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        draft = ""
        Task { await store.add(title) }
    }

    /// Tells Hermes what is on screen, for the in-app chat.
    private func report() {
        HermexAppKit.reportContext(
            route: "home",
            breadcrumb: ["Home"],
            entities: store.items.prefix(20).map { HermexEntity(type: "item", id: $0.id, title: $0.title) }
        )
    }
}

struct ItemView: View {
    let item: Item

    var body: some View {
        List {
            LabeledContent("Status", value: item.done ? "Done" : "Not done")
        }
        .navigationTitle(item.title)
        .onAppear {
            HermexAppKit.reportContext(
                route: "item/\(item.id)",
                breadcrumb: ["Home", item.title],
                entities: [HermexEntity(type: "item", id: item.id, title: item.title)]
            )
        }
    }
}
