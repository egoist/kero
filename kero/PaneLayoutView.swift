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

    /// Gap between tiles, which doubles as the divider hit area. The same
    /// value insets the whole grid from the parent, so the spacing around the
    /// panes matches the spacing between them.
    private let gap: CGFloat = 10
    /// Smallest share any single tile may be shrunk to.
    private let minFraction: CGFloat = 0.1

    @State private var drag: DragState?
    /// While a divider drag is in flight the new weights live here — local
    /// @State that re-renders only this grid — instead of in `tab.columns`,
    /// whose @Published change would re-render the whole window every frame.
    /// Committed back to the model once, on release.
    @State private var dragColumns: [PaneColumn]?

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
        GeometryReader { geo in
            let columns = dragColumns ?? tab.columns
            let availableWidth = max(0, geo.size.width - gap * CGFloat(max(0, columns.count - 1)))
            let widths = sizes(for: columns.map(\.weight), available: availableWidth)

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
        }
        // Inset the whole grid from the parent by the same gap used between
        // tiles, so a split tab has even breathing room on every side. A
        // single-pane tab stays full-bleed, exactly as before splits existed.
        .padding(tab.hasMultiplePanes ? gap : 0)
    }

    @ViewBuilder
    private func columnView(
        _ column: PaneColumn, columnIndex: Int, width: CGFloat, height: CGFloat
    ) -> some View {
        let availableHeight = max(0, height - gap * CGFloat(max(0, column.panes.count - 1)))
        let heights = sizes(for: column.panes.map(\.weight), available: availableHeight)

        VStack(spacing: 0) {
            ForEach(Array(column.panes.enumerated()), id: \.element.id) { paneIndex, pane in
                PaneView(tab: tab, pane: pane, showFocusRing: tab.hasMultiplePanes)
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
            .onHover { hovering in
                guard hovering else { NSCursor.pop(); return }
                (orientation == .columns ? NSCursor.columnResize : NSCursor.rowResize).push()
            }
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
/// draws a focus ring (accent for the focused pane, faint otherwise).
private struct PaneView: View {
    @ObservedObject var tab: PaneTab
    let pane: Pane
    let showFocusRing: Bool

    private var isFocused: Bool { tab.focusedPaneID == pane.id }

    /// Marks this pane focused — invoked when its content takes first-responder
    /// status (a click). Idempotent when already focused.
    private func focus() {
        if tab.focusedPaneID != pane.id {
            tab.focusedPaneID = pane.id
        }
    }

    var body: some View {
        // Single-pane tabs render exactly as before splits existed — no ring —
        // so nothing about the common case changes. For split tabs we draw a
        // rounded outline but deliberately do NOT clip the hosted terminal /
        // editor: masking an AppKit view forces an offscreen recomposite that
        // flickers on live resize. The content background is the same color as
        // the gaps around it, so the square content corners blend in and only
        // the rounded stroke reads.
        if showFocusRing {
            content
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isFocused
                                ? Color(nsColor: Theme.cursor).opacity(0.85)
                                : Color.primary.opacity(0.06),
                            lineWidth: isFocused ? 1.5 : 1
                        )
                }
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch pane.content {
        case .session(let session):
            TerminalHostView(session: session, isFocused: isFocused, onFocused: focus)
                .background(Color(nsColor: Theme.background))
        case .file(let file):
            FileViewerView(file: file, isFocused: isFocused, onFocused: focus)
                .background(Color(nsColor: Theme.background))
        case .diff:
            // Rendered by the always-mounted diff stack behind the layout; stay
            // transparent and non-interactive so clicks and scrolls reach it.
            Color.clear.allowsHitTesting(false)
        }
    }
}
