//
//  SourceTextEditor.swift
//  kero
//

import AppKit
import STPluginNeon
import STTextView
import SwiftUI

/// Scroll offset and cursor position of a file tab's editor, kept on the
/// `FileTab` so it survives tab switches, and in the session snapshot so it
/// survives relaunches. Every field is optional so decoding tolerates
/// snapshots written by earlier editor stacks.
struct EditorState: Codable, Equatable {
    var selectionLocation: Int?
    var selectionLength: Int?
    var scrollX: Double?
    var scrollY: Double?
}

/// Editor colors matching the app's GitHub Light / GitHub Dark theme
/// (`Theme.background` is the same hex, so the editor blends into the
/// window). Selection color is not included: STTextView always uses the
/// system selection color.
struct EditorPalette: Equatable {
    var text: NSColor
    var background: NSColor
    var insertionPoint: NSColor
    var lineHighlight: NSColor
    var gutterText: NSColor

    static func github(dark: Bool) -> EditorPalette {
        dark
            ? EditorPalette(
                text: color(0xe6edf3),
                background: color(0x0d1117),
                insertionPoint: color(0x58a6ff),
                lineHighlight: color(0x161b22),
                gutterText: color(0x484f58)
            )
            : EditorPalette(
                text: color(0x1f2328),
                background: color(0xffffff),
                insertionPoint: color(0x0969da),
                lineHighlight: color(0xf6f8fa),
                gutterText: color(0xafb8c1)
            )
    }

    private static func color(_ hex: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255.0,
            green: CGFloat((hex >> 8) & 0xff) / 255.0,
            blue: CGFloat(hex & 0xff) / 255.0,
            alpha: 1
        )
    }
}

/// STTextView wrapped for SwiftUI: plain-text editing with line numbers and
/// the system find bar (⌘F via the Edit ▸ Find menu). Text edits are written
/// straight back to `FileTab.text`; scroll/cursor state is written back to
/// `FileTab.editorState` as it changes and restored when the view is
/// recreated on tab switch or relaunch.
struct SourceTextEditor: NSViewRepresentable {
    let file: FileTab
    let font: NSFont
    let palette: EditorPalette
    let wrapLines: Bool
    var isFocused: Bool = true
    var onFocused: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(file: file)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = RestorableScrollView()
        let textView = FocusReportingTextView()
        textView.onBecomeFirstResponder = onFocused
        scrollView.wantsLayer = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = textView

        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        // The window uses a full-size content view, so automatic insets
        // would add a titlebar-height top inset that misaligns the gutter
        // numbers against the text by one line.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        // The gutter is a document-height floating subview that scrolls
        // vertically with the text; since macOS 14 NSViews no longer clip
        // subviews by default, so without this the scrolled-away line
        // numbers draw outside the scroll view, over the header above it.
        scrollView.clipsToBounds = true

        // Configure typography before setting the text: the font/color
        // setters restyle the whole document, and restyling after layout
        // used to leave stale layout fragments that broke gutter numbering.
        textView.showsLineNumbers = true
        textView.highlightSelectedLine = true
        apply(to: textView, scrollView: scrollView)
        textView.text = file.text

        // Tree-sitter syntax highlighting (STPluginNeon), for file types with
        // a bundled grammar. Added after the text is set so the plugin's
        // initial full-document parse — which runs when the view lands in a
        // window — sees the whole document. The plugin only layers foreground
        // colors as rendering attributes; the font stays kero's (see
        // SyntaxHighlighting.theme).
        if let plugin = SyntaxHighlighting.plugin(for: file.path) {
            textView.addPlugin(plugin)
        }

        // Captured before the coordinator attaches, because its scroll
        // observer starts overwriting `editorState` immediately.
        let state = file.editorState
        if let location = state.selectionLocation {
            let limit = (textView.text ?? "").utf16.count
            let start = min(max(0, location), limit)
            let length = min(max(0, state.selectionLength ?? 0), limit - start)
            textView.textSelection = NSRange(location: start, length: length)
        }

        context.coordinator.attach(textView: textView, scrollView: scrollView)

        // Restore the saved scroll offset during the first layout pass — while
        // the frame is finally known but before the first paint — so the file
        // opens already at its saved position. Doing this asynchronously (after
        // the initial paint at the top) makes the editor visibly scroll into
        // place and flashes the auto-hiding scroller.
        if state.scrollX != nil || state.scrollY != nil {
            scrollView.restoreOnFirstLayout = { [weak scrollView, weak textView] in
                guard let scrollView, let textView else { return }
                let clipView = scrollView.contentView
                // setBoundsOrigin (not scroll(to:)) avoids clamping against a
                // content height that TextKit2 has only estimated so far.
                clipView.setBoundsOrigin(NSPoint(x: state.scrollX ?? 0, y: state.scrollY ?? 0))
                scrollView.reflectScrolledClipView(clipView)
                // Lay out the viewport around the restored offset in this same
                // pass so the region is painted in place, not after a scroll.
                textView.needsLayout = true
            }
        }

        // Only grab focus on mount when this pane is the focused one, so an
        // unfocused split doesn't steal the caret.
        if isFocused {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
        context.coordinator.wasFocused = isFocused
        // Expose the view so a pane-move drag can snapshot it as a thumbnail.
        file.editorView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? STTextView else { return }
        (textView as? FocusReportingTextView)?.onBecomeFirstResponder = onFocused
        apply(to: textView, scrollView: scrollView)
        // Take focus on the unfocused→focused edge (keyboard navigation moving
        // focus here), never on every render.
        if isFocused, !context.coordinator.wasFocused {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
        context.coordinator.wasFocused = isFocused
    }

    /// Take exactly the space SwiftUI offers. Without this, SwiftUI sizes the
    /// editor from the scroll view's `fittingSize`, which STTextView derives
    /// from the entire document — enormous for a large file, and degenerate
    /// for an empty one. Because the main window tracks its content's ideal
    /// size, that runaway measurement drives the window size and drops it into
    /// an unbounded layout loop (a hard crash: "more Layout Window passes than
    /// there are views"). Reporting the proposed size keeps the editor a
    /// space-filling pane that never influences the window's size.
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSScrollView, context: Context
    ) -> CGSize? {
        func resolve(_ value: CGFloat?, fallback: CGFloat) -> CGFloat {
            guard let value, value.isFinite else { return fallback }
            return value
        }
        return CGSize(
            width: resolve(proposal.width, fallback: nsView.frame.width),
            height: resolve(proposal.height, fallback: nsView.frame.height)
        )
    }

    /// Guarded assignments: the font/color setters restyle the whole
    /// document, and this runs on every SwiftUI render.
    private func apply(to textView: STTextView, scrollView: NSScrollView) {
        if textView.font != font {
            textView.font = font
        }
        if textView.textColor != palette.text {
            textView.textColor = palette.text
        }
        if textView.backgroundColor != palette.background {
            textView.backgroundColor = palette.background
            scrollView.backgroundColor = palette.background
        }
        textView.insertionPointColor = palette.insertionPoint
        textView.selectedLineHighlightColor = palette.lineHighlight
        // false = wrap at the view width, true = expand horizontally.
        textView.isHorizontallyResizable = !wrapLines
        if let gutter = textView.gutterView {
            gutter.textColor = palette.gutterText
            gutter.selectedLineTextColor = palette.text
        }
    }

    @MainActor
    final class Coordinator: NSObject, STTextViewDelegate {
        private let file: FileTab
        private weak var textView: STTextView?
        private var scrollObserver: (any NSObjectProtocol)?
        /// Last-applied focus state, so `updateNSView` can act only on the
        /// unfocused→focused edge.
        var wasFocused = false

        init(file: FileTab) {
            self.file = file
        }

        func attach(textView: STTextView, scrollView: NSScrollView) {
            self.textView = textView
            textView.textDelegate = self
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                MainActor.assumeIsolated {
                    guard let self, let clipView = scrollView?.contentView else { return }
                    self.file.editorState.scrollX = clipView.bounds.origin.x
                    self.file.editorState.scrollY = clipView.bounds.origin.y
                }
            }
        }

        deinit {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }

        func textViewDidChangeText(_ notification: Notification) {
            guard let textView else { return }
            let newText = textView.text ?? ""
            guard newText != file.text else { return }
            file.text = newText
            file.refreshDirtyState()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            let selection = textView.textSelection
            file.editorState.selectionLocation = selection.location
            file.editorState.selectionLength = selection.length
        }
    }
}

/// STTextView that reports when it takes first-responder status (a click, or a
/// programmatic focus), so the owning pane can mark itself focused in the model.
final class FocusReportingTextView: STTextView {
    var onBecomeFirstResponder: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onBecomeFirstResponder?() }
        return became
    }
}

/// NSScrollView that runs a one-shot restoration during its first real layout
/// pass — before the first paint — so a restored file opens already scrolled to
/// its saved position instead of visibly jumping there afterward.
private final class RestorableScrollView: NSScrollView {
    var restoreOnFirstLayout: (() -> Void)?
    private var lastViewportSize: NSSize = .zero
    private var geometryUpdateScheduled = false

    override func layout() {
        super.layout()
        let viewportSize = contentView.bounds.size
        if viewportSize != lastViewportSize {
            lastViewportSize = viewportSize
            scheduleEditorGeometryUpdate()
        }
        if bounds.width > 0, bounds.height > 0, let restore = restoreOnFirstLayout {
            restoreOnFirstLayout = nil
            restore()
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        scheduleEditorGeometryUpdate()
    }

    /// STTextView's document view can inherit the viewport's width while the
    /// window is resizing. Re-run its content sizing after AppKit finishes the
    /// scroll-view layout, then clamp the old offset to the new scroll range
    /// and refresh the scroller thumb/proportion.
    private func scheduleEditorGeometryUpdate() {
        guard !geometryUpdateScheduled else { return }
        geometryUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.geometryUpdateScheduled = false
            guard let textView = self.documentView as? STTextView else { return }

            textView.needsLayout = true
            textView.layoutSubtreeIfNeeded()

            let clipView = self.contentView
            let constrainedBounds = clipView.constrainBoundsRect(clipView.bounds)
            if constrainedBounds.origin != clipView.bounds.origin {
                clipView.setBoundsOrigin(constrainedBounds.origin)
            }
            self.reflectScrolledClipView(clipView)
        }
    }
}
