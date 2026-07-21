//
//  TerminalHostView.swift
//  kero
//

import AppKit
import SwiftTerm
import SwiftUI

/// Hosts a session's long-lived `LocalProcessTerminalView` in SwiftUI,
/// wrapped in a container that insets the terminal content while pinning
/// the session's overlay scrollbar to the container's true trailing edge.
struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession
    /// Whether this terminal's pane is the focused one in its tab.
    var isFocused: Bool = true
    /// Called when the terminal takes focus itself (e.g. a click), so the
    /// model's focused pane can follow.
    var onFocused: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = TerminalContainerView()
        container.terminal = session.terminalView
        container.focusOnAppear = isFocused
        let terminal = session.terminalView
        (terminal as? KeroTerminalView)?.onBecomeFirstResponder = onFocused
        let scrollbar = session.overlayScrollbar
        terminal.translatesAutoresizingMaskIntoConstraints = false
        scrollbar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        container.addSubview(scrollbar, positioned: .above, relativeTo: terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            terminal.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            scrollbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollbar.topAnchor.constraint(equalTo: container.topAnchor),
            scrollbar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollbar.widthAnchor.constraint(equalToConstant: OverlayScrollbarView.stripWidth),
        ])
        context.coordinator.isFocused = isFocused
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        (session.terminalView as? KeroTerminalView)?.onBecomeFirstResponder = onFocused
        // Take focus only on the unfocused→focused edge (keyboard navigation,
        // a split landing here), never on every render — that would fight the
        // user for focus and make sidebar text fields untypable.
        if isFocused, !context.coordinator.isFocused, let container = view as? TerminalContainerView {
            container.focusTerminal()
        }
        context.coordinator.isFocused = isFocused
    }

    final class Coordinator {
        var isFocused = false
    }
}

/// Focuses the terminal when its pane is the focused one — on first appearance
/// and when navigation moves focus here. `TerminalHostView` drives the edge;
/// this only performs the makeFirstResponder.
private final class TerminalContainerView: NSView {
    weak var terminal: NSView?
    var focusOnAppear = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusOnAppear else { return }
        focusTerminal()
    }

    func focusTerminal() {
        guard let window, let terminal else { return }
        DispatchQueue.main.async {
            window.makeFirstResponder(terminal)
        }
    }
}
