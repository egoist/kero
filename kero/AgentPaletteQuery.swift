//
//  AgentPaletteQuery.swift
//  kero
//

import Foundation

/// One agent-bearing terminal session, flattened for the palette.
///
/// Only the session's identity is captured; the live `TerminalSession` is
/// resolved through the manager when the palette needs its surface. That keeps
/// a transient overlay from extending the lifetime of a terminal the user has
/// since closed, and makes a vanished session detectable rather than stale.
struct AgentPaletteEntry {
    let sessionID: UUID
    let alias: String
    let kind: KeroAgentKind
    let projectName: String
    let tabTitle: String
    let directory: String
    /// Alias, agent name, project, tab, and directory folded together so one
    /// unprefixed word can find a session by any of them.
    let searchText: String
    /// Status is restated in place while the palette is open, so a badge stays
    /// truthful without its row moving.
    var phase: KeroAgentPhase
    var unseen: Bool
    var updatedAt: Date

    /// Ordering for an unfiltered palette: whatever wants the user first. An
    /// unacknowledged completion outranks one already seen, the same
    /// distinction the ⇧⌘A cycle and the status badge already draw.
    var attentionRank: Int {
        switch phase {
        case .blocked: return 0
        case .done: return unseen ? 1 : 2
        case .working: return 3
        case .created: return 4
        case .idle: return 5
        case .unknown: return 6
        }
    }
}

/// The search field parsed into structured filters plus leftover fuzzy text.
///
/// Tokens are `key:value`, values comma-separate as OR, and separate tokens
/// AND together. A token whose key is unknown — or whose values are all
/// unrecognized — degrades to plain search text rather than silently matching
/// nothing, so a typo narrows the list instead of emptying it.
struct AgentPaletteQuery {
    var statuses: Set<KeroAgentPhase> = []
    var kinds: Set<KeroAgentKind> = []
    /// One element per `project:` token; the names inside a token are the
    /// comma-separated alternatives. Flattening these would turn `a,b` into a
    /// requirement to match both, which no project name can satisfy.
    var projects: [[String]] = []
    var freeText = ""

    var hasFilters: Bool {
        !statuses.isEmpty || !kinds.isEmpty || !projects.isEmpty
    }

    var isEmpty: Bool { !hasFilters && freeText.isEmpty }

    /// `cursor-agent` is the executable name the recognizer keys on, but nobody
    /// types the suffix; the CLIs' own brand spellings are accepted too.
    private static let kindsByToken: [String: KeroAgentKind] = {
        var map: [String: KeroAgentKind] = [:]
        for kind in KeroAgentKind.allCases {
            map[kind.rawValue] = kind
        }
        map["cursor"] = .cursor
        map["claude-code"] = .claude
        map["opencode-ai"] = .opencode
        return map
    }()

    static func parse(_ raw: String) -> AgentPaletteQuery {
        var query = AgentPaletteQuery()
        var text: [String] = []

        for token in raw.split(separator: " ", omittingEmptySubsequences: true) {
            guard let separator = token.firstIndex(of: ":") else {
                text.append(String(token))
                continue
            }
            let key = token[token.startIndex..<separator].lowercased()
            let values = token[token.index(after: separator)...]
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.lowercased() }
            if values.isEmpty || !query.consume(key: key, values: values) {
                text.append(String(token))
            }
        }

        query.freeText = text.joined(separator: " ")
        return query
    }

    /// Returns false when the token is not a filter this palette understands,
    /// leaving the caller to treat it as search text.
    private mutating func consume(key: String, values: [String]) -> Bool {
        switch key {
        case "status", "s":
            let parsed = values.compactMap(KeroAgentPhase.init(rawValue:))
            guard !parsed.isEmpty else { return false }
            statuses.formUnion(parsed)
            return true
        case "agent", "a":
            let parsed = values.compactMap { Self.kindsByToken[$0] }
            guard !parsed.isEmpty else { return false }
            kinds.formUnion(parsed)
            return true
        case "project", "p":
            projects.append(values)
            return true
        default:
            return false
        }
    }

    /// Structured filters only. Fuzzy text is applied separately because it
    /// also produces the score the results are ranked by.
    func admits(_ entry: AgentPaletteEntry) -> Bool {
        if !statuses.isEmpty, !statuses.contains(entry.phase) { return false }
        if !kinds.isEmpty, !kinds.contains(entry.kind) { return false }
        for alternatives in projects where !alternatives.contains(
            where: { entry.projectName.localizedCaseInsensitiveContains($0) }
        ) {
            return false
        }
        return true
    }

    /// Human read-out of what the query is doing, shown under the field so
    /// typed filters are visibly understood before the results settle.
    var summary: String? {
        var parts: [String] = []
        if !statuses.isEmpty {
            parts.append(statuses.map(\.rawValue).sorted().joined(separator: "/"))
        }
        if !kinds.isEmpty {
            parts.append(kinds.map(\.displayName).sorted().joined(separator: "/"))
        }
        parts.append(contentsOf: projects.map {
            "project \($0.joined(separator: "/"))"
        })
        if !freeText.isEmpty { parts.append("\"\(freeText)\"") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
