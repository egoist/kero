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
        /// A single pane's content — the terminal/file/diff it holds. The case
        /// shapes match the pre-split format exactly, so old saved tabs (which
        /// were one of these directly) still decode; see `TabSnapshot`.
        enum PaneContentSnapshot: Codable {
            case session(workingDirectory: String)
            case file(path: String, editorState: EditorState?)
            case diff(repoRoot: String, path: String, staged: Bool, untracked: Bool, origPath: String?)
        }

        struct PaneSnapshot: Codable {
            var content: PaneContentSnapshot
            var weight: Double
            /// Key into the sidecar terminal-history store for a session pane;
            /// nil for files, diffs, or when history restore is off. Optional so
            /// snapshots written before this feature still decode.
            var historyKey: String?
        }

        struct ColumnSnapshot: Codable {
            var panes: [PaneSnapshot]
            var weight: Double
        }

        /// One tab's niri layout: a row of columns plus the focused pane's
        /// position. Decodes the pre-split format too — where a tab *was* a
        /// single content enum — by wrapping it in a one-pane layout.
        struct TabSnapshot: Codable {
            var columns: [ColumnSnapshot]
            var focusedColumn: Int
            var focusedRow: Int

            init(columns: [ColumnSnapshot], focusedColumn: Int, focusedRow: Int) {
                self.columns = columns
                self.focusedColumn = focusedColumn
                self.focusedRow = focusedRow
            }

            enum CodingKeys: String, CodingKey {
                case columns, focusedColumn, focusedRow
            }

            init(from decoder: any Decoder) throws {
                if let container = try? decoder.container(keyedBy: CodingKeys.self),
                   let columns = try? container.decode([ColumnSnapshot].self, forKey: .columns) {
                    self.columns = columns
                    focusedColumn = (try? container.decode(Int.self, forKey: .focusedColumn)) ?? 0
                    focusedRow = (try? container.decode(Int.self, forKey: .focusedRow)) ?? 0
                    return
                }
                // Legacy: the tab was a single content enum. Wrap it in a
                // one-column, one-pane layout.
                let content = try PaneContentSnapshot(from: decoder)
                columns = [ColumnSnapshot(panes: [PaneSnapshot(content: content, weight: 1)], weight: 1)]
                focusedColumn = 0
                focusedRow = 0
            }
        }

        var customName: String?
        var tabs: [TabSnapshot]
        var selectedTabIndex: Int?
    }

    var projects: [ProjectSnapshot]
    var selectedProjectIndex: Int?
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
