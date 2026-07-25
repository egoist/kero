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
    @EnvironmentObject private var dragging: PaneDragCoordinator
    /// Splits the focused pane on the given edge — from a pane's context menu.
    var onSplit: (PaneDropEdge) -> Void = { _ in }
    /// Lifts a pane out into a tab of its own, at the given index in the strip
    /// (appended next to this tab when nil).
    var onExtractPane: (UUID, Int?) -> Void = { _, _ in }
    /// Closes one pane's content, with the project's save prompts.
    var onCloseContent: (PaneContent) -> Void = { _ in }
    /// The order tabs appear in the strip, so a pane dropped there can be given
    /// an insertion index.
    var tabOrder: [UUID] = []

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
                    showChrome: true,
                    allowsMove: false,
                    isMoveSource: false,
                    dropEdge: nil,
                    onMove: { _ in },
                    onMoveEnded: {},
                    onSplit: onSplit,
                    onExtract: {},
                    onClose: { onCloseContent(pane.content) }
                )
            } else {
                grid
            }
        }
        // Inset the whole grid from the parent by the same gap used between
        // tiles, so a split tab has even breathing room on every side. A
        // single-pane tab stays full-bleed, exactly as before splits existed.
        .padding(tab.hasMultiplePanes ? gap : 0)
        .onPreferenceChange(PaneFramePreferenceKey.self) { frames in
            dragging.paneFrames = frames
        }
        // A divider or pane-move drag can't deliver its ending callback once
        // toggling zoom unmounts its view — drop any in-flight drag state so a
        // stale snapshot never sticks around.
        .onChange(of: tab.isZoomed) {
            drag = nil
            dragColumns = nil
            dragging.clear()
            dragThumbnail = nil
        }
        .onDisappear {
            // Switching tabs mid-drag unmounts this layout, and no ending
            // callback arrives — drop the drag rather than leave it in flight.
            // The frames themselves are left alone: the incoming layout's
            // preference values replace them on the same pass, and clearing
            // here would race that and blank them.
            dragging.clear()
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
                if let paneDrag = dragging.paneDrag {
                    let origin = geo.frame(in: .global).origin
                    let size = thumbnailFrame(for: paneDrag.paneID)
                    dragThumbnailView(
                        for: paneDrag.paneID, size: size, isOverStrip: paneDrag.isOverStrip
                    )
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
                    showChrome: tab.hasMultiplePanes,
                    allowsMove: true,
                    isMoveSource: dragging.paneDrag?.paneID == pane.id,
                    dropEdge: dragging.dropEdge(previewedOn: pane.id),
                    onMove: { updateDropTarget(source: pane.id, location: $0) },
                    onMoveEnded: { commitPaneMove() },
                    onSplit: onSplit,
                    onExtract: { onExtractPane(pane.id, nil) },
                    onClose: { onCloseContent(pane.content) }
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
    /// pane can land in two places, so they are resolved in priority order —
    /// the tab strip first (drop it there and it leaves this layout for a tab
    /// of its own), then whichever *other* pane's frame contains the pointer,
    /// with the edge decided by the quadrant. Over neither, there's no drop.
    private func updateDropTarget(source: UUID, location: CGPoint) {
        // First frame of the drag: grab the thumbnail once.
        if dragging.paneDrag == nil {
            dragThumbnail = thumbnail(for: source)
        }
        var move = PaneDragCoordinator.PaneDrag(paneID: source, location: location)
        // Extracting needs a pane to leave behind; a lone pane is already its
        // own tab, so the strip isn't offered as a target for it.
        if tab.hasMultiplePanes,
           let index = dragging.tabInsertionIndex(at: location, in: tabOrder) {
            move.tabDropIndex = index
            NSCursor.closedHand.set()
        } else if let target = dragging.pane(at: location, excluding: source) {
            move.targetPaneID = target.id
            move.edge = dragging.dropEdge(at: location, in: target.frame)
            NSCursor.closedHand.set()
        } else {
            NSCursor.operationNotAllowed.set()
        }
        dragging.paneDrag = move
    }

    /// Commits a pane-move on release: out to the tab strip as a new tab, or
    /// onto the chosen edge of another pane in this layout.
    private func commitPaneMove() {
        if let move = dragging.paneDrag {
            if let index = move.tabDropIndex {
                onExtractPane(move.paneID, index)
            } else if let target = move.targetPaneID, let edge = move.edge {
                tab.movePane(move.paneID, edge, of: target)
            }
        }
        dragging.paneDrag = nil
        dragThumbnail = nil
        // Clear the drag cursor; the next hover/move asserts the right one.
        NSCursor.arrow.set()
    }

    /// A snapshot of the carried pane's terminal (falls back to a labeled card
    /// for files), shown centered under the cursor while dragging. `size` is
    /// aspect-matched to the pane, so the whole pane scales down instead of
    /// being cropped. Over the tab strip it shrinks to a tab-sized chip, so the
    /// thumbnail itself previews what the drop produces.
    @ViewBuilder
    private func dragThumbnailView(
        for sourceID: UUID, size: CGSize, isOverStrip: Bool
    ) -> some View {
        let pane = tab.allPanes.first { $0.id == sourceID }
        Group {
            if isOverStrip, let pane {
                HStack(spacing: 5) {
                    Image(systemName: pane.content.systemImage)
                        .font(.system(size: 9, weight: .medium))
                    Text(pane.displayTitle)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: Theme.background))
                )
            } else if let dragThumbnail {
                Image(nsImage: dragThumbnail)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else if let pane {
                HStack(spacing: 6) {
                    Image(systemName: pane.content.systemImage)
                    Text(pane.displayTitle).lineLimit(1)
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
        guard let frame = dragging.paneFrames[sourceID], frame.width > 0, frame.height > 0 else {
            return thumbnailMaxSize
        }
        let scale = min(thumbnailMaxSize.width / frame.width, thumbnailMaxSize.height / frame.height)
        return CGSize(width: frame.width * scale, height: frame.height * scale)
    }

    private func thumbnail(for sourceID: UUID) -> NSImage? {
        switch tab.allPanes.first(where: { $0.id == sourceID })?.content {
        case .session(let session):
            return session.terminalView.paneSnapshot()
        case .file(let file): return file.editorView?.paneSnapshot()
        default: return nil
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
/// draws a focus ring (accent for the focused pane, faint otherwise), a header
/// strip carrying the pane's title that you can grab to move it, and a
/// highlight while it's the drop target.
private struct PaneView: View {
    @ObservedObject var tab: PaneTab
    @ObservedObject private var themeChanges = Theme.changes
    let pane: Pane
    /// Whether pane chrome — ring and header — is shown at all. False for a
    /// single-pane tab, which is indistinguishable from a pre-splits tab and
    /// whose title and rename already live in the tab strip.
    let showChrome: Bool
    /// Whether the header may be dragged — false while zoomed, where there is
    /// no other pane on screen to drop onto.
    let allowsMove: Bool
    /// The pane currently being carried by a move drag (dimmed).
    let isMoveSource: Bool
    /// When this pane is the drop target, the edge the carried pane or tab will
    /// land on — drives the half-pane preview. Nil when it isn't the target.
    let dropEdge: PaneDropEdge?
    /// Reports the pointer (global space) as the header is dragged.
    let onMove: (CGPoint) -> Void
    let onMoveEnded: () -> Void
    /// Splits the focused pane on the given edge (from the context menu).
    let onSplit: (PaneDropEdge) -> Void
    /// Lifts this pane out into a tab of its own.
    let onExtract: () -> Void
    /// Closes this pane.
    let onClose: () -> Void

    /// Height of the header strip at the pane's top. Tall enough to read a
    /// title in and to hit without aiming.
    private let headerHeight: CGFloat = 18

    @State private var isHeaderHovered = false
    @State private var isDragging = false
    @State private var isRenaming = false

    private var isFocused: Bool { tab.focusedPaneID == pane.id }

    /// A named pane keeps its header on screen permanently, so the name is
    /// always readable; an unnamed one only reveals it on hover.
    private var isPinned: Bool { pane.customName?.isEmpty == false }

    /// Marks this pane focused — invoked when its content takes first-responder
    /// status (a click). Idempotent when already focused.
    private func focus() {
        if tab.focusedPaneID != pane.id {
            tab.focusedPaneID = pane.id
        }
    }

    var body: some View {
        // Single-pane tabs render exactly as before splits existed — no ring,
        // no header — so nothing about the common case changes.
        Group {
            if showChrome, isPinned || isRenaming {
                // A pinned header takes its own row: it must never sit over the
                // terminal, where it would cover the top line of output.
                VStack(spacing: 0) {
                    header
                    content
                }
            } else if showChrome {
                // Unpinned, the header is an overlay in the terminal's own top
                // padding — invisible until hovered, so it costs no space.
                content.overlay(alignment: .top) {
                    if allowsMove || isPinned { header }
                }
            } else {
                content
            }
        }
        // Deliberately no clip: masking an AppKit view forces an offscreen
        // recomposite that flickers on live resize. The content background
        // matches the surrounding gaps, so square content corners blend in and
        // only the rounded stroke reads.
        .overlay { if showChrome { focusRing } }
        .overlay { dropHighlight }
        .opacity(isMoveSource ? 0.55 : 1)
        // Reported even without chrome: a single-pane tab is still a legitimate
        // target for a tab dragged onto it.
        .background(frameReporter)
    }

    /// Focuses this pane, then acts — the context menu acts on the pane it was
    /// opened over, not whatever held focus before.
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

    /// Strip across the pane's top edge showing its title, which doubles as the
    /// grab handle for moving the pane and as the target for its context menu.
    /// While the pane is unnamed it fades in on hover and sits over the
    /// terminal's own top padding, so it costs no space and covers no text;
    /// once named it is laid out above the content instead.
    private var header: some View {
        HStack(spacing: 5) {
            if isRenaming {
                PaneRenameField(
                    initialValue: pane.customName ?? pane.content.title,
                    commit: { tab.renamePane(pane.id, to: $0) },
                    end: { isRenaming = false }
                )
            } else {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                Text(pane.displayTitle)
                    .font(.system(size: 10.5, weight: isPinned ? .medium : .regular))
                    .foregroundStyle(isPinned ? .secondary : .tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: headerHeight)
        .frame(maxWidth: .infinity)
        .background(headerBackground)
        // The whole strip is grabbable, not just the text.
        .contentShape(Rectangle())
        // Visible only when it has something to say: a pinned name, a hover, or
        // an in-flight rename. The shape stays hit-testable either way, so the
        // invisible strip is still a grab handle exactly as it was at 8pt.
        .opacity(isPinned || isHeaderHovered || isRenaming ? 1 : 0)
        // onContinuousHover (not onHover): re-assert the open hand on every
        // move so it wins against the terminal re-setting its own cursor.
        // On exit, reset explicitly — moving *up* off the header lands in the
        // gap, which has no cursor management to revert it otherwise. Both
        // guarded by !isDragging so they never fight the drag cursor.
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isHeaderHovered = true
                if !isDragging, !isRenaming { NSCursor.openHand.set() }
            case .ended:
                isHeaderHovered = false
                if !isDragging, !isRenaming { NSCursor.arrow.set() }
            }
        }
        .contextMenu { headerMenu }
        // Masked to .subviews while renaming so dragging in the text field
        // selects text instead of carrying the pane off.
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { value in
                    guard allowsMove else { return }
                    isDragging = true
                    onMove(value.location)
                }
                .onEnded { _ in
                    guard allowsMove else { return }
                    isDragging = false
                    onMoveEnded()
                },
            including: isRenaming ? .subviews : .all
        )
    }

    @ViewBuilder
    private var headerBackground: some View {
        if isPinned || isHeaderHovered || isRenaming {
            Rectangle().fill(Color.primary.opacity(isPinned ? 0.05 : 0.08))
        }
    }

    @ViewBuilder
    private var headerMenu: some View {
        Button("Rename…") {
            focus()
            isRenaming = true
        }
        if isPinned {
            Button("Use Automatic Title") { tab.renamePane(pane.id, to: nil) }
        }
        Divider()
        Button("Move to New Tab", action: onExtract)
            .disabled(!tab.hasMultiplePanes)
        Divider()
        Button("Split Right") { splitFromMenu(.right) }
        Button("Split Down") { splitFromMenu(.bottom) }
        Divider()
        Button("Close Pane", action: onClose)
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

/// Inline editor shown in the pane header while it's renamed — the same
/// affordance as the tab strip's rename. Commits on Return or focus loss,
/// cancels on Escape; an empty name returns the pane to its automatic title.
private struct PaneRenameField: View {
    let commit: (String?) -> Void
    let end: () -> Void

    @State private var draft: String
    /// Set by the first commit/cancel so the focus-loss handler that fires
    /// while the field is being torn down doesn't commit a second time.
    @State private var finished = false
    @FocusState private var focused: Bool

    init(initialValue: String, commit: @escaping (String?) -> Void, end: @escaping () -> Void) {
        self.commit = commit
        self.end = end
        _draft = State(initialValue: initialValue)
    }

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 10.5))
            .focused($focused)
            .onSubmit { finish(apply: true) }
            .onExitCommand { finish(apply: false) }
            .onChange(of: focused) {
                if !focused { finish(apply: true) }
            }
            .onAppear {
                DispatchQueue.main.async { focused = true }
            }
    }

    private func finish(apply: Bool) {
        guard !finished else { return }
        finished = true
        if apply { commit(draft) }
        end()
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
