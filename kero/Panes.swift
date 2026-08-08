//
//  Panes.swift
//  kero
//

import AppKit
import Combine
import Foundation

/// The leaf content of a pane: a terminal session, an open file, a browser, or
/// a git diff. A project tab used to *be* one of these; now a tab is a recursive
/// split layout, and this is what sits at each leaf.
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

    var isFile: Bool {
        if case .file = self { return true }
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

    /// File and diff panes both represent a concrete path. Their surrounding
    /// chrome uses the same filename-aware icon as the file and Git panels.
    @MainActor var fileIconPath: String? {
        switch self {
        case .file(let file): return file.path
        case .diff(let diff): return diff.path
        case .session, .browser: return nil
        }
    }

    @MainActor var isDirty: Bool {
        switch self {
        case .file(let file): return file.isDirty
        case .diff(let diff): return diff.isDirty
        case .session, .browser: return false
        }
    }

    @MainActor var saveError: String? {
        switch self {
        case .file(let file): return file.saveError
        case .diff(let diff): return diff.saveError
        case .session, .browser: return nil
        }
    }

    @MainActor func save() {
        switch self {
        case .file(let file): file.save()
        case .diff(let diff): diff.save()
        case .session, .browser: break
        }
    }
}

/// Which side of a target pane a dragged pane is dropped on, deciding where it
/// lands relative to that pane.
enum PaneDropEdge {
    case left, right, top, bottom
}

/// The direction in which a split lays out its two children.
enum PaneSplitAxis: String, Codable {
    case horizontal
    case vertical
}

/// One tile in a tab's layout. The content object is long-lived while the pane
/// itself is a value inside the split tree.
struct Pane: nonisolated Identifiable {
    let id = UUID()
    var content: PaneContent
}

/// A binary split in the pane tree. `fraction` is the first child's share of
/// the available axis after the divider gap is removed.
struct PaneSplit: nonisolated Identifiable {
    let id = UUID()
    var axis: PaneSplitAxis
    var fraction: CGFloat
    var first: PaneNode
    var second: PaneNode
}

/// Pane layouts are recursive so every split subdivides the focused pane's own
/// rectangle. This is what lets a right split of the lower pane in a top/bottom
/// layout stay beside that lower pane instead of spanning the full tab height.
indirect enum PaneNode {
    case pane(Pane)
    case split(PaneSplit)

    var allPanes: [Pane] {
        switch self {
        case .pane(let pane):
            return [pane]
        case .split(let split):
            return split.first.allPanes + split.second.allPanes
        }
    }

    func contains(_ paneID: UUID) -> Bool {
        switch self {
        case .pane(let pane):
            return pane.id == paneID
        case .split(let split):
            return split.first.contains(paneID) || split.second.contains(paneID)
        }
    }

    /// Replaces `target` with a split containing it and `pane`.
    func inserting(_ pane: Pane, toward edge: PaneDropEdge, beside target: UUID) -> PaneNode {
        inserting(.pane(pane), toward: edge, beside: target)
    }

    /// Replaces `target` with a split containing it and another pane tree.
    /// Keeping the inserted tree intact lets a dragged split tab become one
    /// branch of the destination without flattening or losing its fractions.
    func inserting(_ node: PaneNode, toward edge: PaneDropEdge, beside target: UUID) -> PaneNode {
        switch self {
        case .pane(let existing):
            guard existing.id == target else { return self }
            let axis: PaneSplitAxis = edge == .left || edge == .right
                ? .horizontal : .vertical
            let insertedFirst = edge == .left || edge == .top
            return .split(PaneSplit(
                axis: axis,
                fraction: 0.5,
                first: insertedFirst ? node : .pane(existing),
                second: insertedFirst ? .pane(existing) : node
            ))
        case .split(var split):
            if split.first.contains(target) {
                split.first = split.first.inserting(node, toward: edge, beside: target)
            } else if split.second.contains(target) {
                split.second = split.second.inserting(node, toward: edge, beside: target)
            }
            return .split(split)
        }
    }

    /// Removes a leaf and collapses its now-single-child parent.
    func removingPane(_ paneID: UUID) -> (node: PaneNode?, pane: Pane?) {
        switch self {
        case .pane(let pane):
            return pane.id == paneID ? (nil, pane) : (self, nil)
        case .split(var split):
            let firstResult = split.first.removingPane(paneID)
            if let removed = firstResult.pane {
                guard let first = firstResult.node else { return (split.second, removed) }
                split.first = first
                return (.split(split), removed)
            }
            let secondResult = split.second.removingPane(paneID)
            if let removed = secondResult.pane {
                guard let second = secondResult.node else { return (split.first, removed) }
                split.second = second
                return (.split(split), removed)
            }
            return (self, nil)
        }
    }

    func settingFraction(of splitID: UUID, to fraction: CGFloat) -> PaneNode {
        switch self {
        case .pane:
            return self
        case .split(var split):
            if split.id == splitID {
                split.fraction = fraction
            } else {
                split.first = split.first.settingFraction(of: splitID, to: fraction)
                split.second = split.second.settingFraction(of: splitID, to: fraction)
            }
            return .split(split)
        }
    }

    func fraction(of splitID: UUID) -> CGFloat? {
        switch self {
        case .pane:
            return nil
        case .split(let split):
            if split.id == splitID { return split.fraction }
            return split.first.fraction(of: splitID) ?? split.second.fraction(of: splitID)
        }
    }

    func equalized() -> PaneNode {
        switch self {
        case .pane:
            return self
        case .split(var split):
            split.first = split.first.equalized()
            split.second = split.second.equalized()
            let firstSpan = split.first.spanCount(along: split.axis)
            let secondSpan = split.second.spanCount(along: split.axis)
            split.fraction = firstSpan / (firstSpan + secondSpan)
            return .split(split)
        }
    }

    /// Counts adjacent tiles along `axis`, treating a perpendicular subtree as
    /// one tile. This preserves the old equalize behavior for both flat rows
    /// and columns while leaving nested perpendicular groups evenly divided.
    private func spanCount(along axis: PaneSplitAxis) -> CGFloat {
        guard case .split(let split) = self, split.axis == axis else { return 1 }
        return split.first.spanCount(along: axis)
            + split.second.spanCount(along: axis)
    }

    func ancestors(of paneID: UUID) -> [PaneSplitAncestor]? {
        switch self {
        case .pane(let pane):
            return pane.id == paneID ? [] : nil
        case .split(let split):
            if let descendants = split.first.ancestors(of: paneID) {
                return [PaneSplitAncestor(
                    id: split.id, axis: split.axis, paneIsInFirstChild: true
                )] + descendants
            }
            if let descendants = split.second.ancestors(of: paneID) {
                return [PaneSplitAncestor(
                    id: split.id, axis: split.axis, paneIsInFirstChild: false
                )] + descendants
            }
            return nil
        }
    }

    /// Computes absolute pane and divider rectangles for both the live layout
    /// and the tab-switcher thumbnail.
    func geometry(in bounds: CGRect, gap: CGFloat) -> PaneLayoutGeometry {
        var geometry = PaneLayoutGeometry()
        appendGeometry(in: bounds, gap: gap, to: &geometry)
        return geometry
    }

    private func appendGeometry(
        in bounds: CGRect, gap: CGFloat, to geometry: inout PaneLayoutGeometry
    ) {
        switch self {
        case .pane(let pane):
            geometry.panes.append(PanePlacement(pane: pane, frame: bounds))
        case .split(let split):
            let fraction = min(max(split.fraction, 0), 1)
            switch split.axis {
            case .horizontal:
                let available = max(0, bounds.width - gap)
                let firstWidth = available * fraction
                let dividerX = bounds.minX + firstWidth
                split.first.appendGeometry(
                    in: CGRect(
                        x: bounds.minX, y: bounds.minY,
                        width: firstWidth, height: bounds.height
                    ),
                    gap: gap,
                    to: &geometry
                )
                geometry.dividers.append(PaneDividerPlacement(
                    id: split.id,
                    axis: split.axis,
                    frame: CGRect(
                        x: dividerX, y: bounds.minY,
                        width: gap, height: bounds.height
                    ),
                    availableLength: available
                ))
                split.second.appendGeometry(
                    in: CGRect(
                        x: dividerX + gap, y: bounds.minY,
                        width: available - firstWidth, height: bounds.height
                    ),
                    gap: gap,
                    to: &geometry
                )
            case .vertical:
                let available = max(0, bounds.height - gap)
                let firstHeight = available * fraction
                let dividerY = bounds.minY + firstHeight
                split.first.appendGeometry(
                    in: CGRect(
                        x: bounds.minX, y: bounds.minY,
                        width: bounds.width, height: firstHeight
                    ),
                    gap: gap,
                    to: &geometry
                )
                geometry.dividers.append(PaneDividerPlacement(
                    id: split.id,
                    axis: split.axis,
                    frame: CGRect(
                        x: bounds.minX, y: dividerY,
                        width: bounds.width, height: gap
                    ),
                    availableLength: available
                ))
                split.second.appendGeometry(
                    in: CGRect(
                        x: bounds.minX, y: dividerY + gap,
                        width: bounds.width, height: available - firstHeight
                    ),
                    gap: gap,
                    to: &geometry
                )
            }
        }
    }
}

struct PaneSplitAncestor {
    let id: UUID
    let axis: PaneSplitAxis
    let paneIsInFirstChild: Bool
}

struct PanePlacement: Identifiable {
    var id: UUID { pane.id }
    let pane: Pane
    let frame: CGRect
}

struct PaneDividerPlacement: Identifiable {
    let id: UUID
    let axis: PaneSplitAxis
    let frame: CGRect
    let availableLength: CGFloat
}

struct PaneLayoutGeometry {
    var panes: [PanePlacement] = []
    var dividers: [PaneDividerPlacement] = []
}

/// One entry in a project's tab strip. A plain tab is one leaf; every split
/// replaces one leaf with a binary node while the long-lived content objects
/// remain mounted in their corresponding leaves.
@MainActor
final class PaneTab: nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id = UUID()

    /// User-assigned tab name; when nil the tab title follows the focused
    /// pane's content (terminal title, file name, diff title) — the same
    /// override scheme as `Project.customName`.
    @Published var customName: String?
    @Published var layout: PaneNode
    @Published var focusedPaneID: UUID
    /// Whether the focused pane is zoomed to fill the tab. Presentation-only:
    /// the split tree and fractions stay intact underneath, and the layout
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
        layout = .pane(pane)
        focusedPaneID = pane.id
    }

    /// Restores a saved layout.
    init(layout: PaneNode, focusedPaneID: UUID) {
        self.layout = layout
        self.focusedPaneID = focusedPaneID
    }

    // MARK: - Derived

    var allPanes: [Pane] { layout.allPanes }
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
    func focusDown() { moveFocus(.down) }
    func focusLeft() { moveFocus(.left) }
    func focusRight() { moveFocus(.right) }
    /// Cycles focus through every pane in split-tree order, wrapping at the
    /// ends.
    func focusNext() { cycleFocus(1) }
    func focusPrevious() { cycleFocus(-1) }

    private enum FocusDirection {
        case left, right, up, down
    }

    private func moveWithinColumn(_ delta: Int) {
        moveFocus(delta < 0 ? .up : .down)
    }

    /// Picks the closest pane in the requested geometric direction. Prefer a
    /// pane overlapping the focused pane on the perpendicular axis, then the
    /// nearest edge and centre.
    private func moveFocus(_ direction: FocusDirection) {
        unzoom()
        let placements = layout.geometry(
            in: CGRect(x: 0, y: 0, width: 1, height: 1), gap: 0
        ).panes
        guard let current = placements.first(where: { $0.pane.id == focusedPaneID })
        else { return }

        let candidates = placements.compactMap { placement -> (UUID, CGFloat)? in
            guard placement.pane.id != focusedPaneID else { return nil }
            let frame = placement.frame
            let primary: CGFloat
            let perpendicularGap: CGFloat
            let centerDistance: CGFloat
            switch direction {
            case .left:
                guard frame.maxX <= current.frame.minX + 0.0001 else { return nil }
                primary = current.frame.minX - frame.maxX
                perpendicularGap = intervalGap(
                    frame.minY, frame.maxY, current.frame.minY, current.frame.maxY
                )
                centerDistance = abs(frame.midY - current.frame.midY)
            case .right:
                guard frame.minX >= current.frame.maxX - 0.0001 else { return nil }
                primary = frame.minX - current.frame.maxX
                perpendicularGap = intervalGap(
                    frame.minY, frame.maxY, current.frame.minY, current.frame.maxY
                )
                centerDistance = abs(frame.midY - current.frame.midY)
            case .up:
                guard frame.maxY <= current.frame.minY + 0.0001 else { return nil }
                primary = current.frame.minY - frame.maxY
                perpendicularGap = intervalGap(
                    frame.minX, frame.maxX, current.frame.minX, current.frame.maxX
                )
                centerDistance = abs(frame.midX - current.frame.midX)
            case .down:
                guard frame.minY >= current.frame.maxY - 0.0001 else { return nil }
                primary = frame.minY - current.frame.maxY
                perpendicularGap = intervalGap(
                    frame.minX, frame.maxX, current.frame.minX, current.frame.maxX
                )
                centerDistance = abs(frame.midX - current.frame.midX)
            }
            let score = (perpendicularGap > 0 ? 10 : 0)
                + perpendicularGap * 5 + primary + centerDistance * 0.01
            return (placement.pane.id, score)
        }
        if let closest = candidates.min(by: { $0.1 < $1.1 }) {
            focusedPaneID = closest.0
        }
    }

    private func intervalGap(
        _ firstMin: CGFloat, _ firstMax: CGFloat,
        _ secondMin: CGFloat, _ secondMax: CGFloat
    ) -> CGFloat {
        max(0, max(firstMin, secondMin) - min(firstMax, secondMax))
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

    /// Inserts `pane` inside the focused pane's rectangle, taking half of that
    /// rectangle on the requested edge. Focuses the new pane.
    func split(_ pane: Pane, toward edge: PaneDropEdge) {
        split(
            pane,
            toward: edge,
            beside: focusedPaneID,
            focusInserted: true
        )
    }

    /// Automation can split a specific pane without stealing the user's tab
    /// or pane focus. Interactive split commands keep using the convenience
    /// overload above and therefore focus the inserted pane.
    func split(
        _ pane: Pane,
        toward edge: PaneDropEdge,
        beside requestedTarget: UUID,
        focusInserted: Bool
    ) {
        unzoom()
        let target = layout.contains(requestedTarget)
            ? requestedTarget : layout.allPanes[0].id
        layout = layout.inserting(pane, toward: edge, beside: target)
        if focusInserted { focusedPaneID = pane.id }
    }

    /// Inserts another tab's complete layout beside a pane in this tab. The
    /// dragged tab's focused pane becomes focused here after the move.
    func insert(
        _ insertedLayout: PaneNode,
        focusedPaneID insertedFocus: UUID,
        toward edge: PaneDropEdge,
        beside target: UUID
    ) {
        guard layout.contains(target), insertedLayout.contains(insertedFocus) else { return }
        unzoom()
        layout = layout.inserting(insertedLayout, toward: edge, beside: target)
        focusedPaneID = insertedFocus
    }

    /// Moves `dragged` next to `target` on the given edge — the drag-to-split
    /// gesture. The target leaf is subdivided on that edge, exactly like a new
    /// split. The moved pane takes half the target's space and focus follows it.
    func movePane(_ dragged: UUID, _ edge: PaneDropEdge, of target: UUID) {
        guard dragged != target, layout.contains(dragged), layout.contains(target) else { return }
        unzoom()
        let result = layout.removingPane(dragged)
        guard let moved = result.pane, let remaining = result.node,
              remaining.contains(target) else { return }
        layout = remaining.inserting(moved, toward: edge, beside: target)
        focusedPaneID = moved.id
    }

    /// Removes the pane with `id`, collapsing the empty split branch and moving
    /// focus to the nearest survivor in tree order. Returns false when the tab
    /// is now empty, so the caller can drop the tab itself.
    @discardableResult
    func removePane(_ id: UUID) -> Bool {
        let panesBefore = allPanes
        guard let index = panesBefore.firstIndex(where: { $0.id == id }) else {
            return !panesBefore.isEmpty
        }
        let wasFocused = focusedPaneID == id
        let result = layout.removingPane(id)
        guard result.pane != nil, let remaining = result.node else { return false }
        layout = remaining
        if wasFocused {
            let survivors = allPanes
            focusedPaneID = survivors[min(index, survivors.count - 1)].id
        }
        // Losing the zoomed pane itself (or the whole split) drops back to the
        // layout; a hidden sibling closing underneath the zoom does not.
        if wasFocused || allPanes.count <= 1 { unzoom() }
        return true
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

    /// Sets every adjacent run of panes back to equal shares.
    func equalize() {
        unzoom()
        guard hasMultiplePanes else { return }
        layout = layout.equalized()
    }

    /// Pushes the nearest horizontal ancestor divider one step left or right
    /// (`direction` -1/+1): the divider on the pressed side when there is one,
    /// so the focused branch grows that way; at an edge the opposite divider
    /// moves instead, shrinking the branch — both keys always do something.
    private func resizeColumns(toward direction: Int) {
        resizeSplit(axis: .horizontal, toward: direction)
    }

    /// Same as `resizeColumns`, for the nearest vertical ancestor divider.
    private func resizeRows(toward direction: Int) {
        resizeSplit(axis: .vertical, toward: direction)
    }

    private func resizeSplit(axis: PaneSplitAxis, toward direction: Int) {
        unzoom()
        guard let ancestors = layout.ancestors(of: focusedPaneID) else { return }
        let matching = ancestors.reversed().filter { $0.axis == axis }
        guard let split = matching.first(where: {
            $0.paneIsInFirstChild == (direction > 0)
        }) ?? matching.first,
        let fraction = layout.fraction(of: split.id) else { return }
        let next = min(
            max(fraction + CGFloat(direction) * Self.resizeStep, Self.minShare),
            1 - Self.minShare
        )
        guard next != fraction else { return }
        layout = layout.settingFraction(of: split.id, to: next)
    }

    // MARK: - Location helpers

    /// The id of the pane currently holding `contentID`.
    func paneID(forContent contentID: UUID) -> UUID? {
        allPanes.first { $0.content.id == contentID }?.id
    }
}
