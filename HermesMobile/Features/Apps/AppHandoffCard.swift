import SwiftUI

/// Hermes' `apps_open` call in a chat.
struct AppOpenCall: Equatable {
    let id: String
    /// The server's id replaces a live call's generated one; either finds its claim.
    let callIDs: [String]
    let appID: String
    let route: String?
    let note: String?
    let startedAt: Double
    let isError: Bool

    /// Every open call in this group, in order.
    static func calls(in toolCalls: [ToolCall]) -> [AppOpenCall] {
        toolCalls.compactMap(AppOpenCall.init)
    }

    init?(_ toolCall: ToolCall) {
        guard let call = HermexAppsToolCall(toolCall), call.name.hasSuffix("apps_open"),
              let appID = call.fields.string("app_id"), !appID.isEmpty
        else { return nil }
        id = toolCall.id
        callIDs = Array(Set([toolCall.id, toolCall.presentationID]))
        self.appID = appID
        route = call.fields.string("route")
        note = call.fields.string("note")
        startedAt = toolCall.startedAt
        isError = toolCall.isError == true
    }
}

/// Screen 11 in chat: while Hermes' request counts down, the full opening
/// card; afterwards, a small card saying what happened, with Open.
struct AppOpenCard: View {
    let call: AppOpenCall
    let library: AppLibrary

    @State private var isOpening = false

    private typealias Theme = HermexAppsTheme

    private var handoff: AppLibrary.Handoff? {
        library.handoff(appID: call.appID, callIDs: call.callIDs, callStartedAt: call.startedAt)
    }

    var body: some View {
        if !call.isError {
            Group {
                if let handoff, handoff.outcome == .pending {
                    AppHandoffCard(handoff: handoff, library: library)
                        .onAppear { library.handoffCardAppeared() }
                        .onDisappear { library.handoffCardDisappeared() }
                } else {
                    settled(handoff)
                }
            }
            // Before Hermes' request arrives the card is settled; it still
            // needs the library listening for it.
            .onAppear { library.openCardAppeared() }
            .onDisappear { library.openCardDisappeared() }
            // A live call takes the server's id when it completes, which can
            // come after its request; claim again under each id it gets.
            .onChange(of: [String(handoff?.id ?? -1)] + call.callIDs.sorted(), initial: true) {
                if let id = handoff?.id { library.claimHandoff(id, callIDs: call.callIDs) }
            }
        }
    }

    private var app: HermexApp? {
        library.entries.first { $0.id == call.appID }?.app
    }

    private func settled(_ handoff: AppLibrary.Handoff?) -> some View {
        let name = app?.name ?? call.appID
        let route = handoff?.route ?? call.route ?? ""
        let status: Text = switch handoff?.outcome {
        case .opened?: Text("Opened by Hermes")
        case .stayed?: Text("You stayed in chat")
        case .alreadyOpen?: Text("Shown in the open app")
        case .pending?, nil: Text(verbatim: AppHandoffCard.link(appID: call.appID, route: route))
        }
        return HStack(spacing: 12) {
            if let app {
                AppIconTile(app: app, size: 36, cornerRadius: 10)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name)
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                status
                    .font(Theme.body(12, relativeTo: .caption))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                isOpening = true
                Task {
                    await library.open(AppLibrary.OpenRequest(
                        appID: call.appID,
                        route: route.isEmpty ? nil : route,
                        highlight: handoff?.highlight ?? []
                    ))
                    isOpening = false
                }
            } label: {
                Group {
                    if isOpening || library.installing[call.appID] != nil {
                        ProgressView().tint(Theme.accent)
                    } else {
                        Text("Open")
                    }
                }
                .font(Theme.body(14, weight: .semibold, relativeTo: .subheadline))
                .foregroundStyle(Theme.accent)
                .frame(minWidth: 64, minHeight: 32)
                .padding(.horizontal, 4)
                .background(Theme.surface2, in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isOpening)
            .accessibilityLabel(Text("Open \(name)"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line))
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: 420, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// Screen 11's card: the app Hermes is opening, where, a preview of what
/// changed, and a 2 s countdown. Stay here cancels it.
struct AppHandoffCard: View {
    let handoff: AppLibrary.Handoff
    let library: AppLibrary

    @State private var isOpening = false

    private typealias Theme = HermexAppsTheme

    /// The deep link as the card shows it, e.g. `hyrox-noida://week`.
    static func link(appID: String, route: String) -> String {
        "\(appID)://\(route)"
    }

    private var app: HermexApp? {
        library.entries.first { $0.id == handoff.appID }?.app
    }

    private var name: String { app?.name ?? handoff.appID }

    private var needsInstall: Bool {
        library.entries.first { $0.id == handoff.appID }?.isInstalled != true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if let app {
                    AppIconTile(app: app, size: 44, cornerRadius: 12)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Opening \(name)")
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(verbatim: Self.link(appID: handoff.appID, route: handoff.route))
                        .font(Theme.mono(12, relativeTo: .caption))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if let opensAt = handoff.opensAt {
                    CountdownRing(opensAt: opensAt, total: library.handoffCountdown)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if !handoff.preview.isEmpty, let app {
                preview(app)
            }

            HStack(spacing: 8) {
                Button {
                    isOpening = true
                    Task {
                        await library.openHandoff(handoff.id)
                        isOpening = false
                    }
                } label: {
                    Group {
                        if isOpening || library.installing[handoff.appID] != nil {
                            ProgressView().tint(Theme.onAccent)
                        } else if needsInstall {
                            Text("Install and open")
                        } else {
                            Text("Open now")
                        }
                    }
                    .font(Theme.body(14, weight: .semibold, relativeTo: .subheadline))
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isOpening)

                Button { library.stay(handoff.id) } label: {
                    Text("Stay here")
                        .font(Theme.body(14, weight: .medium, relativeTo: .subheadline))
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(12)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.line))
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: 420, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Hermes is opening \(name)"))
    }

    /// The rows Hermes says changed, in a light panel tinted with the app's color.
    private func preview(_ app: HermexApp) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let note = handoff.note {
                Text(verbatim: note)
                    .font(Theme.body(12, weight: .semibold, relativeTo: .caption))
                    .textCase(.uppercase)
                    .tracking(0.7)
                    .foregroundStyle(Color(hex: app.color, over: 0x2A2A2A, amount: 0.45))
            }
            ForEach(Array(handoff.preview.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: row.label)
                    Spacer(minLength: 8)
                    if let value = row.value {
                        Text(verbatim: value).foregroundStyle(Color(hex: 0x4A4A46))
                    }
                }
                .font(Theme.body(14, relativeTo: .subheadline))
                .foregroundStyle(Color(hex: 0x1C1C1A))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(hex: app.color, over: 0xFBF8EE, amount: 0.16),
            in: UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14)
        )
        .padding(.horizontal, 12)
    }
}

/// The seconds left before the app opens, in a ring that empties.
private struct CountdownRing: View {
    let opensAt: Date
    let total: Double

    private typealias Theme = HermexAppsTheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { context in
            let remaining = max(0, opensAt.timeIntervalSince(context.date))
            ZStack {
                Circle().stroke(Theme.line, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: remaining / total)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(verbatim: "\(Int(remaining.rounded(.up)))")
                    .font(Theme.mono(12, relativeTo: .caption))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 34, height: 34)
            .accessibilityElement()
            .accessibilityLabel(Text("Opens in \(Int(remaining.rounded(.up))) s"))
        }
    }
}

/// Screen 12's banner over an app Hermes opened: what it did, and the way
/// back to the chat.
struct OpenedByHermesBanner: View {
    let request: AppLibrary.OpenRequest
    let backToChat: () -> Void

    private typealias Theme = HermexAppsTheme

    private var detail: String? {
        var parts: [String] = []
        if let note = request.note { parts.append(note) }
        if !request.highlight.isEmpty {
            parts.append(String(localized: "Highlighted: \(request.highlight.count)"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            HermesMark()
                .stroke(Theme.onAccent, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                .frame(width: 15, height: 15)
                .frame(width: 28, height: 28)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Opened by Hermes")
                    .font(Theme.body(13, weight: .semibold, relativeTo: .footnote))
                    .foregroundStyle(Theme.text)
                if let detail {
                    Text(verbatim: detail)
                        .font(Theme.body(12, relativeTo: .caption))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button(action: backToChat) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                    Text("Chat")
                }
                .font(Theme.body(13, weight: .medium, relativeTo: .footnote))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Back to chat"))
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isStaticText)
    }
}
