//
//  TerminalHostView.swift
//  kero
//

import AppKit
import GhosttyTerminal
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
        // Coming out of parking: let the renderer draw again.
        terminal.setSurfaceVisible(true)
        terminal.onBecomeFirstResponder = onFocused
        terminal.splitTarget.onSplit = onSplit
        let scrollbar = session.overlayScrollbar
        // Kero's visual insets live inside ghostty as window-padding (see
        // TerminalSession), so that window-padding-color=extend can flood
        // them with the content's background and window-padding-balance
        // keeps the prompt near the pane's bottom edge. The surface keeps a
        // hairline inset of pane background so a full-screen TUI's fill
        // stops just short of the pane edges.
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
        context.coordinator.isFocused = isFocused
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        session.terminalView.setSurfaceVisible(true)
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
            // Parked panes stay attached at full size so the grid survives
            // unparking, but nothing composites them. Marking them occluded
            // lets libghostty drop the renderer's pane-sized IOSurfaces
            // (~20 MB each) while `shouldProcessWakeup` — gated on attachment,
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
