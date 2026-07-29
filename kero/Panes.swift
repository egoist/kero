//
//  Panes.swift
//  kero
//

import AppKit
import Combine
import Foundation

/// The leaf content of a pane: a terminal session, an open file, a browser, or
/// a git diff. A project tab used to *be* one of these; now a tab is a
/// niri-style layout of panes, and this is what sits at each leaf.
enum PaneContent: nonisolated Identifiable {
    case session(TerminalSession)
    case file(FileTab)
    case browser(BrowserTab)
    case diff(DiffTab)

    nonisolated var id: UUID {
        switch self {
        case .session(let session): return session.id
        case .file(let file): return file.id
        case .browser(let browser): return browser.id
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
        case .browser(let browser): return browser.title
        case .diff(let diff): return diff.title
        }
    }

    @MainActor var systemImage: String {
        switch self {
        case .session: return "terminal"
        case .file: return "doc.text"
        case .browser: return "globe"
        case .diff: return "plus.forwardslash.minus"
        }
    }

    @MainActor var isDirty: Bool {
        if case .file(let file) = self { return file.isDirty }
        return false
    }
}

/// Which side of a target pane a dragged pane is dropped on, deciding where it
/// lands relative to that pane.
enum PaneDropEdge {
    case left, right, top, bottom
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

    /// User-assigned tab name; when nil the tab title follows the focused
    /// pane's content (terminal title, file name, diff title) — the same
    /// override scheme as `Project.customName`.
    @Published var customName: String?
    @Published var columns: [PaneColumn]
    @Published var focusedPaneID: UUID
    /// Whether the focused pane is zoomed to fill the tab. Presentation-only:
    /// the column structure and weights stay intact underneath, and the layout
    /// simply renders the focused pane alone while set — so zoom follows a
    /// focus change instead of hiding it. Cleared by focus navigation and by
    /// anything structural, so those commands always land on a visible layout.
    /// Deliberately not persisted.
    @Published var isZoomed = false

    /// The terminal whose directory this tab is oriented around when it holds
    /// no terminal of its own — captured from the focused session when a file
    /// or diff is opened into a fresh tab. Lets the file-tree / git / info
    /// panels keep tracking the directory the file was opened from instead of
    /// falling back to the project's first session. Weak, so closing that
    /// shell simply drops the association.
    weak var contextSession: TerminalSession?

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

    /// Title for the tab strip and Window menu: the user-assigned name when
    /// set, else the focused pane's own title.
    var displayTitle: String? {
        if let customName, !customName.isEmpty { return customName }
        return focusedContent?.title
    }

    var sessions: [TerminalSession] {
        allContents.compactMap { if case .session(let session) = $0 { return session }; return nil }
    }

    var diffs: [DiffTab] {
        allContents.compactMap { if case .diff(let diff) = $0 { return diff }; return nil }
    }

    var browsers: [BrowserTab] {
        allContents.compactMap {
            if case .browser(let browser) = $0 { return browser }
            return nil
        }
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
    /// Cycles focus through every pane in layout order — columns left to
    /// right, top to bottom within each — wrapping at the ends.
    func focusNext() { cycleFocus(1) }
    func focusPrevious() { cycleFocus(-1) }

    private func moveWithinColumn(_ delta: Int) {
        unzoom()
        guard let (col, row) = focusedLocation() else { return }
        let next = row + delta
        guard columns[col].panes.indices.contains(next) else { return }
        focusedPaneID = columns[col].panes[next].id
    }

    private func moveToColumn(_ delta: Int) {
        unzoom()
        guard let (col, row) = focusedLocation() else { return }
        let nextCol = col + delta
        guard columns.indices.contains(nextCol) else { return }
        let panes = columns[nextCol].panes
        guard !panes.isEmpty else { return }
        // Land on the pane nearest the current vertical position.
        focusedPaneID = panes[min(row, panes.count - 1)].id
    }

    private func cycleFocus(_ delta: Int) {
        unzoom()
        let panes = allPanes
        guard panes.count > 1,
              let index = panes.firstIndex(where: { $0.id == focusedPaneID }) else { return }
        focusedPaneID = panes[(index + delta + panes.count) % panes.count].id
    }

    // MARK: - Zoom

    /// Zooms the focused pane out to fill the tab, or restores the layout.
    func toggleZoom() {
        if isZoomed {
            isZoomed = false
        } else if hasMultiplePanes {
            isZoomed = true
        }
    }

    /// Leaves zoom, guarded so the common unzoomed case doesn't fire a
    /// spurious @Published change.
    private func unzoom() {
        if isZoomed { isZoomed = false }
    }

    // MARK: - Structure

    /// Inserts `pane` next to the focused pane on the given edge, taking half
    /// the space it splits into. Left/right open a new column beside the focused
    /// column; top/bottom stack within it. Focuses the new pane.
    func split(_ pane: Pane, toward edge: PaneDropEdge) {
        unzoom()
        guard let (col, row) = focusedLocation() else {
            columns.append(PaneColumn(panes: [pane]))
            focusedPaneID = pane.id
            return
        }
        switch edge {
        case .left, .right:
            let share = columns[col].weight / 2
            columns[col].weight = share
            var column = PaneColumn(panes: [pane])
            column.weight = share
            columns.insert(column, at: edge == .left ? col : col + 1)
        case .top, .bottom:
            let share = columns[col].panes[row].weight / 2
            columns[col].panes[row].weight = share
            var inserted = pane
            inserted.weight = share
            columns[col].panes.insert(inserted, at: edge == .top ? row : row + 1)
        }
        focusedPaneID = pane.id
    }

    /// Moves `dragged` next to `target` on the given edge — the drag-to-split
    /// gesture. Top/bottom stack it directly above/below the target inside the
    /// target's column; left/right place it in a new column beside the target's
    /// column (niri moves windows between columns, so there's no nesting). The
    /// moved pane takes half the space it splits into, and focus follows it.
    func movePane(_ dragged: UUID, _ edge: PaneDropEdge, of target: UUID) {
        guard dragged != target, let from = location(of: dragged) else { return }
        unzoom()
        var moved = columns[from.col].panes[from.row]

        // Remove from the old slot first — indices shift, so the target is
        // re-found by id below rather than trusting a stale position.
        columns[from.col].panes.remove(at: from.row)
        if columns[from.col].panes.isEmpty {
            columns.remove(at: from.col)
        }

        guard let to = location(of: target) else {
            // Shouldn't happen, but never drop the pane on the floor.
            moved.weight = 1
            columns.append(PaneColumn(panes: [moved]))
            focusedPaneID = moved.id
            return
        }

        switch edge {
        case .top, .bottom:
            let share = columns[to.col].panes[to.row].weight / 2
            columns[to.col].panes[to.row].weight = share
            moved.weight = share
            columns[to.col].panes.insert(moved, at: edge == .top ? to.row : to.row + 1)
        case .left, .right:
            let share = columns[to.col].weight / 2
            columns[to.col].weight = share
            moved.weight = 1
            var column = PaneColumn(panes: [moved])
            column.weight = share
            columns.insert(column, at: edge == .left ? to.col : to.col + 1)
        }
        focusedPaneID = moved.id
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
        // Losing the zoomed pane itself (or the whole split) drops back to the
        // layout; a hidden sibling closing underneath the zoom does not.
        if wasFocused || allPanes.count <= 1 { unzoom() }
        return !allPanes.isEmpty
    }

    // MARK: - Keyboard resize

    /// Fraction of an axis's total weight one keyboard-resize step shifts.
    private static let resizeStep: CGFloat = 0.05
    /// Smallest share any tile may be shrunk to — the same floor the drag
    /// dividers enforce (`PaneLayoutView.minFraction`).
    private static let minShare: CGFloat = 0.1

    func resizeUp() { resizeRows(toward: -1) }
    func resizeDown() { resizeRows(toward: 1) }
    func resizeLeft() { resizeColumns(toward: -1) }
    func resizeRight() { resizeColumns(toward: 1) }

    /// Sets every column and pane back to equal shares.
    func equalize() {
        unzoom()
        guard hasMultiplePanes else { return }
        for col in columns.indices {
            columns[col].weight = 1
            for row in columns[col].panes.indices {
                columns[col].panes[row].weight = 1
            }
        }
    }

    /// Pushes a divider of the focused column one step left or right
    /// (`direction` -1/+1): the divider on the pressed side when there is one,
    /// so the column grows that way; at the edges the opposite divider moves
    /// instead, shrinking the column — both keys always do something.
    private func resizeColumns(toward direction: Int) {
        unzoom()
        guard columns.count > 1, let (col, _) = focusedLocation() else { return }
        let divider = dividerIndex(at: col, count: columns.count, toward: direction)
        guard let (first, second) = shifted(columns.map(\.weight), at: divider, toward: direction)
        else { return }
        columns[divider].weight = first
        columns[divider + 1].weight = second
    }

    /// Same as `resizeColumns`, for the pane dividers within the focused
    /// column.
    private func resizeRows(toward direction: Int) {
        unzoom()
        guard let (col, row) = focusedLocation(), columns[col].panes.count > 1 else { return }
        let divider = dividerIndex(at: row, count: columns[col].panes.count, toward: direction)
        guard let (first, second) = shifted(columns[col].panes.map(\.weight), at: divider, toward: direction)
        else { return }
        columns[col].panes[divider].weight = first
        columns[col].panes[divider + 1].weight = second
    }

    /// Which divider a resize at tile `index` moves: the one on the pressed
    /// side, falling back to the only remaining side at the edges. Divider `d`
    /// sits between tiles `d` and `d + 1`.
    private func dividerIndex(at index: Int, count: Int, toward direction: Int) -> Int {
        if direction > 0 {
            return index < count - 1 ? index : index - 1
        } else {
            return index > 0 ? index - 1 : index
        }
    }

    /// One resize step across the divider between tiles `index` and
    /// `index + 1`: +1 grows the first tile, -1 the second, by
    /// `resizeStep` of the axis's total — clamped so the shrinking tile never
    /// drops below `minShare`. Nil when it is already there.
    private func shifted(
        _ weights: [CGFloat], at index: Int, toward direction: Int
    ) -> (CGFloat, CGFloat)? {
        let total = weights.reduce(0, +)
        guard total > 0 else { return nil }
        let donor = direction > 0 ? weights[index + 1] : weights[index]
        let step = min(total * Self.resizeStep, donor - total * Self.minShare)
        guard step > 0 else { return nil }
        let delta = step * CGFloat(direction)
        return (weights[index] + delta, weights[index + 1] - delta)
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
