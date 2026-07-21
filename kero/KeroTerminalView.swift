//
//  KeroTerminalView.swift
//  kero
//

import AppKit
import SwiftTerm

/// The per-session terminal NSView. Subclasses SwiftTerm's
/// `LocalProcessTerminalView` to add two things SwiftTerm ships without:
/// a right-click context menu, and a dragging destination that inserts
/// dropped files' paths at the prompt (from the Files panel or from Finder).
final class KeroTerminalView: LocalProcessTerminalView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    // MARK: - Context menu

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

    // MARK: - File drops

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canReadFileURLs(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canReadFileURLs(sender) ? .copy : []
    }

    /// Inserts the dropped files' absolute paths at the prompt — space
    /// separated, shell-escaped, with a trailing space — as if pasted.
    /// Handles drags from the Files panel and from Finder alike; both vend
    /// `public.file-url`.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = fileURLs(sender), !urls.isEmpty else { return false }
        // The drop should type into *this* terminal, so take focus the way a
        // right-click does — otherwise the path lands wherever focus was.
        window?.makeFirstResponder(self)
        let text = urls.map { Self.shellToken(for: $0.path) }.joined(separator: " ")
        send(txt: text + " ")
        return true
    }

    private func canReadFileURLs(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        )
    }

    private func fileURLs(_ sender: NSDraggingInfo) -> [URL]? {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
    }

    /// Renders a path for the prompt: bare when it's made only of "safe"
    /// characters, otherwise single-quoted — which neutralises spaces, quotes,
    /// glob characters and the like uniformly (an embedded `'` via the classic
    /// `'\''` dance).
    private static func shellToken(for path: String) -> String {
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/")
        if !path.isEmpty, path.allSatisfy({ safe.contains($0) }) {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
