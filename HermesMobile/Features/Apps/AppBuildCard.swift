import SwiftUI

/// Hermes' `apps_create` / `apps_build` calls in a group of tool calls, shown
/// as build cards (screen 04). Outside the webui home (no `AppLibrary` in the
/// environment) it shows nothing.
struct AppBuildCards: View {
    let toolCalls: [ToolCall]

    @Environment(AppLibrary.self) private var library: AppLibrary?

    var body: some View {
        if let library {
            ForEach(AppBuildCall.calls(in: toolCalls), id: \.appID) { call in
                AppBuildCard(call: call, library: library)
            }
        }
    }
}

/// A factory call the card follows. The newest call for an app owns its card.
struct AppBuildCall: Equatable {
    enum Kind: Equatable {
        case create
        case build
    }

    let appID: String
    let kind: Kind
    let startedAt: Double
    let isCompleted: Bool
    let isError: Bool
    /// From `apps_create`, before the registry knows the app.
    let name: String?
    let symbol: String?
    let color: String?
    let ink: String?
    let routes: Int?

    /// The newest create or build call per app in this group.
    static func calls(in toolCalls: [ToolCall]) -> [AppBuildCall] {
        var newest: [String: AppBuildCall] = [:]
        for toolCall in toolCalls {
            guard let call = AppBuildCall(toolCall) else { continue }
            if call.startedAt >= newest[call.appID]?.startedAt ?? -1 {
                newest[call.appID] = call
            }
        }
        return newest.values.sorted { $0.startedAt < $1.startedAt }
    }

    init?(_ toolCall: ToolCall) {
        // Hermes may defer MCP tools behind a generic `tool_call(name, arguments)`.
        var name = toolCall.name ?? ""
        var arguments: JSONValue? = toolCall.args.map(JSONValue.object)
        if name == "tool_call" {
            name = Self.string(toolCall.args?["name"]) ?? ""
            arguments = toolCall.args?["arguments"]
        }
        guard name.contains("hermex_apps") else { return nil }
        if name.hasSuffix("apps_create") {
            kind = .create
        } else if name.hasSuffix("apps_build") {
            kind = .build
        } else {
            return nil
        }
        let fields = Fields(arguments)
        guard let appID = fields.string("app_id"), !appID.isEmpty else { return nil }
        self.appID = appID
        startedAt = toolCall.startedAt
        isCompleted = toolCall.isCompleted
        isError = toolCall.isError == true
        self.name = fields.string("name")
        symbol = fields.string("symbol")
        color = fields.string("color")
        ink = fields.string("ink")
        routes = fields.count("routes")
    }

    /// Arguments as an object, or as the text the server keeps for settled
    /// calls (JSON or Python-style, possibly cut short).
    private struct Fields {
        let object: [String: JSONValue]?
        let text: String?

        init(_ value: JSONValue?) {
            switch value {
            case .object(let object)?:
                self.object = object
                text = nil
            case .string(let text)?:
                if let data = text.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
                    object = decoded
                    self.text = nil
                } else {
                    object = nil
                    self.text = text
                }
            default:
                object = nil
                text = nil
            }
        }

        func string(_ key: String) -> String? {
            if let object { return AppBuildCall.string(object[key]) }
            guard let text,
                  let pattern = try? Regex("['\"]\(key)['\"]\\s*:\\s*['\"]([^'\"]*)['\"]"),
                  let match = text.firstMatch(of: pattern)
            else { return nil }
            return match.output[1].substring.map(String.init)
        }

        func count(_ key: String) -> Int? {
            if case .array(let items)? = object?[key] { return items.count }
            return nil
        }
    }

    private static func string(_ value: JSONValue?) -> String? {
        if case .string(let string)? = value { return string }
        return nil
    }
}

/// Screen 04's card: five steps from plan to ready, then Open.
struct AppBuildCard: View {
    let call: AppBuildCall
    let library: AppLibrary

    @State private var isOpening = false

    private typealias Theme = HermexAppsTheme

    enum StepState: Equatable {
        case done
        case active
        case todo
        case failed
    }

    struct Step: Identifiable, Equatable {
        let id: Int
        let title: String
        let detail: String
        let state: StepState
    }

    var body: some View {
        if library.isNewestBuildCard(appID: call.appID, callStartedAt: call.startedAt) {
            card
                .onAppear { library.buildCardAppeared(appID: call.appID, callStartedAt: call.startedAt) }
                .onDisappear { library.buildCardDisappeared() }
        }
    }

    // MARK: - State

    private var entry: HermexAppEntry? {
        library.entries.first { $0.id == call.appID }
    }

    private var progress: BuildProgress? {
        library.builds[call.appID]
    }

    private var version: Int? {
        progress?.version ?? entry?.app.download?.version
    }

    private var isBuilt: Bool {
        if progress?.isReady == true { return true }
        switch call.kind {
        case .build: return call.isCompleted && !call.isError && progress?.isRunning != true
        case .create: return progress == nil && entry?.app.download != nil
        }
    }

    private var isFailed: Bool {
        guard !isBuilt else { return false }
        if let progress, progress.failure != nil, !progress.isRunning { return true }
        return call.kind == .build && call.isCompleted && call.isError && progress?.isRunning != true
    }

    private var isInstalled: Bool {
        guard let version, let installed = entry?.installedVersion else { return false }
        return installed >= version
    }

    private var steps: [Step] {
        let buildStarted = progress.map { !$0.steps.isEmpty } ?? (call.kind == .build && !call.isCompleted)
        let writeState: StepState = isBuilt || buildStarted || isFailed ? .done : .active
        let buildState: StepState = isBuilt ? .done : isFailed ? .failed : buildStarted ? .active : .todo
        let installState: StepState = isInstalled ? .done : library.installing[call.appID] != nil ? .active : .todo

        var buildDetail = ""
        if let start = progress?.compileStartedAt, let end = progress?.compileFinishedAt {
            buildDetail = String(localized: "\(Int(end.timeIntervalSince(start).rounded())) s")
        }
        let installDetail = entry?.app.download.map { ByteCountFormatter.string(fromByteCount: Int64($0.size), countStyle: .file) } ?? ""
        let screens = call.routes.map { String(localized: "\($0) screens") } ?? ""

        return [
            Step(id: 0, title: String(localized: "Plan screens and data"), detail: screens, state: .done),
            Step(id: 1, title: String(localized: "Write the code"), detail: "", state: writeState),
            Step(id: 2, title: String(localized: "Build on your Mac"), detail: buildDetail, state: buildState),
            Step(id: 3, title: String(localized: "Install into app container"), detail: isBuilt ? installDetail : "", state: installState),
            Step(id: 4, title: String(localized: "Ready to open"), detail: "", state: isInstalled ? .done : .todo)
        ]
    }

    private var name: String { entry?.app.name ?? call.name ?? call.appID }
    private var symbol: String { entry?.app.symbol ?? call.symbol ?? "app.fill" }
    private var color: UInt32 { entry?.app.color ?? call.color.flatMap(AppRegistry.hex) ?? 0x3A3F46 }
    private var ink: UInt32 { entry?.app.ink ?? call.ink.flatMap(AppRegistry.hex) ?? 0xF3F2ED }

    private var subtitle: String {
        let isNew = progress?.isNew ?? (call.kind == .create)
        guard let version else { return isNew ? String(localized: "New app") : String(localized: "Update") }
        return isNew ? String(localized: "New app · v\(version)") : String(localized: "Update · v\(version)")
    }

    // MARK: - Views

    private var card: some View {
        let steps = steps
        let done = steps.filter { $0.state == .done }.count
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color(hex: ink))
                    .frame(width: 48, height: 48)
                    .background(Color(hex: color), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: name)
                        .font(Theme.body(16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(verbatim: subtitle)
                        .font(Theme.body(13, relativeTo: .footnote))
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
                Text(verbatim: "\(done) / \(steps.count)")
                    .font(Theme.mono(12, relativeTo: .caption))
                    .foregroundStyle(isFailed ? Theme.destructive : Theme.accent)
                    .accessibilityLabel(Text("\(done) of \(steps.count) steps done"))
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line)
                    Capsule()
                        .fill(isFailed ? Theme.destructive : Theme.accent)
                        .frame(width: proxy.size.width * CGFloat(done) / CGFloat(steps.count))
                }
            }
            .frame(height: 4)
            .animation(.easeOut(duration: 0.3), value: done)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(steps) { step in
                    HStack(spacing: 10) {
                        indicator(step.state)
                        Text(verbatim: step.title)
                            .font(Theme.body(14, relativeTo: .subheadline))
                            .foregroundStyle(step.state == .todo ? Theme.muted : Theme.text)
                        Spacer(minLength: 0)
                        Text(verbatim: step.detail)
                            .font(Theme.mono(12, relativeTo: .caption))
                            .foregroundStyle(Theme.muted)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            if isFailed {
                failureText
                    .font(Theme.body(13, relativeTo: .footnote))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if !isBuilt && !isFailed {
                    Button {
                        Task { await library.cancelBuild(appID: call.appID) }
                    } label: {
                        Text("Cancel build")
                            .font(Theme.body(14, weight: .medium, relativeTo: .subheadline))
                            .foregroundStyle(Theme.text)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                openButton
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.line))
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: 420, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Build of \(name)"))
    }

    private var failureText: Text {
        if case .cancelled? = progress?.failure {
            return Text("You cancelled this build.")
        }
        return Text("The build failed. Hermes reads the errors and usually fixes them and builds again.")
    }

    private var openButton: some View {
        let canOpen = isBuilt && (entry?.downloadFitsThisDevice == true || entry?.isInstalled == true) && !isOpening
        return Button {
            isOpening = true
            Task {
                await library.open(appID: call.appID)
                isOpening = false
            }
        } label: {
            Group {
                if isOpening || library.installing[call.appID] != nil {
                    ProgressView().tint(Theme.onAccent)
                } else if !isBuilt {
                    Text("Open when ready")
                } else {
                    Text("Open \(name)")
                }
            }
            .font(Theme.body(14, weight: .semibold, relativeTo: .subheadline))
            .foregroundStyle(canOpen ? Theme.onAccent : Theme.muted)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(canOpen ? Theme.accent : Theme.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canOpen)
    }

    @ViewBuilder
    private func indicator(_ state: StepState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 18, height: 18)
                .background(Theme.accent, in: Circle())
        case .active:
            ProgressView()
                .controlSize(.mini)
                .tint(Theme.accent)
                .frame(width: 18, height: 18)
        case .todo:
            Circle()
                .strokeBorder(Theme.line, lineWidth: 2)
                .frame(width: 18, height: 18)
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(Theme.background)
                .frame(width: 18, height: 18)
                .background(Theme.destructive, in: Circle())
        }
    }
}
