//
//  AlacrittyFind.swift
//  kero
//

import Foundation

/// Drives find-in-terminal for the Alacritty backend.
///
/// The bridge collects every match up front and moves the selection, so this
/// only has to keep the bar's counts in step: `TerminalFind` learns the total
/// and the selected index through `TerminalBackendEvents`, exactly as it does
/// from Ghostty's asynchronous reports.
final class AlacrittyFind {
    private var total = 0

    func begin(
        needle: String,
        handle: OpaquePointer?,
        events: (any TerminalBackendEvents)?
    ) {
        guard let handle else { return }
        guard !needle.isEmpty else {
            end(handle: handle)
            events?.terminalDidUpdateFindTotal(nil)
            events?.terminalDidUpdateFindSelected(nil)
            return
        }

        total = needle.withCString { kero_alacritty_find(handle, $0) }
        events?.terminalDidUpdateFindTotal(total)
        // Nothing is selected until the bar asks to step, matching how Ghostty
        // reports a fresh needle — TerminalFind then reveals the first match.
        events?.terminalDidUpdateFindSelected(nil)
    }

    func step(
        forward: Bool,
        handle: OpaquePointer?,
        events: (any TerminalBackendEvents)?
    ) {
        guard let handle, total > 0 else { return }
        let index = kero_alacritty_find_step(handle, forward)
        events?.terminalDidUpdateFindSelected(index >= 0 ? Int(index) : nil)
    }

    func end(handle: OpaquePointer?) {
        total = 0
        guard let handle else { return }
        kero_alacritty_find_end(handle)
    }
}
