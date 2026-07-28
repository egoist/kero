//
//  PaneDragCoordinator.swift
//  kero
//

import Combine
import Foundation
import SwiftUI

/// Shared state for the two drags that cross between the tab strip and the
/// pane layout: carrying a pane up onto the strip (it becomes its own tab) and
/// carrying a tab down onto a pane (its panes merge into that layout).
///
/// The two live in different parts of the view tree — `SessionTabsView` in the
/// header, `PaneLayoutView` in the content area — and each needs the other's
/// geometry to hit-test the cursor, so the frames and the in-flight drag meet
/// here rather than in either view's `@State`.
///
/// Frames are deliberately *not* `@Published`: they are written from
/// `onPreferenceChange` during layout, and republishing them there would feed
/// straight back into another layout pass. Only the drags publish, and only
/// this small pair of views observes them — a per-frame change never reaches
/// the manager, so it never re-renders the window.
@MainActor
final class PaneDragCoordinator: ObservableObject {
    /// A pane being carried by its header strip.
    struct PaneDrag {
        let paneID: UUID
        var location: CGPoint
        /// The pane it is hovering over, and which edge of it — a split.
        var targetPaneID: UUID?
        var edge: PaneDropEdge?
        /// Where it would land in the tab strip, when the cursor is up there
        /// instead — the index the extracted tab is inserted at.
        var tabDropIndex: Int?
        /// The sidebar project it would move to, when the cursor is over a
        /// project row.
        var targetProjectID: UUID?

        var isOverStrip: Bool { tabDropIndex != nil }
        /// Over the strip or a project row, the pane becomes a tab either way,
        /// so the thumbnail previews a tab rather than the pane.
        var previewsTab: Bool { tabDropIndex != nil || targetProjectID != nil }
    }

    /// A tab being carried out of the strip and over the pane layout.
    struct TabDrag {
        let tabID: UUID
        var location: CGPoint
        var targetPaneID: UUID?
        var edge: PaneDropEdge?
        /// The sidebar project it would move to, when the cursor is over a
        /// project row.
        var targetProjectID: UUID?
    }

    @Published var paneDrag: PaneDrag?
    @Published var tabDrag: TabDrag?

    /// Global-space frame of every mounted pane, from `PaneLayoutView`.
    var paneFrames: [UUID: CGRect] = [:]
    /// Global-space frame of every tab item, and of the strip as a whole, from
    /// `SessionTabsView`. The strip frame is the drop region: anywhere in the
    /// header row counts, so the gesture doesn't demand pixel accuracy.
    var tabFrames: [UUID: CGRect] = [:]
    var stripFrame: CGRect = .zero
    /// Global-space frame of every sidebar project row, from `SidebarView`.
    var projectFrames: [UUID: CGRect] = [:]

    /// The pane under `location`, if any — excluding `excluding`, which is the
    /// pane being carried.
    func pane(at location: CGPoint, excluding: UUID? = nil) -> (id: UUID, frame: CGRect)? {
        paneFrames
            .first { $0.key != excluding && $0.value.contains(location) }
            .map { (id: $0.key, frame: $0.value) }
    }

    /// The sidebar project row under `location`, if any — excluding
    /// `excluding`, the project the dragged tab already belongs to, so its own
    /// row never lights up as a destination.
    func project(at location: CGPoint, excluding: UUID? = nil) -> UUID? {
        projectFrames
            .first { $0.key != excluding && $0.value.contains(location) }?
            .key
    }

    /// The project row being previewed as a drop target right now, from
    /// whichever drag is in flight.
    func isDropTarget(project projectID: UUID) -> Bool {
        paneDrag?.targetProjectID == projectID || tabDrag?.targetProjectID == projectID
    }

    /// Where a pane dropped at `location` would be inserted in the strip: the
    /// number of tabs whose midpoint the cursor has passed. Nil when the cursor
    /// isn't over the strip at all.
    func tabInsertionIndex(at location: CGPoint, in order: [UUID]) -> Int? {
        guard stripFrame.contains(location) else { return nil }
        return order.filter { id in
            guard let frame = tabFrames[id] else { return false }
            return location.x > frame.midX
        }.count
    }

    /// Which edge of `frame` the pointer is nearest — the target is cut into
    /// four triangular quadrants by its diagonals, the standard drop-zone
    /// scheme (VS Code, Ghostty).
    func dropEdge(at location: CGPoint, in frame: CGRect) -> PaneDropEdge {
        let dx = (location.x - frame.midX) / max(frame.width, 1)
        let dy = (location.y - frame.midY) / max(frame.height, 1)
        if abs(dx) > abs(dy) {
            return dx < 0 ? .left : .right
        } else {
            return dy < 0 ? .top : .bottom
        }
    }

    /// The drop edge being previewed on `paneID` right now, from whichever of
    /// the two drags is in flight. Drives the half-pane highlight.
    func dropEdge(previewedOn paneID: UUID) -> PaneDropEdge? {
        if let paneDrag, paneDrag.targetPaneID == paneID { return paneDrag.edge }
        if let tabDrag, tabDrag.targetPaneID == paneID { return tabDrag.edge }
        return nil
    }

    func clear() {
        paneDrag = nil
        tabDrag = nil
    }
}

/// Collects each pane's global-space frame so a drag can hit-test the cursor
/// against them.
struct PaneFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Collects each tab item's global frame, so a direct drag gesture can
/// hit-test the pointer even while the horizontal strip scrolls under it.
struct TabFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
