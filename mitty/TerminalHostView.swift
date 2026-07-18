//
//  TerminalHostView.swift
//  mitty
//

import AppKit
import SwiftTerm
import SwiftUI

/// Hosts a session's long-lived `LocalProcessTerminalView` in SwiftUI,
/// wrapped in a container that insets the terminal content while pinning
/// the session's overlay scrollbar to the container's true trailing edge.
struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> NSView {
        let container = TerminalContainerView()
        container.terminal = session.terminalView
        let terminal = session.terminalView
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
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// Focuses the terminal once, when the container lands in a window (view
/// creation and tab switches — `.id(session.id)` remakes it per session).
/// Refocusing on every SwiftUI update would fight the user for focus and
/// make sidebar text fields (e.g. the commit message) untypable.
private final class TerminalContainerView: NSView {
    weak var terminal: NSView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, let terminal else { return }
        DispatchQueue.main.async {
            window.makeFirstResponder(terminal)
        }
    }
}
