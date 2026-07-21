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
    /// Fired when this terminal is clicked, right-clicked, or dropped onto —
    /// i.e. takes focus — so the owning pane can mark itself focused in the
    /// model. (SwiftTerm's `becomeFirstResponder` is not open to override, so
    /// a passive click recognizer stands in for the plain-click case.)
    var onBecomeFirstResponder: (() -> Void)?
    /// Owns the split context-menu items. Kept separate from the terminal so
    /// SwiftTerm's `validateUserInterfaceItem` — which disables selectors it
    /// doesn't recognize — doesn't grey them out.
    let splitTarget = SplitMenuTarget()

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        installFocusClickRecognizer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
        installFocusClickRecognizer()
    }

    private func installFocusClickRecognizer() {
        let recognizer = FocusClickRecognizer()
        recognizer.onMouseDown = { [weak self] in self?.onBecomeFirstResponder?() }
        addGestureRecognizer(recognizer)
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
        onBecomeFirstResponder?()

        let menu = NSMenu()
        menu.addItem(contextItem("Copy", #selector(copy(_:))))
        menu.addItem(contextItem("Paste", #selector(paste(_:))))
        menu.addItem(.separator())
        menu.addItem(contextItem("Select All", #selector(selectAll(_:))))
        menu.addItem(.separator())
        for item in splitTarget.menuItems() { menu.addItem(item) }
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
        onBecomeFirstResponder?()
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

/// Target for the pane-split context-menu items. A dedicated NSObject (rather
/// than the terminal/editor itself) so the host view's own menu validation —
/// which disables selectors it doesn't know — leaves these enabled: AppKit
/// enables an item whose target responds to its action and doesn't veto it.
final class SplitMenuTarget: NSObject {
    /// Splits the pane on the given edge.
    var onSplit: ((PaneDropEdge) -> Void)?

    /// The four split items, targeting this object.
    func menuItems() -> [NSMenuItem] {
        [
            item("Split Right", #selector(splitRight)),
            item("Split Left", #selector(splitLeft)),
            item("Split Up", #selector(splitUp)),
            item("Split Down", #selector(splitDown)),
        ]
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    @objc private func splitRight() { onSplit?(.right) }
    @objc private func splitLeft() { onSplit?(.left) }
    @objc private func splitUp() { onSplit?(.top) }
    @objc private func splitDown() { onSplit?(.bottom) }
}

/// A passive primary-button recognizer: it reports the mouse-down, then
/// immediately fails so the terminal still receives the event for selection
/// and mouse reporting. Used purely to notice a click landing on this pane.
private final class FocusClickRecognizer: NSClickGestureRecognizer {
    var onMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        state = .failed
    }
}
