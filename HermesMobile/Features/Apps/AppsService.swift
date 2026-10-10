import CryptoKit
import Foundation

/// The Mac side of Hermex Apps (`Mac/` in this repo): a loopback service that
/// hermes-webui proxies as the `hermex-apps` extension sidecar. It serves the
/// app registry, the IPAs, each app's data API and an events feed, all through
/// the server URL and password Hermex already uses.
struct AppsService: Sendable {
    static let extensionID = "hermex-apps"

    let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    init(server: URL) {
        self.init(client: APIClient(baseURL: server))
    }

    /// The apps Hermes built that have a build to install.
    func registry() async throws -> AppsRegistry {
        try decode(AppsRegistry.self, from: try await send("apps"))
    }

    /// Downloads the IPA in parts (the webui proxies at most 512 KiB per
    /// response), checks it against the registry's SHA-256 and returns a file
    /// the caller deletes.
    func downloadIPA(_ download: RemoteApp.IPA, appID: String, progress: @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        var data = Data(capacity: download.size)
        for part in 0..<download.parts {
            try Task.checkCancellation()
            data += try await send("apps/\(appID)/ipa", query: [URLQueryItem(name: "part", value: String(part))], accept: "application/octet-stream")
            progress(Double(part + 1) / Double(download.parts))
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == download.size, digest == download.sha256 else {
            throw AppsServiceError.damagedDownload
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermex-\(appID)-\(download.version)-\(UUID().uuidString).ipa")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Runs one of the app's data tools for the app itself. Returns the tool's
    /// JSON result.
    func call(appID: String, tool: String, arguments: Data) async throws -> Data {
        let body = try await send("apps/\(appID)/call/\(tool)", method: "POST", body: arguments)
        guard let object = try JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) as? [String: Any],
              let result = object["result"] else {
            throw AppsServiceError.failed(String(localized: "The app's API sent an unreadable answer."))
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
    }

    /// Stops the app's running build on the Mac (the build card's Cancel build).
    func cancelBuild(appID: String) async throws {
        _ = try await send("apps/\(appID)/cancel", method: "POST", body: Data("{}".utf8))
    }

    /// Events after `cursor` (build steps, refresh requests), and the newest sequence number.
    func events(after cursor: Int) async throws -> AppsEventPage {
        try decode(AppsEventPage.self, from: try await send("events", query: [URLQueryItem(name: "after", value: String(cursor))]))
    }

    /// Records the user's OK for the webui to proxy Hermex Apps' service. The
    /// webui asks for this once per server, like its Settings → Extensions switch.
    func allowAccess() async throws {
        let (data, response) = try await client.setSidecarProxyConsent(extensionID: Self.extensionID, approved: true)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.error(status: response.statusCode, body: data)
        }
    }

    // MARK: - Plumbing

    private func send(
        _ path: String,
        query: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil,
        accept: String = "application/json"
    ) async throws -> Data {
        let (data, response) = try await client.sendSidecar(
            extensionID: Self.extensionID, path: path, queryItems: query,
            method: method, body: body, accept: accept, timeout: 30
        )
        guard (200..<300).contains(response.statusCode) else {
            throw Self.error(status: response.statusCode, body: data)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw AppsServiceError.failed(String(localized: "Hermex Apps on your Mac sent an unreadable answer."))
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Maps the webui proxy's and the service's `{"error": …}` answers.
    static func error(status: Int, body: Data) -> AppsServiceError {
        let message = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String ?? ""
        switch (status, message) {
        case (403, let m) where m.contains("consent required"):
            return .needsAccess
        case (404, let m) where m.hasPrefix("Extension"),
             (409, let m) where m.hasPrefix("Extension"):
            return .notSetUp
        case (502, let m) where m.contains("Failed to reach extension sidecar"):
            return .serviceDown
        default:
            return .failed(message.isEmpty ? String(localized: "Hermex Apps on your Mac answered with error \(status).") : message)
        }
    }
}

enum AppsServiceError: LocalizedError, Equatable {
    /// The webui hasn't been allowed to proxy Hermex Apps yet.
    case needsAccess
    /// The webui doesn't know the hermex-apps extension.
    case notSetUp
    /// The extension is set up but its service isn't running.
    case serviceDown
    case damagedDownload
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .needsAccess: String(localized: "Hermex needs your OK to reach the apps on your Mac.")
        case .notSetUp: String(localized: "Hermex Apps isn't set up on your Mac yet.")
        case .serviceDown: String(localized: "Hermex Apps isn't running on your Mac.")
        case .damagedDownload: String(localized: "The app download was damaged. Try again.")
        case .failed(let message): message
        }
    }

    /// The Mac couldn't be reached, as opposed to refusing the request.
    var isOffline: Bool {
        self == .serviceDown
    }
}

struct AppsRegistry: Decodable, Sendable {
    let apps: [RemoteApp]
    /// What the Mac builds for: "device" or "simulator".
    let platform: String
}

/// One app as the Mac's registry describes it.
struct RemoteApp: Decodable, Hashable, Sendable {
    struct API: Decodable, Hashable, Sendable {
        let tools: Int
        let changes: Int
    }

    struct Version: Decodable, Hashable, Sendable {
        let number: Int
        let change: String
        let reason: String?
        let at: Date?
    }

    struct IPA: Decodable, Hashable, Sendable {
        let version: Int
        let size: Int
        let sha256: String
        let platform: String
        let parts: Int
    }

    let id: String
    let name: String
    let tagline: String
    let summary: String
    let bundleId: String
    let symbol: String
    let color: String
    let ink: String
    let version: Int
    let builtAt: Date?
    let updatedAt: Date?
    let origin: String?
    let routes: [String]
    let api: API?
    let versions: [Version]
    let ipa: IPA?
}

struct AppsEvent: Decodable, Hashable, Sendable {
    let seq: Int
    /// ISO 8601 with fractional seconds.
    var at: String? = nil
    let kind: String
    let app: String?
    let route: String?
    let highlight: [String]?
    let step: String?
    let state: String?
    let detail: String?
    let version: Int?
    let isNew: Bool?
    /// `open`: a few words for the banner and rows for the card's preview.
    var note: String? = nil
    var preview: [PreviewRow]? = nil

    struct PreviewRow: Decodable, Hashable, Sendable {
        let label: String
        var value: String? = nil
    }
}

struct AppsEventPage: Decodable, Sendable {
    let events: [AppsEvent]
    let last: Int
}
