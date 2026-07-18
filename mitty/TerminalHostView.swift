//
//  TerminalHostView.swift
//  mitty
//

import AppKit
import SwiftTerm
import SwiftUI

/// Hosts a session's long-lived `LocalProcessTerminalView` in SwiftUI.
struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        session.terminalView
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
    }
}
