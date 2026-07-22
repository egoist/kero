//
//  KeroTerminalView.swift
//  kero
//

import AppKit
import QuartzCore
import SwiftTerm

/// The per-session terminal NSView. Subclasses SwiftTerm's
/// `LocalProcessTerminalView` for Kero-specific terminal integrations,
/// context menus, and file drops.
final class KeroTerminalView: LocalProcessTerminalView {
    /// Fired when this terminal is clicked, right-clicked, or dropped onto —
    /// i.e. takes focus — so the owning pane can mark itself focused in the
    /// model. SwiftTerm's `becomeFirstResponder` is not open to override, so
    /// the plain-click path is reported from `mouseDown` instead.
    var onBecomeFirstResponder: (() -> Void)?
    /// Owns the split context-menu items. Kept separate from the terminal so
    /// SwiftTerm's `validateUserInterfaceItem` — which disables selectors it
    /// doesn't recognize — doesn't grey them out.
    let splitTarget = SplitMenuTarget()
    private var gpuRenderingEnabled = true
    private var lastReportedTerminalFocus = false

    /// Keep Kero's deduplication state in sync with the focus reports
    /// SwiftTerm sends from its non-open first-responder overrides.
    override var hasFocus: Bool {
        get { super.hasFocus }
        set {
            super.hasFocus = newValue
            lastReportedTerminalFocus = newValue
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        installEffectiveFocusReporting()
        installOSC9Handler()
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installEffectiveFocusReporting()
        installOSC9Handler()
        registerForDraggedTypes([.fileURL])
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// SwiftTerm reports DECSET 1004 focus changes when this view gains or
    /// resigns first responder, but AppKit keeps a view as first responder when
    /// its window deactivates. Report key-window transitions too so terminal
    /// apps can distinguish foreground/background.
    private func installEffectiveFocusReporting() {
        // A session starts its PTY before SwiftUI attaches this view. SwiftTerm
        // otherwise defaults the reported state to focused, so an app enabling
        // focus reporting during startup can receive a false FocusGained.
        getTerminal().setTerminalFocus(false)
        lastReportedTerminalFocus = false

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(applicationFocusChanged(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationFocusChanged(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(windowFocusChanged(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(windowFocusChanged(_:)),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
    }

    @objc private func applicationFocusChanged(_ notification: Notification) {
        reportEffectiveTerminalFocus()
    }

    @objc private func windowFocusChanged(_ notification: Notification) {
        guard let changedWindow = notification.object as? NSWindow,
              changedWindow === window else { return }
        reportEffectiveTerminalFocus()
    }

    private var hasEffectiveTerminalFocus: Bool {
        NSApp.isActive && window?.isKeyWindow == true && window?.firstResponder === self
    }

    private func reportEffectiveTerminalFocus() {
        let focused = hasEffectiveTerminalFocus
        guard focused != lastReportedTerminalFocus else { return }
        lastReportedTerminalFocus = focused
        getTerminal().setTerminalFocus(focused)
    }

    private func installOSC9Handler() {
        getTerminal().registerOscHandler(code: 9) { [weak self] data in
            guard let self else { return }

            if let report = OSC9PayloadParser.progressReport(from: data) {
                // A registered OSC handler replaces SwiftTerm's built-in one,
                // so forward valid 9;4 reports to preserve its progress bar.
                self.progressReport(source: self.getTerminal(), report: report)
            } else if let message = String(bytes: data, encoding: .utf8),
                      !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                TerminalNotificationService.shared.post(message: message)
            }
        }
    }

    override func bell(source: Terminal) {
        super.bell(source: source)
        guard !hasEffectiveTerminalFocus else { return }

        TerminalNotificationService.shared.post(message: "Terminal bell")
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // SwiftUI reparents this long-lived view when a single pane becomes a
        // split layout. AppKit drops a detached first responder without
        // calling resignFirstResponder(), which leaves SwiftTerm's hasFocus
        // flag (and therefore its cursor) active. Resign while the old window
        // still owns us so the inactive pane redraws with an outline cursor.
        if newWindow == nil, let window, window.firstResponder === self {
            window.makeFirstResponder(nil)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportEffectiveTerminalFocus()
        updateRenderer()
    }

    /// Switches rendering without replacing the terminal view, preserving the
    /// running process, scrollback, selection, and focus.
    func setGPURenderingEnabled(_ enabled: Bool) {
        gpuRenderingEnabled = enabled
        updateRenderer()
    }

    private func updateRenderer() {
        // Disabling is safe even while the terminal is temporarily detached.
        // Enabling must wait until AppKit attaches the view to a window so
        // SwiftTerm can bind its CAMetalLayer to the correct WindowServer surface.
        if gpuRenderingEnabled {
            guard window != nil, !isUsingMetalRenderer else { return }
        } else {
            guard isUsingMetalRenderer else { return }
        }

        do {
            try setUseMetal(gpuRenderingEnabled)
            if gpuRenderingEnabled { primeMetalLayerBackground() }
        } catch {
            NSLog("Kero: SwiftTerm Metal renderer unavailable: %@", String(describing: error))
        }
    }

    /// Enabling Metal inserts an `MTKView` whose `CAMetalLayer` has no drawable
    /// until its first frame is presented. On the initial enable SwiftTerm only
    /// schedules that frame with `setNeedsDisplay` (its window-rebind path draws
    /// synchronously, but this one doesn't), so the empty, opaque layer
    /// composites as black for a frame or two before the terminal first paints —
    /// the black flash on launch. Fill the layer background with the terminal's
    /// own background color so that gap shows the theme instead of black.
    private func primeMetalLayerBackground() {
        for subview in subviews where subview.layer is CAMetalLayer {
            subview.layer?.backgroundColor = nativeBackgroundColor.cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        focusForInteraction()
        super.mouseDown(with: event)
    }

    /// SwiftTerm handles selection in `mouseDown` but does not make its macOS
    /// view first responder. Do that explicitly for every direct interaction.
    private func focusForInteraction() {
        window?.makeFirstResponder(self)
        onBecomeFirstResponder?()
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
        focusForInteraction()

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
        focusForInteraction()
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

/// Pure parser matching SwiftTerm's OSC 9;4 behavior. Keeping it separate
/// makes the compatibility rule independently testable without a terminal.
enum OSC9PayloadParser {
    static func progressReport(from data: ArraySlice<UInt8>) -> Terminal.ProgressReport? {
        guard let text = String(bytes: data, encoding: .ascii) else { return nil }

        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "4" else { return nil }

        let statePart = parts[1]
        guard statePart.count == 1,
              let stateValue = Int(statePart),
              let state = Terminal.ProgressReportState(rawValue: stateValue) else {
            return nil
        }

        var progress: UInt8?
        if parts.count >= 3, !parts[2].isEmpty {
            guard let rawProgress = Int(parts[2]) else { return nil }
            progress = UInt8(max(0, min(rawProgress, 100)))
        } else if state == .set {
            progress = 0
        }

        if state == .remove {
            progress = nil
        }

        return Terminal.ProgressReport(state: state, progress: progress)
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
