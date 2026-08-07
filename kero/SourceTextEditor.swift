//
//  SourceTextEditor.swift
//  kero
//

import AppKit
import STPluginNeon
import STTextView

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

/// Editor colors derived from the selected ghostty theme (`Theme.background`
/// is the same color, so the editor blends into the window). Selection color
/// is not included: STTextView always uses the system selection color.
struct EditorPalette: Equatable {
    var text: NSColor
    var background: NSColor
    var insertionPoint: NSColor
    var lineHighlight: NSColor
    var gutterText: NSColor

    static func theme(dark: Bool) -> EditorPalette {
        let theme = Theme.terminal(dark: dark)
        return EditorPalette(
            text: theme.foregroundNSColor,
            background: theme.backgroundNSColor,
            insertionPoint: theme.accentNSColor,
            lineHighlight: theme.surfaceNSColor(elevation: 0.04),
            gutterText: theme.surfaceNSColor(elevation: 0.3)
        )
    }
}

/// STTextView driven directly from AppKit: plain-text editing with line
/// numbers and the system search-and-replace find bar (⌘F / ⌥⌘F via the Edit ▸
/// Find menu, routed here by `FileTab.performFindAction`). Text edits are
/// written straight back to `FileTab.text`; scroll/cursor state is written back
/// to `FileTab.editorState` as it changes and restored when the editor is
/// rebuilt on tab switch or relaunch.
///
/// Owned by `FileViewerContainerView`, which mounts and discards it as the tab
/// switches between source and rendered markdown.
@MainActor
final class SourceEditorController: NSObject, STTextViewDelegate {
    /// The editor's scroll view, for the container to install.
    let scrollView: NSScrollView

    private let file: FileTab
    private weak var textView: STTextView?
    private var scrollObserver: (any NSObjectProtocol)?
    /// Last-applied focus state, so `update` acts only on the unfocused→focused
    /// edge rather than stealing the caret on every settings change.
    private var wasFocused = false

    init(
        file: FileTab,
        font: NSFont,
        palette: EditorPalette,
        wrapLines: Bool,
        isFocused: Bool,
        onFocused: @escaping () -> Void,
        onSplit: @escaping (PaneDropEdge) -> Void
    ) {
        self.file = file
        let scrollView = RestorableScrollView()
        self.scrollView = scrollView
        super.init()

        let textView = FocusReportingTextView()
        self.textView = textView
        textView.onBecomeFirstResponder = onFocused
        textView.splitTarget.onSplit = onSplit
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
        // Highlight every match as the query is typed in the find bar, the way
        // the terminal's find bar searches as you type. Off by default in
        // STTextView.
        textView.isIncrementalSearchingEnabled = true
        apply(font: font, palette: palette, wrapLines: wrapLines)
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

        // Captured before the scroll observer attaches, because it starts
        // overwriting `editorState` immediately.
        let state = file.editorState
        if let location = state.selectionLocation {
            let limit = (textView.text ?? "").utf16.count
            let start = min(max(0, location), limit)
            let length = min(max(0, state.selectionLength ?? 0), limit - start)
            textView.textSelection = NSRange(location: start, length: length)
        }

        attach(textView: textView, scrollView: scrollView)

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
        wasFocused = isFocused
        // Expose the view so a pane-move drag can snapshot it as a thumbnail,
        // and so Find menu actions can reach the text view.
        file.editorView = scrollView
    }

    deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
    }

    func update(
        font: NSFont,
        palette: EditorPalette,
        wrapLines: Bool,
        isFocused: Bool,
        onFocused: @escaping () -> Void,
        onSplit: @escaping (PaneDropEdge) -> Void
    ) {
        guard let textView = textView as? FocusReportingTextView else { return }
        textView.onBecomeFirstResponder = onFocused
        textView.splitTarget.onSplit = onSplit
        apply(font: font, palette: palette, wrapLines: wrapLines)
        // Take focus on the unfocused→focused edge (keyboard navigation moving
        // focus here), never on every update.
        if isFocused, !wasFocused {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
        wasFocused = isFocused
    }

    func takeFocus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    /// Guarded assignments: the font/color setters restyle the whole document,
    /// and this runs on every settings or appearance change.
    private func apply(font: NSFont, palette: EditorPalette, wrapLines: Bool) {
        guard let textView else { return }
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

    private func attach(textView: STTextView, scrollView: NSScrollView) {
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

/// STTextView that reports when it takes first-responder status (a click, or a
/// programmatic focus), so the owning pane can mark itself focused in the model,
/// and appends pane-split items to its context menu.
final class FocusReportingTextView: STTextView {
    var onBecomeFirstResponder: (() -> Void)?
    /// Owns the split context-menu items, kept off the text view so its own
    /// menu validation doesn't disable them.
    let splitTarget = SplitMenuTarget()

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onBecomeFirstResponder?() }
        return became
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menu.addItem(.separator())
        for item in splitTarget.menuItems() { menu.addItem(item) }
        return menu
    }
}

/// NSScrollView that runs a one-shot restoration during its first real layout
/// pass — before the first paint — so a restored file opens already scrolled to
/// its saved position instead of visibly jumping there afterward.
private final class RestorableScrollView: NSScrollView {
    var restoreOnFirstLayout: (() -> Void)?
    private var lastViewportSize: NSSize = .zero
    private var geometryUpdateScheduled = false

    /// Temporary: set KERO_SCROLLER_DEBUG=1 to trace scroller geometry.
    private func logScroller(_ tag: String) {
        guard ProcessInfo.processInfo.environment["KERO_SCROLLER_DEBUG"] != nil else { return }
        guard let scroller = verticalScroller else { print("[scroller] \(tag) none"); return }
        let scrollerInWindow = scroller.convert(scroller.bounds, to: nil)
        let selfInWindow = convert(bounds, to: nil)
        print("""
        [scroller] \(tag) \
        sv.w=\(Int(bounds.width)) sv.inWindow.x=\(Int(selfInWindow.minX))..\(Int(selfInWindow.maxX)) \
        clip.w=\(Int(contentView.bounds.width)) doc.w=\(Int(documentView?.frame.width ?? -1)) \
        scroller.frame=\(Int(scroller.frame.minX)),w=\(Int(scroller.frame.width)) \
        scroller.inWindow.x=\(Int(scrollerInWindow.minX)) hidden=\(scroller.isHidden) \
        super=\(scroller.superview.map { String(describing: type(of: $0)) } ?? "nil")
        """)
    }

    override func layout() {
        super.layout()
        let viewportSize = contentView.bounds.size
        if viewportSize != lastViewportSize {
            lastViewportSize = viewportSize
            scheduleEditorGeometryUpdate()
        }
        logScroller("layout")
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

            // Re-place the scrollers against the new width. An overlay scroller
            // that was faded out when the viewport changed keeps the frame it
            // had, so it comes back at the editor's *old* trailing edge — most
            // visibly after ⇧⌘B closes the right panel, where it reappears
            // mid-document with text running past it.
            self.tile()

            let clipView = self.contentView
            let constrainedBounds = clipView.constrainBoundsRect(clipView.bounds)
            if constrainedBounds.origin != clipView.bounds.origin {
                clipView.setBoundsOrigin(constrainedBounds.origin)
            }
            self.reflectScrolledClipView(clipView)
        }
    }
}
