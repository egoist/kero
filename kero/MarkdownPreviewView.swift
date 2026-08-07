//
//  MarkdownPreviewView.swift
//  kero
//

import AppKit

/// The rendered half of a markdown file tab: a read-only text view showing the
/// document as formatted content, with the source one click away on the mode
/// chip.
///
/// Deliberately TextKit 1. `MarkdownRenderer` expresses blockquote bars, code
/// backgrounds and GFM tables as `NSTextBlock`/`NSTextTable`, which TextKit 2
/// does not lay out at all. The editor beside it stays TextKit 2 (STTextView) —
/// only the preview drops back, and only because a preview is a short,
/// read-only, immutable document where TextKit 2's incremental editing wins
/// buy nothing.
///
/// Re-rendering is whole-document rather than incremental: markdown files are
/// small, and a full re-render keeps image arrival, grammar compilation,
/// appearance changes and width changes on one obvious path.
@MainActor
final class MarkdownPreviewView: NSView {
    private let file: FileTab
    private let scrollView = NSScrollView()
    private let textView: PreviewTextView
    private let images = MarkdownImageLoader()

    /// Text width the current render was laid out for. A resize past this
    /// re-renders, because image scaling and table columns depend on it.
    private var renderedWidth: CGFloat = 0
    /// Source the current render was built from, so a re-render triggered by an
    /// unrelated event (an image arriving) can skip re-parsing unchanged text.
    private var renderedSource: String?
    private var renderedDark: Bool?
    private var renderScheduled = false

    var onFocused: (() -> Void)?
    var onSplit: ((PaneDropEdge) -> Void)? {
        didSet { textView.splitTarget.onSplit = onSplit }
    }

    private static let contentInset = NSSize(width: 26, height: 22)

    init(file: FileTab) {
        self.file = file

        // TextKit 1 stack, built explicitly: a programmatically created
        // NSTextView is TextKit 2 by default, and text blocks would silently
        // not draw.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        textView = PreviewTextView(frame: .zero, textContainer: container)

        super.init(frame: .zero)

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.textContainerInset = Self.contentInset
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // A document view grows vertically with its text and tracks the scroll
        // view's width; without an unbounded max size it would stop laying out
        // past its initial frame height.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        // Same find bar the editor gets, so ⌘F works in both modes.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.onBecomeFirstResponder = { [weak self] in self?.onFocused?() }

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        // Matches the editor: the window uses a full-size content view, so
        // automatic insets would push the content down by a titlebar height.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // The source is unchanged when an image lands, so the render guard has
        // to be cleared explicitly or the new bytes would never be drawn.
        images.onLoad = { [weak self] in
            self?.renderedSource = nil
            self?.setNeedsRender()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(grammarBecameReady),
            name: MarkdownCodeHighlighter.grammarReadyNotification,
            object: nil
        )
        applyColors()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// A fence's grammar finished compiling, so the document can be drawn again
    /// with that block colored.
    @objc private func grammarBecameReady() {
        renderedSource = nil
        setNeedsRender()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The text view, so the tab can route Find menu actions at it.
    var findTarget: NSTextView { textView }

    func takeFocus() {
        window?.makeFirstResponder(textView)
    }

    /// Re-reads `file.text`, keeping the image cache and the scroll position.
    /// Called when the tab switches back from the source editor, so edits made
    /// there show up without refetching every remote image.
    func refresh() {
        renderedSource = nil
        setNeedsRender()
    }

    /// The document moved on disk, so every relative link and image resolves
    /// against a different directory now.
    func reloadForPathChange() {
        images.reset()
        refresh()
    }

    override func layout() {
        super.layout()
        // Width drives image scaling and table columns, so a resize past the
        // width the document was laid out for needs a fresh render — but a
        // sub-point jitter during live resize should not.
        if abs(availableWidth - renderedWidth) > 0.5 {
            setNeedsRender()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        setNeedsRender()
    }

    private var availableWidth: CGFloat {
        max(bounds.width - Self.contentInset.width * 2, 1)
    }

    /// Coalesces the several things that can invalidate a render — an image
    /// landing, a grammar finishing its compile, a resize, an appearance change
    /// — into one pass per turn of the run loop.
    private func setNeedsRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            self.render()
        }
    }

    private func render() {
        guard bounds.width > 0 else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let source = file.text
        let width = availableWidth
        guard source != renderedSource || width != renderedWidth || isDark != renderedDark
        else {
            return
        }
        renderedSource = source
        renderedWidth = width
        renderedDark = isDark

        let rendered = MarkdownRenderer.render(
            source,
            style: .theme(dark: isDark),
            baseURL: URL(fileURLWithPath: file.path).deletingLastPathComponent(),
            contentWidth: width,
            images: images
        )

        // Re-rendering replaces the whole document, which would otherwise snap
        // the reader back to the top on every image that arrives.
        let offset = scrollView.contentView.bounds.origin
        textView.textStorage?.setAttributedString(rendered)
        textView.scroll(offset)
    }

    private func applyColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let palette = EditorPalette.theme(dark: isDark)
        textView.backgroundColor = palette.background
        scrollView.backgroundColor = palette.background
        textView.linkTextAttributes = [
            .foregroundColor: palette.insertionPoint,
            .cursor: NSCursor.pointingHand,
        ]
    }
}

/// Read-only text view that reports focus and carries the pane-split context
/// menu, so a preview pane behaves like the editor pane it replaces.
private final class PreviewTextView: NSTextView {
    var onBecomeFirstResponder: (() -> Void)?
    /// Owns the split menu items, kept off the text view so its own menu
    /// validation doesn't disable them. Same arrangement as the editor's
    /// `FocusReportingTextView`.
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

    /// Opens links in the user's browser (or the default app for a local file)
    /// rather than trying to navigate inside a text view.
    override func clicked(onLink link: Any, at charIndex: Int) {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
