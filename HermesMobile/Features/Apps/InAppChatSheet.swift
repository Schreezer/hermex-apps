import SwiftUI
import SwiftData
import HermexAppKit

/// Screen 09: Hermes over a running app. The first message carries what the
/// app reports through the bridge; the thread is a normal Hermes session.
struct InAppChatSheet: View {
    let model: InAppChatModel
    let bridge: GuestBridge
    let openFullChat: (String) -> Void
    let close: () -> Void

    @State private var draft = ""
    @FocusState private var isComposerFocused: Bool
    @Environment(\.modelContext) private var modelContext

    private typealias Theme = HermexAppsTheme

    var body: some View {
        VStack(spacing: 0) {
            header
            Theme.surface2.frame(height: 1)
            transcript
            composer
        }
        .background(Color(hex: 0x111315).ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .task { await model.resume(modelContext: modelContext) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            HermesMark()
                .stroke(Theme.onAccent, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                .frame(width: 16, height: 16)
                .frame(width: 30, height: 30)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "Hermes")
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Sees: \(InAppChatContext.seesLine(appName: model.app.name, context: bridge.context))")
                    .font(Theme.body(12, relativeTo: .caption))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .accessibilityIdentifier("inAppChat.sees")
            }
            Spacer(minLength: 0)
            if let sessionID = model.sessionID {
                Button { openFullChat(sessionID) } label: {
                    Text("Full chat")
                        .font(Theme.body(13, relativeTo: .footnote))
                        .foregroundStyle(Theme.muted)
                        .frame(minHeight: 44)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.plain)
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 32, height: 32)
                    .background(Theme.surface2, in: Circle())
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let chat = model.chat {
                        ForEach(chat.displayedTranscriptMessages, id: \.renderID) { item in
                            messageRow(item.message, chat: chat)
                        }
                        let anchored = Set(chat.displayedTranscriptMessages.compactMap(\.message.messageId))
                        if !chat.liveToolCalls.isEmpty, !anchored.contains(chat.toolCallAnchorMessageID ?? "") {
                            toolCallBox(chat.liveToolCalls, isLive: true)
                        }
                        if let approval = chat.approvalPrompt {
                            approvalCard(approval, chat: chat)
                        }
                        if chat.clarificationPrompt != nil, let sessionID = model.sessionID {
                            handOffCard(sessionID: sessionID)
                        }
                        if let error = chat.sendErrorMessage {
                            errorText(error)
                        }
                    } else if model.isStarting {
                        ProgressView().tint(Theme.muted).frame(maxWidth: .infinity)
                    } else {
                        Text("Ask about what's on screen. Hermes sees \(model.app.name) and can change it for you.")
                            .font(Theme.body(14, relativeTo: .subheadline))
                            .foregroundStyle(Theme.muted)
                    }
                    if let error = model.startError {
                        errorText(error)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.chat?.displayedTranscriptMessages.last?.message.content) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: model.chat?.liveToolCalls.count) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage, chat: ChatViewModel) -> some View {
        if message.role == "user" {
            Text(verbatim: InAppChatContext.displayText(message.content ?? ""))
                .font(Theme.body(15))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Theme.surface2, in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20))
                .frame(maxWidth: 300, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                let groups = chat.completedToolCallGroupsForAnchor(message.messageId)
                let calls = groups.flatMap(\.toolCalls)
                if !calls.isEmpty {
                    toolCallBox(calls, isLive: false)
                }
                if chat.toolCallAnchorMessageID == message.messageId, !chat.liveToolCalls.isEmpty {
                    toolCallBox(chat.liveToolCalls, isLive: true)
                }
                if let content = message.content, !content.isEmpty {
                    Text(Self.markdown(content))
                        .font(Theme.body(15))
                        .foregroundStyle(Theme.text)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func toolCallBox(_ calls: [ToolCall], isLive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(calls) { call in
                if let row = ToolCallSummaryFormatter.row(for: call, isLive: isLive) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        statusIcon(row.status)
                        Text(verbatim: [row.summary, row.detail].compactMap { $0 }.joined(separator: " "))
                            .font(Theme.mono(12, relativeTo: .caption))
                            .foregroundStyle(Theme.text)
                            .lineLimit(2)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: row.accessibilityLabel))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.surface2))
    }

    @ViewBuilder
    private func statusIcon(_ status: ToolCallLogRow.Status) -> some View {
        switch status {
        case .running:
            ProgressView().controlSize(.mini).tint(Theme.accent)
        case .failure:
            Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.destructive)
        case .interrupted:
            Image(systemName: "minus").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.muted)
        case .success:
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
        }
    }

    private func approvalCard(_ approval: ApprovalPromptState, chat: ChatViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hermes needs your OK")
                .font(Theme.body(14, weight: .semibold, relativeTo: .subheadline))
                .foregroundStyle(Theme.text)
            if let command = approval.pending.command, !command.isEmpty {
                Text(verbatim: command)
                    .font(Theme.mono(12, relativeTo: .caption))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(4)
            }
            HStack(spacing: 8) {
                chip(String(localized: "Allow once"), filled: true) { Task { _ = await chat.respondToApproval(.once) } }
                chip(String(localized: "Deny"), filled: false) { Task { _ = await chat.respondToApproval(.deny) } }
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
    }

    private func handOffCard(sessionID: String) -> some View {
        HStack {
            Text("Hermes has a question.")
                .font(Theme.body(14, relativeTo: .subheadline))
                .foregroundStyle(Theme.text)
            Spacer()
            chip(String(localized: "Answer in full chat"), filled: true) { openFullChat(sessionID) }
        }
    }

    private func chip(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(Theme.body(14, weight: filled ? .semibold : .regular, relativeTo: .subheadline))
                .foregroundStyle(filled ? Theme.onAccent : Theme.text)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(filled ? Theme.accent : .clear, in: Capsule())
                .overlay(Capsule().stroke(filled ? .clear : Theme.line))
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
    }

    private func errorText(_ message: String) -> some View {
        Text(verbatim: message)
            .font(Theme.body(13, relativeTo: .footnote))
            .foregroundStyle(Theme.destructive)
    }

    private var composer: some View {
        HStack(spacing: 6) {
            TextField("Ask about this screen", text: $draft, axis: .vertical)
                .font(Theme.body(15))
                .foregroundStyle(Theme.text)
                .lineLimit(1...5)
                .focused($isComposerFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .accessibilityLabel(Text("Message Hermes about \(model.app.name)"))
                .accessibilityIdentifier("inAppChat.composer")
            if model.isRunning {
                Button { Task { await model.stop() } } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 34, height: 34)
                        .background(Theme.surface2, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Stop"))
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 34, height: 34)
                        .background(Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(Text("Send"))
                .accessibilityIdentifier("inAppChat.send")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .frame(minHeight: 44)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.line))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !model.isRunning else { return }
        draft = ""
        let context = bridge.context
        Task { await model.send(text, context: context, modelContext: modelContext) }
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
