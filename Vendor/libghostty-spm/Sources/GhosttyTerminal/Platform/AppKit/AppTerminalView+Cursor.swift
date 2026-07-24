//
//  AppTerminalView+Cursor.swift
//  libghostty-spm
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit

    extension AppTerminalView {
        override open func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: mouseShape.cursor)
        }

        func applyMouseShape(_ shape: TerminalMouseShape) {
            guard shape != mouseShape else { return }
            mouseShape = shape
            // The pointer is usually already inside the view when ghostty
            // changes shape, so rebuild the rects and set the cursor now
            // instead of waiting for the next mouse entry.
            window?.invalidateCursorRects(for: self)
            shape.cursor.set()
        }
    }

    extension TerminalMouseShape {
        /// Closest AppKit cursor. macOS ships no public cursor for a handful of
        /// the CSS-style shapes (help, progress/wait, diagonal resizes), so
        /// those fall back to the arrow rather than reaching for private API.
        var cursor: NSCursor {
            switch self {
            case .text: .iBeam
            case .verticalText: .iBeamCursorForVerticalLayout
            case .pointer: .pointingHand
            case .contextMenu: .contextualMenu
            case .cell, .crosshair: .crosshair
            case .alias: .dragLink
            case .copy: .dragCopy
            case .noDrop, .notAllowed: .operationNotAllowed
            case .grab, .allScroll: .openHand
            case .grabbing, .move: .closedHand
            case .colResize, .eResize, .wResize, .ewResize: .resizeLeftRight
            case .rowResize, .nResize, .sResize, .nsResize: .resizeUpDown
            default: .arrow
            }
        }
    }
#endif
