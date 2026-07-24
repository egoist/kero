//
//  TerminalHostView.swift
//  kero
//

import AppKit
import SwiftUI

/// Hosts a session's long-lived Ghostty terminal view in SwiftUI,
/// wrapped in a container that insets the terminal content while pinning
/// the session's overlay scrollbar to the container's true trailing edge.
struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession
    /// Whether this terminal's pane is the focused one in its tab.
    var isFocused: Bool = true
    /// Called when the terminal takes focus itself (e.g. a click), so the
    /// model's focused pane can follow.
    var onFocused: () -> Void = {}
    /// Splits this pane on the given edge — wired to the context-menu items.
    var onSplit: (PaneDropEdge) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = TerminalContainerView()
        container.terminal = session.terminalView
        container.focusOnAppear = isFocused
        let terminal = session.terminalView
        terminal.onBecomeFirstResponder = onFocused
        terminal.splitTarget.onSplit = onSplit
        let scrollbar = session.overlayScrollbar
        // The terminal is framed manually by the container: its height snaps
        // to whole grid rows and the sub-row remainder is split between the
        // top and bottom insets, keeping the prompt line near the pane's
        // bottom edge without the top gap outgrowing the bottom one.
        terminal.translatesAutoresizingMaskIntoConstraints = true
        terminal.autoresizingMask = []
        scrollbar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        container.addSubview(scrollbar, positioned: .above, relativeTo: terminal)
        container.needsLayout = true
        NSLayoutConstraint.activate([
            scrollbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollbar.topAnchor.constraint(equalTo: container.topAnchor),
            scrollbar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollbar.widthAnchor.constraint(equalToConstant: OverlayScrollbarView.stripWidth),
        ])
        context.coordinator.isFocused = isFocused
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        session.terminalView.onBecomeFirstResponder = onFocused
        session.terminalView.splitTarget.onSplit = onSplit
        let container = view as? TerminalContainerView
        container?.focusOnAppear = isFocused
        // Take focus only on the unfocused→focused edge (keyboard navigation,
        // a split landing here), never on every render — that would fight the
        // user for focus and make sidebar text fields untypable.
        if isFocused, !context.coordinator.isFocused, let container {
            container.requestTerminalFocus()
        }
        context.coordinator.isFocused = isFocused
    }

    final class Coordinator {
        var isFocused = false
    }
}

/// Keeps every non-visible terminal attached to the window. libghostty starts
/// an exec surface only after attachment and drains process/title/bell events
/// from its app tick, so parking preserves the eager/background session
/// behavior Kero had before the backend migration without drawing those panes
/// into the visible layout.
struct TerminalParkingView: NSViewRepresentable {
    let sessions: [TerminalSession]

    func makeNSView(context: Context) -> TerminalParkingContainerView {
        TerminalParkingContainerView(frame: .zero)
    }

    func updateNSView(_ view: TerminalParkingContainerView, context: Context) {
        view.mount(sessions)
    }

    static func dismantleNSView(
        _ view: TerminalParkingContainerView, coordinator: ()
    ) {
        view.unmountAll()
    }
}

final class TerminalParkingContainerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        alphaValue = 0
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func mount(_ sessions: [TerminalSession]) {
        let desired = Set(sessions.map { ObjectIdentifier($0.terminalView) })
        for subview in subviews where !desired.contains(ObjectIdentifier(subview)) {
            subview.removeFromSuperview()
        }

        for session in sessions {
            let terminal = session.terminalView
            guard terminal.superview !== self else { continue }
            let parkedSize = terminal.frame.size
            if terminal.window?.firstResponder === terminal {
                terminal.window?.makeFirstResponder(nil)
            }
            terminal.removeFromSuperview()
            terminal.translatesAutoresizingMaskIntoConstraints = true
            let hasUsableSize =
                parkedSize.width.isFinite && parkedSize.height.isFinite
                && parkedSize.width > 0 && parkedSize.height > 0
            terminal.frame = NSRect(
                origin: .zero,
                size: hasUsableSize
                    ? parkedSize
                    : NSSize(width: 800, height: 600)
            )
            addSubview(terminal)
        }
    }

    func unmountAll() {
        for subview in subviews { subview.removeFromSuperview() }
    }
}

/// Focuses the terminal when its pane is the focused one — on first appearance
/// and when navigation moves focus here. `TerminalHostView` drives the edge;
/// this only performs the makeFirstResponder.
private final class TerminalContainerView: NSView {
    weak var terminal: KeroTerminalView?

    /// Content insets around the terminal surface. Ghostty's own
    /// window-padding is zeroed (TerminalSession), so these are the only
    /// padding the grid gets and the snap math below stays exact.
    private static let insets = NSEdgeInsets(top: 6, left: 12, bottom: 10, right: 6)

    var focusOnAppear = true {
        didSet {
            if !focusOnAppear { pendingFocusRequest = false }
        }
    }
    private var pendingFocusRequest = false

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        layoutTerminal()
    }

    /// The row snap depends on the backing scale; re-derive it when the
    /// window lands on a display with a different one.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    /// Snaps the terminal's height down to a whole number of grid rows and
    /// splits the sub-row remainder between the top and bottom insets, like
    /// ghostty's window-padding-balance. Ghostty itself pins the grid to the
    /// surface's top and leaves the whole remainder at the bottom, which
    /// strands the prompt up to a full row above the pane's bottom edge;
    /// dumping it all on the top instead makes the top gap visibly outgrow
    /// the bottom one. The split keeps both gaps near their base insets, and
    /// the remainder blends into the pane's matching background.
    private func layoutTerminal() {
        guard let terminal else { return }
        let insets = Self.insets
        let width = max(bounds.width - insets.left - insets.right, 0)
        let available = max(bounds.height - insets.top - insets.bottom, 0)
        var height = available
        var bottomExtra: CGFloat = 0
        // Same fallback chain the wrapper's surface coordinator uses, so the
        // pixel height ghostty receives is exactly rows × cell height.
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        if let cellPixels = terminal.cellHeightPixels, cellPixels > 0, scale > 0 {
            let cell = CGFloat(cellPixels)
            let rows = ((available * scale).rounded(.down) / cell).rounded(.down)
            if rows >= 1 {
                height = rows * cell / scale
                // Pixel-align the bottom share; the top absorbs any sub-pixel
                // fraction of the container height.
                bottomExtra = ((available - height) * scale / 2).rounded() / scale
            }
        }
        terminal.frame = NSRect(
            x: insets.left,
            y: insets.bottom + bottomExtra,
            width: width,
            height: height
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey(_:)),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
        }
        guard focusOnAppear else { return }
        requestTerminalFocus()
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard focusOnAppear, pendingFocusRequest else { return }
        focusTerminalIfPossible()
    }

    func requestTerminalFocus() {
        pendingFocusRequest = true
        focusTerminalIfPossible()
    }

    private func focusTerminalIfPossible() {
        guard NSApp.isActive, let window, window.isKeyWindow, let terminal else {
            return
        }
        DispatchQueue.main.async { [weak self, weak window, weak terminal] in
            guard
                let self,
                let window,
                let terminal,
                self.focusOnAppear,
                NSApp.isActive,
                window.isKeyWindow,
                terminal.window === window
            else { return }
            if window.makeFirstResponder(terminal) {
                self.pendingFocusRequest = false
            }
        }
    }
}
