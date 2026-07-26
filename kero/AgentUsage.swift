//
//  AgentUsage.swift
//  kero
//

import Foundation

/// A coding agent whose plan usage kero knows how to report.
nonisolated enum AgentUsageProvider: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        }
    }

    /// Executable names, as `ps` reports them, that mean this agent is running.
    var executableNames: Set<String> {
        switch self {
        case .codex: ["codex"]
        case .claude: ["claude"]
        }
    }
}

/// One rate-limit window — a 5-hour session, a weekly cap, a model-scoped
/// weekly cap — as a percentage consumed plus when it refills.
nonisolated struct AgentUsageWindow: Identifiable, Equatable, Sendable {
    let label: String
    /// 0–100.
    let usedPercent: Double
    let resetsAt: Date?

    var id: String { label }

    var percentLabel: String {
        usedPercent >= 10
            ? String(format: "%.0f%%", usedPercent)
            : String(format: "%.1f%%", usedPercent)
    }

    /// "resets in 3h 20m", or nil when the provider didn't say.
    func resetLabel(now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0 else { return "resetting" }
        return "resets in " + AgentUsage.durationLabel(remaining)
    }
}

/// What kero shows for one agent in the Info tab.
nonisolated struct AgentUsageSnapshot: Equatable, Sendable {
    let provider: AgentUsageProvider
    var windows: [AgentUsageWindow] = []
    /// e.g. "Pro" — whatever plan the provider reports, when it does.
    var planLabel: String?
    /// Codex reports the live context-window fill for the session; Claude
    /// does not expose it, so this stays nil there.
    var contextPercent: Double?
    var contextDetail: String?
    /// Where the numbers came from, shown as the section's footnote.
    var sourceLabel: String?
    var updatedAt = Date()

    var isEmpty: Bool { windows.isEmpty && contextPercent == nil }
}

/// A failure worth showing in place of numbers, with the fix spelled out.
nonisolated struct AgentUsageFailure: Equatable, Sendable {
    let provider: AgentUsageProvider
    let message: String
    /// True when the user can resolve it by granting keychain access — the
    /// panel offers a retry button in that case.
    var isRecoverable = false
}

nonisolated enum AgentUsage {
    /// Compact "3h 20m" / "6d 4h" / "45m" for countdowns.
    static func durationLabel(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return minutes > 0 ? "\(minutes)m" : "under a minute"
    }

    /// Names a rate-limit window by its length, since providers label the
    /// same window inconsistently ("primary", "five_hour", …).
    static func windowLabel(minutes: Int) -> String {
        switch minutes {
        case ..<60:
            return "\(minutes)m limit"
        case ..<1_440:
            return "\(minutes / 60)h limit"
        case 10_080:
            return "Weekly limit"
        default:
            let days = minutes / 1_440
            return days == 1 ? "Daily limit" : "\(days)d limit"
        }
    }

    /// 1.2M / 34.5K / 812 — token counts at a glance.
    static func tokenLabel(_ tokens: Int) -> String {
        switch tokens {
        case 1_000_000...:
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", Double(tokens) / 1_000)
        default:
            return "\(tokens)"
        }
    }
}
