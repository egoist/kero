//
//  CodexUsageReader.swift
//  kero
//

import Foundation

/// Reads Codex plan usage out of the CLI's own session logs.
///
/// Codex writes a `token_count` event into its rollout file after every turn,
/// and each one carries the account's current `rate_limits`. That makes usage
/// a local file read — no credentials, no network, nothing to authorize.
///
/// Rollouts live at `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`.
nonisolated enum CodexUsageReader {
    /// Newest-first candidates to consider when looking for the session that
    /// belongs to a pane. Bounded so a long-lived `~/.codex` stays cheap.
    private static let candidateLimit = 60
    /// Rate limits sit in the last few events, so only the tail is parsed.
    private static let tailByteLimit = 512 * 1024

    static func snapshot(cwd: String) -> AgentUsageSnapshot? {
        let candidates = recentRollouts()
        guard !candidates.isEmpty else { return nil }

        // Prefer the rollout started in this pane's directory so the context
        // gauge describes the session on screen. Rate limits are account-wide,
        // so any recent rollout carries usable numbers if that lookup misses.
        let preferred = candidates.first { sessionDirectory(of: $0) == cwd }
        for url in [preferred].compactMap({ $0 }) + candidates {
            if let snapshot = parse(rollout: url, isSessionMatch: url == preferred) {
                return snapshot
            }
        }
        return nil
    }

    // MARK: - Locating rollouts

    private static var sessionsRoot: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let root = (codexHome?.isEmpty == false)
            ? URL(fileURLWithPath: codexHome!)
            : home.appendingPathComponent(".codex")
        let sessions = root.appendingPathComponent("sessions")
        return FileManager.default.fileExists(atPath: sessions.path) ? sessions : nil
    }

    /// Rollout files sorted newest-modified first.
    ///
    /// The tree is date-partitioned, so descending only the newest day
    /// directories keeps this bounded no matter how much history has piled up.
    private static func recentRollouts() -> [URL] {
        guard let sessionsRoot else { return [] }
        let fileManager = FileManager.default

        // sessions/YYYY/MM/DD — walk the three levels newest-first by name,
        // which is chronological given the zero-padded numeric components.
        var dayDirectories: [URL] = []
        for year in sortedChildren(of: sessionsRoot).prefix(2) {
            for month in sortedChildren(of: year).prefix(2) {
                dayDirectories.append(contentsOf: sortedChildren(of: month).prefix(7))
            }
            if dayDirectories.count >= 7 { break }
        }

        var entries: [(url: URL, modified: Date)] = []
        for directory in dayDirectories.prefix(14) {
            let contents = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in contents where url.pathExtension == "jsonl" {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                entries.append((url, modified))
            }
        }

        return entries
            .sorted { $0.modified > $1.modified }
            .prefix(candidateLimit)
            .map(\.url)
    }

    private static func sortedChildren(of directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// The `cwd` recorded in the rollout's `session_meta` header line.
    private static func sessionDirectory(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // The header is line one; 64 KB comfortably covers it.
        guard let data = try? handle.read(upToCount: 64 * 1024),
              let newline = data.firstIndex(of: 0x0A) ?? data.indices.last.map({ $0 + 1 }),
              let object = try? JSONSerialization.jsonObject(
                  with: data[data.startIndex..<newline]
              ) as? [String: Any],
              let payload = object["payload"] as? [String: Any]
        else { return nil }
        return payload["cwd"] as? String
    }

    // MARK: - Parsing

    private static func parse(rollout url: URL, isSessionMatch: Bool) -> AgentUsageSnapshot? {
        guard let tail = tailLines(of: url) else { return nil }

        // The newest `token_count` wins; scanning backwards finds it first.
        for line in tail.reversed() {
            guard line.contains("\"token_count\""),
                  let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count"
            else { continue }

            var snapshot = AgentUsageSnapshot(provider: .codex)
            snapshot.sourceLabel = "Codex session log"

            if let limits = payload["rate_limits"] as? [String: Any] {
                snapshot.windows = windows(from: limits)
                if let plan = limits["plan_type"] as? String, !plan.isEmpty {
                    snapshot.planLabel = plan.capitalized
                }
            }

            // Only meaningful when this rollout is the pane's own session.
            if isSessionMatch, let info = payload["info"] as? [String: Any] {
                applyContext(from: info, to: &snapshot)
            }

            return snapshot.isEmpty ? nil : snapshot
        }
        return nil
    }

    private static func windows(from limits: [String: Any]) -> [AgentUsageWindow] {
        ["primary", "secondary"].compactMap { key in
            guard let window = limits[key] as? [String: Any],
                  let usedPercent = window["used_percent"] as? Double
            else { return nil }
            let minutes = (window["window_minutes"] as? Int) ?? 0
            let resetsAt = (window["resets_at"] as? Double).map {
                Date(timeIntervalSince1970: $0)
            }
            return AgentUsageWindow(
                label: minutes > 0 ? AgentUsage.windowLabel(minutes: minutes) : key.capitalized,
                usedPercent: usedPercent,
                resetsAt: resetsAt
            )
        }
    }

    private static func applyContext(
        from info: [String: Any], to snapshot: inout AgentUsageSnapshot
    ) {
        // `last_token_usage`, not `total_token_usage`: the latter sums every
        // turn in the session and runs into the millions, while the context
        // window only ever holds what the most recent request carried.
        guard let contextWindow = info["model_context_window"] as? Int, contextWindow > 0,
              let usage = info["last_token_usage"] as? [String: Any],
              let total = usage["total_tokens"] as? Int
        else { return }
        snapshot.contextPercent = min(Double(total) / Double(contextWindow) * 100, 100)
        snapshot.contextDetail =
            "\(AgentUsage.tokenLabel(total)) / \(AgentUsage.tokenLabel(contextWindow)) tokens"
    }

    /// The last `tailByteLimit` bytes as whole lines — enough to hold the most
    /// recent `token_count` without reading a long session end to end.
    private static func tailLines(of url: URL) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(tailByteLimit) ? size - UInt64(tailByteLimit) : 0
        try? handle.seek(toOffset: offset)
        guard var data = try? handle.readToEnd() else { return nil }

        // A non-zero offset almost certainly lands mid-line; drop the partial.
        if offset > 0, let newline = data.firstIndex(of: 0x0A) {
            data = data[(newline + 1)...]
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").map(String.init)
    }
}
