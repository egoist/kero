//
//  GitStatusModel.swift
//  kero
//

import Combine
import Darwin
import Dispatch
import Foundation

/// Loads repository state in response to explicit UI events and performs
/// source-control operations without blocking the UI.
@MainActor
final class GitStatusModel: nonisolated ObservableObject {
    nonisolated struct Worktree: Identifiable, Equatable, Sendable {
        var id: String { path }
        let path: String
        let headOID: String?
        let branch: String?
        let isDetached: Bool
        let isBare: Bool
        let lockedReason: String?
        let prunableReason: String?

        var shortHeadOID: String {
            guard let headOID else { return "" }
            return String(headOID.prefix(7))
        }
    }

    nonisolated struct Entry: Identifiable, Equatable, Sendable {
        var id: String { path }
        /// Relative to the repository root, as porcelain v2 reports it.
        let path: String
        /// Index (staged) status letter, "." when clean, "?" for untracked.
        let staged: Character
        /// Worktree (unstaged) status letter.
        let unstaged: Character
        var isConflict = false
        /// Previous path for renames/copies (porcelain "2" entries).
        var origPath: String?
        /// Canonical repo that produced this snapshot. Mutations reject stale
        /// rows after the active terminal moves to another repository.
        var repositoryRoot = ""

        var fileName: String { (path as NSString).lastPathComponent }
        var directory: String {
            let dir = (path as NSString).deletingLastPathComponent
            return dir.isEmpty ? "" : dir
        }
        /// Intent-to-add (`git add -N`) is represented as `.A`; restoring it
        /// from the empty index blob would truncate user content, so destructive
        /// handling treats it like an untracked file and uses the Trash.
        var isIntentToAdd: Bool { staged == "." && unstaged == "A" }
        var isUntracked: Bool { staged == "?" || isIntentToAdd }
        var isWorktreeRename: Bool { unstaged == "R" && origPath != nil }
        var isWorktreeCopy: Bool { unstaged == "C" && origPath != nil }

        // A file can sit in two sections at once (for example, "MM"). Rows in
        // the same lazy stack need distinct identities or SwiftUI drops one.
        var mergeRowID: String { "merge/" + path }
        var stagedRowID: String { "staged/" + path }
        var changedRowID: String { "changed/" + path }
    }

    /// Compact Explorer-style decoration for a path in the active repository.
    /// The file tree maps these semantic states to both a color and a visible
    /// status badge, so color is never the only indication.
    nonisolated enum FileDecoration: Equatable, Sendable {
        case modified
        case added
        case untracked
        case deleted
        case renamed
        case copied
        case conflict
        case ignored

        /// When a directory contains several changed files, bubble up the
        /// state that most needs attention.
        var directoryPriority: Int {
            switch self {
            case .conflict: 8
            case .deleted: 7
            case .modified: 6
            case .added: 5
            case .untracked: 4
            case .renamed: 3
            case .copied: 2
            case .ignored: 1
            }
        }
    }

    nonisolated struct RecentCommit: Identifiable, Equatable, Sendable {
        nonisolated struct FileChange: Identifiable, Equatable, Sendable {
            let status: Character
            let path: String
            let originalPath: String?

            var id: String {
                "\(status)\u{0}\(originalPath ?? "")\u{0}\(path)"
            }
            var fileName: String { (path as NSString).lastPathComponent }
            var directory: String {
                let dir = (path as NSString).deletingLastPathComponent
                return dir.isEmpty ? "" : dir
            }
        }

        var id: String { hash }
        let hash: String
        let shortHash: String
        let subject: String
        let author: String
        let date: Date
        let parentHash: String?
        let references: [String]
        let files: [FileChange]

        var relativeDate: String {
            date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        }
    }

    nonisolated struct Operation: Identifiable, Equatable, Sendable {
        enum State: Equatable, Sendable {
            case running
            case succeeded
            case failed(exitCode: Int32)
        }

        let id: UUID
        let label: String
        var state: State
        var output: String
        let startedAt: Date
        var finishedAt: Date?

        var isRunning: Bool { state == .running }
        var isSuccess: Bool { state == .succeeded }

        var statusLabel: String {
            switch state {
            case .running:
                return String(localized: "\(label)…", comment: "A Git operation that is still running.")
            case .succeeded:
                return String(localized: "\(label) completed", comment: "A Git operation that completed successfully.")
            case .failed:
                return String(localized: "\(label) failed", comment: "A Git operation that failed.")
            }
        }
    }

    @Published private(set) var rootPath = ""
    /// Stable canonical repository root, used by the UI to key drafts. It is
    /// preserved while a cwd change is being resolved inside the same repo.
    @Published private(set) var repositoryIdentity = ""
    @Published private(set) var isRepo = false
    @Published private(set) var fileDecorations: [String: FileDecoration] = [:]
    /// Relative porcelain paths. Directory records retain their trailing slash
    /// so expanded descendants can inherit the ignored state.
    @Published private(set) var ignoredPaths: Set<String> = []
    @Published private(set) var branch: String?
    @Published private(set) var headOID: String?
    @Published private(set) var hasHead = true
    @Published private(set) var upstream: String?
    @Published private(set) var ahead = 0
    @Published private(set) var behind = 0
    @Published private(set) var hasUpstream = false
    @Published private(set) var lineAdditions = 0
    @Published private(set) var lineDeletions = 0
    @Published private(set) var mergeEntries: [Entry] = []
    @Published private(set) var stagedEntries: [Entry] = []
    @Published private(set) var changedEntries: [Entry] = []
    @Published private(set) var worktrees: [Worktree] = []
    @Published private(set) var branches: [String] = []
    @Published private(set) var defaultBranch: String?
    @Published private(set) var remotes: [String] = []
    @Published private(set) var recentCommits: [RecentCommit] = []
    @Published private(set) var hasMoreRecentCommits = false
    @Published private(set) var isLoadingMoreCommits = false
    @Published private(set) var repositoryOperation: String?
    @Published private(set) var stashCount = 0
    @Published private(set) var isRefreshing = false
    /// True once a status load has completed for the current `rootPath`. The
    /// UI keeps showing resolved content during later event-driven refreshes
    /// instead of flashing a loading placeholder.
    @Published private(set) var hasResolvedStatus = false
    @Published private(set) var statusError: String?
    /// True while a user-initiated Git operation runs.
    @Published private(set) var isBusy = false
    @Published private(set) var operation: Operation?
    @Published var lastError: String?

    /// Absolute repository root. Porcelain paths are relative to this path,
    /// not necessarily to the terminal's current working directory.
    private var topLevel = ""
    /// Invalidates async refreshes and operations after the terminal changes cwd.
    private var contextGeneration: UInt = 0
    /// Restores a previously resolved directory immediately when switching
    /// tabs. Without this, every return to a repository clears `isRepo` until
    /// the asynchronous Git refresh finishes, briefly removing the toolbar
    /// and resizing the terminal through the wrong height.
    private var cachedStatusByRoot: [String: StatusLoadResult] = [:]
    /// Invalidates an in-flight status refresh when a mutation begins, so its
    /// pre-operation snapshot cannot overwrite the post-operation state.
    private var statusRequestID: UInt = 0
    /// Coalesces an event that arrives while another refresh or mutation is
    /// running. Without polling, dropping that event could leave the snapshot
    /// stale indefinitely.
    private var refreshPending = false
    private static let recentCommitPageSize = 30
    private var recentCommitLimit = recentCommitPageSize
    private var recentCommitLimitByRoot: [String: Int] = [:]
    /// Keeps a mutation globally exclusive even if the terminal changes cwd
    /// while its Git process is still running.
    private var runningOperationID: UUID?
    /// Watches Git's shared worktree administration directory. Agents often
    /// add/remove worktrees inside one long-running shell command, so command
    /// completion alone would not update the navigator until the agent exits.
    private var worktreeMetadataWatcher: DispatchSourceFileSystemObject?
    private var worktreeMetadataWatchedPath = ""
    var totalChangeCount: Int {
        mergeEntries.count + stagedEntries.count + changedEntries.count
    }

    /// True while the first status load for the current directory is still in
    /// flight, so later event-driven refreshes do not replace resolved content
    /// with a loading state.
    var isResolvingInitialStatus: Bool {
        isRefreshing && !hasResolvedStatus
    }

    var repoRoot: String {
        topLevel.isEmpty ? rootPath : topLevel
    }

    func absolutePath(for entry: Entry) -> String {
        let base = entry.repositoryRoot.isEmpty ? repoRoot : entry.repositoryRoot
        return (base as NSString).appendingPathComponent(entry.path)
    }

    func isCurrent(_ entry: Entry) -> Bool {
        entry.repositoryRoot.isEmpty || entry.repositoryRoot == repoRoot
    }

    func isCurrent(_ worktree: Worktree) -> Bool {
        Self.normalizedPath(worktree.path) == Self.normalizedPath(repoRoot)
    }

    func worktree(forBranch branch: String) -> Worktree? {
        worktrees.first { $0.branch == branch }
    }

    /// Returns a Git decoration only when `absolutePath` belongs to the
    /// currently resolved repository. Plain folders therefore keep the normal
    /// file-tree appearance, even when their names resemble ignored paths.
    func fileDecoration(for absolutePath: String, isDirectory: Bool) -> FileDecoration? {
        guard isRepo, !topLevel.isEmpty else { return nil }
        let repositoryPath = (topLevel as NSString).standardizingPath
        let itemPath = (absolutePath as NSString).standardizingPath
        let relativePath: String
        if itemPath == repositoryPath {
            relativePath = ""
        } else {
            let prefix = repositoryPath + "/"
            guard itemPath.hasPrefix(prefix) else { return nil }
            relativePath = String(itemPath.dropFirst(prefix.count))
        }

        if let decoration = fileDecorations[relativePath] {
            return decoration
        }
        if ignoredPaths.contains(where: { ignoredPath in
            if ignoredPath.hasSuffix("/") {
                let directory = String(ignoredPath.dropLast())
                return relativePath == directory || relativePath.hasPrefix(directory + "/")
            }
            return relativePath == ignoredPath
        }) {
            return .ignored
        }
        guard isDirectory, !relativePath.isEmpty else { return nil }

        let descendantPrefix = relativePath + "/"
        return fileDecorations
            .filter { $0.key.hasPrefix(descendantPrefix) }
            .map(\.value)
            .max { $0.directoryPriority < $1.directoryPriority }
    }

    func sync(root: String) {
        if root != rootPath {
            contextGeneration &+= 1
            rootPath = root
            recentCommitLimit = recentCommitLimitByRoot[root]
                ?? Self.recentCommitPageSize
            hasResolvedStatus = false
            stopWorktreeMetadataWatcher()
            clearRepositoryState(preserveIdentity: true)
            if let cachedStatus = cachedStatusByRoot[root] {
                apply(cachedStatus)
                hasResolvedStatus = true
            }
        }
        refresh()
    }

    func refresh() {
        let root = rootPath
        let generation = contextGeneration
        let commitLimit = recentCommitLimit
        guard !root.isEmpty else { return }
        guard !isRefreshing, !isBusy else {
            refreshPending = true
            return
        }
        refreshPending = false
        statusRequestID &+= 1
        let requestID = statusRequestID
        isRefreshing = true

        // This is deliberately independent of the worker. Even filesystem
        // metadata calls can become uninterruptible on a disconnected volume;
        // the sidebar must still leave its initial loading state and offer a
        // retry while the stale worker winds down in the background.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self,
                  self.isRefreshing,
                  self.contextGeneration == generation,
                  self.statusRequestID == requestID,
                  self.rootPath == root else { return }
            self.statusRequestID &+= 1
            self.isRefreshing = false
            self.isLoadingMoreCommits = false
            self.refreshPending = false
            self.apply(.failed(String(localized: "Git did not respond in time.")))
            self.hasResolvedStatus = true
        }

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Self.runGitStatus(in: root, recentCommitLimit: commitLimit)
            }.value
            guard let self, self.contextGeneration == generation,
                  self.statusRequestID == requestID,
                  self.rootPath == root else { return }
            self.isRefreshing = false
            // A pagination request may have arrived while this older snapshot
            // was already running. Keep its loading state latched until the
            // queued refresh using the larger limit finishes.
            self.isLoadingMoreCommits = commitLimit < self.recentCommitLimit
            switch result {
            case .repository, .notRepository:
                self.cachedStatusByRoot[root] = result
            case .failed:
                break
            }
            self.apply(result)
            self.hasResolvedStatus = true
            if self.refreshPending {
                self.refreshPending = false
                self.refresh()
            }
        }
    }

    @discardableResult
    func loadMoreCommits() -> Bool {
        guard isRepo, hasMoreRecentCommits,
              !isLoadingMoreCommits, !isBusy else { return false }
        recentCommitLimit += Self.recentCommitPageSize
        recentCommitLimitByRoot[rootPath] = recentCommitLimit
        isLoadingMoreCommits = true
        if isRefreshing {
            // The active worker captured the previous limit. Queue a second
            // refresh instead of dropping the request made as the section is
            // opened near the end of the viewport.
            refreshPending = true
        } else {
            refresh()
        }
        return true
    }

    func dismissOperation() {
        guard operation?.isRunning != true else { return }
        operation = nil
        lastError = nil
    }

    // MARK: - File operations

    func stage(_ entry: Entry) {
        guard validate(entry) else { return }
        let original = entry.unstaged == "R" ? entry.origPath.map { [$0] } ?? [] : []
        let paths = [entry.path] + original
        perform(
            label: String(localized: "Stage \(entry.fileName)"),
            commands: [["--literal-pathspecs", "add", "--"] + paths]
        )
    }

    func unstage(_ entry: Entry) {
        guard validate(entry) else { return }
        let original = entry.staged == "R" ? entry.origPath.map { [$0] } ?? [] : []
        let paths = [entry.path] + original
        let args = hasHead
            ? ["--literal-pathspecs", "restore", "--staged", "--"] + paths
            : ["--literal-pathspecs", "rm", "--cached", "-f", "--"] + paths
        perform(label: String(localized: "Unstage \(entry.fileName)"), commands: [args])
    }

    func stageAll() {
        perform(label: String(localized: "Stage all changes"), commands: [["add", "-A"]])
    }

    func unstageAll() {
        let args = hasHead
            ? ["restore", "--staged", "--", "."]
            : ["rm", "--cached", "-r", "-f", "--", "."]
        perform(label: String(localized: "Unstage all changes"), commands: [args])
    }

    /// Restores a tracked file from the index, or moves an untracked file to
    /// the Trash. The UI confirms before calling this.
    func discard(_ entry: Entry) {
        guard validate(entry) else { return }
        if entry.isIntentToAdd {
            perform(
                label: String(localized: "Remove intent-to-add for \(entry.fileName)"),
                commands: [[
                    "--literal-pathspecs", "rm", "--cached", "-f", "--", entry.path,
                ]]
            ) { [weak self] success in
                guard success else { return }
                self?.trash(
                    paths: [entry.path],
                    label: String(localized: "Move \(entry.fileName) to Trash"),
                    completedBefore: String(localized: "Removed the intent-to-add index entry.")
                )
            }
        } else if entry.isUntracked || entry.isWorktreeCopy {
            trash(
                paths: [entry.path],
                label: String(localized: "Move \(entry.fileName) to Trash")
            )
        } else if entry.isWorktreeRename, let original = entry.origPath {
            perform(
                label: String(localized: "Restore \((original as NSString).lastPathComponent)"),
                commands: [["--literal-pathspecs", "restore", "--worktree", "--", original]]
            ) { [weak self] success in
                guard success else { return }
                self?.trash(
                    paths: [entry.path],
                    label: String(localized: "Move \(entry.fileName) to Trash"),
                    completedBefore: String(localized: "Restored \((original as NSString).lastPathComponent).")
                )
            }
        } else {
            perform(
                label: String(localized: "Discard changes in \(entry.fileName)"),
                commands: [["--literal-pathspecs", "restore", "--worktree", "--", entry.path]]
            )
        }
    }

    /// Discards every worktree change. Tracked files are restored and
    /// untracked files are moved to the Trash. The UI confirms first.
    func discardAllChanges() {
        discardChanges(changedEntries)
    }

    /// Discards only the confirmed snapshot. This prevents new files written
    /// by an agent while the dialog is open from joining a bulk destructive action.
    func discardChanges(_ entries: [Entry]) {
        guard !entries.isEmpty else { return }
        guard entries.allSatisfy(isCurrent) else {
            cancelStaleDiscard()
            return
        }
        let intentToAdd = entries.filter(\.isIntentToAdd)
        let moved = entries.filter { $0.isWorktreeRename || $0.isWorktreeCopy }
        let untracked = entries.filter(\.isUntracked).map(\.path) + moved.map(\.path)
        let renamedOriginals = moved.filter(\.isWorktreeRename).compactMap(\.origPath)
        let tracked = entries.filter {
            !$0.isUntracked && !$0.isWorktreeRename && !$0.isWorktreeCopy
        }.map(\.path) + renamedOriginals
        var commands: [[String]] = []
        if !tracked.isEmpty {
            commands.append(["--literal-pathspecs", "restore", "--worktree", "--"] + tracked)
        }
        if !intentToAdd.isEmpty {
            commands.append(
                ["--literal-pathspecs", "rm", "--cached", "-f", "--"]
                    + intentToAdd.map(\.path)
            )
        }
        guard !commands.isEmpty || !untracked.isEmpty else { return }

        if commands.isEmpty {
            trash(paths: untracked, label: String(localized: "Move untracked files to Trash"))
        } else {
            var completedSteps: [String] = []
            if !tracked.isEmpty {
                completedSteps.append(
                    String(localized: "Restored \(tracked.count) tracked paths.")
                )
            }
            if !intentToAdd.isEmpty {
                completedSteps.append(
                    String(localized: "Removed \(intentToAdd.count) intent-to-add index entries.")
                )
            }
            perform(label: String(localized: "Discard all changes"), commands: commands) { [weak self] success in
                guard success, !untracked.isEmpty else { return }
                self?.trash(
                    paths: untracked,
                    label: String(localized: "Finish discarding all changes"),
                    completedBefore: completedSteps.joined(separator: "\n")
                )
            }
        }
    }

    func cancelStaleDiscard() {
        failImmediately(String(localized: "Files changed while the confirmation was open. Review them and try again."))
    }

    // MARK: - Commit and remote operations

    /// Commits only the index unless `includeAll` explicitly requests `git add -A`.
    func commit(
        message: String,
        includeAll: Bool,
        amend: Bool = false,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            failImmediately(String(localized: "Enter a commit message"), completion: completion)
            return
        }
        guard includeAll || !stagedEntries.isEmpty || amend else {
            failImmediately(String(localized: "Stage changes before committing"), completion: completion)
            return
        }

        var commands: [[String]] = []
        if includeAll { commands.append(["add", "-A"]) }
        var commitArgs = ["commit"]
        if amend { commitArgs.append("--amend") }
        commitArgs += ["-m", trimmed]
        commands.append(commitArgs)
        let label = amend
            ? String(localized: "Amend commit")
            : (includeAll
                ? String(localized: "Stage all and commit")
                : String(localized: "Commit staged changes"))
        perform(label: label, commands: commands, completion: completion)
    }

    /// Compatibility for older call sites. The behavior remains explicit in
    /// the new panel, which uses the overload above.
    func commit(message: String) {
        commit(message: message, includeAll: stagedEntries.isEmpty)
    }

    func fetch() {
        guard !remotes.isEmpty else {
            failImmediately(String(localized: "No Git remote is configured"))
            return
        }
        perform(
            label: String(localized: "Fetch"),
            commands: [["fetch", "--all", "--prune"]],
            requiresStableHead: false
        )
    }

    func pull() {
        guard hasUpstream else {
            failImmediately(String(localized: "This branch has no upstream to pull from"))
            return
        }
        perform(
            label: String(localized: "Pull"),
            commands: [["pull", "--ff-only"]],
            requiresStableUpstream: true
        )
    }

    func push() {
        guard branch != "detached HEAD" || hasUpstream else {
            failImmediately(String(localized: "Create or switch to a branch before publishing detached HEAD"))
            return
        }
        if hasUpstream {
            perform(label: String(localized: "Push"), commands: [["push"]], requiresStableUpstream: true)
            return
        }
        guard let remote = unambiguousRemote else {
            failImmediately(remotes.isEmpty
                ? String(localized: "Add a Git remote before publishing this branch")
                : String(localized: "Choose which remote should receive this branch"))
            return
        }
        perform(label: String(localized: "Publish branch"), commands: [["push", "-u", remote, "HEAD"]])
    }

    func publish(to remote: String) {
        guard branch != "detached HEAD" else {
            failImmediately(String(localized: "Create or switch to a branch before publishing detached HEAD"))
            return
        }
        guard remotes.contains(remote) else {
            failImmediately(String(localized: "The selected Git remote is no longer available"))
            return
        }
        perform(
            label: String(localized: "Publish branch to \(remote)"),
            commands: [["push", "-u", remote, "HEAD"]]
        )
    }

    func syncChanges() {
        guard branch != "detached HEAD" || hasUpstream else {
            failImmediately(String(localized: "Create or switch to a branch before publishing detached HEAD"))
            return
        }
        if hasUpstream {
            perform(
                label: String(localized: "Sync changes"),
                commands: [["pull", "--ff-only"], ["push"]],
                requiresStableUpstream: true
            )
        } else {
            guard let remote = unambiguousRemote else {
                failImmediately(remotes.isEmpty
                    ? String(localized: "Add a Git remote before publishing this branch")
                    : String(localized: "Choose which remote should receive this branch"))
                return
            }
            perform(label: String(localized: "Publish branch"), commands: [["push", "-u", remote, "HEAD"]])
        }
    }

    // MARK: - Branches, stash, and repository setup

    func switchBranch(to name: String, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard !name.isEmpty, name != branch else {
            completion?(name == branch)
            return
        }
        perform(
            label: String(localized: "Switch to \(name)"),
            commands: [["switch", name]],
            completion: completion
        )
    }

    func createBranch(named name: String, completion: (@MainActor (Bool) -> Void)? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            failImmediately(String(localized: "Enter a branch name"), completion: completion)
            return
        }
        perform(
            label: String(localized: "Create branch \(trimmed)"),
            commands: [["switch", "-c", trimmed]],
            completion: completion
        )
    }

    func stash(includeUntracked: Bool = true) {
        guard totalChangeCount > 0 else {
            failImmediately(String(localized: "There are no changes to stash"))
            return
        }
        var args = ["stash", "push"]
        if includeUntracked { args.append("--include-untracked") }
        perform(label: String(localized: "Stash changes"), commands: [args])
    }

    func stashPop() {
        guard stashCount > 0 else {
            failImmediately(String(localized: "There are no stashes to pop"))
            return
        }
        perform(label: String(localized: "Pop stash"), commands: [["stash", "pop"]])
    }

    func initializeRepository(completion: (@MainActor (Bool) -> Void)? = nil) {
        guard !rootPath.isEmpty else {
            failImmediately(String(localized: "Open a terminal directory first"), completion: completion)
            return
        }
        perform(
            label: String(localized: "Initialize repository"),
            commands: [["init"]],
            directory: rootPath,
            completion: completion
        )
    }

    // MARK: - Operation runner

    private var unambiguousRemote: String? {
        remotes.count == 1 ? remotes[0] : nil
    }

    private func validate(_ entry: Entry) -> Bool {
        guard isCurrent(entry) else {
            failImmediately(String(localized: "Repository changed; refresh and try the Git action again"))
            return false
        }
        return true
    }

    private func perform(
        label: String,
        commands: [[String]],
        directory: String? = nil,
        requiresStableHead: Bool = true,
        requiresStableUpstream: Bool = false,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        if directory == nil && !isRepo {
            failImmediately(
                String(localized: "Repository changed; review the current directory and try the Git action again."),
                completion: completion
            )
            return
        }
        let dir = directory ?? repoRoot
        let generation = contextGeneration
        let validationRoot = rootPath
        let expectedRepositoryRoot = directory == nil && isRepo ? repoRoot : nil
        let expectedHeadOID = headOID
        let expectedBranch = branch
        let expectedUpstream = upstream
        guard !dir.isEmpty, !isBusy, !commands.isEmpty else { return }

        let operationID = UUID()
        invalidateStatusRefresh()
        runningOperationID = operationID
        isBusy = true
        lastError = nil
        operation = Operation(
            id: operationID,
            label: label,
            state: .running,
            output: "",
            startedAt: Date(),
            finishedAt: nil
        )

        Task { [weak self] in
            let batch = await Task.detached(priority: .userInitiated) {
                var transcript: [String] = []
                var failureCode: Int32?
                var failureMessage: String?

                if let expectedRepositoryRoot {
                    guard Self.resolveRepositoryRoot(in: validationRoot) == expectedRepositoryRoot else {
                        let message = String(localized: "Repository changed before the Git action could run. Review the current changes and try again.")
                        return CommandBatchResult(
                            output: message, failureCode: -1, failureMessage: message
                        )
                    }
                    if requiresStableHead {
                        let liveStatus = Self.runGit(
                            ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=no"],
                            in: expectedRepositoryRoot
                        )
                        let live = liveStatus.status == 0
                            ? Self.parseStatus(liveStatus.stdout)
                            : nil
                        guard let live,
                              live.headOID == expectedHeadOID,
                              live.branch == expectedBranch,
                              !requiresStableUpstream || live.upstream == expectedUpstream else {
                            let message = requiresStableUpstream
                                ? String(localized: "Branch, HEAD, or upstream changed before the Git action could run. Review the current changes and try again.")
                                : String(localized: "Branch or HEAD changed before the Git action could run. Review the current changes and try again.")
                            return CommandBatchResult(
                                output: message, failureCode: -1, failureMessage: message
                            )
                        }
                    }
                }

                for args in commands {
                    transcript.append("$ git " + Self.displayCommand(args))
                    let run = Self.runGit(args, in: dir)
                    let text = [run.stdout, run.stderr]
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                    if !text.isEmpty { transcript.append(text) }
                    if run.status != 0 {
                        let fallback = String(localized: "Git command failed")
                        failureCode = run.status
                        failureMessage = text.isEmpty ? fallback : text
                        break
                    }
                }
                return CommandBatchResult(
                    output: transcript.joined(separator: "\n"),
                    failureCode: failureCode,
                    failureMessage: failureMessage
                )
            }.value

            guard let self, self.runningOperationID == operationID else { return }
            self.runningOperationID = nil
            self.isBusy = false
            guard self.contextGeneration == generation,
                  self.operation?.id == operationID else {
                // The command may have completed in the old repository, but
                // success-only follow-ups (for example moving a renamed file
                // to Trash) must never continue in the newly selected context.
                completion?(false)
                self.refresh()
                return
            }
            let finishedAt = Date()
            if let failureCode = batch.failureCode {
                self.lastError = batch.failureMessage
                self.operation = Operation(
                    id: operationID,
                    label: label,
                    state: .failed(exitCode: failureCode),
                    output: batch.output,
                    startedAt: self.operation?.startedAt ?? finishedAt,
                    finishedAt: finishedAt
                )
                completion?(false)
            } else {
                self.lastError = nil
                self.operation = Operation(
                    id: operationID,
                    label: label,
                    state: .succeeded,
                    output: batch.output.isEmpty
                        ? String(localized: "Completed successfully.")
                        : batch.output,
                    startedAt: self.operation?.startedAt ?? finishedAt,
                    finishedAt: finishedAt
                )
                completion?(true)
            }
            self.refresh()
        }
    }

    private func failImmediately(
        _ message: String,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard !isBusy else {
            completion?(false)
            return
        }
        lastError = message
        operation = Operation(
            id: UUID(),
            label: String(localized: "Git action"),
            state: .failed(exitCode: -1),
            output: message,
            startedAt: Date(),
            finishedAt: Date()
        )
        completion?(false)
    }

    private func trash(paths: [String], label: String, completedBefore: String? = nil) {
        guard !paths.isEmpty, !isBusy else { return }
        let base = URL(fileURLWithPath: repoRoot, isDirectory: true)
        let expectedRepositoryRoot = repoRoot
        let expectedHeadOID = headOID
        let expectedBranch = branch
        let validationRoot = rootPath
        let generation = contextGeneration
        let operationID = UUID()
        invalidateStatusRefresh()
        runningOperationID = operationID
        isBusy = true
        lastError = nil
        operation = Operation(
            id: operationID, label: label, state: .running, output: "",
            startedAt: Date(), finishedAt: nil
        )

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                guard Self.resolveRepositoryRoot(in: validationRoot) == expectedRepositoryRoot else {
                    return TrashResult(
                        moved: [],
                        failure: String(localized: "Repository changed before the file action could run. Review the current changes and try again.")
                    )
                }
                let liveStatus = Self.runGit(
                    ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=no"],
                    in: expectedRepositoryRoot
                )
                let live = liveStatus.status == 0 ? Self.parseStatus(liveStatus.stdout) : nil
                guard let live,
                      live.headOID == expectedHeadOID,
                      live.branch == expectedBranch else {
                    return TrashResult(
                        moved: [],
                        failure: String(localized: "Branch or HEAD changed before the file action could run. Review the current changes and try again.")
                    )
                }
                var moved: [String] = []
                var failure: String?
                for path in paths {
                    do {
                        try FileManager.default.trashItem(
                            at: base.appendingPathComponent(path), resultingItemURL: nil
                        )
                        moved.append(path)
                    } catch {
                        failure = error.localizedDescription
                        break
                    }
                }
                return TrashResult(moved: moved, failure: failure)
            }.value

            guard let self, self.runningOperationID == operationID else { return }
            self.runningOperationID = nil
            self.isBusy = false
            guard self.contextGeneration == generation,
                  self.operation?.id == operationID else {
                self.refresh()
                return
            }
            let finishedAt = Date()
            if let failure = result.failure {
                let completedResult = completedBefore.map { $0 + "\n" } ?? ""
                let partialResult = result.moved.isEmpty
                    ? ""
                    : "\n\n" + String(localized: "Moved to Trash before the failure:") + "\n"
                        + result.moved.joined(separator: "\n")
                let output = completedResult + failure + partialResult
                self.lastError = result.moved.isEmpty
                    ? completedResult + failure
                    : completedResult + String(
                        localized: "\(failure) (\(result.moved.count) items were already moved to Trash.)"
                    )
                self.operation = Operation(
                    id: operationID, label: label, state: .failed(exitCode: -1),
                    output: output, startedAt: self.operation?.startedAt ?? finishedAt,
                    finishedAt: finishedAt
                )
            } else {
                let output = [
                    completedBefore,
                    String(localized: "Moved to Trash:") + "\n"
                        + result.moved.joined(separator: "\n"),
                ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                self.operation = Operation(
                    id: operationID, label: label, state: .succeeded,
                    output: output,
                    startedAt: self.operation?.startedAt ?? finishedAt,
                    finishedAt: finishedAt
                )
            }
            self.refresh()
        }
    }

    private nonisolated struct CommandBatchResult: Sendable {
        let output: String
        let failureCode: Int32?
        let failureMessage: String?
    }

    private nonisolated struct TrashResult: Sendable {
        let moved: [String]
        let failure: String?
    }

    private nonisolated final class PipeData: @unchecked Sendable {
        var value = Data()
    }

    private func invalidateStatusRefresh() {
        statusRequestID &+= 1
        isRefreshing = false
        isLoadingMoreCommits = false
        refreshPending = false
    }

    private nonisolated static func displayCommand(_ args: [String]) -> String {
        let safeCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_@%+=:,./-")
        )
        return args.map { arg in
            guard arg.isEmpty || arg.unicodeScalars.contains(where: { !safeCharacters.contains($0) }) else {
                return arg
            }
            return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    // MARK: - Status

    private func clearRepositoryState(
        preserveIdentity: Bool = false,
        preserveFailedOperation: Bool = false
    ) {
        let failedOperation = preserveFailedOperation ? operation : nil
        let failedError = preserveFailedOperation ? lastError : nil
        topLevel = ""
        isRepo = false
        branch = nil
        headOID = nil
        hasHead = true
        upstream = nil
        ahead = 0
        behind = 0
        hasUpstream = false
        lineAdditions = 0
        lineDeletions = 0
        mergeEntries = []
        stagedEntries = []
        changedEntries = []
        worktrees = []
        fileDecorations = [:]
        ignoredPaths = []
        branches = []
        defaultBranch = nil
        remotes = []
        recentCommits = []
        hasMoreRecentCommits = false
        isLoadingMoreCommits = false
        repositoryOperation = nil
        stashCount = 0
        isRefreshing = false
        isBusy = runningOperationID != nil
        operation = failedOperation
        lastError = failedError
        statusError = nil
        statusRequestID &+= 1
        if !preserveIdentity { repositoryIdentity = "" }
    }

    private func apply(_ loadResult: StatusLoadResult) {
        switch loadResult {
        case .notRepository:
            // A refresh can finish after a user action starts. Do not let a
            // transient status failure erase the active operation/result.
            if isBusy { return }
            let preserveFailure: Bool
            if let operation, case .failed = operation.state {
                preserveFailure = true
            } else {
                preserveFailure = false
            }
            stopWorktreeMetadataWatcher()
            clearRepositoryState(preserveFailedOperation: preserveFailure)
            return
        case .failed(let message):
            if isBusy { return }
            let preserveFailure: Bool
            if let operation, case .failed = operation.state {
                preserveFailure = true
            } else {
                preserveFailure = false
            }
            clearRepositoryState(
                preserveIdentity: true,
                preserveFailedOperation: preserveFailure
            )
            statusError = message
            return
        case .repository(let result):
            statusError = nil
            applyRepository(result)
        }
    }

    private func applyRepository(_ result: StatusResult) {
        isRepo = true
        branch = result.branch
        headOID = result.headOID
        hasHead = result.hasHead
        upstream = result.upstream
        ahead = result.ahead
        behind = result.behind
        hasUpstream = result.upstream != nil
        lineAdditions = result.lineAdditions
        lineDeletions = result.lineDeletions
        topLevel = result.topLevel
        repositoryIdentity = result.topLevel
        if result.loadedDetails {
            worktrees = result.worktrees
            branches = result.branches
            defaultBranch = result.defaultBranch
            remotes = result.remotes
            recentCommits = result.recentCommits
            hasMoreRecentCommits = result.hasMoreRecentCommits
            repositoryOperation = result.repositoryOperation
            stashCount = result.stashCount
            configureWorktreeMetadataWatcher(
                commonGitDirectory: result.commonGitDirectory
            )
        }

        let entries = result.entries.map { entry in
            var entry = entry
            entry.repositoryRoot = result.topLevel
            return entry
        }
        fileDecorations = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.path, Self.fileDecoration(for: $0)) }
        )
        ignoredPaths = result.ignoredPaths
        mergeEntries = entries.filter(\.isConflict)
        stagedEntries = entries.filter {
            !$0.isConflict && $0.staged != "." && $0.staged != "?"
        }
        changedEntries = entries.filter {
            !$0.isConflict && $0.unstaged != "."
        }
    }

    private func configureWorktreeMetadataWatcher(commonGitDirectory: String) {
        guard !commonGitDirectory.isEmpty else {
            stopWorktreeMetadataWatcher()
            return
        }
        let worktreesDirectory = (commonGitDirectory as NSString)
            .appendingPathComponent("worktrees")
        var isDirectory: ObjCBool = false
        let watchedPath: String
        if FileManager.default.fileExists(
            atPath: worktreesDirectory, isDirectory: &isDirectory
        ), isDirectory.boolValue {
            watchedPath = worktreesDirectory
        } else {
            // Before the first linked worktree exists, watch the common Git
            // directory so creation of its `worktrees` child is still seen.
            watchedPath = commonGitDirectory
        }
        guard watchedPath != worktreeMetadataWatchedPath else { return }
        stopWorktreeMetadataWatcher()

        let descriptor = Darwin.open(watchedPath, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend, .link],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self,
                  self.worktreeMetadataWatchedPath == watchedPath else { return }
            let event = self.worktreeMetadataWatcher?.data ?? []
            if event.contains(.delete) || event.contains(.rename) {
                self.stopWorktreeMetadataWatcher()
            }
            self.refresh()
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        worktreeMetadataWatchedPath = watchedPath
        worktreeMetadataWatcher = source
        source.resume()
    }

    private func stopWorktreeMetadataWatcher() {
        worktreeMetadataWatcher?.cancel()
        worktreeMetadataWatcher = nil
        worktreeMetadataWatchedPath = ""
    }

    nonisolated enum StatusLoadResult: Equatable, Sendable {
        case repository(StatusResult)
        case notRepository
        case failed(String)
    }

    nonisolated struct StatusResult: Equatable, Sendable {
        var branch: String?
        var headOID: String?
        var hasHead = true
        var upstream: String?
        var ahead = 0
        var behind = 0
        var lineAdditions = 0
        var lineDeletions = 0
        var topLevel = ""
        var commonGitDirectory = ""
        var entries: [Entry] = []
        var ignoredPaths: Set<String> = []
        var worktrees: [Worktree] = []
        var branches: [String] = []
        var defaultBranch: String?
        var remotes: [String] = []
        var recentCommits: [RecentCommit] = []
        var hasMoreRecentCommits = false
        var repositoryOperation: String?
        var stashCount = 0
        var loadedDetails = false
    }

    /// Runs Git while draining stdout and stderr concurrently. Dedicated
    /// reader threads are intentional: several restored diff tabs can call
    /// this from Swift's cooperative executor at once, and dispatching the
    /// readers back onto the shared pool can starve every pipe drain.
    nonisolated static func runGit(
        _ args: [String], in dir: String, timeout: TimeInterval? = nil
    ) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: dir, isDirectory: true)
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        // Fail rather than hanging on a credential prompt behind the app.
        env["GIT_TERMINAL_PROMPT"] = "0"
        // Git diagnostics are parsed only to distinguish an ordinary folder
        // from a broken repository. Pinning the locale makes that safe and
        // also keeps relative dates stable in the compact history list.
        env["LC_ALL"] = "C"
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let processExited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in processExited.signal() }

        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        let outData = PipeData()
        let errData = PipeData()
        let readers = DispatchGroup()
        // These readers are on the synchronous completion path below. Match
        // the caller so a user-initiated Git request never waits on utility
        // threads, while background refreshes keep their lower priority.
        let readerQualityOfService = Thread.current.qualityOfService
        readers.enter()
        let stdoutReader = Thread {
            outData.value = stdout.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        stdoutReader.qualityOfService = readerQualityOfService
        stdoutReader.start()
        readers.enter()
        let stderrReader = Thread {
            errData.value = stderr.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        stderrReader.qualityOfService = readerQualityOfService
        stderrReader.start()
        var timedOut = false
        if let timeout {
            timedOut = processExited.wait(timeout: .now() + timeout) == .timedOut
            if timedOut {
                process.terminate()
                if processExited.wait(timeout: .now() + 1) == .timedOut {
                    // Git can launch a helper that ignores SIGTERM. It is our
                    // child, so force it down before waiting for pipe EOF.
                    Darwin.kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }
            }
        } else {
            process.waitUntilExit()
        }
        readers.wait()
        let output = String(data: outData.value, encoding: .utf8) ?? ""
        var errorOutput = String(data: errData.value, encoding: .utf8) ?? ""
        if timedOut {
            let timeoutMessage = String(localized: "Git did not respond in time.")
            if !errorOutput.isEmpty, !errorOutput.hasSuffix("\n") {
                errorOutput += "\n"
            }
            errorOutput += timeoutMessage
            return (-2, output, errorOutput)
        }
        return (
            process.terminationStatus,
            output,
            errorOutput
        )
    }

    /// Resolves the active repository and distinguishes a normal non-repo
    /// directory from an actual Git failure that the UI should surface.
    private nonisolated static func runGitStatus(
        in root: String,
        recentCommitLimit: Int
    ) -> StatusLoadResult {
        // A filesystem, Git helper, or corrupt repository must not leave the
        // initial sidebar spinner running forever. Share one deadline across
        // the full snapshot instead of allowing every detail command its own
        // timeout.
        let deadline = Date().addingTimeInterval(10)
        let timeoutMessage = String(localized: "Git did not respond in time.")
        func statusGit(
            _ args: [String], in directory: String
        ) -> (status: Int32, stdout: String, stderr: String) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return (-2, "", timeoutMessage) }
            return runGit(args, in: directory, timeout: remaining)
        }

        let top = statusGit(["rev-parse", "--show-toplevel"], in: root)
        guard top.status == 0 else {
            let failure = gitFailureMessage(
                top,
                fallback: String(localized: "Unable to locate the Git repository.")
            )
            if top.status == 128,
               failure.localizedCaseInsensitiveContains("not a git repository"),
               !containsGitMetadata(atOrAbove: root) {
                return .notRepository
            }
            return .failed(failure)
        }
        let resolvedRoot = strippingTrailingLineEnding(top.stdout)
        guard !resolvedRoot.isEmpty else {
            return .failed(String(localized: "Git returned an empty repository path."))
        }
        let status = statusGit(
            [
                "status", "--porcelain=v2", "--branch", "-z",
                "--untracked-files=all", "--ignored=matching",
            ],
            in: resolvedRoot
        )
        guard status.status == 0 else {
            return .failed(
                gitFailureMessage(
                    status,
                    fallback: String(localized: "Unable to read Git status.")
                )
            )
        }
        var result = parseStatus(status.stdout)
        result.topLevel = resolvedRoot

        let commonGitDirectory = statusGit(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            in: resolvedRoot
        )
        if commonGitDirectory.status == 0 {
            result.commonGitDirectory = strippingTrailingLineEnding(
                commonGitDirectory.stdout
            )
        }

        // Worktrees belong to the repository family rather than only this
        // checkout. `-z` keeps agent-created paths lossless, including spaces
        // and newlines, while porcelain fields remain forward-compatible.
        let worktreeList = statusGit(
            ["worktree", "list", "--porcelain", "-z"], in: resolvedRoot
        )
        if worktreeList.status == 0 {
            result.worktrees = parseWorktrees(worktreeList.stdout)
        }

        let diff = statusGit(
            result.hasHead
                ? ["diff", "--numstat", "HEAD", "--"]
                : ["diff", "--numstat", "--cached", "--"],
            in: resolvedRoot
        )
        if diff.status == 0 {
            let totals = parseNumstat(diff.stdout)
            result.lineAdditions = totals.additions
            result.lineDeletions = totals.deletions
        }
        // An unborn branch has no HEAD to compare against. Its cached diff is
        // the initial snapshot; add any edits made after staging as a second
        // layer so the toolbar still reflects all pending work.
        if !result.hasHead {
            let unstaged = statusGit(["diff", "--numstat", "--"], in: resolvedRoot)
            if unstaged.status == 0 {
                let totals = parseNumstat(unstaged.stdout)
                result.lineAdditions += totals.additions
                result.lineDeletions += totals.deletions
            }
        }
        // `git diff` intentionally omits untracked files. Count their text
        // lines as additions so the compact toolbar totals cover all pending
        // work reported by the porcelain snapshot.
        result.lineAdditions += untrackedLineAdditions(
            for: result.entries,
            in: resolvedRoot
        )

        result.loadedDetails = true
        let repoRoot = resolvedRoot

        let refs = statusGit(
            ["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: repoRoot
        )
        if refs.status == 0 {
            result.branches = refs.stdout.split(separator: "\n").map(String.init).sorted()
        }

        let remoteRun = statusGit(["remote"], in: repoRoot)
        if remoteRun.status == 0 {
            result.remotes = remoteRun.stdout.split(separator: "\n").map(String.init).sorted()
        }

        // A clone records its remote's default branch as a symbolic HEAD.
        // Prefer origin when more than one remote is present because that is
        // the repository the local branch list conventionally belongs to.
        if let remote = result.remotes.contains("origin") ? "origin" : result.remotes.first {
            let remoteHead = statusGit(
                ["symbolic-ref", "--quiet", "--short", "refs/remotes/\(remote)/HEAD"],
                in: repoRoot
            )
            let prefix = "\(remote)/"
            let ref = strippingTrailingLineEnding(remoteHead.stdout)
            if remoteHead.status == 0, ref.hasPrefix(prefix) {
                let branch = String(ref.dropFirst(prefix.count))
                if result.branches.contains(branch) {
                    result.defaultBranch = branch
                }
            }
        }

        // NUL-delimited name-status records preserve every valid path while
        // supplying the nested file rows used by the native commit graph.
        let log = statusGit([
            "log", "-n", "\(recentCommitLimit + 1)", "--decorate=short",
            "--pretty=format:%x1e%H%x1f%h%x1f%s%x1f%an%x1f%ct%x1f%P%x1f%D",
            "--name-status", "-z",
        ], in: repoRoot)
        if log.status == 0 {
            let commits = parseRecentCommits(log.stdout)
            result.hasMoreRecentCommits = commits.count > recentCommitLimit
            result.recentCommits = Array(commits.prefix(recentCommitLimit))
        }

        let stash = statusGit(
            ["rev-list", "--walk-reflogs", "--count", "refs/stash"], in: repoRoot
        )
        if stash.status == 0 {
            result.stashCount = Int(stash.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        let gitDir = statusGit(["rev-parse", "--absolute-git-dir"], in: repoRoot)
        if gitDir.status == 0 {
            let path = strippingTrailingLineEnding(gitDir.stdout)
            result.repositoryOperation = detectRepositoryOperation(gitDirectory: path)
        }
        return .repository(result)
    }

    private nonisolated static func resolveRepositoryRoot(in root: String) -> String? {
        let top = runGit(["rev-parse", "--show-toplevel"], in: root)
        guard top.status == 0 else { return nil }
        let path = strippingTrailingLineEnding(top.stdout)
        return path.isEmpty ? nil : path
    }

    /// A malformed `.git` directory/file can produce the same rev-parse text
    /// as a plain folder. Preserve that as an actionable status error instead
    /// of offering to initialize a nested repository on top of broken metadata.
    private nonisolated static func containsGitMetadata(atOrAbove root: String) -> Bool {
        let fm = FileManager.default
        var directory = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        while true {
            if fm.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return true
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return false }
            directory = parent
        }
    }

    private nonisolated static func strippingTrailingLineEnding(_ value: String) -> String {
        var value = value
        if value.hasSuffix("\n") { value.removeLast() }
        if value.hasSuffix("\r") { value.removeLast() }
        return value
    }

    private nonisolated static func normalizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private nonisolated static func gitFailureMessage(
        _ run: (status: Int32, stdout: String, stderr: String), fallback: String
    ) -> String {
        let message = [run.stderr, run.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return message ?? fallback
    }

    /// Parses NUL-delimited porcelain v2. Unlike Git's default quoted output,
    /// this preserves spaces, quotes, tabs, and newlines in file names.
    nonisolated static func parseStatus(_ output: String) -> StatusResult {
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var result = StatusResult()
        var index = 0
        while index < records.count {
            let record = records[index]
            if record.hasPrefix("# branch.oid ") {
                let oid = String(record.dropFirst("# branch.oid ".count))
                result.hasHead = oid != "(initial)"
                result.headOID = result.hasHead ? oid : nil
            } else if record.hasPrefix("# branch.head ") {
                let name = String(record.dropFirst("# branch.head ".count))
                result.branch = name == "(detached)" ? "detached HEAD" : name
            } else if record.hasPrefix("# branch.upstream ") {
                result.upstream = String(record.dropFirst("# branch.upstream ".count))
            } else if record.hasPrefix("# branch.ab ") {
                let parts = record.dropFirst("# branch.ab ".count).split(separator: " ")
                for part in parts {
                    if part.hasPrefix("+") { result.ahead = Int(part.dropFirst()) ?? 0 }
                    if part.hasPrefix("-") { result.behind = Int(part.dropFirst()) ?? 0 }
                }
            } else if record.hasPrefix("1 ") {
                let fields = record.split(separator: " ", maxSplits: 8)
                if fields.count == 9, fields[1].count == 2 {
                    let xy = Array(fields[1])
                    result.entries.append(
                        Entry(path: String(fields[8]), staged: xy[0], unstaged: xy[1])
                    )
                }
            } else if record.hasPrefix("2 ") {
                let fields = record.split(separator: " ", maxSplits: 9)
                if fields.count == 10, fields[1].count == 2, index + 1 < records.count {
                    let xy = Array(fields[1])
                    // With -z, the destination is in this record and the
                    // original path is the following NUL-delimited token.
                    result.entries.append(
                        Entry(
                            path: String(fields[9]), staged: xy[0], unstaged: xy[1],
                            origPath: records[index + 1]
                        )
                    )
                    index += 1
                }
            } else if record.hasPrefix("u ") {
                let fields = record.split(separator: " ", maxSplits: 10)
                if fields.count == 11, fields[1].count == 2 {
                    let xy = Array(fields[1])
                    result.entries.append(
                        Entry(
                            path: String(fields[10]), staged: xy[0], unstaged: xy[1],
                            isConflict: true
                        )
                    )
                }
            } else if record.hasPrefix("? ") {
                result.entries.append(
                    Entry(path: String(record.dropFirst(2)), staged: "?", unstaged: "?")
                )
            } else if record.hasPrefix("! ") {
                result.ignoredPaths.insert(String(record.dropFirst(2)))
            }
            index += 1
        }
        return result
    }

    /// Parses `git worktree list --porcelain -z`. Records are separated by an
    /// empty NUL field and each attribute is itself NUL-terminated, so paths
    /// never need Git's quoting rules. Unknown attributes are ignored.
    nonisolated static func parseWorktrees(_ output: String) -> [Worktree] {
        var result: [Worktree] = []
        var path: String?
        var headOID: String?
        var branch: String?
        var isDetached = false
        var isBare = false
        var lockedReason: String?
        var prunableReason: String?

        func appendCurrent() {
            guard let path, !path.isEmpty else { return }
            result.append(Worktree(
                path: path,
                headOID: headOID,
                branch: branch,
                isDetached: isDetached,
                isBare: isBare,
                lockedReason: lockedReason,
                prunableReason: prunableReason
            ))
        }

        func resetCurrent() {
            path = nil
            headOID = nil
            branch = nil
            isDetached = false
            isBare = false
            lockedReason = nil
            prunableReason = nil
        }

        for token in output.split(separator: "\0", omittingEmptySubsequences: false) {
            let record = String(token)
            if record.isEmpty {
                appendCurrent()
                resetCurrent()
                continue
            }
            if record.hasPrefix("worktree ") {
                path = String(record.dropFirst("worktree ".count))
            } else if record.hasPrefix("HEAD ") {
                headOID = String(record.dropFirst("HEAD ".count))
            } else if record.hasPrefix("branch ") {
                let ref = String(record.dropFirst("branch ".count))
                let prefix = "refs/heads/"
                branch = ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : ref
            } else if record == "detached" {
                isDetached = true
            } else if record == "bare" {
                isBare = true
            } else if record == "locked" {
                lockedReason = ""
            } else if record.hasPrefix("locked ") {
                lockedReason = String(record.dropFirst("locked ".count))
            } else if record == "prunable" {
                prunableReason = ""
            } else if record.hasPrefix("prunable ") {
                prunableReason = String(record.dropFirst("prunable ".count))
            }
        }
        // Be tolerant of producers that omit the porcelain block's final
        // empty field even though Git itself currently emits one.
        appendCurrent()
        return result
    }

    /// Adds the numeric columns from `git diff --numstat`. Binary-file rows
    /// use `-` instead of a count and therefore contribute zero lines.
    nonisolated static func parseNumstat(_ output: String) -> (additions: Int, deletions: Int) {
        output.split(separator: "\n").reduce(into: (additions: 0, deletions: 0)) { total, row in
            let fields = row.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 2 else { return }
            total.additions += Int(fields[0]) ?? 0
            total.deletions += Int(fields[1]) ?? 0
        }
    }

    /// Git's numstat output has no representation for untracked files. Mirror
    /// its new-text-file behavior without spawning one Git process per path.
    private nonisolated static func untrackedLineAdditions(
        for entries: [Entry], in root: String
    ) -> Int {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"

        // Line totals are secondary metadata. Keep generated or accidentally
        // enormous untracked trees from delaying the repository itself.
        let maximumFiles = 2_048
        let maximumFileBytes = 8 * 1_024 * 1_024
        var remainingBytes = 32 * 1_024 * 1_024
        var visitedFiles = 0
        var total = 0
        for entry in entries where entry.staged == "?" {
            guard visitedFiles < maximumFiles, remainingBytes > 0 else { break }
            visitedFiles += 1
            let fileURL = rootURL.appendingPathComponent(entry.path).standardizedFileURL
            guard fileURL.path.hasPrefix(rootPrefix) else { continue }
            let count = textLineCount(
                at: fileURL,
                maximumBytes: min(maximumFileBytes, remainingBytes)
            )
            total += count.lines
            remainingBytes -= count.bytesRead
        }
        return total
    }

    /// Counts logical lines while using Git's usual NUL-byte binary heuristic.
    /// Symlink content is its destination path, which is one added line.
    private nonisolated static func textLineCount(
        at url: URL,
        maximumBytes: Int
    ) -> (lines: Int, bytesRead: Int) {
        guard let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        ) else { return (0, 0) }
        if values.isSymbolicLink == true { return (1, 0) }
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize <= maximumBytes,
              let handle = try? FileHandle(forReadingFrom: url) else { return (0, 0) }
        defer { try? handle.close() }

        let binaryProbeSize = 8_000
        guard let probe = try? handle.read(upToCount: binaryProbeSize) else {
            return (0, 0)
        }
        guard !probe.contains(0) else { return (0, probe.count) }

        var byteCount = probe.count
        var newlineCount = probe.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        var lastByte = probe.last

        while let chunk = try? handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            byteCount += chunk.count
            newlineCount += chunk.reduce(into: 0) { count, byte in
                if byte == 0x0A { count += 1 }
            }
            lastByte = chunk.last
        }

        guard byteCount > 0 else { return (0, 0) }
        return (newlineCount + (lastByte == 0x0A ? 0 : 1), byteCount)
    }

    private static func fileDecoration(for entry: Entry) -> FileDecoration {
        let statuses = [entry.staged, entry.unstaged]
        if entry.isConflict || statuses.contains("U") { return .conflict }
        if statuses.contains("?") { return .untracked }
        if entry.staged == "A" { return .added }
        if statuses.contains("D") { return .deleted }
        if statuses.contains("R") { return .renamed }
        if statuses.contains("C") { return .copied }
        return .modified
    }

    nonisolated static func parseRecentCommits(_ output: String) -> [RecentCommit] {
        output.split(separator: "\u{1e}").compactMap { record in
            var chunks = record.split(separator: "\u{0}", omittingEmptySubsequences: false)
                .map(String.init)
            guard !chunks.isEmpty else { return nil }

            // With --name-status -z, the first status follows the pretty
            // header after a newline; subsequent statuses are their own NUL
            // fields. Rename/copy records carry both old and new paths.
            let headerAndStatus = chunks.removeFirst()
            let boundary = headerAndStatus.lastIndex(of: "\n")
            let header = boundary.map { String(headerAndStatus[..<$0]) } ?? headerAndStatus
            var statusToken = boundary.map {
                String(headerAndStatus[headerAndStatus.index(after: $0)...])
            } ?? ""
            let fields = header.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count == 7, let timestamp = TimeInterval(fields[4]) else {
                return nil
            }

            var files: [RecentCommit.FileChange] = []
            var index = 0
            while !statusToken.isEmpty, index < chunks.count {
                guard let status = statusToken.first else { break }
                if status == "R" || status == "C" {
                    guard index + 1 < chunks.count else { break }
                    files.append(.init(
                        status: status,
                        path: chunks[index + 1],
                        originalPath: chunks[index]
                    ))
                    index += 2
                } else {
                    files.append(.init(
                        status: status,
                        path: chunks[index],
                        originalPath: nil
                    ))
                    index += 1
                }
                guard index < chunks.count else { break }
                statusToken = chunks[index]
                index += 1
            }

            let parentHash = fields[5]
                .split(separator: " ")
                .first
                .map(String.init)
            let references = fields[6]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return RecentCommit(
                hash: String(fields[0]), shortHash: String(fields[1]),
                subject: String(fields[2]), author: String(fields[3]),
                date: Date(timeIntervalSince1970: timestamp),
                parentHash: parentHash,
                references: references,
                files: files
            )
        }
    }

    nonisolated static func detectRepositoryOperation(gitDirectory: String) -> String? {
        let fm = FileManager.default
        let git = URL(fileURLWithPath: gitDirectory, isDirectory: true)
        func exists(_ name: String) -> Bool {
            fm.fileExists(atPath: git.appendingPathComponent(name).path)
        }

        if exists("rebase-merge") || exists("rebase-apply") {
            return String(localized: "Rebase in progress")
        }
        if exists("MERGE_HEAD") {
            return String(localized: "Merge in progress")
        }
        if exists("CHERRY_PICK_HEAD") {
            return String(localized: "Cherry-pick in progress")
        }
        if exists("REVERT_HEAD") {
            return String(localized: "Revert in progress")
        }
        if exists("BISECT_LOG") {
            return String(localized: "Bisect in progress")
        }
        return nil
    }
}
