import SwiftUI
import HermexAppKit

@main
struct LiftLogApp: App {
    @State private var store = LiftStore()
    @State private var router = Router()

    var body: some Scene {
        WindowGroup {
            RootView(store: store, router: router)
                .task {
                    HermexAppKit.registerRoutes(["today", "history", "lift/{id}"])
                    HermexAppKit.onOpen { route in router.open(route, store: store) }
                    HermexAppKit.onRefresh { _ in store.reload() }
                }
        }
    }
}

/// Where the app is; also what it reports to Hermes.
@MainActor
@Observable
final class Router {
    enum Tab: Hashable { case today, history }
    var tab = Tab.today
    var path: [String] = []

    /// Handles a Hermes route: `today`, `history` or `lift/{id}`.
    func open(_ route: String, store: LiftStore) -> Bool {
        let parts = route.split(separator: "/").map(String.init)
        switch parts.first {
        case "today":
            tab = .today
            path = []
        case "history":
            tab = .history
        case "lift" where parts.count == 2 && store.lift(id: parts[1]) != nil:
            tab = .today
            path = [parts[1]]
        default:
            return false
        }
        return true
    }
}

private enum Palette {
    static let paper = Color(red: 0xF6 / 255, green: 0xF1 / 255, blue: 0xEA / 255)
    static let ink = Color(red: 0x24 / 255, green: 0x1A / 255, blue: 0x14 / 255)
    static let rust = Color(red: 0xB4 / 255, green: 0x50 / 255, blue: 0x1F / 255)
    static let soft = Color(red: 0x6B / 255, green: 0x5A / 255, blue: 0x4E / 255)
    static let rule = Color(red: 0xD9 / 255, green: 0xC9 / 255, blue: 0xBA / 255)
}

struct RootView: View {
    let store: LiftStore
    @Bindable var router: Router

    var body: some View {
        TabView(selection: $router.tab) {
            NavigationStack(path: $router.path) {
                TodayView(store: store)
                    .navigationDestination(for: String.self) { id in
                        if let lift = store.lift(id: id) { LiftView(store: store, lift: lift) }
                    }
            }
            .tabItem { Label("Today", systemImage: "dumbbell") }
            .tag(Router.Tab.today)

            HistoryView(store: store)
                .tabItem { Label("History", systemImage: "calendar") }
                .tag(Router.Tab.history)
        }
        .tint(Palette.rust)
    }
}

struct TodayView: View {
    let store: LiftStore

    var body: some View {
        let session = store.data.today
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.day.uppercased())
                        .font(.footnote.weight(.semibold)).tracking(1).foregroundStyle(Palette.rust)
                    Text(session.title)
                        .font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(Palette.ink)
                    Text("\(session.lifts.count) lifts · \(session.setsDone) of \(session.setCount) sets done")
                        .font(.subheadline).foregroundStyle(Palette.soft)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
                ForEach(session.lifts) { lift in
                    LiftCard(store: store, lift: lift)
                }
            }
            .padding(16)
        }
        .background(Palette.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { report(session) }
        .onChange(of: store.data.today) { report(store.data.today) }
    }

    private func report(_ session: Session) {
        HermexAppKit.reportContext(
            route: "today",
            breadcrumb: ["Today", session.title],
            entities: [HermexEntity(type: "session", id: session.id, title: session.title)]
                + session.lifts.map { HermexEntity(type: "lift", id: $0.id, title: $0.name) }
        )
    }
}

struct LiftCard: View {
    let store: LiftStore
    let lift: Lift

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: lift.id) {
                HStack(alignment: .firstTextBaseline) {
                    Text(lift.name).font(.headline).foregroundStyle(Palette.ink)
                    Spacer()
                    Text("last \(lift.last)").font(.footnote).foregroundStyle(Palette.soft)
                }
            }
            HStack(spacing: 8) {
                ForEach(lift.sets) { set in
                    Button { store.toggle(set, in: lift) } label: {
                        Text(set.label)
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(set.done ? .white : Palette.soft)
                            .background(set.done ? Palette.rust : .clear, in: RoundedRectangle(cornerRadius: 12))
                            .overlay {
                                if !set.done {
                                    RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.rule, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(lift.name), \(set.label)")
                    .accessibilityValue(set.done ? "Done" : "Not done")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.white, in: RoundedRectangle(cornerRadius: 18))
        .hermexHighlight(id: lift.id)
    }
}

struct LiftView: View {
    let store: LiftStore
    let lift: Lift

    var body: some View {
        List {
            Section("Last time") { Text(lift.last) }
            Section("Today") {
                ForEach(lift.sets) { set in
                    LabeledContent(set.label) { Image(systemName: set.done ? "checkmark.circle.fill" : "circle") }
                }
            }
        }
        .navigationTitle(lift.name)
        .onAppear {
            HermexAppKit.reportContext(
                route: "lift/\(lift.id)",
                breadcrumb: ["Today", store.data.today.title, lift.name],
                entities: [HermexEntity(type: "lift", id: lift.id, title: lift.name)]
            )
        }
    }
}

struct HistoryView: View {
    let store: LiftStore

    var body: some View {
        NavigationStack {
            List(store.data.history) { session in
                VStack(alignment: .leading) {
                    Text(session.title).font(.headline)
                    Text(session.day).font(.footnote).foregroundStyle(.secondary)
                }
                .hermexHighlight(id: session.id, cornerRadius: 8)
            }
            .navigationTitle("History")
        }
        .onAppear {
            HermexAppKit.reportContext(
                route: "history",
                breadcrumb: ["History"],
                entities: store.data.history.map { HermexEntity(type: "session", id: $0.id, title: $0.title) }
            )
        }
    }
}
