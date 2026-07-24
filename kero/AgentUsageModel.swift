//
//  AgentUsageModel.swift
//  kero
//

import Combine
import Foundation

/// Tracks plan usage for the coding agents running in the selected session.
///
/// The two providers have very different costs, so they refresh on different
/// clocks: Codex is a local file read and can follow the panel's poll, while
/// Claude is a network call against a rate-limited endpoint and is both
/// opt-in and throttled hard.
@MainActor
final class AgentUsageModel: nonisolated ObservableObject {
    /// Persisted so the keychain prompt is a one-time, user-initiated event
    /// rather than something kero does on every launch.
    private static let claudeEnabledKey = "agentUsage.claudeEnabled"

    private static let codexInterval: TimeInterval = 3
    private static let claudeInterval: TimeInterval = 120
    /// Backoff after a failed Claude fetch, so a bad token or a 429 doesn't
    /// turn into a retry loop against Anthropic.
    private static let claudeFailureBackoff: TimeInterval = 300

    @Published private(set) var snapshots: [AgentUsageSnapshot] = []
    @Published private(set) var failures: [AgentUsageFailure] = []
    /// Agents seen running under the session's shell, in display order.
    @Published private(set) var detected: [AgentUsageProvider] = []
    @Published private(set) var isClaudeLoading = false

    @Published var isClaudeEnabled: Bool {
        didSet {
            guard isClaudeEnabled != oldValue else { return }
            UserDefaults.standard.set(isClaudeEnabled, forKey: Self.claudeEnabledKey)
            if isClaudeEnabled {
                claudeNextAllowedRefresh = .distantPast
                refreshClaude()
            } else {
                snapshots.removeAll { $0.provider == .claude }
                failures.removeAll { $0.provider == .claude }
            }
        }
    }

    private var cwd = ""
    private var codexLastRefresh = Date.distantPast
    private var isCodexRefreshing = false
    private var claudeNextAllowedRefresh = Date.distantPast

    init() {
        isClaudeEnabled = UserDefaults.standard.bool(forKey: Self.claudeEnabledKey)
    }

    // MARK: - Syncing

    /// Called from the Info panel's poll with the session's live process list.
    func sync(processNames: [String], cwd: String) {
        if self.cwd != cwd {
            self.cwd = cwd
            // A different directory means a different Codex session; drop the
            // stale context gauge instead of showing another pane's numbers.
            codexLastRefresh = .distantPast
        }

        let names = Set(processNames)
        let detected = AgentUsageProvider.allCases.filter { provider in
            !provider.executableNames.isDisjoint(with: names)
        }
        if self.detected != detected {
            self.detected = detected
            // Clear anything for agents that are no longer running.
            snapshots.removeAll { !detected.contains($0.provider) }
            failures.removeAll { !detected.contains($0.provider) }
        }

        if detected.contains(.codex) { refreshCodex() }
        if detected.contains(.claude), isClaudeEnabled { refreshClaude() }
    }

    /// Explicit user refresh — bypasses both throttles.
    func refreshNow() {
        codexLastRefresh = .distantPast
        claudeNextAllowedRefresh = .distantPast
        if detected.contains(.codex) { refreshCodex() }
        if detected.contains(.claude), isClaudeEnabled { refreshClaude() }
    }

    // MARK: - Codex

    private func refreshCodex() {
        guard !isCodexRefreshing,
              Date().timeIntervalSince(codexLastRefresh) >= Self.codexInterval
        else { return }
        isCodexRefreshing = true
        codexLastRefresh = Date()

        let cwd = self.cwd
        Task.detached(priority: .utility) { [weak self] in
            let snapshot = CodexUsageReader.snapshot(cwd: cwd)
            await self?.applyCodex(snapshot, cwd: cwd)
        }
    }

    private func applyCodex(_ snapshot: AgentUsageSnapshot?, cwd: String) {
        isCodexRefreshing = false
        // A tab switch may have re-targeted us while the log was being read.
        guard self.cwd == cwd, detected.contains(.codex) else { return }
        if let snapshot {
            store(snapshot)
            failures.removeAll { $0.provider == .codex }
        } else {
            store(
                AgentUsageFailure(
                    provider: .codex,
                    message: "No usage recorded yet — it appears after Codex's first reply."
                )
            )
        }
    }

    // MARK: - Claude

    private func refreshClaude() {
        guard isClaudeEnabled, !isClaudeLoading, Date() >= claudeNextAllowedRefresh else { return }
        isClaudeLoading = true

        Task { [weak self] in
            do {
                let snapshot = try await ClaudeUsageReader.fetchSnapshot()
                guard let self else { return }
                self.isClaudeLoading = false
                self.claudeNextAllowedRefresh = Date().addingTimeInterval(Self.claudeInterval)
                guard self.detected.contains(.claude) else { return }
                self.store(snapshot)
                self.failures.removeAll { $0.provider == .claude }
            } catch {
                guard let self else { return }
                self.isClaudeLoading = false
                self.claudeNextAllowedRefresh = Date()
                    .addingTimeInterval(Self.claudeFailureBackoff)
                let readerError = error as? ClaudeUsageReader.ReaderError
                self.snapshots.removeAll { $0.provider == .claude }
                self.store(
                    AgentUsageFailure(
                        provider: .claude,
                        message: readerError?.errorDescription
                            ?? error.localizedDescription,
                        isRecoverable: readerError?.isRecoverable ?? true
                    )
                )
            }
        }
    }

    // MARK: - Storage

    private func store(_ snapshot: AgentUsageSnapshot) {
        var updated = snapshots.filter { $0.provider != snapshot.provider }
        updated.append(snapshot)
        updated.sort { lhs, rhs in
            order(of: lhs.provider) < order(of: rhs.provider)
        }
        if snapshots != updated { snapshots = updated }
    }

    private func store(_ failure: AgentUsageFailure) {
        var updated = failures.filter { $0.provider != failure.provider }
        updated.append(failure)
        updated.sort { lhs, rhs in
            order(of: lhs.provider) < order(of: rhs.provider)
        }
        if failures != updated { failures = updated }
    }

    private func order(of provider: AgentUsageProvider) -> Int {
        AgentUsageProvider.allCases.firstIndex(of: provider) ?? 0
    }
}
