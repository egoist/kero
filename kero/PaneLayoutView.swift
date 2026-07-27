//
//  PaneLayoutView.swift
//  kero
//

import AppKit
import SwiftUI

/// Tiles a tab's panes niri-style: columns laid out left-to-right, each a
/// vertical stack of panes. Column widths and pane heights come from their
/// relative `weight`s; draggable dividers between tiles shift weight between
/// neighbors. Only the selected tab's layout is ever mounted.
struct PaneLayoutView: View {
    @ObservedObject var tab: PaneTab
    @ObservedObject private var themeChanges = Theme.changes
    /// Splits the focused pane on the given edge — from a pane's context menu.
    var onSplit: (PaneDropEdge) -> Void = { _ in }

    /// Gap between tiles, which doubles as the divider hit area. The same
    /// value insets the whole grid from the parent, so the spacing around the
    /// panes matches the spacing between them.
    private let gap: CGFloat = 10
    /// Smallest share any single tile may be shrunk to.
    private let minFraction: CGFloat = 0.1
    /// Bounding box the drag thumbnail is scaled to fit within, preserving the
    /// pane's aspect ratio so a tall pane yields a tall thumbnail (rather than
    /// cropping to its empty middle).
    private let thumbnailMaxSize = CGSize(width: 220, height: 160)

    @State private var drag: DragState?
    /// While a divider drag is in flight the new weights live here — local
    /// @State that re-renders only this grid — instead of in `tab.columns`,
    /// whose @Published change would re-render the whole window every frame.
    /// Committed back to the model once, on release.
    @State private var dragColumns: [PaneColumn]?

    /// Global-space frame of every pane, so a pane-move drag can tell which
    /// pane the cursor is over.
    @State private var paneFrames: [UUID: CGRect] = [:]
    /// In-flight pane-move drag: which pane is being carried, where the pointer
    /// is, and which pane it is hovering over (the drop target).
    @State private var paneDrag: PaneMove?
    /// A snapshot of the carried pane, shown as a thumbnail under the cursor.
    @State private var dragThumbnail: NSImage?

    private struct DragState {
        enum Kind: Equatable {
            case columns
            case rows(columnID: UUID)
        }
        var kind: Kind
        var index: Int
        var weights: [CGFloat]
    }

    private struct PaneMove {
        let sourceID: UUID
        var location: CGPoint
        var targetID: UUID?
        var edge: PaneDropEdge?
    }

    var body: some View {
        Group {
            if tab.isZoomed, tab.hasMultiplePanes, let pane = tab.focusedPane {
                // Zoom: the focused pane alone, filling the tab. The grid — and
                // with it the dividers and the other panes — unmounts, exactly
                // like an unselected tab's layout; the focus ring stays as the
                // hint that a split layout is hiding underneath.
                PaneView(
                    tab: tab,
                    pane: pane,
                    showFocusRing: true,
                    allowsMove: false,
                    isMoveSource: false,
                    dropEdge: nil,
                    onMove: { _ in },
                    onMoveEnded: {},
                    onSplit: onSplit
                )
            } else {
                grid
            }
        }
        // Inset the whole grid from the parent by the same gap used between
        // tiles, so a split tab has even breathing room on every side. A
        // single-pane tab stays full-bleed, exactly as before splits existed.
        .padding(tab.hasMultiplePanes ? gap : 0)
        .onPreferenceChange(PaneFramePreferenceKey.self) { paneFrames = $0 }
        // A divider or pane-move drag can't deliver its ending callback once
        // toggling zoom unmounts its view — drop any in-flight drag state so a
        // stale snapshot never sticks around.
        .onChange(of: tab.isZoomed) {
            drag = nil
            dragColumns = nil
            paneDrag = nil
            dragThumbnail = nil
        }
    }

    private var grid: some View {
        GeometryReader { geo in
            let columns = dragColumns ?? tab.columns
            let availableWidth = max(0, geo.size.width - gap * CGFloat(max(0, columns.count - 1)))
            let widths = sizes(for: columns.map(\.weight), available: availableWidth)

            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(Array(columns.enumerated()), id: \.element.id) { columnIndex, column in
                        columnView(
                            column,
                            columnIndex: columnIndex,
                            width: widths[columnIndex],
                            height: geo.size.height
                        )
                        if columnIndex < columns.count - 1 {
                            ResizableDivider(orientation: .columns, thickness: gap) { translation in
                                resizeColumns(
                                    dividerAt: columnIndex,
                                    translation: translation,
                                    availableWidth: availableWidth
                                )
                            } onEnded: {
                                commitDrag()
                            }
                        }
                    }
                }

                // The carried pane's thumbnail, trailing the cursor. Positioned
                // in this grid's local space by subtracting its global origin
                // from the (global) pointer location.
                if let paneDrag {
                    let origin = geo.frame(in: .global).origin
                    let size = thumbnailFrame(for: paneDrag.sourceID)
                    dragThumbnailView(for: paneDrag.sourceID, size: size)
                        // Centered on the pointer, both axes.
                        .offset(
                            x: paneDrag.location.x - origin.x - size.width / 2,
                            y: paneDrag.location.y - origin.y - size.height / 2
                        )
                        .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    private func columnView(
        _ column: PaneColumn, columnIndex: Int, width: CGFloat, height: CGFloat
    ) -> some View {
        let availableHeight = max(0, height - gap * CGFloat(max(0, column.panes.count - 1)))
        let heights = sizes(for: column.panes.map(\.weight), available: availableHeight)

        VStack(spacing: 0) {
            ForEach(Array(column.panes.enumerated()), id: \.element.id) { paneIndex, pane in
                PaneView(
                    tab: tab,
                    pane: pane,
                    showFocusRing: tab.hasMultiplePanes,
                    allowsMove: true,
                    isMoveSource: paneDrag?.sourceID == pane.id,
                    dropEdge: paneDrag?.targetID == pane.id ? paneDrag?.edge : nil,
                    onMove: { updateDropTarget(source: pane.id, location: $0) },
                    onMoveEnded: { commitPaneMove() },
                    onSplit: onSplit
                )
                .frame(width: width, height: heights[paneIndex])
                if paneIndex < column.panes.count - 1 {
                    ResizableDivider(orientation: .rows, thickness: gap) { translation in
                        resizePanes(
                            columnIndex: columnIndex,
                            dividerAt: paneIndex,
                            translation: translation,
                            availableHeight: availableHeight
                        )
                    } onEnded: {
                        commitDrag()
                    }
                    .frame(width: width)
                }
            }
        }
        .frame(width: width, height: height)
    }

    /// Distributes `available` across items in proportion to their weights.
    private func sizes(for weights: [CGFloat], available: CGFloat) -> [CGFloat] {
        let total = weights.reduce(0, +)
        guard total > 0, !weights.isEmpty else {
            let each = weights.isEmpty ? 0 : available / CGFloat(weights.count)
            return weights.map { _ in each }
        }
        return weights.map { $0 / total * available }
    }

    // MARK: - Resizing

    private func resizeColumns(dividerAt index: Int, translation: CGFloat, availableWidth: CGFloat) {
        let baseline = baselineWeights(for: .columns, index: index) { tab.columns.map(\.weight) }
        guard availableWidth > 0, baseline.indices.contains(index + 1) else { return }
        let (left, right) = adjusted(baseline: baseline, at: index, translation: translation, available: availableWidth)
        var columns = tab.columns
        guard columns.indices.contains(index + 1) else { return }
        columns[index].weight = left
        columns[index + 1].weight = right
        dragColumns = columns
    }

    private func resizePanes(
        columnIndex: Int, dividerAt index: Int, translation: CGFloat, availableHeight: CGFloat
    ) {
        guard tab.columns.indices.contains(columnIndex) else { return }
        let columnID = tab.columns[columnIndex].id
        let baseline = baselineWeights(for: .rows(columnID: columnID), index: index) {
            tab.columns[columnIndex].panes.map(\.weight)
        }
        guard availableHeight > 0, baseline.indices.contains(index + 1) else { return }
        let (top, bottom) = adjusted(baseline: baseline, at: index, translation: translation, available: availableHeight)
        var columns = tab.columns
        guard columns.indices.contains(columnIndex),
              columns[columnIndex].panes.indices.contains(index + 1) else { return }
        columns[columnIndex].panes[index].weight = top
        columns[columnIndex].panes[index + 1].weight = bottom
        dragColumns = columns
    }

    /// Writes the in-flight weights back to the model once the drag ends —
    /// a single @Published update instead of one per frame.
    private func commitDrag() {
        if let dragColumns {
            tab.columns = dragColumns
        }
        dragColumns = nil
        drag = nil
    }

    // MARK: - Moving panes

    /// Tracks a pane-move drag: `location` is the pointer in global space. The
    /// drop target is whichever *other* pane's frame contains it (none over a
    /// gap), and the edge is which quadrant of that pane the pointer is in.
    /// Local @State, so only this grid re-renders per frame.
    private func updateDropTarget(source: UUID, location: CGPoint) {
        // First frame of the drag: grab the thumbnail once.
        if paneDrag == nil {
            dragThumbnail = thumbnail(for: source)
        }
        if let (targetID, frame) = paneFrames.first(where: { $0.key != source && $0.value.contains(location) }) {
            paneDrag = PaneMove(sourceID: source, location: location, targetID: targetID, edge: dropEdge(at: location, in: frame))
            NSCursor.closedHand.set()
        } else {
            paneDrag = PaneMove(sourceID: source, location: location, targetID: nil, edge: nil)
            NSCursor.operationNotAllowed.set()
        }
    }

    /// Commits a pane-move on release: splits the target on the chosen edge and
    /// drops the carried pane there.
    private func commitPaneMove() {
        if let paneDrag, let target = paneDrag.targetID, let edge = paneDrag.edge {
            tab.movePane(paneDrag.sourceID, edge, of: target)
        }
        paneDrag = nil
        dragThumbnail = nil
        // Clear the drag cursor; the next hover/move asserts the right one.
        NSCursor.arrow.set()
    }

    /// A snapshot of the carried pane's terminal (falls back to a labeled card
    /// for files), shown centered under the cursor while dragging. `size` is
    /// aspect-matched to the pane, so the whole pane scales down instead of
    /// being cropped.
    @ViewBuilder
    private func dragThumbnailView(for sourceID: UUID, size: CGSize) -> some View {
        let content = tab.allPanes.first { $0.id == sourceID }?.content
        Group {
            if let dragThumbnail {
                Image(nsImage: dragThumbnail)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else if let content {
                HStack(spacing: 6) {
                    Image(systemName: content.systemImage)
                    Text(content.title).lineLimit(1)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .frame(width: size.width, height: size.height, alignment: .center)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: Theme.background)))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color(nsColor: Theme.accent), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .opacity(0.9)
    }

    /// The thumbnail's on-screen size: the source pane's aspect ratio scaled to
    /// fit within `thumbnailMaxSize`.
    private func thumbnailFrame(for sourceID: UUID) -> CGSize {
        guard let frame = paneFrames[sourceID], frame.width > 0, frame.height > 0 else {
            return thumbnailMaxSize
        }
        let scale = min(thumbnailMaxSize.width / frame.width, thumbnailMaxSize.height / frame.height)
        return CGSize(width: frame.width * scale, height: frame.height * scale)
    }

    private func thumbnail(for sourceID: UUID) -> NSImage? {
        switch tab.allPanes.first(where: { $0.id == sourceID })?.content {
        case .session(let session):
            return session.surface.paneSnapshot()
        case .file(let file): return file.editorView?.paneSnapshot()
        default: return nil
        }
    }

    /// Which edge of `frame` the pointer is nearest — the target is cut into
    /// four triangular quadrants by its diagonals, the standard drop-zone
    /// scheme (VS Code, Ghostty).
    private func dropEdge(at location: CGPoint, in frame: CGRect) -> PaneDropEdge {
        let dx = (location.x - frame.midX) / max(frame.width, 1)
        let dy = (location.y - frame.midY) / max(frame.height, 1)
        if abs(dx) > abs(dy) {
            return dx < 0 ? .left : .right
        } else {
            return dy < 0 ? .top : .bottom
        }
    }

    /// Baseline weights captured at the start of a drag, so the cumulative
    /// gesture translation is always applied against a fixed starting point.
    private func baselineWeights(
        for kind: DragState.Kind, index: Int, current: () -> [CGFloat]
    ) -> [CGFloat] {
        if let drag, drag.kind == kind, drag.index == index {
            return drag.weights
        }
        let weights = current()
        drag = DragState(kind: kind, index: index, weights: weights)
        return weights
    }

    /// Splits `translation` (points) into new weights for the two tiles either
    /// side of the divider, keeping each at or above `minFraction`.
    private func adjusted(
        baseline: [CGFloat], at index: Int, translation: CGFloat, available: CGFloat
    ) -> (CGFloat, CGFloat) {
        let total = baseline.reduce(0, +)
        let minWeight = total * minFraction
        let delta = translation / available * total
        var first = baseline[index] + delta
        var second = baseline[index + 1] - delta
        if first < minWeight { second -= (minWeight - first); first = minWeight }
        if second < minWeight { first -= (minWeight - second); second = minWeight }
        return (first, second)
    }
}

/// Invisible drag strip in the gap between two tiles. Dragging shifts weight
/// between the neighbors; the cursor hints at the resize direction.
private struct ResizableDivider: View {
    enum Orientation { case columns, rows }

    let orientation: Orientation
    let thickness: CGFloat
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(
                width: orientation == .columns ? thickness : nil,
                height: orientation == .rows ? thickness : nil
            )
            .frame(
                maxWidth: orientation == .rows ? .infinity : nil,
                maxHeight: orientation == .columns ? .infinity : nil
            )
            .contentShape(Rectangle())
            // System pointer resolution rather than pushing onto the cursor
            // stack by hand — see SidebarResizeHandle for why the manual push
            // never showed up next to a file editor.
            .pointerStyle(orientation == .columns ? .columnResize : .rowResize)
            // Global coordinate space is essential: the divider itself shifts
            // as the panes resize, so a local-space translation would be
            // measured against a moving reference frame and oscillate (the
            // divider fights the cursor). Global translation tracks the actual
            // pointer movement regardless. Matches SidebarResizeHandle.
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        onChanged(orientation == .columns ? value.translation.width : value.translation.height)
                    }
                    .onEnded { _ in onEnded() }
            )
    }
}

/// One tile: hosts its content and, when the tab holds more than one pane,
/// draws a focus ring (accent for the focused pane, faint otherwise), a thin
/// top strip you can grab to move the pane onto another, and a highlight while
/// it's the drop target.
private struct PaneView: View {
    @ObservedObject var tab: PaneTab
    @ObservedObject private var themeChanges = Theme.changes
    let pane: Pane
    let showFocusRing: Bool
    /// Whether the top grab strip is offered at all — false while zoomed,
    /// where there is no other pane on screen to drop onto.
    let allowsMove: Bool
    /// The pane currently being carried by a move drag (dimmed).
    let isMoveSource: Bool
    /// When this pane is the drop target, the edge the carried pane will land
    /// on — drives the half-pane preview. Nil when it isn't the target.
    let dropEdge: PaneDropEdge?
    /// Reports the pointer (global space) as the top strip is dragged.
    let onMove: (CGPoint) -> Void
    let onMoveEnded: () -> Void
    /// Splits the focused pane on the given edge (from the content's context
    /// menu).
    let onSplit: (PaneDropEdge) -> Void

    /// Height of the grab strip at the pane's top.
    private let handleHeight: CGFloat = 8

    @State private var isHandleHovered = false
    @State private var isDragging = false

    private var isFocused: Bool { tab.focusedPaneID == pane.id }

    /// Marks this pane focused — invoked when its content takes first-responder
    /// status (a click). Idempotent when already focused.
    private func focus() {
        if tab.focusedPaneID != pane.id {
            tab.focusedPaneID = pane.id
        }
    }

    var body: some View {
        // Single-pane tabs render exactly as before splits existed — no ring,
        // no handle — so nothing about the common case changes.
        if showFocusRing {
            content
                // Deliberately no clip: masking an AppKit view forces an
                // offscreen recomposite that flickers on live resize. The
                // content background matches the surrounding gaps, so square
                // content corners blend in and only the rounded stroke reads.
                .overlay { focusRing }
                .overlay(alignment: .top) {
                    if allowsMove { moveHandle }
                }
                .overlay { dropHighlight }
                .opacity(isMoveSource ? 0.55 : 1)
                .background(frameReporter)
        } else {
            content
        }
    }

    /// Focuses this pane, then splits it — the context menu acts on the pane it
    /// was opened over, not whatever held focus before.
    private func splitFromMenu(_ edge: PaneDropEdge) {
        focus()
        onSplit(edge)
    }

    @ViewBuilder
    private var content: some View {
        switch pane.content {
        case .session(let session):
            TerminalHostView(session: session, isFocused: isFocused, onFocused: focus, onSplit: splitFromMenu)
                .background(Color(nsColor: Theme.background))
                .overlay(alignment: .topTrailing) {
                    TerminalFindOverlay(find: session.find)
                }
        case .file(let file):
            FileViewerView(file: file, isFocused: isFocused, onFocused: focus, onSplit: splitFromMenu)
                .background(Color(nsColor: Theme.background))
        case .diff:
            // Rendered by the always-mounted diff stack behind the layout; stay
            // transparent and non-interactive so clicks and scrolls reach it.
            Color.clear.allowsHitTesting(false)
        }
    }

    private var focusRing: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(
                isFocused
                    ? Color(nsColor: Theme.accent).opacity(0.85)
                    : Color.primary.opacity(0.06),
                lineWidth: isFocused ? 1.5 : 1
            )
    }

    /// Thin strip pinned to the pane's top edge — an absolutely-positioned grab
    /// handle over the content — that you drag to move this pane onto another.
    /// A grab bar fades in on hover so the zone is easy to find; the strip sits
    /// in the terminal's own top padding, so it doesn't cover text. Global
    /// coordinate space so the reported location survives the layout shifting.
    private var moveHandle: some View {
        Color.clear
            .frame(height: handleHeight)
            .frame(maxWidth: .infinity)
            .overlay {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .opacity(isHandleHovered ? 0.9 : 0)
            }
            .contentShape(Rectangle())
            // onContinuousHover (not onHover): re-assert the open hand on every
            // move so it wins against the terminal re-setting its own cursor.
            // On exit, reset explicitly — moving *up* off the handle lands in the
            // gap, which has no cursor management to revert it otherwise. Both
            // guarded by !isDragging so they never fight the drag cursor.
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isHandleHovered = true
                    if !isDragging { NSCursor.openHand.set() }
                case .ended:
                    isHandleHovered = false
                    if !isDragging { NSCursor.arrow.set() }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { value in
                        isDragging = true
                        onMove(value.location)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onMoveEnded()
                    }
            )
    }

    @ViewBuilder
    private var dropHighlight: some View {
        if let dropEdge {
            GeometryReader { geo in
                let rect = highlightRect(for: dropEdge, in: geo.size)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: Theme.accent).opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color(nsColor: Theme.accent), lineWidth: 2)
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
            .allowsHitTesting(false)
        }
    }

    /// The half of the pane that previews where the dragged pane will land.
    private func highlightRect(for edge: PaneDropEdge, in size: CGSize) -> CGRect {
        switch edge {
        case .left:   return CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .right:  return CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top:    return CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom: return CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        }
    }

    private var frameReporter: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: PaneFramePreferenceKey.self,
                value: [pane.id: proxy.frame(in: .global)]
            )
        }
    }
}

/// Mounts a session's find bar only while it is open, so a closed bar never
/// sits over the terminal swallowing clicks. Separate from `PaneView` so that
/// opening and closing it re-renders nothing but the overlay.
private struct TerminalFindOverlay: View {
    @ObservedObject var find: TerminalFind

    var body: some View {
        if find.isPresented {
            TerminalFindBar(find: find)
        }
    }
}

/// Collects each pane's global-space frame so a move drag can hit-test the
/// cursor against them.
private struct PaneFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension NSView {
    /// A bitmap of the view's current rendering, used as the drag thumbnail.
    func paneSnapshot() -> NSImage? {
        guard bounds.width > 0, bounds.height > 0,
              let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
