import Foundation
import HermexAppKit

/// The context a chat started inside an app sends with its first message
/// (BUILD_SPEC §3.4). hermes-webui has no field for hidden context, so it
/// travels as a marked block after the user's text: Hermes reads it, and
/// `displayText(_:)` removes it wherever Hermex shows the message.
enum InAppChatContext {
    static let marker = "\n\n[Hermex app context]\n"

    struct Payload: Encodable, Equatable {
        struct App: Encodable, Equatable {
            let id: String
            let name: String
            let version: Int
            let hasAPI: Bool

            enum CodingKeys: String, CodingKey {
                case id, name, version
                case hasAPI = "has_api"
            }
        }

        let surface = "in_app"
        let app: App
        let route: String?
        /// The screen path the user sees, e.g. ["Today", "Legs"].
        let sees: [String]
        let entities: [HermexEntity]

        enum CodingKeys: String, CodingKey {
            case surface, app, route, sees, entities
        }

        init(app: HermexApp, context: HermexContext?) {
            self.app = App(
                id: app.id,
                name: app.name,
                version: app.version,
                hasAPI: app.capabilities.contains { $0.kind == .api }
            )
            route = context?.route
            sees = context?.breadcrumb ?? []
            entities = context?.entities ?? []
        }
    }

    /// The text sent to the server: the user's message, then the context block.
    static func message(_ text: String, with payload: Payload) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload), let json = String(data: data, encoding: .utf8) else {
            return text
        }
        return text + marker + json
    }

    /// The message as the user wrote it, without the context block.
    static func displayText(_ content: String) -> String {
        guard let range = content.range(of: marker) else { return content }
        return String(content[..<range.lowerBound])
    }

    /// "Lift Log › Today › Legs" for the sheet's "Sees:" line.
    static func seesLine(appName: String, context: HermexContext?) -> String {
        ([appName] + (context?.breadcrumb ?? [])).joined(separator: " › ")
    }
}

/// Which app each in-app chat started in, so Home can label it "in Lift Log".
enum InAppChatSessions {
    private static let key = "inAppChat.sessionApps"

    static func record(sessionID: String, appID: String, defaults: UserDefaults = .standard) {
        var map = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        map[sessionID] = appID
        defaults.set(map, forKey: key)
    }

    static func appID(forSession sessionID: String, defaults: UserDefaults = .standard) -> String? {
        (defaults.dictionary(forKey: key) as? [String: String])?[sessionID]
    }
}
