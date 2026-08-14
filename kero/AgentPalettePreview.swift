//
//  AgentPalettePreview.swift
//  kero
//

import AppKit

/// The agent palette's terminal pane: a recessed well holding the highlighted
/// agent's own screen, in its own colors.
///
/// This owns everything about showing that capture — the scroll position it
/// must not disturb, the debounce that keeps key repeat from exporting a
/// screen per keystroke, and the change detection that lets a still agent
/// refresh for free. The controller only says which session is highlighted.
@MainActor
final class AgentPalettePreviewView: NSView {
    private enum Metrics {
        static let cornerRadius: CGFloat = 8
        static let fontSize: CGFloat = 10
        static let lines = 44
        /// Wide enough to hold an agent's own box drawing without reflowing
        /// it. Overflow is clipped rather than wrapped.
        static let columns = 200
        static let inset = NSSize(width: 12, height: 11)
        /// Coalesces the export burst that arrow-key repeat produces.
        static let debounce: TimeInterval = 0.06
        /// Slack when deciding whether the reader sits at the bottom.
        static let tailTolerance: CGFloat = 6
    }

    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let placeholder = NSTextField(labelWithString: "")

    /// What is on screen now, so a refresh producing identical output can
    /// leave the text storage — and the reader's scroll position — alone.
    private var shownSessionID: UUID?
    private var shownText = ""
    private var pendingRender: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Metrics.cornerRadius
        layer?.cornerCurve = .continuous
        // Clips the unwrapped terminal lines that overflow the pane.
        layer?.masksToBounds = true
        applyColors()
        buildSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// Terminal output is a different kind of content from the list beside it,
    /// and a faint well says so without adding another border to the panel.
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.bestMatch(
                from: [.darkAqua, .aqua]
            ) == .darkAqua
            layer?.backgroundColor = NSColor.labelColor
                .withAlphaComponent(isDark ? 0.045 : 0.03).cgColor
        }
    }

    private func buildSubviews() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        textView.isEditable = false
        // Selection would compete with the search field for the responder and
        // give the terminal tail an I-beam it cannot act on.
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = Metrics.inset
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        // Terminal output is already laid out in columns. Reflowing it to the
        // pane width folds an agent's own box drawing onto itself, so give the
        // container unbounded width and let this well clip the overflow.
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.lineFragmentPadding = 0
        scrollView.documentView = textView

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.font = .systemFont(ofSize: 11)
        placeholder.textColor = .quaternaryLabelColor
        placeholder.alignment = .center
        placeholder.stringValue = String(
            localized: "No output yet",
            comment: "Agent palette preview pane with nothing to show."
        )
        placeholder.isHidden = true

        addSubview(scrollView)
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // MARK: - Presenting

    /// Shows `session`'s screen. Pass `debounced` when walking the list, so key
    /// repeat does not export a screen per row; the periodic refresh of an
    /// already-shown session passes false and renders immediately.
    func show(_ session: TerminalSession?, id: UUID?, debounced: Bool) {
        pendingRender?.cancel()
        guard let session, let id else {
            clear()
            return
        }
        guard debounced else {
            render(session, id: id)
            return
        }
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session else { return }
            self.render(session, id: id)
        }
        pendingRender = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.debounce, execute: work)
    }

    func clear() {
        pendingRender?.cancel()
        pendingRender = nil
        placeholder.isHidden = false
        scrollView.isHidden = true
        textView.string = ""
        shownSessionID = nil
        shownText = ""
    }

    private func render(_ session: TerminalSession, id: UUID) {
        guard let capture = TerminalHistorySerializer.previewCapture(
            from: session.surface
        ) else {
            clear()
            return
        }
        let isDark = effectiveAppearance.bestMatch(
            from: [.darkAqua, .aqua]
        ) == .darkAqua
        let font = NSFont(
            descriptor: TerminalFont.current().fontDescriptor,
            size: Metrics.fontSize
        ) ?? .monospacedSystemFont(ofSize: Metrics.fontSize, weight: .regular)

        guard let styled = TerminalPreviewStyle.attributedPreview(
            vt: capture,
            maxLines: Metrics.lines,
            maxColumns: Metrics.columns,
            theme: Theme.terminal(dark: isDark),
            font: font
        ), styled.length > 0 else {
            clear()
            return
        }
        display(styled, id: id)
    }

    private func display(_ text: NSAttributedString, id: UUID) {
        placeholder.isHidden = true
        scrollView.isHidden = false

        let isNewSelection = id != shownSessionID
        // A still agent re-renders identically every tick. Replacing the text
        // storage anyway would fight the scroll wheel, so do nothing at all.
        guard isNewSelection || text.string != shownText else { return }

        let clipView = scrollView.contentView
        let previousOrigin = clipView.bounds.origin
        // Follow live output only for a reader already at the bottom. Someone
        // who scrolled up is reading, and must not be yanked back.
        let followTail = isNewSelection || isScrolledToTail

        textView.textStorage?.setAttributedString(text)
        // The container is unbounded, so the text view has to be sized to its
        // own laid-out content before the scroll view can position it.
        textView.sizeToFit()
        shownSessionID = id
        shownText = text.string

        if followTail {
            // An agent's newest output is its last row — the question it is
            // blocked on, or the prompt it waits at. Open on that, not on the
            // banner that happens to sit at the top of the screen.
            textView.scrollToEndOfDocument(nil)
        } else {
            clipView.scroll(to: previousOrigin)
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    private var isScrolledToTail: Bool {
        let clipView = scrollView.contentView
        let documentHeight = textView.frame.height
        guard documentHeight > clipView.bounds.height else { return true }
        return clipView.bounds.maxY >= documentHeight - Metrics.tailTolerance
    }
}
