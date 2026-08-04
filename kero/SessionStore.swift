//
//  SessionStore.swift
//  kero
//

import Foundation

/// Snapshot of open projects and tabs, saved so a relaunch restores the
/// previous layout. Terminal sessions restore as fresh shells started in
/// their last known working directory — with their previous scrollback
/// replayed above the prompt when the "Restore session history" setting is on
/// (see `historyKey` and `TerminalHistoryStore`); file and diff panes reload
/// from disk.
struct SessionSnapshot: Codable {
    struct ProjectSnapshot: Codable {
        /// A single pane's content — the terminal, file, browser, or diff it
        /// holds. The original case shapes stay unchanged, so old saved tabs
        /// still decode; see `TabSnapshot`.
        enum PaneContentSnapshot: Codable {
            case session(workingDirectory: String)
            case file(path: String, editorState: EditorState?)
            case browser(url: String?)
            case diff(repoRoot: String, path: String, staged: Bool, untracked: Bool, origPath: String?)
            case commitDiff(
                repoRoot: String,
                path: String,
                commitHash: String,
                parentHash: String?,
                status: String,
                origPath: String?
            )
        }

        struct PaneSnapshot: Codable {
            var content: PaneContentSnapshot
            var weight: Double
            /// Key into the sidecar terminal-history store for a session pane;
            /// nil for files, browsers, diffs, or when history restore is off.
            /// Optional so snapshots written before this feature still decode.
            var historyKey: String?
        }

        struct ColumnSnapshot: Codable {
            var panes: [PaneSnapshot]
            var weight: Double
        }

        /// The persisted recursive pane tree. Fractions belong to individual
        /// splits, so a child can be divided on either axis without affecting
        /// its siblings.
        indirect enum LayoutSnapshot: Codable {
            case pane(PaneSnapshot)
            case split(
                axis: PaneSplitAxis,
                fraction: Double,
                first: LayoutSnapshot,
                second: LayoutSnapshot
            )
        }

        /// One tab's recursive layout plus the focused leaf's tree-order
        /// position. Decodes both the former column/row format and the original
        /// pre-split single-content format.
        struct TabSnapshot: Codable {
            var layout: LayoutSnapshot
            var focusedPaneIndex: Int
            /// User-assigned tab name; nil when the title is automatic.
            /// Optional so older snapshots still decode.
            var customName: String?
            /// Position of the terminal this non-terminal tab was opened
            /// from in the project's flattened session list. Optional so
            /// snapshots written before context persistence still decode.
            var contextSessionIndex: Int?

            init(
                layout: LayoutSnapshot, focusedPaneIndex: Int,
                customName: String? = nil, contextSessionIndex: Int? = nil
            ) {
                self.layout = layout
                self.focusedPaneIndex = focusedPaneIndex
                self.customName = customName
                self.contextSessionIndex = contextSessionIndex
            }

            enum CodingKeys: String, CodingKey {
                case layout, focusedPaneIndex, customName, contextSessionIndex
                case columns, focusedColumn, focusedRow
            }

            init(from decoder: any Decoder) throws {
                if let container = try? decoder.container(keyedBy: CodingKeys.self),
                   container.contains(.layout) {
                    layout = try container.decode(LayoutSnapshot.self, forKey: .layout)
                    focusedPaneIndex =
                        (try? container.decode(Int.self, forKey: .focusedPaneIndex)) ?? 0
                    customName = try? container.decode(String.self, forKey: .customName)
                    contextSessionIndex = try? container.decode(
                        Int.self, forKey: .contextSessionIndex
                    )
                    return
                }
                if let container = try? decoder.container(keyedBy: CodingKeys.self),
                   let columns = try? container.decode(
                       [ColumnSnapshot].self, forKey: .columns
                   ), !columns.isEmpty {
                    let nonEmptyColumns = columns.filter { !$0.panes.isEmpty }
                    guard !nonEmptyColumns.isEmpty else {
                        throw DecodingError.dataCorruptedError(
                            forKey: .columns,
                            in: container,
                            debugDescription: "A pane layout must contain at least one pane"
                        )
                    }
                    let focusedColumn =
                        (try? container.decode(Int.self, forKey: .focusedColumn)) ?? 0
                    let focusedRow =
                        (try? container.decode(Int.self, forKey: .focusedRow)) ?? 0
                    layout = Self.layout(from: nonEmptyColumns)
                    let clampedColumn = min(max(0, focusedColumn), columns.count - 1)
                    focusedPaneIndex = columns[..<clampedColumn]
                        .reduce(0) { $0 + $1.panes.count }
                        + min(
                            max(0, focusedRow),
                            max(0, columns[clampedColumn].panes.count - 1)
                        )
                    customName = try? container.decode(String.self, forKey: .customName)
                    contextSessionIndex = nil
                    return
                }
                // Legacy: the tab was a single content enum. Wrap it in a
                // one-pane layout.
                let content = try PaneContentSnapshot(from: decoder)
                layout = .pane(PaneSnapshot(content: content, weight: 1))
                focusedPaneIndex = 0
                customName = nil
                contextSessionIndex = nil
            }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(layout, forKey: .layout)
                try container.encode(focusedPaneIndex, forKey: .focusedPaneIndex)
                try container.encodeIfPresent(customName, forKey: .customName)
                try container.encodeIfPresent(
                    contextSessionIndex, forKey: .contextSessionIndex
                )
            }

            /// Converts the former row-of-columns layout to an equivalent
            /// recursive tree so existing saved sessions continue to restore.
            private static func layout(from columns: [ColumnSnapshot]) -> LayoutSnapshot {
                let columnLayouts = columns.map { column in
                    (
                        node: stack(
                            column.panes.map { (.pane($0), $0.weight) },
                            axis: .vertical
                        ),
                        weight: column.weight
                    )
                }
                return stack(
                    columnLayouts.map { ($0.node, $0.weight) },
                    axis: .horizontal
                )
            }

            /// Builds a binary tree that preserves an n-item weighted stack.
            private static func stack(
                _ nodes: [(LayoutSnapshot, Double)], axis: PaneSplitAxis
            ) -> LayoutSnapshot {
                precondition(!nodes.isEmpty)
                guard nodes.count > 1 else { return nodes[0].0 }
                let firstWeight = max(0, nodes[0].1)
                let remainingWeight = nodes.dropFirst().reduce(0) {
                    $0 + max(0, $1.1)
                }
                let total = firstWeight + remainingWeight
                let fraction = total > 0
                    ? firstWeight / total
                    : 1 / Double(nodes.count)
                return .split(
                    axis: axis,
                    fraction: fraction,
                    first: nodes[0].0,
                    second: stack(Array(nodes.dropFirst()), axis: axis)
                )
            }
        }

        var customName: String?
        /// User-pinned project directory; nil when the directory is
        /// automatic (the closest git repository, never persisted).
        /// Optional so older snapshots still decode.
        var customDirectory: String?
        var tabs: [TabSnapshot]
        var selectedTabIndex: Int?
    }

    var projects: [ProjectSnapshot]
    var selectedProjectIndex: Int?
    /// Sidebar layout. Optional so snapshots written before these were
    /// captured still decode; nil leaves the window at its defaults.
    var isLeftSidebarVisible: Bool?
    var isRightPanelVisible: Bool?
    var rightPanelTab: RightPanel?
}

/// Persisted top level: one `SessionSnapshot` per open window, in
/// window-creation order.
private struct AppSnapshot: Codable {
    var windows: [SessionSnapshot]
}

enum SessionStore {
    private static let key = "sessionSnapshot"

    static func save(_ windows: [SessionSnapshot]) {
        guard let data = try? JSONEncoder().encode(AppSnapshot(windows: windows)) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> [SessionSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        if let app = try? JSONDecoder().decode(AppSnapshot.self, from: data) {
            return app.windows
        }
        // Pre-multi-window format: the snapshot of a single window.
        if let single = try? JSONDecoder().decode(SessionSnapshot.self, from: data) {
            return [single]
        }
        return []
    }
}
