import Foundation
import LiveContainerSwiftUI

/// Turns the Mac's app registry (BUILD_SPEC §3, served by `Mac/`) into the
/// Apps tab's records. Debug builds can add the design's sample apps with the
/// `--sample-apps` launch argument.
enum AppRegistry {
    static func sampleRecords(now: Date = .now) -> [HermexApp] {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--sample-apps") else { return [] }
        return designSamples(now: now)
        #else
        return []
        #endif
    }

    /// One app as the Mac describes it.
    static func record(from remote: RemoteApp) -> HermexApp {
        var capabilities: [HermexApp.Capability] = []
        if let api = remote.api, api.tools > 0 {
            capabilities.append(.init(
                kind: .api,
                title: String(localized: "Reads and writes your data"),
                detail: String(localized: "MCP · \(remote.id) · \(api.tools) tools")
            ))
        }
        if !remote.routes.isEmpty {
            capabilities.append(.init(
                kind: .link,
                title: String(localized: "Opens any screen"),
                detail: remote.routes.joined(separator: " · ")
            ))
        }
        capabilities.append(tapCapability)
        return HermexApp(
            id: remote.id,
            name: remote.name,
            tagline: remote.tagline,
            summary: remote.summary,
            bundleIdentifier: remote.bundleId,
            symbol: remote.symbol,
            color: hex(remote.color) ?? 0x3A3F46,
            ink: hex(remote.ink) ?? 0xF3F2ED,
            version: remote.version,
            builtAt: remote.builtAt ?? .distantPast,
            updatedAt: remote.updatedAt ?? remote.builtAt ?? .distantPast,
            origin: remote.origin,
            capabilities: capabilities,
            versions: remote.versions.map {
                .init(
                    number: $0.number,
                    change: $0.change,
                    reason: $0.reason ?? $0.at?.formatted(.dateTime.month(.abbreviated).day()) ?? ""
                )
            },
            routes: remote.routes,
            download: remote.ipa
        )
    }

    private static var tapCapability: HermexApp.Capability {
        .init(kind: .tap, title: String(localized: "Taps and types for you"), detail: String(localized: "Fallback only · asks first"))
    }

    /// `#RRGGBB` → 0xRRGGBB.
    static func hex(_ string: String) -> UInt32? {
        let digits = string.hasPrefix("#") ? String(string.dropFirst()) : string
        guard digits.count == 6 else { return nil }
        return UInt32(digits, radix: 16)
    }

    /// Plain metadata for an installed app the registry does not list.
    static func record(forUnlisted hostApp: LCHostApp) -> HermexApp {
        HermexApp(
            id: hostApp.bundleIdentifier,
            name: hostApp.displayName,
            tagline: hostApp.bundleIdentifier,
            summary: hostApp.bundleIdentifier,
            bundleIdentifier: hostApp.bundleIdentifier,
            symbol: "app.fill",
            color: 0x3A3F46,
            ink: 0xF3F2ED,
            version: Int(hostApp.version.split(separator: ".").first ?? "") ?? 1,
            builtAt: .distantPast,
            updatedAt: .distantPast,
            origin: nil,
            capabilities: [tapCapability],
            versions: []
        )
    }

    #if DEBUG
    private static func designSamples(now: Date) -> [HermexApp] {
        let calendar = Calendar.current
        func daysAgo(_ days: Int) -> Date { calendar.date(byAdding: .day, value: -days, to: now) ?? now }
        let tap = HermexApp.Capability(kind: .tap, title: "Taps and types for you", detail: "Fallback only · asks first")
        return [
            HermexApp(
                id: "lift-log", name: "Lift Log",
                tagline: "Push / pull / legs · sets per lift",
                summary: "Push / pull / legs, one tap per set, progress per lift",
                bundleIdentifier: "dev.hermex.liftlog", symbol: "dumbbell.fill",
                color: 0xFF7A45, ink: 0x1A0E08, version: 4,
                builtAt: now.addingTimeInterval(-120), updatedAt: now.addingTimeInterval(-120), origin: nil,
                capabilities: [
                    .init(kind: .api, title: "Reads and writes your data", detail: "MCP · lift-log · 6 tools"),
                    .init(kind: .link, title: "Opens any screen", detail: "liftlog://today · /history · /lift/{id}"),
                    tap
                ],
                versions: [
                    .init(number: 4, change: "Rest timer between sets", reason: "You asked on Tuesday · today"),
                    .init(number: 3, change: "Progress line for each lift", reason: "You asked after leg day · Oct 5"),
                    .init(number: 2, change: "Imported 23 sessions from Notes", reason: "Oct 4")
                ]
            ),
            HermexApp(
                id: "fuel", name: "Fuel",
                tagline: "Meals and macros",
                summary: "Meals and macros, logged by photo or by asking Hermes",
                bundleIdentifier: "dev.hermex.fuel", symbol: "fork.knife",
                color: 0xF2CC4A, ink: 0x1E1904, version: 6,
                builtAt: daysAgo(12), updatedAt: now.addingTimeInterval(-3 * 60 * 60), origin: nil,
                capabilities: [
                    .init(kind: .api, title: "Reads and writes your data", detail: "MCP · fuel · 8 tools"),
                    .init(kind: .link, title: "Opens any screen", detail: "fuel://today · /meal/{id}"),
                    tap
                ],
                versions: [
                    .init(number: 6, change: "Breakfast presets", reason: "You asked this morning · today"),
                    .init(number: 5, change: "Weekly macro chart", reason: "Oct 3")
                ]
            ),
            HermexApp(
                id: "sleep-ledger", name: "Sleep Ledger",
                tagline: "From a GitHub repo",
                summary: "A sleep tracker forked from GitHub and rebuilt for you",
                bundleIdentifier: "dev.hermex.sleepledger", symbol: "moon.fill",
                color: 0x7C93FF, ink: 0x0B1030, version: 2,
                builtAt: daysAgo(5), updatedAt: daysAgo(4), origin: "From a GitHub repo",
                capabilities: [
                    .init(kind: .link, title: "Opens any screen", detail: "sleepledger://tonight · /week"),
                    tap
                ],
                versions: [
                    .init(number: 2, change: "Rebuilt with your colors", reason: "Sun"),
                    .init(number: 1, change: "Forked from GitHub", reason: "You asked for a sleep tracker · Sat")
                ]
            ),
            HermexApp(
                id: "sip", name: "Sip",
                tagline: "Water nudges",
                summary: "Water nudges that back off when you're already drinking",
                bundleIdentifier: "dev.hermex.sip", symbol: "drop.fill",
                color: 0x4CC3E0, ink: 0x04181D, version: 3,
                builtAt: daysAgo(9), updatedAt: daysAgo(3), origin: nil,
                capabilities: [
                    .init(kind: .api, title: "Reads and writes your data", detail: "MCP · sip · 3 tools"),
                    tap
                ],
                versions: [
                    .init(number: 3, change: "A 2 pm nudge", reason: "You asked to make it louder · Mon")
                ]
            ),
            HermexApp(
                id: "streaks", name: "Streaks",
                tagline: "Daily habits",
                summary: "Daily habits with a streak for each",
                bundleIdentifier: "dev.hermex.streaks", symbol: "chart.line.uptrend.xyaxis",
                color: 0xE36BA8, ink: 0x22081A, version: 1,
                builtAt: daysAgo(8), updatedAt: daysAgo(8), origin: nil,
                capabilities: [tap],
                versions: [
                    .init(number: 1, change: "First version", reason: "You asked for a habit tracker · last week")
                ]
            ),
            HermexApp(
                id: "container-test", name: "Container Test",
                tagline: "Runtime check · scripts/build-container-test-ipa.sh",
                summary: "The one-screen app that checks the embedded runtime",
                bundleIdentifier: "dev.hermex.containertest", symbol: "shippingbox.fill",
                color: 0x5B7CFF, ink: 0x0A1030, version: 1,
                builtAt: daysAgo(30), updatedAt: daysAgo(1), origin: nil,
                capabilities: [tap],
                versions: [
                    .init(number: 1, change: "Tap counter that persists", reason: "Build step 2")
                ]
            )
        ]
    }
    #endif
}
