//
//  GitStatusModel.swift
//  mitty
//

import Combine
import Foundation

/// Polls `git status --porcelain=v2` for the active session's directory.
@MainActor
final class GitStatusModel: nonisolated ObservableObject {
    struct Entry: Identifiable, Equatable {
        var id: String { path }
        let path: String
        /// Index (staged) status letter, '.' when clean, '?' for untracked.
        let staged: Character
        /// Worktree (unstaged) status letter.
        let unstaged: Character

        var fileName: String { (path as NSString).lastPathComponent }
        var directory: String {
            let dir = (path as NSString).deletingLastPathComponent
            return dir.isEmpty ? "" : dir
        }
    }

    @Published private(set) var rootPath = ""
    @Published private(set) var isRepo = false
    @Published private(set) var branch: String?
    @Published private(set) var ahead = 0
    @Published private(set) var behind = 0
    @Published private(set) var stagedEntries: [Entry] = []
    @Published private(set) var changedEntries: [Entry] = []

    private var isRefreshing = false

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

    private func apply(_ result: Result?) {
        guard let result else {
            if isRepo { isRepo = false }
            return
        }
        if !isRepo { isRepo = true }
        if branch != result.branch { branch = result.branch }
        if ahead != result.ahead { ahead = result.ahead }
        if behind != result.behind { behind = result.behind }

        let staged = result.entries.filter { $0.staged != "." && $0.staged != "?" }
        let changed = result.entries.filter { $0.unstaged != "." }
        if stagedEntries != staged { stagedEntries = staged }
        if changedEntries != changed { changedEntries = changed }
    }

    private struct Result {
        var branch: String?
        var ahead = 0
        var behind = 0
        var entries: [Entry] = []
    }

    /// Returns nil when `root` is not inside a git repository.
    private nonisolated static func runGitStatus(in root: String) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["status", "--porcelain=v2", "--branch"]
        process.currentDirectoryURL = URL(fileURLWithPath: root, isDirectory: true)
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = env

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8)
        else { return nil }

        return parse(output)
    }

    private nonisolated static func parse(_ output: String) -> Result {
        var result = Result()
        for line in output.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                let name = String(line.dropFirst("# branch.head ".count))
                result.branch = name == "(detached)" ? "detached HEAD" : name
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
                let path = fields[9].split(separator: "\t").first.map(String.init) ?? String(fields[9])
                result.entries.append(Entry(path: path, staged: xy[0], unstaged: xy[1]))
            } else if line.hasPrefix("u ") {
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let fields = line.split(separator: " ", maxSplits: 10)
                guard fields.count == 11 else { continue }
                result.entries.append(Entry(path: String(fields[10]), staged: "U", unstaged: "U"))
            } else if line.hasPrefix("? ") {
                result.entries.append(Entry(path: String(line.dropFirst(2)), staged: "?", unstaged: "?"))
            }
        }
        return result
    }
}
