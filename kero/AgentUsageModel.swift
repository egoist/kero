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

    /// Both providers poll on the same relaxed clock. Plan limits move slowly,
    /// so a tighter loop just re-reads unchanged rollout files (and, for
    /// Claude, spends requests against a rate-limited endpoint). Opening the
    /// panel, switching directory, and the refresh button all bypass this.
    private static let codexInterval: TimeInterval = 120
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
    /// Set only by a 429, and respected even by an explicit user refresh.
    private var claudeRateLimitedUntil: Date?

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
        // Deliberately keeps snapshots for agents that just left `detected`.
        // The process list is polled a tick behind and momentarily reads empty
        // on tab switches, so clearing here blanked the card on every flap —
        // and the refresh throttle then held it blank. The section only renders
        // while an agent is detected, so stale entries stay invisible until the
        // agent returns, at which point last-known numbers beat an empty card.
        if self.detected != detected { self.detected = detected }

        if detected.contains(.codex) { refreshCodex() }
        if detected.contains(.claude), isClaudeEnabled { refreshClaude() }
    }

    /// Explicit user refresh — bypasses the polling throttles, but never an
    /// active rate limit: hammering a 429 only extends it.
    func refreshNow() {
        codexLastRefresh = .distantPast
        if let claudeRateLimitedUntil, claudeRateLimitedUntil > Date() {
            claudeNextAllowedRefresh = claudeRateLimitedUntil
        } else {
            claudeRateLimitedUntil = nil
            claudeNextAllowedRefresh = .distantPast
        }
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
                self.claudeRateLimitedUntil = nil
                self.claudeNextAllowedRefresh = Date().addingTimeInterval(Self.claudeInterval)
                guard self.detected.contains(.claude) else { return }
                self.store(snapshot)
                self.failures.removeAll { $0.provider == .claude }
            } catch {
                guard let self else { return }
                self.isClaudeLoading = false
                let readerError = error as? ClaudeUsageReader.ReaderError
                // Honour Anthropic's own Retry-After when it sends one; a
                // fixed guess otherwise.
                if case let .rateLimited(retryAfter) = readerError {
                    let until = retryAfter
                        ?? Date().addingTimeInterval(Self.claudeFailureBackoff)
                    self.claudeRateLimitedUntil = until
                    self.claudeNextAllowedRefresh = until
                } else {
                    self.claudeNextAllowedRefresh = Date()
                        .addingTimeInterval(Self.claudeFailureBackoff)
                }
                // The previous reading stays on screen: a transient network
                // blip shouldn't throw away numbers that are still roughly
                // true. The failure shows as a warning beneath them.
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
