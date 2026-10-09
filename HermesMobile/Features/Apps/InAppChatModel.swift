import Foundation
import Observation
import SwiftData
import HermexAppKit

/// One running app's conversation with Hermes. It lives as long as the app is
/// open, so closing and reopening the sheet keeps the thread. The chat is a
/// normal webui session driven by Hermex's own `ChatViewModel`.
@MainActor
@Observable
final class InAppChatModel {
    let server: URL
    let app: HermexApp
    private(set) var chat: ChatViewModel?
    private(set) var sessionID: String?
    private(set) var isStarting = false
    private(set) var startError: String?

    @ObservationIgnored private let client: APIClient

    init(server: URL, app: HermexApp) {
        self.server = server
        self.app = app
        client = APIClient(baseURL: server)
    }

    var isRunning: Bool {
        guard let chat else { return isStarting }
        return chat.activeStreamID != nil || chat.isStartingChat
    }

    /// Sends a message. The first one creates the session and carries the
    /// app's context.
    func send(_ text: String, context: HermexContext?, modelContext: ModelContext?) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        startError = nil

        if let chat {
            _ = await chat.sendMessage(trimmed, modelContext: modelContext)
            return
        }

        isStarting = true
        defer { isStarting = false }
        do {
            let (chat, sessionID) = try await startChat()
            self.chat = chat
            self.sessionID = sessionID
            InAppChatSessions.record(sessionID: sessionID, appID: app.id)
            let payload = InAppChatContext.Payload(app: app, context: context)
            _ = await chat.sendMessage(InAppChatContext.message(trimmed, with: payload), modelContext: modelContext)
        } catch {
            startError = error.localizedDescription
        }
    }

    func stop() async {
        _ = await chat?.cancelActiveStream()
    }

    /// Leaves the run going on the server so the full chat can reattach.
    func suspend() {
        chat?.suspendStreamForNavigation()
        chat?.cleanupPollingTasks()
    }

    func resume(modelContext: ModelContext?) async {
        await chat?.reconnectStreamIfNeeded(modelContext: modelContext)
    }

    /// Creates the session the way Hermex's New Chat does, then applies the
    /// composer picks (model, reasoning, profile) of the user's last new chat.
    private func startChat() async throws -> (ChatViewModel, String) {
        let workspaces = try await client.workspaces()
        let workspace = workspaces.last ?? workspaces.workspaces?.compactMap(\.path).first
        let response = try await client.createSession(workspace: workspace, model: nil, modelProvider: nil, profile: nil)
        guard let detail = response.session else {
            throw InAppChatError(message: String(localized: "The server did not return the new session."))
        }
        let session = SessionSummary(from: detail)
        guard let sessionID = session.sessionId, !sessionID.isEmpty else {
            throw InAppChatError(message: String(localized: "The server did not return the new session ID."))
        }

        let chat = ChatViewModel(session: session, server: server, client: client)
        let generation = chat.composerConfigurationInteractionGeneration
        await chat.loadComposerConfiguration()
        if let settings = await ChatDraftStore.shared.draft(for: .newChat(server: server))?.settings {
            await chat.restoreDraftSettings(settings, expectedInteractionGeneration: generation)
        }
        return (chat, sessionID)
    }
}

struct InAppChatError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
