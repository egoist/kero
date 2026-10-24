//
//  SidebarResizeHandle.swift
//  kero
//

import AppKit
import SwiftUI

/// Invisible drag strip overlaid on a sidebar's inner edge. Dragging
/// resizes within `range`; double-click snaps back to `defaultWidth`.
struct SidebarResizeHandle: View {
    /// Edge of the sidebar this handle sits on: `.trailing` for the left
    /// sidebar, `.leading` for the right one (flips the drag direction).
    let edge: HorizontalEdge
    @Binding var width: Double
    let range: ClosedRange<Double>
    let defaultWidth: Double

    @State private var baseline: Double?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 7)
            .contentShape(Rectangle())
            // Not `NSCursor.columnResize.push()` from `onHover`, which looks
            // equivalent but loses: it pushes onto the shared cursor stack from
            // outside AppKit's own pointer resolution, and AppKit resets the
            // pointer as it leaves a registered cursor rect — which is what a
            // neighbouring editor is covered in (STTextView adds an I-beam rect
            // over its text). Coming off the text onto the handle, that reset
            // lands after the push and wins, so the handle dragged fine while
            // showing a plain arrow, giving no sign it was there.
            // `pointerStyle` registers through the same resolution instead.
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = baseline ?? width
                        baseline = base
                        let delta = edge == .trailing
                            ? value.translation.width
                            : -value.translation.width
                        width = min(max(base + delta, range.lowerBound), range.upperBound)
                        NSCursor.columnResize.set()
                    }
                    .onEnded { _ in baseline = nil }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { width = defaultWidth }
            )
    }
}
