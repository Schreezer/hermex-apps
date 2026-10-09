import Foundation

/// A Hermes chat's repository (#1114), read through the host's Git routes on the sign-in its Bot
/// screens share, mapped into webui's Git models so the menu, Changes sheet, diffs and
/// turn-changes card read it unchanged. It shows the whole repository holding the chat's folder,
/// not only the folder: the root is resolved once from `GET /api/fs/git-root` and every read names
/// it, since the host's paths are relative to the root. A folder outside a repository is asked
/// again on the next read, so a repository the agent creates shows at turn end.
///
/// Read-only: writes stay on webui's routes. Neither the root nor git's own output (a refusal's
/// `detail`, which can name host paths) reaches the screen or a log. Checked at the
/// `HERMES_AGENT_TESTED_SHA` pin (ca678285) in `hermes_cli/web_git.py` and `web_routers/git.py`.
@MainActor final class HermesGitClient: GitDataClient {
    let context: HermesWorkspaceContext
    private let http: HermesConnection
    /// The repository root, once `fs/git-root` has found one. Never shown, logged or persisted.
    private var root: String?

    /// webui's diff cap: a longer diff shows "Diff too large to show." instead of its text.
    static let maximumDiffBytes = 512 * 1024

    init(context: HermesWorkspaceContext, http: HermesConnection) {
        self.context = context
        self.http = http
    }

    /// The branch, ahead/behind and dirty counts from `git/status`; nil outside a repository.
    func info() async throws -> GitInfo? {
        guard let root = try await repositoryRoot() else { return nil }
        let summary = try Self.json(try await send(.gitStatus(repository: root)))
        guard summary.fields != nil else { return nil }
        let changed = summary["changed"].integer ?? 0
        let untracked = summary["untracked"].integer ?? 0
        return GitInfo(branch: Self.branch(summary), dirty: changed, modified: changed - untracked, untracked: untracked,
                       ahead: summary["ahead"].integer, behind: summary["behind"].integer, isGit: true)
    }

    /// Every uncommitted change: `review/list`'s rows joined by path with `git/status`' flags
    /// (`Self.status(summary:changes:)`). `isGit == false` outside a repository.
    func status() async throws -> GitStatus? {
        guard let root = try await repositoryRoot() else { return Self.notARepository }
        async let summary = send(.gitStatus(repository: root))
        async let changes = send(.gitChanges(repository: root))
        let (summaryBody, changesBody) = try await (summary, changes)
        return Self.status(summary: try Self.json(summaryBody), changes: try Self.json(changesBody))
    }

    /// The row's staged diff when it has only staged changes, else its worktree diff, which the
    /// host synthesizes as all-add for an untracked file. A staged row past the status cap may also
    /// have worktree edits, so it reads its whole change against HEAD. Over `maximumDiffBytes` it
    /// is too large.
    func diff(for file: GitFile) async throws -> GitDiff? {
        guard let root = try await repositoryRoot() else { return nil }
        let path = file.displayPath
        let wholeChange = file.staged == true && file.unstaged == nil
        let kind = wholeChange ? nil : file.preferredDiffKind
        let request: HermesREST = wholeChange ? .gitFileDiff(repository: root, file: path)
            : .gitDiff(repository: root, file: path, staged: kind == "staged")
        let text = try Self.json(try await send(request))["diff"].text ?? ""
        let tooLarge = text.utf8.count > Self.maximumDiffBytes
        return GitDiff(path: path, kind: kind, binary: Self.isBinary(text),
                       tooLarge: tooLarge, additions: nil, deletions: nil, diff: tooLarge ? nil : text)
    }

    /// A turn's tool path as its row's root-relative path: Hermes tools name files relative to the
    /// chat's folder or absolutely. Left as named until the root is known, or when it lies outside.
    func rowPath(forToolPath path: String) -> String {
        guard let root else { return path }
        return Self.rowPath(path, folder: context.cwd, root: root)
    }

    /// `rowPath(forToolPath:)` for a chat working in `folder` inside the repository at `root`.
    nonisolated static func rowPath(_ path: String, folder: String, root: String) -> String {
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        if path.hasPrefix(rootPrefix) { return String(path.dropFirst(rootPrefix.count)) }
        guard !path.hasPrefix("/") else { return path }
        let folderPrefix = folder.hasSuffix("/") ? folder : folder + "/"
        if folderPrefix == rootPrefix { return path }
        guard folderPrefix.hasPrefix(rootPrefix) else { return path }
        return String(folderPrefix.dropFirst(rootPrefix.count)) + path
    }

    /// `git/status` and `review/list` as one `GitStatus`. Rows are `review/list`'s, which lists
    /// every change; `status.files` stops at 200 and adds the flags a row lacks. A row past it has
    /// no `unstaged` flag (unknown, not clean) and takes untracked and conflicted from its status
    /// letter (`?`, `U`).
    /// The list is whole, so it is never `truncated`; `changed` is the host's full count.
    nonisolated static func status(summary: BotJSON, changes: BotJSON) -> GitStatus {
        guard summary.fields != nil else { return notARepository }
        var flags: [String: BotJSON] = [:]
        for entry in summary["files"].list ?? [] {
            if let path = entry["path"].text { flags[path] = entry }
        }
        let files = (changes["files"].list ?? []).compactMap { row -> GitFile? in
            guard let path = row["path"].text, !path.isEmpty else { return nil }
            let flag = flags[path]
            let letter = row["status"].text
            return GitFile(path: path, status: letter, staged: row["staged"].flag ?? flag?["staged"].flag,
                           unstaged: flag?["unstaged"].flag, untracked: flag?["untracked"].flag ?? (letter == "?"),
                           conflict: flag?["conflicted"].flag ?? (letter == "U"),
                           additions: row["added"].integer, deletions: row["removed"].integer)
        }
        let totals = GitTotals(changed: summary["changed"].integer ?? files.count, staged: summary["staged"].integer,
                               unstaged: summary["unstaged"].integer, untracked: summary["untracked"].integer,
                               conflicts: summary["conflicted"].integer)
        return GitStatus(isGit: true, branch: branch(summary), upstream: nil, ahead: summary["ahead"].integer,
                         behind: summary["behind"].integer, totals: totals, files: files, truncated: false)
    }

    private nonisolated static let notARepository = GitStatus(isGit: false, branch: nil, upstream: nil, ahead: nil,
                                                              behind: nil, totals: nil, files: nil, truncated: nil)

    /// The branch's name, or `HEAD` when detached, as webui names it.
    private nonisolated static func branch(_ summary: BotJSON) -> String? {
        summary["branch"].text ?? (summary["detached"].flag == true ? "HEAD" : nil)
    }

    /// A diff with no hunk whose patch says the file is binary.
    private nonisolated static func isBinary(_ text: String) -> Bool {
        !text.contains("\n@@") && text.split(separator: "\n").contains { $0.hasPrefix("Binary files ") && $0.hasSuffix(" differ") }
    }

    /// The root of the repository holding the chat's folder, resolved once; nil outside one.
    private func repositoryRoot() async throws -> String? {
        if let root { return root }
        let found = try Self.json(try await send(.gitRoot(path: context.cwd)))["root"].text
        root = found.flatMap { $0.isEmpty ? nil : $0 }
        return root
    }

    /// One request's body. A refusal (400 `{detail}`, git's stderr) and any other failed status
    /// read as `HermesGitUnavailable`, so neither git's output nor a host path reaches the screen.
    /// A dropped request reads as webui's network failure; the sign-in's own failures keep theirs.
    private func send(_ rest: HermesREST) async throws -> Data {
        let reply: (body: Data, status: Int)
        do { reply = try await http.reply(rest) } catch let error as URLError { throw APIError.network(underlying: error) }
        do { return try HermesCronClient.accepted(reply) } catch is HermesCronRefusal {
            throw HermesGitUnavailable()
        } catch let error as APIError {
            if case .http = error { throw HermesGitUnavailable() }
            throw error
        }
    }

    private nonisolated static func json(_ body: Data) throws -> BotJSON {
        do { return try JSONDecoder().decode(BotJSON.self, from: body) } catch { throw APIError.decoding(underlying: error) }
    }
}

/// A Git read a Hermes host refused (#1114), shown with the existing copy instead of git's output.
struct HermesGitUnavailable: LocalizedError, Equatable {
    var errorDescription: String? { String(localized: "Repository status unavailable") }
}
