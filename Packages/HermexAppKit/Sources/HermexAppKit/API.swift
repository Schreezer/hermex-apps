import CryptoKit
import Foundation

/// Why an API call failed. `message` is fit to show the user.
public struct HermexAPIError: LocalizedError, Sendable {
    public let message: String
    /// True when the Mac could not be reached (or the app runs outside Hermex).
    public let isOffline: Bool

    public var errorDescription: String? { message }
}

/// The app's data lives on the Mac, behind the tools in the app's `server.py`.
/// Hermes calls the same tools, so the app and the agent always agree.
///
///     struct Item: Codable, Identifiable { let id: String; var title: String; var done: Bool }
///     let items: [Item] = try await HermexAppKit.fetch("items")
///     try await HermexAppKit.perform("set_done", ["id": item.id, "done": true])
///
/// Arguments are encoded with snake_case keys and results decoded from
/// snake_case, so Swift types keep camelCase names.
extension HermexAppKit {
    /// Reads through a tool. When the Mac can't be reached, returns the last
    /// answer this call got, so the app still opens offline.
    public static func fetch<T: Decodable>(_ tool: String, as type: T.Type = T.self) async throws -> T {
        try await fetch(tool, HermexNoArguments(), as: type)
    }

    public static func fetch<T: Decodable, Arguments: Encodable>(
        _ tool: String, _ arguments: Arguments, as type: T.Type = T.self
    ) async throws -> T {
        let encoded = try encode(arguments)
        let cacheURL = HermexAPICache.url(tool: tool, arguments: encoded)
        do {
            let data = try await call(tool, encoded)
            let value = try decode(T.self, from: data)
            try? data.write(to: cacheURL, options: .atomic)
            return value
        } catch let error as HermexAPIError where error.isOffline {
            guard let cached = try? Data(contentsOf: cacheURL) else { throw error }
            return try decode(T.self, from: cached)
        }
    }

    /// Changes data through a tool and returns its result.
    public static func perform<T: Decodable, Arguments: Encodable>(
        _ tool: String, _ arguments: Arguments, as type: T.Type = T.self
    ) async throws -> T {
        try decode(T.self, from: try await call(tool, try encode(arguments)))
    }

    /// Changes data through a tool, ignoring its result.
    public static func perform<Arguments: Encodable>(_ tool: String, _ arguments: Arguments) async throws {
        _ = try await call(tool, try encode(arguments))
    }

    /// Changes data through a tool that takes no arguments.
    public static func perform(_ tool: String) async throws {
        _ = try await call(tool, try encode(HermexNoArguments()))
    }

    private static func call(_ tool: String, _ arguments: Data) async throws -> Data {
        guard isHosted else {
            throw HermexAPIError(message: "Open this app from Hermex to load its data.", isOffline: true)
        }
        let reply = await HermexGuestClient.shared.callAPI(tool, arguments: arguments)
        if let result = reply.result { return result }
        throw HermexAPIError(message: reply.error ?? "The app's API did not answer.", isOffline: reply.offline)
    }

    private static func encode<Arguments: Encodable>(_ arguments: Arguments) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(arguments)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw HermexAPIError(message: "The app's API answered in an unexpected shape: \(error)", isOffline: false)
        }
    }
}

/// Encodes as `{}`.
public struct HermexNoArguments: Encodable, Sendable {
    public init() {}
}

enum HermexAPICache {
    static func url(tool: String, arguments: Data) -> URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HermexAppKit", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let key = SHA256.hash(data: Data(tool.utf8) + [0] + arguments).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(key + ".json")
    }
}

extension HermexGuestClient {
    func callAPI(_ tool: String, arguments: Data) async -> HermexAPIReply {
        await withCheckedContinuation { continuation in
            let once = HermexOnce(continuation)
            let host = host { _ in
                once.resume(HermexAPIReply(result: nil, error: "Lost the connection to Hermex.", offline: true))
            }
            guard let host else {
                once.resume(HermexAPIReply(result: nil, error: "Not running inside Hermex.", offline: true))
                return
            }
            host.callAPI(tool, arguments: arguments) { data in
                let reply = (try? HermexBridge.decoder.decode(HermexAPIReply.self, from: data))
                    ?? HermexAPIReply(result: nil, error: "Hermex sent an unreadable reply.", offline: false)
                once.resume(reply)
            }
        }
    }
}

/// Resumes a continuation at most once: XPC may call both the reply and the error handler.
final class HermexOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HermexAPIReply, Never>?

    init(_ continuation: CheckedContinuation<HermexAPIReply, Never>) {
        self.continuation = continuation
    }

    func resume(_ reply: HermexAPIReply) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: reply)
    }
}
