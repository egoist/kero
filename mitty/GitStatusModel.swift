//
//  GitStatusModel.swift
//  mitty
//

import Combine
import Foundation

/// Polls `git status --porcelain=v2` for the active session's directory and
/// runs source-control operations (stage, commit, push, …) against the repo.
@MainActor
final class GitStatusModel: nonisolated ObservableObject {
    struct Entry: Identifiable, Equatable {
        var id: String { path }
        /// Relative to the repository root, as porcelain v2 reports it.
        let path: String
        /// Index (staged) status letter, '.' when clean, '?' for untracked.
        let staged: Character
        /// Worktree (unstaged) status letter.
        let unstaged: Character
        var isConflict = false
        /// Previous path for renames/copies (porcelain "2" entries).
        var origPath: String?

        var fileName: String { (path as NSString).lastPathComponent }
        var directory: String {
            let dir = (path as NSString).deletingLastPathComponent
            return dir.isEmpty ? "" : dir
        }
        var isUntracked: Bool { staged == "?" }

        // A file can sit in two sections at once (e.g. "MM"); rows in the
        // same lazy stack need distinct identities or SwiftUI drops one.
        var mergeRowID: String { "merge/" + path }
        var stagedRowID: String { "staged/" + path }
        var changedRowID: String { "changed/" + path }
    }

    @Published private(set) var rootPath = ""
    @Published private(set) var isRepo = false
    @Published private(set) var branch: String?
    @Published private(set) var ahead = 0
    @Published private(set) var behind = 0
    @Published private(set) var hasUpstream = false
    @Published private(set) var mergeEntries: [Entry] = []
    @Published private(set) var stagedEntries: [Entry] = []
    @Published private(set) var changedEntries: [Entry] = []
    /// True while a user-initiated git operation (not a status poll) runs.
    @Published private(set) var isBusy = false
    @Published var lastError: String?

    /// Absolute path of the repository root; operations run here because
    /// porcelain paths are relative to it, not to `rootPath`.
    private var topLevel = ""
    private var isRefreshing = false

    var totalChangeCount: Int {
        mergeEntries.count + stagedEntries.count + changedEntries.count
    }

    /// Absolute repository root; falls back to the polled directory until
    /// the first status run resolves the real toplevel.
    var repoRoot: String {
        topLevel.isEmpty ? rootPath : topLevel
    }

    func absolutePath(for entry: Entry) -> String {
        (repoRoot as NSString).appendingPathComponent(entry.path)
    }

    func sync(root: String) {
        if root != rootPath {
            rootPath = root
        }
        refresh()
    }

    func refresh() {
        let root = rootPath
        guard !root.isEmpty, !isRefreshing else { return }
        isRefreshing = true

        Task.detached(priority: .utility) { [weak self] in
            let result = Self.runGitStatus(in: root)
            await MainActor.run {
                guard let self else { return }
                self.isRefreshing = false
                // A tab switch may have re-rooted us while git was running.
                guard self.rootPath == root else { return }
                self.apply(result)
            }
        }
    }

    // MARK: - Operations

    func stage(_ entry: Entry) {
        perform([["add", "--", entry.path]])
    }

    func unstage(_ entry: Entry) {
        perform([["restore", "--staged", "--", entry.path]])
    }

    func stageAll() {
        perform([["add", "-A"]])
    }

    func unstageAll() {
        perform([["restore", "--staged", "--", "."]])
    }

    /// Restores a tracked file from the index, or moves an untracked file
    /// to the Trash. The UI confirms before calling this.
    func discard(_ entry: Entry) {
        if entry.isUntracked {
            trash(paths: [entry.path])
        } else {
            perform([["checkout", "--", entry.path]])
        }
    }

    /// Discards every worktree change: restores tracked files and moves
    /// untracked ones to the Trash. The UI confirms before calling this.
    func discardAllChanges() {
        let untracked = changedEntries.filter(\.isUntracked).map(\.path)
        let tracked = changedEntries.filter { !$0.isUntracked }.map(\.path)
        var commands: [[String]] = []
        if !tracked.isEmpty {
            commands.append(["checkout", "--"] + tracked)
        }
        if commands.isEmpty && untracked.isEmpty { return }
        perform(commands) { [weak self] in
            self?.trash(paths: untracked)
        }
    }

    /// Commits staged changes; when nothing is staged, stages everything
    /// first (VS Code's "smart commit").
    func commit(message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var commands: [[String]] = []
        if stagedEntries.isEmpty {
            commands.append(["add", "-A"])
        }
        commands.append(["commit", "-m", trimmed])
        perform(commands)
    }

    func pull() {
        perform([["pull"]])
    }

    func push() {
        // -u so pushing a new local branch just works, like VS Code's publish.
        perform([["push", "-u", "origin", "HEAD"]])
    }

    func syncChanges() {
        // Like VS Code's Sync: pull first, then push.
        if hasUpstream {
            perform([["pull"], ["push"]])
        } else {
            perform([["push", "-u", "origin", "HEAD"]])
        }
    }

    /// Runs `commands` sequentially in the repo root, stopping at the first
    /// failure (surfaced via `lastError`), then refreshes.
    private func perform(_ commands: [[String]], onSuccess: (@MainActor () -> Void)? = nil) {
        let dir = repoRoot
        guard !dir.isEmpty, !isBusy else { return }
        isBusy = true
        lastError = nil

        Task.detached(priority: .userInitiated) { [weak self] in
            let failure: String? = {
                for args in commands {
                    let run = Self.runGit(args, in: dir)
                    if run.status != 0 {
                        let message = run.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        return message.isEmpty ? "git \(args.first ?? "") failed" : message
                    }
                }
                return nil
            }()
            await MainActor.run {
                guard let self else { return }
                self.isBusy = false
                self.lastError = failure
                if failure == nil { onSuccess?() }
                self.refresh()
            }
        }
    }

    private func trash(paths: [String]) {
        guard !paths.isEmpty else { return }
        let base = URL(fileURLWithPath: repoRoot, isDirectory: true)
        for path in paths {
            do {
                try FileManager.default.trashItem(
                    at: base.appendingPathComponent(path), resultingItemURL: nil
                )
            } catch {
                lastError = error.localizedDescription
            }
        }
        refresh()
    }

    // MARK: - Status

    private func apply(_ result: Result?) {
        guard let result else {
            if isRepo { isRepo = false }
            return
        }
        if !isRepo { isRepo = true }
        if branch != result.branch { branch = result.branch }
        if ahead != result.ahead { ahead = result.ahead }
        if behind != result.behind { behind = result.behind }
        if hasUpstream != result.hasUpstream { hasUpstream = result.hasUpstream }
        if topLevel != result.topLevel { topLevel = result.topLevel }

        let merge = result.entries.filter(\.isConflict)
        let staged = result.entries.filter { !$0.isConflict && $0.staged != "." && $0.staged != "?" }
        let changed = result.entries.filter { !$0.isConflict && $0.unstaged != "." }
        if mergeEntries != merge { mergeEntries = merge }
        if stagedEntries != staged { stagedEntries = staged }
        if changedEntries != changed { changedEntries = changed }
    }

    private struct Result {
        var branch: String?
        var ahead = 0
        var behind = 0
        var hasUpstream = false
        var topLevel = ""
        var entries: [Entry] = []
    }

    nonisolated static func runGit(
        _ args: [String], in dir: String
    ) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: dir, isDirectory: true)
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        // Fail fast instead of hanging on a credential prompt.
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// Returns nil when `root` is not inside a git repository.
    private nonisolated static func runGitStatus(in root: String) -> Result? {
        let status = runGit(["status", "--porcelain=v2", "--branch"], in: root)
        guard status.status == 0 else { return nil }
        var result = parse(status.stdout)

        let top = runGit(["rev-parse", "--show-toplevel"], in: root)
        if top.status == 0 {
            result.topLevel = top.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private nonisolated static func parse(_ output: String) -> Result {
        var result = Result()
        for line in output.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                let name = String(line.dropFirst("# branch.head ".count))
                result.branch = name == "(detached)" ? "detached HEAD" : name
            } else if line.hasPrefix("# branch.upstream ") {
                result.hasUpstream = true
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                for part in parts {
                    if part.hasPrefix("+") { result.ahead = Int(part.dropFirst()) ?? 0 }
                    if part.hasPrefix("-") { result.behind = Int(part.dropFirst()) ?? 0 }
                }
            } else if line.hasPrefix("1 ") {
                // 1 XY sub mH mI mW hH hI path
                let fields = line.split(separator: " ", maxSplits: 8)
                guard fields.count == 9, fields[1].count == 2 else { continue }
                let xy = Array(fields[1])
                result.entries.append(Entry(path: String(fields[8]), staged: xy[0], unstaged: xy[1]))
            } else if line.hasPrefix("2 ") {
                // 2 XY sub mH mI mW hH hI Xscore path\torigPath
                let fields = line.split(separator: " ", maxSplits: 9)
                guard fields.count == 10, fields[1].count == 2 else { continue }
                let xy = Array(fields[1])
                let paths = fields[9].split(separator: "\t")
                let path = paths.first.map(String.init) ?? String(fields[9])
                let orig = paths.count > 1 ? String(paths[1]) : nil
                result.entries.append(
                    Entry(path: path, staged: xy[0], unstaged: xy[1], origPath: orig)
                )
            } else if line.hasPrefix("u ") {
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let fields = line.split(separator: " ", maxSplits: 10)
                guard fields.count == 11, fields[1].count == 2 else { continue }
                let xy = Array(fields[1])
                result.entries.append(
                    Entry(path: String(fields[10]), staged: xy[0], unstaged: xy[1], isConflict: true)
                )
            } else if line.hasPrefix("? ") {
                result.entries.append(Entry(path: String(line.dropFirst(2)), staged: "?", unstaged: "?"))
            }
        }
        return result
    }
}
