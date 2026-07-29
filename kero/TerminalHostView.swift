//
//  TerminalHostView.swift
//  kero
//

import AppKit
import SwiftUI

/// Hosts a session's long-lived terminal surface in SwiftUI, wrapped in a
/// container that insets the terminal content while pinning the session's
/// overlay scrollbar to the container's true trailing edge.
struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession
    /// Whether this terminal's pane is the focused one in its tab.
    var isFocused: Bool = true
    /// Called when the terminal takes focus itself (e.g. a click), so the
    /// model's focused pane can follow.
    var onFocused: () -> Void = {}
    /// Splits this pane on the given edge — wired to the context-menu items.
    var onSplit: (PaneDropEdge) -> Void = { _ in }
    var onNewBrowserTab: (String?) -> Void = { _ in }
    var onNewBrowserPane: (String?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = TerminalContainerView()
        container.terminal = session.surface
        container.focusOnAppear = isFocused
        let terminal = session.surface
        terminal.onBecomeFirstResponder = onFocused
        terminal.splitTarget.onSplit = onSplit
        terminal.splitTarget.onNewBrowserTab = onNewBrowserTab
        terminal.splitTarget.onNewBrowserPane = onNewBrowserPane
        let scrollbar = session.overlayScrollbar
        // Kero's visual insets live inside the backend as window padding (see
        // KeroTerminalView+Ghostty), so that a padding-color of `extend` can
        // flood them with the content's background and padding balance keeps
        // the prompt near the pane's bottom edge. The surface keeps a hairline
        // inset of pane background so a full-screen TUI's fill stops just
        // short of the pane edges.
        let frameInset: CGFloat = 2
        terminal.translatesAutoresizingMaskIntoConstraints = false
        scrollbar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        container.addSubview(scrollbar, positioned: .above, relativeTo: terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: frameInset),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -frameInset),
            terminal.topAnchor.constraint(equalTo: container.topAnchor, constant: frameInset),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -frameInset),
            scrollbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollbar.topAnchor.constraint(equalTo: container.topAnchor),
            scrollbar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollbar.widthAnchor.constraint(equalToConstant: OverlayScrollbarView.stripWidth),
        ])
        // A parked Metal surface has discarded its drawable pool. Activate it
        // only after Auto Layout has assigned the real pane geometry, so its
        // first replacement drawable is created at the correct size.
        container.activateSurfaceAfterLayout()
        context.coordinator.isFocused = isFocused
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        session.surface.onBecomeFirstResponder = onFocused
        session.surface.splitTarget.onSplit = onSplit
        session.surface.splitTarget.onNewBrowserTab = onNewBrowserTab
        session.surface.splitTarget.onNewBrowserPane = onNewBrowserPane
        let container = view as? TerminalContainerView
        container?.activateSurfaceAfterLayout()
        container?.focusOnAppear = isFocused
        // Take focus only on the unfocused→focused edge (keyboard navigation,
        // a split landing here), never on every render — that would fight the
        // user for focus and make sidebar text fields untypable.
        if isFocused, !context.coordinator.isFocused, let container {
            container.requestTerminalFocus()
        }
        context.coordinator.isFocused = isFocused
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        guard let container = view as? TerminalContainerView,
              let terminal = container.terminal as? any TerminalBackendSurface
        else { return }
        // These closures originate on PaneView and therefore capture its
        // PaneContent, including the same TerminalSession that owns `terminal`.
        // Clear them whenever SwiftUI removes this host so a closed tab cannot
        // leave the session and its renderer in a retain cycle. A parked
        // session gets fresh callbacks when its host is recreated.
        terminal.onBecomeFirstResponder = nil
        terminal.splitTarget.onSplit = nil
        terminal.splitTarget.onNewBrowserTab = nil
        terminal.splitTarget.onNewBrowserPane = nil
        container.terminal = nil
    }

    final class Coordinator {
        var isFocused = false
    }
}

/// Keeps every non-visible terminal attached to the window. A backend may
/// start its shell only after attachment and drain process/title/bell events
/// from its own tick, so parking preserves the eager/background session
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
        let desired = Set(sessions.map { ObjectIdentifier($0.surface) })
        for subview in subviews where !desired.contains(ObjectIdentifier(subview)) {
            subview.removeFromSuperview()
        }

        for session in sessions {
            let terminal = session.surface
            // Parked panes stay attached at full size so the grid survives
            // unparking, but nothing composites them. Marking them occluded
            // lets the backend drop the renderer's pane-sized IOSurfaces
            // (~20 MB each) while its wakeup check — gated on attachment,
            // not visibility — keeps title/bell/exit events draining.
            terminal.setSurfaceVisible(false)
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
    weak var terminal: NSView?
    var focusOnAppear = true {
        didSet {
            if !focusOnAppear { pendingFocusRequest = false }
        }
    }
    private var pendingFocusRequest = false
    private var needsSurfaceActivation = false

    deinit {
        NotificationCenter.default.removeObserver(self)
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
            if needsSurfaceActivation {
                needsLayout = true
            }
        }
        guard focusOnAppear else { return }
        requestTerminalFocus()
    }

    func activateSurfaceAfterLayout() {
        needsSurfaceActivation = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard needsSurfaceActivation,
              window != nil,
              bounds.width > 0, bounds.height > 0,
              let terminal = terminal as? any TerminalBackendSurface,
              terminal.window != nil,
              terminal.bounds.width > 0, terminal.bounds.height > 0
        else { return }
        needsSurfaceActivation = false
        terminal.setSurfaceVisible(true)
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
