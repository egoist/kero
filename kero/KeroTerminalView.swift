//
//  KeroTerminalView.swift
//  kero
//

import AppKit
import SwiftTerm

/// The per-session terminal NSView. Subclasses SwiftTerm's
/// `LocalProcessTerminalView` purely to add a right-click context menu:
/// SwiftTerm wires up the `copy:`/`paste:`/`selectAll:` selectors and their
/// validation (Copy auto-disables without a selection) but ships no menu of
/// its own, and never overrides `menu(for:)`, so this is purely additive.
final class KeroTerminalView: LocalProcessTerminalView {
    /// AppKit calls this on right-/control-click to build the context menu.
    /// Items target `self` so AppKit routes validation through SwiftTerm's
    /// `validateUserInterfaceItem(_:)` — that's what greys out Copy when
    /// nothing is selected.
    override func menu(for event: NSEvent) -> NSMenu? {
        // A right-click on an unfocused terminal should focus it, so that a
        // following Paste (or typing) lands here rather than in whatever held
        // focus before — matching Terminal.app.
        window?.makeFirstResponder(self)

        let menu = NSMenu()
        menu.addItem(contextItem("Copy", #selector(copy(_:))))
        menu.addItem(contextItem("Paste", #selector(paste(_:))))
        menu.addItem(.separator())
        menu.addItem(contextItem("Select All", #selector(selectAll(_:))))
        return menu
    }

    private func contextItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
}
