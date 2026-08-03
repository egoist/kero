import Combine
import Foundation

struct RemoteFileItem: Identifiable, Equatable, Sendable {
    var id: String { path }

    let name: String
    let path: String
    let isDirectory: Bool
    let depth: Int
}

struct RemoteGitEntry: Identifiable, Equatable, Sendable {
    var id: String { path }

    let path: String
    let stagedStatus: Character
    let worktreeStatus: Character
    let originalPath: String?

    init(
        path: String,
        stagedStatus: Character,
        worktreeStatus: Character,
        originalPath: String? = nil
    ) {
        self.path = path
        self.stagedStatus = stagedStatus
        self.worktreeStatus = worktreeStatus
        self.originalPath = originalPath
    }

    var fileName: String {
        (path as NSString).lastPathComponent
    }

    var directory: String {
        let value = (path as NSString).deletingLastPathComponent
        return value == "." ? "" : value
    }

    var isConflict: Bool {
        stagedStatus == "U"
            || worktreeStatus == "U"
            || (stagedStatus == "A" && worktreeStatus == "A")
            || (stagedStatus == "D" && worktreeStatus == "D")
    }

    var isStaged: Bool {
        stagedStatus != "." && stagedStatus != "?"
    }

    var hasWorktreeChange: Bool {
        worktreeStatus != "." || stagedStatus == "?"
    }

    var isIntentToAdd: Bool {
        stagedStatus == "." && worktreeStatus == "A"
    }

    var isUntracked: Bool {
        stagedStatus == "?" || isIntentToAdd
    }

    var isWorktreeRename: Bool {
        worktreeStatus == "R" && originalPath != nil
    }

    var isWorktreeCopy: Bool {
        worktreeStatus == "C" && originalPath != nil
    }
}

struct RemoteGitCommit: Identifiable, Equatable, Sendable {
    var id: String { hash }

    let hash: String
    let shortHash: String
    let subject: String
    let author: String
    let date: Date

    var relativeDate: String {
        date.formatted(
            .relative(
                presentation: .named,
                unitsStyle: .abbreviated
            )
        )
    }
}

struct RemoteGitOperation: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case running
        case succeeded
        case failed
    }

    let id: UUID
    let label: String
    let state: State
    let output: String

    var isRunning: Bool {
        state == .running
    }

    var statusText: String {
        switch state {
        case .running:
            "\(label)…"
        case .succeeded:
            "\(label) completed"
        case .failed:
            "\(label) failed"
        }
    }
}

struct RemoteGitSnapshot: Equatable, Sendable {
    let repositoryRoot: String
    let branch: String
    let headOID: String?
    let hasHead: Bool
    let upstream: String?
    let ahead: Int
    let behind: Int
    let entries: [RemoteGitEntry]
    let branches: [String]
    let remotes: [String]
    let recentCommits: [RemoteGitCommit]
    let repositoryOperation: String?
    let stashCount: Int

    init(
        repositoryRoot: String,
        branch: String,
        headOID: String? = nil,
        hasHead: Bool = true,
        upstream: String?,
        ahead: Int,
        behind: Int,
        entries: [RemoteGitEntry],
        branches: [String] = [],
        remotes: [String] = [],
        recentCommits: [RemoteGitCommit] = [],
        repositoryOperation: String? = nil,
        stashCount: Int = 0
    ) {
        self.repositoryRoot = repositoryRoot
        self.branch = branch
        self.headOID = headOID
        self.hasHead = hasHead
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.entries = entries
        self.branches = branches
        self.remotes = remotes
        self.recentCommits = recentCommits
        self.repositoryOperation = repositoryOperation
        self.stashCount = stashCount
    }

    var conflicts: [RemoteGitEntry] {
        entries.filter(\.isConflict)
    }

    var staged: [RemoteGitEntry] {
        entries.filter { $0.isStaged && !$0.isConflict }
    }

    var changed: [RemoteGitEntry] {
        entries.filter { $0.hasWorktreeChange && !$0.isConflict }
    }

    var totalChangeCount: Int {
        conflicts.count + staged.count + changed.count
    }
}

enum RemoteProjectError: LocalizedError {
    case invalidDirectory
    case commandFailed(String)
    case binaryFile

    var errorDescription: String? {
        switch self {
        case .invalidDirectory:
            "The remote shell did not report a project directory."
        case .commandFailed(let message):
            message.isEmpty ? "The remote command failed." : message
        case .binaryFile:
            "This file appears to be binary and can’t be previewed as text."
        }
    }
}

@MainActor
final class RemoteProjectModel: ObservableObject {
    typealias Executor = @MainActor (String) async throws -> SSHCommandResult

    @Published private(set) var workingDirectory: String?
    @Published private(set) var projectRoot: String?
    @Published private(set) var files: [RemoteFileItem] = []
    @Published private(set) var isLoadingFiles = false
    @Published private(set) var filesError: String?
    @Published private(set) var git: RemoteGitSnapshot?
    @Published private(set) var hasLoadedGit = false
    @Published private(set) var canInitializeGit = false
    @Published private(set) var isLoadingGit = false
    @Published private(set) var gitError: String?
    @Published private(set) var isRunningGitAction = false
    @Published private(set) var gitOperation: RemoteGitOperation?

    private struct FileNode: Equatable {
        let name: String
        let path: String
        let isDirectory: Bool
    }

    private let execute: Executor
    private var childrenByDirectory: [String: [FileNode]] = [:]
    private var expandedDirectories: Set<String> = []
    private var contextGeneration: UInt = 0
    private var contextTask: Task<Void, Never>?

    init(execute: @escaping Executor) {
        self.execute = execute
    }

    var projectName: String {
        guard let projectRoot else {
            return "Project"
        }
        let name = (projectRoot as NSString).lastPathComponent
        return name.isEmpty ? projectRoot : name
    }

    func setWorkingDirectory(_ rawValue: String?) {
        guard let directory = Self.normalizedDirectory(rawValue),
              directory != workingDirectory else {
            return
        }
        workingDirectory = directory
        beginResolvingContext(for: directory)
    }

    func discoverInitialDirectory() async {
        if workingDirectory == nil {
            do {
                let result = try await execute("pwd -P")
                guard result.exitStatus == 0 else {
                    throw Self.commandError(result)
                }
                setWorkingDirectory(result.stdoutString)
            } catch {
                filesError = error.localizedDescription
                gitError = error.localizedDescription
            }
        } else if projectRoot == nil, let workingDirectory {
            beginResolvingContext(for: workingDirectory)
        }
        await waitForContext()
    }

    func refreshFiles() async {
        await ensureContext()
        guard let projectRoot else {
            filesError = RemoteProjectError.invalidDirectory.localizedDescription
            return
        }
        await loadChildren(of: projectRoot, replacingRoot: true)
    }

    func toggleDirectory(_ item: RemoteFileItem) async {
        guard item.isDirectory else {
            return
        }
        if expandedDirectories.remove(item.path) != nil {
            rebuildVisibleFiles()
            return
        }
        expandedDirectories.insert(item.path)
        if childrenByDirectory[item.path] == nil {
            await loadChildren(of: item.path, replacingRoot: false)
        } else {
            rebuildVisibleFiles()
        }
    }

    func isExpanded(_ item: RemoteFileItem) -> Bool {
        expandedDirectories.contains(item.path)
    }

    func loadFile(_ item: RemoteFileItem) async throws -> String {
        guard !item.isDirectory else {
            return ""
        }
        let result = try await execute(
            "LC_ALL=C head -c 262144 -- \(Self.shellQuote(item.path))"
        )
        guard result.exitStatus == 0 else {
            throw Self.commandError(result)
        }
        guard !result.stdout.contains(0) else {
            throw RemoteProjectError.binaryFile
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }

    func refreshGit() async {
        await ensureContext()
        guard let projectRoot else {
            git = nil
            hasLoadedGit = true
            canInitializeGit = false
            gitError = RemoteProjectError.invalidDirectory.localizedDescription
            return
        }

        isLoadingGit = true
        gitError = nil
        canInitializeGit = false
        defer {
            isLoadingGit = false
            hasLoadedGit = true
        }
        do {
            let result = try await execute(
                "env LC_ALL=C GIT_TERMINAL_PROMPT=0 "
                    + "GIT_OPTIONAL_LOCKS=0 git "
                    + "-C \(Self.shellQuote(projectRoot)) "
                    + "status --porcelain=v2 --branch -z --untracked-files=all"
            )
            guard result.exitStatus == 0 else {
                git = nil
                if Self.isMissingRepository(result) {
                    canInitializeGit = true
                    return
                }
                throw Self.commandError(result)
            }
            var snapshot = Self.parseGitStatus(
                result.stdout,
                repositoryRoot: projectRoot
            )
            let details = try await execute(
                Self.repositoryDetailsCommand(projectRoot)
            )
            if details.exitStatus == 0 {
                snapshot = Self.parseRepositoryDetails(
                    details.stdout,
                    snapshot: snapshot
                )
            }
            git = snapshot
        } catch {
            git = nil
            canInitializeGit = false
            gitError = error.localizedDescription
        }
    }

    func initializeRepository() async {
        guard let projectRoot else {
            gitError = RemoteProjectError.invalidDirectory.localizedDescription
            return
        }
        if await runGitAction(
            label: "Initialize repository",
            commands: ["init"],
            root: projectRoot,
            validateSnapshot: false
        ) {
            canInitializeGit = false
        } else {
            canInitializeGit = true
        }
    }

    @discardableResult
    func stage(_ entry: RemoteGitEntry) async -> Bool {
        let paths = [entry.path]
            + (entry.worktreeStatus == "R"
                ? entry.originalPath.map { [$0] } ?? []
                : [])
        return await runGitAction(
            label: "Stage \(entry.fileName)",
            commands: [
                "--literal-pathspecs add -- "
                    + Self.shellArguments(paths)
            ]
        )
    }

    @discardableResult
    func unstage(_ entry: RemoteGitEntry) async -> Bool {
        guard let git else {
            return failGitAction("Repository changed; refresh and try again.")
        }
        let paths = [entry.path]
            + (entry.stagedStatus == "R"
                ? entry.originalPath.map { [$0] } ?? []
                : [])
        let arguments = git.hasHead
            ? "--literal-pathspecs restore --staged -- "
                + Self.shellArguments(paths)
            : "--literal-pathspecs rm --cached -f -- "
                + Self.shellArguments(paths)
        return await runGitAction(
            label: "Unstage \(entry.fileName)",
            commands: [arguments]
        )
    }

    @discardableResult
    func stageAll() async -> Bool {
        await runGitAction(
            label: "Stage all changes",
            commands: ["add -A"]
        )
    }

    @discardableResult
    func unstageAll() async -> Bool {
        guard let git else {
            return failGitAction("Repository changed; refresh and try again.")
        }
        let arguments = git.hasHead
            ? "restore --staged -- ."
            : "rm --cached -r -f -- ."
        return await runGitAction(
            label: "Unstage all changes",
            commands: [arguments]
        )
    }

    @discardableResult
    func discard(_ entry: RemoteGitEntry) async -> Bool {
        var commands: [String] = []
        if entry.isIntentToAdd {
            commands.append(
                "--literal-pathspecs rm --cached -f -- "
                    + Self.shellQuote(entry.path)
            )
            commands.append(
                "--literal-pathspecs clean -f -- "
                    + Self.shellQuote(entry.path)
            )
        } else if entry.isUntracked || entry.isWorktreeCopy {
            commands.append(
                "--literal-pathspecs clean -f -- "
                    + Self.shellQuote(entry.path)
            )
        } else if entry.isWorktreeRename,
                  let originalPath = entry.originalPath {
            commands.append(
                "--literal-pathspecs restore --worktree -- "
                    + Self.shellQuote(originalPath)
            )
            commands.append(
                "--literal-pathspecs clean -f -- "
                    + Self.shellQuote(entry.path)
            )
        } else {
            commands.append(
                "--literal-pathspecs restore --worktree -- "
                    + Self.shellQuote(entry.path)
            )
        }
        return await runGitAction(
            label: "Discard \(entry.fileName)",
            commands: commands
        )
    }

    @discardableResult
    func discardChanges(_ entries: [RemoteGitEntry]) async -> Bool {
        guard !entries.isEmpty else {
            return failGitAction("There are no changes to discard.")
        }
        let intentToAdd = entries.filter(\.isIntentToAdd)
        let moved = entries.filter {
            $0.isWorktreeRename || $0.isWorktreeCopy
        }
        let untracked = entries.filter(\.isUntracked).map(\.path)
            + moved.map(\.path)
        let tracked = entries.filter {
            !$0.isUntracked
                && !$0.isWorktreeRename
                && !$0.isWorktreeCopy
        }.map(\.path)
            + moved.filter(\.isWorktreeRename)
                .compactMap(\.originalPath)
        var commands: [String] = []
        if !tracked.isEmpty {
            commands.append(
                "--literal-pathspecs restore --worktree -- "
                    + Self.shellArguments(tracked)
            )
        }
        if !intentToAdd.isEmpty {
            commands.append(
                "--literal-pathspecs rm --cached -f -- "
                    + Self.shellArguments(intentToAdd.map(\.path))
            )
        }
        if !untracked.isEmpty {
            commands.append(
                "--literal-pathspecs clean -f -- "
                    + Self.shellArguments(untracked)
            )
        }
        return await runGitAction(
            label: "Discard reviewed changes",
            commands: commands
        )
    }

    @discardableResult
    func commit(
        message: String,
        includeAll: Bool,
        amend: Bool = false
    ) async -> Bool {
        guard let git else {
            return failGitAction("Repository changed; refresh and try again.")
        }
        let message = message.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !message.isEmpty else {
            return failGitAction("Enter a commit message.")
        }
        guard includeAll || !git.staged.isEmpty || amend else {
            return failGitAction("Stage changes before committing.")
        }
        var commands: [String] = []
        if includeAll {
            commands.append("add -A")
        }
        var commit = "commit"
        if amend {
            commit += " --amend"
        }
        commit += " -m \(Self.shellQuote(message))"
        commands.append(commit)
        return await runGitAction(
            label: amend
                ? "Amend commit"
                : (includeAll
                    ? "Stage all and commit"
                    : "Commit staged changes"),
            commands: commands
        )
    }

    @discardableResult
    func fetch() async -> Bool {
        guard let git, !git.remotes.isEmpty else {
            return failGitAction("No Git remote is configured.")
        }
        return await runGitAction(
            label: "Fetch",
            commands: ["fetch --all --prune"],
            requiresStableHead: false
        )
    }

    @discardableResult
    func pull() async -> Bool {
        guard git?.upstream != nil else {
            return failGitAction(
                "This branch has no upstream to pull from."
            )
        }
        return await runGitAction(
            label: "Pull",
            commands: ["pull --ff-only"],
            requiresStableUpstream: true
        )
    }

    @discardableResult
    func push(to remote: String? = nil) async -> Bool {
        guard let git else {
            return failGitAction("Repository changed; refresh and try again.")
        }
        if git.branch == "Detached HEAD" {
            return failGitAction(
                "Create or switch to a branch before pushing."
            )
        }
        if git.upstream != nil {
            return await runGitAction(
                label: "Push",
                commands: ["push"],
                requiresStableUpstream: true
            )
        }
        let selectedRemote: String
        if let remote {
            guard git.remotes.contains(remote) else {
                return failGitAction(
                    "The selected Git remote is no longer available."
                )
            }
            selectedRemote = remote
        } else if git.remotes.count == 1,
                  let remote = git.remotes.first {
            selectedRemote = remote
        } else {
            return failGitAction(
                git.remotes.isEmpty
                    ? "Add a Git remote before publishing this branch."
                    : "Choose which remote should receive this branch."
            )
        }
        return await runGitAction(
            label: "Publish branch",
            commands: [
                "push -u \(Self.shellQuote(selectedRemote)) HEAD"
            ]
        )
    }

    @discardableResult
    func syncChanges() async -> Bool {
        guard let git else {
            return failGitAction("Repository changed; refresh and try again.")
        }
        if git.upstream != nil {
            return await runGitAction(
                label: "Sync changes",
                commands: ["pull --ff-only", "push"],
                requiresStableUpstream: true
            )
        }
        return await push()
    }

    @discardableResult
    func switchBranch(to branch: String) async -> Bool {
        guard branch != git?.branch else {
            return true
        }
        return await runGitAction(
            label: "Switch to \(branch)",
            commands: ["switch \(Self.shellQuote(branch))"]
        )
    }

    @discardableResult
    func createBranch(named rawName: String) async -> Bool {
        let name = rawName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !name.isEmpty else {
            return failGitAction("Enter a branch name.")
        }
        return await runGitAction(
            label: "Create branch \(name)",
            commands: ["switch -c \(Self.shellQuote(name))"]
        )
    }

    @discardableResult
    func stash(includeUntracked: Bool = true) async -> Bool {
        guard let git, git.totalChangeCount > 0 else {
            return failGitAction("There are no changes to stash.")
        }
        return await runGitAction(
            label: "Stash changes",
            commands: [
                includeUntracked
                    ? "stash push --include-untracked"
                    : "stash push"
            ]
        )
    }

    @discardableResult
    func popStash() async -> Bool {
        guard let git, git.stashCount > 0 else {
            return failGitAction("There are no stashes to pop.")
        }
        return await runGitAction(
            label: "Pop stash",
            commands: ["stash pop"]
        )
    }

    func loadDiff(
        for entry: RemoteGitEntry,
        staged: Bool
    ) async throws -> String {
        guard let root = git?.repositoryRoot ?? projectRoot else {
            throw RemoteProjectError.invalidDirectory
        }
        let arguments: String
        let acceptsDifferenceExitStatus: Bool
        if entry.isUntracked && !staged {
            arguments = "diff --no-index --no-ext-diff --no-color -- "
                + "/dev/null \(Self.shellQuote(entry.path))"
            acceptsDifferenceExitStatus = true
        } else {
            arguments = "diff --no-ext-diff --no-color "
                + (staged ? "--cached " : "")
                + "-- \(Self.shellQuote(entry.path))"
            acceptsDifferenceExitStatus = false
        }
        let result = try await execute(
            Self.gitCommand(root: root, arguments: arguments)
        )
        guard result.exitStatus == 0
                || (acceptsDifferenceExitStatus
                    && result.exitStatus == 1) else {
            throw Self.commandError(result)
        }
        return result.stdoutString
    }

    func loadCommit(_ commit: RemoteGitCommit) async throws -> String {
        guard let root = git?.repositoryRoot ?? projectRoot else {
            throw RemoteProjectError.invalidDirectory
        }
        let result = try await execute(
            Self.gitCommand(
                root: root,
                arguments: "show --no-ext-diff --no-color --stat "
                    + "--format=fuller --max-count=1 "
                    + Self.shellQuote(commit.hash)
            )
        )
        guard result.exitStatus == 0 else {
            throw Self.commandError(result)
        }
        return result.stdoutString
    }

    func dismissGitOperation() {
        guard gitOperation?.isRunning != true else {
            return
        }
        gitOperation = nil
        gitError = nil
    }

    #if DEBUG
    func installPreview(
        root: String,
        files: [RemoteFileItem],
        git: RemoteGitSnapshot?
    ) {
        contextTask?.cancel()
        workingDirectory = root
        projectRoot = root
        self.files = files
        self.git = git
        hasLoadedGit = true
        canInitializeGit = git == nil
        gitError = nil
    }
    #endif

    private func beginResolvingContext(for directory: String) {
        contextTask?.cancel()
        contextGeneration &+= 1
        let generation = contextGeneration
        contextTask = Task { [weak self] in
            guard let self else {
                return
            }
            let resolvedRoot: String
            do {
                let result = try await execute(
                    "git -C \(Self.shellQuote(directory)) "
                        + "rev-parse --show-toplevel 2>/dev/null"
                )
                if result.exitStatus == 0,
                   let value = Self.normalizedDirectory(
                       result.stdoutString
                   ) {
                    resolvedRoot = value
                } else {
                    resolvedRoot = directory
                }
            } catch {
                resolvedRoot = directory
            }
            guard !Task.isCancelled,
                  contextGeneration == generation else {
                return
            }
            applyProjectRoot(resolvedRoot)
            contextTask = nil
        }
    }

    private func applyProjectRoot(_ root: String) {
        guard root != projectRoot else {
            return
        }
        projectRoot = root
        files = []
        filesError = nil
        childrenByDirectory = [:]
        expandedDirectories = []
        git = nil
        hasLoadedGit = false
        canInitializeGit = false
        gitError = nil
        gitOperation = nil
    }

    private func waitForContext() async {
        await contextTask?.value
    }

    private func ensureContext() async {
        await discoverInitialDirectory()
        await waitForContext()
    }

    private func loadChildren(
        of directory: String,
        replacingRoot: Bool
    ) async {
        isLoadingFiles = true
        filesError = nil
        defer { isLoadingFiles = false }
        do {
            let result = try await execute(
                Self.directoryListingCommand(directory)
            )
            guard result.exitStatus == 0 else {
                throw Self.commandError(result)
            }
            childrenByDirectory[directory] = Self.parseDirectoryListing(
                result.stdout,
                parent: directory
            )
            if replacingRoot {
                expandedDirectories = []
            }
            rebuildVisibleFiles()
        } catch {
            filesError = error.localizedDescription
            rebuildVisibleFiles()
        }
    }

    private func rebuildVisibleFiles() {
        guard let projectRoot else {
            files = []
            return
        }
        var result: [RemoteFileItem] = []
        appendChildren(
            of: projectRoot,
            depth: 0,
            result: &result
        )
        files = result
    }

    private func appendChildren(
        of directory: String,
        depth: Int,
        result: inout [RemoteFileItem]
    ) {
        guard depth < 32,
              let children = childrenByDirectory[directory] else {
            return
        }
        for child in children {
            let item = RemoteFileItem(
                name: child.name,
                path: child.path,
                isDirectory: child.isDirectory,
                depth: depth
            )
            result.append(item)
            if child.isDirectory,
               expandedDirectories.contains(child.path) {
                appendChildren(
                    of: child.path,
                    depth: depth + 1,
                    result: &result
                )
            }
        }
    }

    @discardableResult
    private func runGitAction(
        label: String,
        commands: [String],
        root requestedRoot: String? = nil,
        validateSnapshot: Bool = true,
        requiresStableHead: Bool = true,
        requiresStableUpstream: Bool = false
    ) async -> Bool {
        guard !commands.isEmpty else {
            return false
        }
        guard !isRunningGitAction else {
            return false
        }
        guard let root = requestedRoot
                ?? git?.repositoryRoot
                ?? projectRoot else {
            return failGitAction(
                RemoteProjectError.invalidDirectory.localizedDescription
            )
        }
        let generation = contextGeneration
        let snapshot = git
        isRunningGitAction = true
        gitError = nil
        gitOperation = RemoteGitOperation(
            id: UUID(),
            label: label,
            state: .running,
            output: ""
        )
        let operationID = gitOperation?.id
        defer {
            isRunningGitAction = false
        }
        var transcript: [String] = []
        do {
            if validateSnapshot {
                guard let snapshot else {
                    throw RemoteProjectError.commandFailed(
                        "Repository changed; refresh and try again."
                    )
                }
                try await validateRepository(
                    snapshot,
                    requiresStableHead: requiresStableHead,
                    requiresStableUpstream: requiresStableUpstream
                )
            }
            for arguments in commands {
                guard contextGeneration == generation,
                      projectRoot == root else {
                    throw RemoteProjectError.commandFailed(
                        "Repository changed while the Git action was running."
                    )
                }
                transcript.append("$ git \(arguments)")
                let result = try await execute(
                    Self.gitCommand(root: root, arguments: arguments)
                )
                let output = [
                    result.stdoutString,
                    result.stderrString,
                ]
                    .map {
                        $0.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                    }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                if !output.isEmpty {
                    transcript.append(output)
                }
                guard result.exitStatus == 0 else {
                    throw RemoteProjectError.commandFailed(
                        output.isEmpty
                            ? "Git command failed with status "
                                + "\(result.exitStatus)."
                            : output
                    )
                }
            }
            guard contextGeneration == generation else {
                throw RemoteProjectError.commandFailed(
                    "Repository changed while the Git action was running."
                )
            }
            gitOperation = RemoteGitOperation(
                id: operationID ?? UUID(),
                label: label,
                state: .succeeded,
                output: transcript.isEmpty
                    ? "Completed successfully."
                    : transcript.joined(separator: "\n")
            )
            await refreshGit()
            return true
        } catch {
            gitError = error.localizedDescription
            if transcript.last != error.localizedDescription {
                transcript.append(error.localizedDescription)
            }
            gitOperation = RemoteGitOperation(
                id: operationID ?? UUID(),
                label: label,
                state: .failed,
                output: transcript.joined(separator: "\n")
            )
            await refreshGit()
            return false
        }
    }

    private func validateRepository(
        _ snapshot: RemoteGitSnapshot,
        requiresStableHead: Bool,
        requiresStableUpstream: Bool
    ) async throws {
        let rootResult = try await execute(
            Self.gitCommand(
                root: snapshot.repositoryRoot,
                arguments: "rev-parse --show-toplevel"
            )
        )
        guard rootResult.exitStatus == 0,
              Self.normalizedDirectory(rootResult.stdoutString)
                == snapshot.repositoryRoot else {
            throw RemoteProjectError.commandFailed(
                "Repository changed before the Git action could run."
            )
        }
        guard requiresStableHead || requiresStableUpstream else {
            return
        }
        let status = try await execute(
            Self.gitCommand(
                root: snapshot.repositoryRoot,
                arguments: "status --porcelain=v2 --branch -z "
                    + "--untracked-files=no"
            )
        )
        guard status.exitStatus == 0 else {
            throw Self.commandError(status)
        }
        let current = Self.parseGitStatus(
            status.stdout,
            repositoryRoot: snapshot.repositoryRoot
        )
        guard !requiresStableHead
                || (current.headOID == snapshot.headOID
                    && current.branch == snapshot.branch) else {
            throw RemoteProjectError.commandFailed(
                "Branch or HEAD changed before the Git action could run."
            )
        }
        guard !requiresStableUpstream
                || current.upstream == snapshot.upstream else {
            throw RemoteProjectError.commandFailed(
                "Upstream changed before the Git action could run."
            )
        }
    }

    @discardableResult
    private func failGitAction(_ message: String) -> Bool {
        gitError = message
        gitOperation = RemoteGitOperation(
            id: UUID(),
            label: "Git action",
            state: .failed,
            output: message
        )
        return false
    }

    private static func directoryListingCommand(_ directory: String) -> String {
        let script = """
        dir=$1
        for p in "$dir"/.[!.]* "$dir"/..?* "$dir"/*; do
          [ -e "$p" ] || [ -L "$p" ] || continue
          name=${p##*/}
          [ "$name" = ".git" ] && continue
          if [ -d "$p" ] && [ ! -L "$p" ]; then kind=d; else kind=f; fi
          printf '%s\\0%s\\0' "$kind" "$name"
        done
        """
        // SSH exec requests are interpreted by the account's login shell.
        // Run this POSIX script explicitly so fish and other non-POSIX shells
        // never have to parse its assignments or parameter expansion.
        return "/bin/sh -c \(shellQuote(script)) sh \(shellQuote(directory))"
    }

    private static func parseDirectoryListing(
        _ data: Data,
        parent: String
    ) -> [FileNode] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        var nodes: [FileNode] = []
        var index = 0
        while index + 1 < fields.count {
            let kind = String(decoding: fields[index], as: UTF8.self)
            let name = String(decoding: fields[index + 1], as: UTF8.self)
            index += 2
            guard !name.isEmpty, name != ".git" else {
                continue
            }
            let path = parent == "/" ? "/\(name)" : "\(parent)/\(name)"
            nodes.append(
                FileNode(
                    name: name,
                    path: path,
                    isDirectory: kind == "d"
                )
            )
        }
        return nodes.sorted {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func parseGitStatus(
        _ data: Data,
        repositoryRoot: String
    ) -> RemoteGitSnapshot {
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
        var branch = "Detached HEAD"
        var headOID: String?
        var hasHead = true
        var upstream: String?
        var ahead = 0
        var behind = 0
        var entries: [RemoteGitEntry] = []
        var skipRenameSource = false

        for bytes in records {
            if skipRenameSource {
                if let renamed = entries.popLast() {
                    entries.append(
                        RemoteGitEntry(
                            path: renamed.path,
                            stagedStatus: renamed.stagedStatus,
                            worktreeStatus: renamed.worktreeStatus,
                            originalPath: String(
                                decoding: bytes,
                                as: UTF8.self
                            )
                        )
                    )
                }
                skipRenameSource = false
                continue
            }
            let record = String(decoding: bytes, as: UTF8.self)
            if record.hasPrefix("# branch.oid ") {
                let value = String(
                    record.dropFirst("# branch.oid ".count)
                )
                if value == "(initial)" {
                    headOID = nil
                    hasHead = false
                } else {
                    headOID = value
                    hasHead = true
                }
                continue
            }
            if record.hasPrefix("# branch.head ") {
                branch = String(record.dropFirst("# branch.head ".count))
                if branch == "(detached)" {
                    branch = "Detached HEAD"
                }
                continue
            }
            if record.hasPrefix("# branch.upstream ") {
                upstream = String(
                    record.dropFirst("# branch.upstream ".count)
                )
                continue
            }
            if record.hasPrefix("# branch.ab ") {
                let values = record.split(separator: " ")
                if values.count >= 4 {
                    ahead = Int(values[2].dropFirst()) ?? 0
                    behind = Int(values[3].dropFirst()) ?? 0
                }
                continue
            }

            let parsed: (Character, Character, String)?
            if record.hasPrefix("1 ") {
                let values = record.split(
                    separator: " ",
                    maxSplits: 8,
                    omittingEmptySubsequences: true
                )
                parsed = values.count == 9
                    ? statusEntry(xy: values[1], path: values[8])
                    : nil
            } else if record.hasPrefix("2 ") {
                let values = record.split(
                    separator: " ",
                    maxSplits: 9,
                    omittingEmptySubsequences: true
                )
                parsed = values.count == 10
                    ? statusEntry(xy: values[1], path: values[9])
                    : nil
                skipRenameSource = parsed != nil
            } else if record.hasPrefix("u ") {
                let values = record.split(
                    separator: " ",
                    maxSplits: 10,
                    omittingEmptySubsequences: true
                )
                parsed = values.count == 11
                    ? statusEntry(xy: values[1], path: values[10])
                    : nil
            } else if record.hasPrefix("? ") {
                parsed = ("?", ".", String(record.dropFirst(2)))
            } else {
                parsed = nil
            }

            if let parsed {
                entries.append(
                    RemoteGitEntry(
                        path: parsed.2,
                        stagedStatus: parsed.0,
                        worktreeStatus: parsed.1
                    )
                )
            }
        }

        entries.sort {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        return RemoteGitSnapshot(
            repositoryRoot: repositoryRoot,
            branch: branch,
            headOID: headOID,
            hasHead: hasHead,
            upstream: upstream,
            ahead: ahead,
            behind: behind,
            entries: entries
        )
    }

    static func parseRepositoryDetails(
        _ data: Data,
        snapshot: RemoteGitSnapshot
    ) -> RemoteGitSnapshot {
        var branches: [String] = []
        var remotes: [String] = []
        var commits: [RemoteGitCommit] = []
        var repositoryOperation: String?
        var stashCount = 0

        for line in String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true) {
            let values = line.split(
                separator: "\t",
                maxSplits: 5,
                omittingEmptySubsequences: false
            )
            guard let kind = values.first else {
                continue
            }
            switch kind {
            case "B" where values.count >= 2:
                branches.append(String(values[1]))
            case "R" where values.count >= 2:
                remotes.append(String(values[1]))
            case "C" where values.count >= 6:
                guard let timestamp = TimeInterval(values[3]) else {
                    continue
                }
                commits.append(
                    RemoteGitCommit(
                        hash: String(values[1]),
                        shortHash: String(values[2]),
                        subject: String(values[5]),
                        author: String(values[4]),
                        date: Date(timeIntervalSince1970: timestamp)
                    )
                )
            case "S" where values.count >= 2:
                stashCount = Int(values[1]) ?? 0
            case "O" where values.count >= 2:
                repositoryOperation = String(values[1])
            default:
                continue
            }
        }

        branches = Array(Set(branches)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        remotes = Array(Set(remotes)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        if !branches.contains(snapshot.branch),
           snapshot.branch != "Detached HEAD" {
            branches.insert(snapshot.branch, at: 0)
        }
        return RemoteGitSnapshot(
            repositoryRoot: snapshot.repositoryRoot,
            branch: snapshot.branch,
            headOID: snapshot.headOID,
            hasHead: snapshot.hasHead,
            upstream: snapshot.upstream,
            ahead: snapshot.ahead,
            behind: snapshot.behind,
            entries: snapshot.entries,
            branches: branches,
            remotes: remotes,
            recentCommits: commits,
            repositoryOperation: repositoryOperation,
            stashCount: stashCount
        )
    }

    private static func statusEntry(
        xy: Substring,
        path: Substring
    ) -> (Character, Character, String)? {
        guard xy.count >= 2 else {
            return nil
        }
        let characters = Array(xy)
        return (characters[0], characters[1], String(path))
    }

    private static func normalizedDirectory(_ rawValue: String?) -> String? {
        guard let value = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            return nil
        }
        if let url = URL(string: value), url.isFileURL {
            return url.path
        }
        guard value.hasPrefix("/") else {
            return nil
        }
        return value
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func shellArguments(_ values: [String]) -> String {
        values.map(shellQuote).joined(separator: " ")
    }

    private static func gitCommand(
        root: String,
        arguments: String
    ) -> String {
        "env LC_ALL=C GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 "
            + "git -C \(shellQuote(root)) \(arguments)"
    }

    private static func repositoryDetailsCommand(_ root: String) -> String {
        let script = """
        root=$1
        git -C "$root" for-each-ref \
          --format='B\t%(refname:short)' refs/heads 2>/dev/null || true
        git -C "$root" remote 2>/dev/null |
          while IFS= read -r value; do printf 'R\t%s\n' "$value"; done
        git -C "$root" log -10 --date=unix \
          --format='C%x09%H%x09%h%x09%at%x09%an%x09%s' \
          2>/dev/null || true
        count=$(git -C "$root" stash list --format='%gd' 2>/dev/null |
          wc -l | tr -d ' ')
        printf 'S\t%s\n' "$count"
        git_dir=$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null ||
          true)
        if [ -n "$git_dir" ]; then
          if [ -f "$git_dir/MERGE_HEAD" ]; then
            printf 'O\tMerging\n'
          elif [ -d "$git_dir/rebase-merge" ] ||
               [ -d "$git_dir/rebase-apply" ]; then
            printf 'O\tRebasing\n'
          elif [ -f "$git_dir/CHERRY_PICK_HEAD" ]; then
            printf 'O\tCherry-picking\n'
          elif [ -f "$git_dir/REVERT_HEAD" ]; then
            printf 'O\tReverting\n'
          fi
        fi
        """
        return "/bin/sh -c \(shellQuote(script)) sh \(shellQuote(root))"
    }

    private static func commandError(
        _ result: SSHCommandResult
    ) -> RemoteProjectError {
        let message = result.stderrString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .commandFailed(message)
    }

    private static func isMissingRepository(
        _ result: SSHCommandResult
    ) -> Bool {
        guard result.exitStatus != 0 else {
            return false
        }
        let output = "\(result.stderrString)\n\(result.stdoutString)"
            .lowercased()
        return output.contains("not a git repository")
    }
}
