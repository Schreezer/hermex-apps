import Foundation
import Observation

struct LiftSet: Codable, Identifiable, Hashable {
    let id: String
    let label: String
    var done: Bool
}

struct Lift: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let last: String
    var sets: [LiftSet]
}

struct Session: Codable, Identifiable, Hashable {
    let id: String
    let day: String
    let title: String
    var lifts: [Lift]

    var setsDone: Int { lifts.reduce(0) { $0 + $1.sets.filter(\.done).count } }
    var setCount: Int { lifts.reduce(0) { $0 + $1.sets.count } }
}

struct LiftData: Codable {
    var today: Session
    var history: [Session]
}

/// The app's data, kept in Documents/liftlog.json. In build step 6 the app's
/// MCP server on the Mac owns this data and the app syncs with it; for now the
/// file is the source of truth, and `reload()` is what Hermes' refresh calls.
@MainActor
@Observable
final class LiftStore {
    private(set) var data: LiftData
    private let url: URL

    init(fileManager: FileManager = .default) {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = documents.appendingPathComponent("liftlog.json")
        data = Self.load(from: url) ?? Self.seed
        if !fileManager.fileExists(atPath: url.path) { save() }
    }

    func reload() {
        if let fresh = Self.load(from: url) { data = fresh }
    }

    func toggle(_ set: LiftSet, in lift: Lift) {
        guard let l = data.today.lifts.firstIndex(where: { $0.id == lift.id }),
              let s = data.today.lifts[l].sets.firstIndex(where: { $0.id == set.id }) else { return }
        data.today.lifts[l].sets[s].done.toggle()
        save()
    }

    func lift(id: String) -> Lift? {
        data.today.lifts.first { $0.id == id }
    }

    private func save() {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        try? encoded.write(to: url, options: .atomic)
    }

    private static func load(from url: URL) -> LiftData? {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LiftData.self, from: raw)
    }

    private static func sets(_ label: String) -> [LiftSet] {
        (1...3).map { LiftSet(id: "set-\($0)", label: label, done: false) }
    }

    static let seed = LiftData(
        today: Session(id: "2026-10-07-legs", day: "Tuesday · week 6", title: "Legs", lifts: [
            Lift(id: "back-squat", name: "Back squat", last: "3×5 · 97.5 kg", sets: sets("5 × 100")),
            Lift(id: "romanian-deadlift", name: "Romanian deadlift", last: "3×8 · 67.5 kg", sets: sets("8 × 70")),
            Lift(id: "leg-press", name: "Leg press", last: "3×10 · 160 kg", sets: sets("10 × 160"))
        ]),
        history: [
            Session(id: "2026-10-05-pull", day: "Sunday", title: "Pull", lifts: []),
            Session(id: "2026-10-03-push", day: "Friday", title: "Push", lifts: [])
        ]
    )
}
