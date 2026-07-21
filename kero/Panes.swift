//
//  Panes.swift
//  kero
//

import AppKit
import Combine
import Foundation

/// The leaf content of a pane: a terminal session, an open file, or a git
/// diff. A project tab used to *be* one of these; now a tab is a niri-style
/// layout of panes, and this is what sits at each leaf.
enum PaneContent: nonisolated Identifiable {
    case session(TerminalSession)
    case file(FileTab)
    case diff(DiffTab)

    nonisolated var id: UUID {
        switch self {
        case .session(let session): return session.id
        case .file(let file): return file.id
        case .diff(let diff): return diff.id
        }
    }

    var isDiff: Bool {
        if case .diff = self { return true }
        return false
    }
}

extension PaneContent {
    /// Label for the tab strip and pane chrome — the focused content's title.
    @MainActor var title: String {
        switch self {
        case .session(let session): return session.title
        case .file(let file): return file.name
        case .diff(let diff): return diff.title
        }
    }

    @MainActor var systemImage: String {
        switch self {
        case .session: return "terminal"
        case .file: return "doc.text"
        case .diff: return "plus.forwardslash.minus"
        }
    }

    @MainActor var isDirty: Bool {
        if case .file(let file) = self { return file.isDirty }
        return false
    }
}

/// One tile in a tab's layout. A value type so any structural change reassigns
/// the enclosing `@Published` column array and SwiftUI re-renders; the content
/// objects it points at are the long-lived reference types.
struct Pane: nonisolated Identifiable {
    let id = UUID()
    var content: PaneContent
    /// Relative vertical share within its column. Ratios are what matter — the
    /// layout normalises against the column's total.
    var weight: CGFloat = 1
}

/// A vertical stack of panes; columns tile left-to-right across the tab.
struct PaneColumn: nonisolated Identifiable {
    let id = UUID()
    var panes: [Pane]
    /// Relative horizontal share within the tab.
    var weight: CGFloat = 1
}

/// One entry in a project's tab strip: a niri-style layout of panes arranged
/// as a row of columns, each column a vertical stack. A plain single-content
/// tab is just a layout with one column holding one pane, so it looks and
/// behaves exactly as tabs did before splits existed.
@MainActor
final class PaneTab: nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id = UUID()

    @Published var columns: [PaneColumn]
    @Published var focusedPaneID: UUID

    /// A fresh single-pane tab wrapping one piece of content.
    init(content: PaneContent) {
        let pane = Pane(content: content)
        columns = [PaneColumn(panes: [pane])]
        focusedPaneID = pane.id
    }

    /// Restores a saved layout.
    init(columns: [PaneColumn], focusedPaneID: UUID) {
        self.columns = columns
        self.focusedPaneID = focusedPaneID
    }

    // MARK: - Derived

    var allPanes: [Pane] { columns.flatMap(\.panes) }
    var allContents: [PaneContent] { allPanes.map(\.content) }

    var focusedPane: Pane? { allPanes.first { $0.id == focusedPaneID } }
    var focusedContent: PaneContent? { focusedPane?.content }

    var sessions: [TerminalSession] {
        allContents.compactMap { if case .session(let session) = $0 { return session }; return nil }
    }

    var diffs: [DiffTab] {
        allContents.compactMap { if case .diff(let diff) = $0 { return diff }; return nil }
    }

    var hasMultiplePanes: Bool { allPanes.count > 1 }

    /// Splitting is disallowed while a diff is focused: diffs stay in their own
    /// single-pane tab so their always-mounted web view keeps filling the tab.
    var canSplit: Bool {
        if case .diff? = focusedContent { return false }
        return true
    }

    // MARK: - Navigation

    func focusUp() { moveWithinColumn(-1) }
    func focusDown() { moveWithinColumn(1) }
    func focusLeft() { moveToColumn(-1) }
    func focusRight() { moveToColumn(1) }

    private func moveWithinColumn(_ delta: Int) {
        guard let (col, row) = focusedLocation() else { return }
        let next = row + delta
        guard columns[col].panes.indices.contains(next) else { return }
        focusedPaneID = columns[col].panes[next].id
    }

    private func moveToColumn(_ delta: Int) {
        guard let (col, row) = focusedLocation() else { return }
        let nextCol = col + delta
        guard columns.indices.contains(nextCol) else { return }
        let panes = columns[nextCol].panes
        guard !panes.isEmpty else { return }
        // Land on the pane nearest the current vertical position.
        focusedPaneID = panes[min(row, panes.count - 1)].id
    }

    // MARK: - Structure

    /// Inserts `pane` as a new column immediately right of the focused pane's
    /// column, halving that column's width to make room. Focuses the new pane.
    func splitRight(with pane: Pane) {
        guard let (col, _) = focusedLocation() else {
            columns.append(PaneColumn(panes: [pane]))
            focusedPaneID = pane.id
            return
        }
        let share = columns[col].weight / 2
        columns[col].weight = share
        var column = PaneColumn(panes: [pane])
        column.weight = share
        columns.insert(column, at: col + 1)
        focusedPaneID = pane.id
    }

    /// Inserts `pane` directly below the focused pane in its column, halving
    /// that pane's height to make room. Focuses the new pane.
    func splitDown(with pane: Pane) {
        guard let (col, row) = focusedLocation() else { return }
        let share = columns[col].panes[row].weight / 2
        columns[col].panes[row].weight = share
        var inserted = pane
        inserted.weight = share
        columns[col].panes.insert(inserted, at: row + 1)
        focusedPaneID = inserted.id
    }

    /// Removes the pane with `id`, dropping its column when it empties and
    /// moving focus to the nearest survivor. Returns false when the tab is now
    /// empty, so the caller can drop the tab itself.
    @discardableResult
    func removePane(_ id: UUID) -> Bool {
        guard let (col, row) = location(of: id) else { return !allPanes.isEmpty }
        let wasFocused = focusedPaneID == id
        columns[col].panes.remove(at: row)
        if columns[col].panes.isEmpty {
            columns.remove(at: col)
        }
        if wasFocused { reassignFocus(near: col, row: row) }
        return !allPanes.isEmpty
    }

    // MARK: - Location helpers

    /// (column, row) of the focused pane.
    func focusedLocation() -> (col: Int, row: Int)? { location(of: focusedPaneID) }

    /// The id of the pane currently holding `contentID`.
    func paneID(forContent contentID: UUID) -> UUID? {
        allPanes.first { $0.content.id == contentID }?.id
    }

    private func location(of id: UUID) -> (col: Int, row: Int)? {
        for (col, column) in columns.enumerated() {
            if let row = column.panes.firstIndex(where: { $0.id == id }) {
                return (col, row)
            }
        }
        return nil
    }

    private func reassignFocus(near col: Int, row: Int) {
        guard !columns.isEmpty else { return }
        let column = columns[min(col, columns.count - 1)]
        guard !column.panes.isEmpty else {
            focusedPaneID = allPanes.first?.id ?? focusedPaneID
            return
        }
        focusedPaneID = column.panes[min(row, column.panes.count - 1)].id
    }
}
