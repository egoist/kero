//
//  KeroTerminalView.swift
//  kero
//

import AppKit
import GhosttyTerminal

/// Kero's libghostty backend: Ghostty's Metal-backed terminal surface plus
/// Kero's pane focus, context menu, effective application focus, and
/// Finder/file-tree drop behavior.
///
/// This is the only type in Kero that knows libghostty exists. It owns the
/// `TerminalController`, renders Kero's settings into Ghostty's config, and
/// translates Ghostty's delegate callbacks into ``TerminalBackendEvents`` —
/// see `KeroTerminalView+Ghostty.swift`.
final class KeroTerminalView: AppTerminalView, TerminalBackendSurface {
    /// The session listening to this surface. Weak: the session owns the view.
    weak var events: (any TerminalBackendEvents)?

    /// Fired whenever direct interaction makes this pane the active one.
    var onBecomeFirstResponder: (() -> Void)?
    let splitTarget = SplitMenuTarget()

    /// Held strongly for the surface's lifetime; ``detach()`` drops it.
    var ghosttyController: TerminalController?
    /// The `/bin/sh -c …` line this surface launched, kept so a live
    /// re-configure can restate it rather than start a second shell.
    var launchCommand = ""
    /// Latest scroll report, so a scrollbar drag can be mapped back onto a row.
    var lastScroll: TerminalScrollPosition?
    /// Ghostty reports the recognized link under the pointer as hover state.
    /// The Command-right-click menu uses it to seed a new browser.
    var hoveredLink: String?

    private let progressBar = KeroTerminalProgressBarView(frame: .zero)
    private var isCapturingHistoryExport = false
    private var capturedHistoryExportPath: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        installProgressBar()
        registerForDraggedTypes([.fileURL])
    }

    /// Entry point for `TerminalBackend.makeSurface(launch:)`. Starts the
    /// emulator immediately; libghostty only spawns the shell once the view is
    /// attached to a window, which `TerminalHostView` guarantees.
    convenience init(launch: TerminalLaunch) {
        self.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        start(launch: launch)
    }

    // MARK: - TerminalBackendSurface

    func clearScreen() {
        performBindingAction("clear_screen")
        // Ask the foreground shell to repaint its prompt at the top.
        performBindingAction("text:\\x0c")
    }

    func scroll(toFraction fraction: Double) {
        guard let lastScroll else { return }
        scrollToRow(UInt(clamping: lastScroll.row(atDragFraction: fraction)))
    }

    func beginFind(_ needle: String) { search(needle) }

    func endFind() { endSearch() }

    func stepFind(forward: Bool) { navigateSearch(forward: forward) }

    func findSelection() { searchSelection() }

    func exportScreenFile() -> String? {
        captureHistoryExportPath(action: "write_screen_file:open,vt")
    }

    func exportScrollbackFile() -> String? {
        captureHistoryExportPath(action: "write_scrollback_file:open,vt")
    }

    override func layout() {
        super.layout()
        let height: CGFloat = 2
        progressBar.frame = CGRect(
            x: 0, y: bounds.height - height,
            width: bounds.width, height: height
        )
    }

    private func installProgressBar() {
        progressBar.isHidden = true
        addSubview(progressBar)
    }

    /// Mirrors Kero's OSC 9;4 indicator: a two-point bar
    /// at the top of the terminal, with error/pause colors and a 15-second
    /// stale-report timeout.
    func applyProgressReport(state: TerminalProgressState, percent: Int?) {
        progressBar.applyReport(state: state, percent: percent)
    }

    /// Uses Ghostty's `open` export action as a synchronous host callback. The
    /// delegate consumes that one URL into this slot instead of opening it.
    private func captureHistoryExportPath(action: String) -> String? {
        guard !isCapturingHistoryExport else { return nil }
        isCapturingHistoryExport = true
        capturedHistoryExportPath = nil
        defer {
            isCapturingHistoryExport = false
            capturedHistoryExportPath = nil
        }
        guard performBindingAction(action) else { return nil }
        return capturedHistoryExportPath
    }

    func consumeHistoryExportURL(_ url: String, kind: TerminalOpenURLKind) -> Bool {
        guard isCapturingHistoryExport else { return false }
        guard case .text = kind else { return false }
        capturedHistoryExportPath = url
        return true
    }

    /// The terminal is effectively focused only while Kero itself is active,
    /// its window is key, and this exact surface owns the first responder.
    var hasEffectiveTerminalFocus: Bool {
        NSApp.isActive && window?.isKeyWindow == true && window?.firstResponder === self
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onBecomeFirstResponder?() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // This view is long-lived and reparented as panes split. Resign while
        // the old window still owns us so Ghostty receives FocusOut and draws
        // an inactive cursor instead of retaining stale focus state.
        if newWindow == nil, let window, window.firstResponder === self {
            window.makeFirstResponder(nil)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func mouseDown(with event: NSEvent) {
        focusForInteraction()
        super.mouseDown(with: event)
    }

    private func focusForInteraction() {
        if window?.firstResponder === self {
            onBecomeFirstResponder?()
        } else {
            window?.makeFirstResponder(self)
        }
    }

    // MARK: - Context menu

    /// Kero consistently reserves right-click for its terminal/pane menu. This
    /// matches Kero's existing UI, including focusing before Paste.
    override func rightMouseDown(with event: NSEvent) {
        focusForInteraction()
        NSMenu.popUpContextMenu(
            contextMenu(initialURL: browserInitialURL(for: event)),
            with: event,
            for: self
        )
    }

    override func rightMouseUp(with event: NSEvent) {}

    override func menu(for event: NSEvent) -> NSMenu? {
        focusForInteraction()
        return contextMenu(initialURL: browserInitialURL(for: event))
    }

    private func browserInitialURL(for event: NSEvent) -> String? {
        event.modifierFlags.contains(.command) ? hoveredLink : nil
    }

    private func contextMenu(initialURL: String?) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(contextItem(String(localized: "Copy"), #selector(copy(_:))))
        menu.addItem(contextItem(String(localized: "Paste"), #selector(NSText.paste(_:))))
        menu.addItem(.separator())
        menu.addItem(contextItem(String(localized: "Select All"), #selector(selectAll(_:))))
        menu.addItem(.separator())
        for item in splitTarget.browserMenuItems(initialURL: initialURL) {
            menu.addItem(item)
        }
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

    /// Inserts dropped absolute paths, shell-escaped and space-separated, at
    /// the active prompt exactly as a paste would.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = fileURLs(sender), !urls.isEmpty else { return false }
        focusForInteraction()
        let text = urls.map { Self.shellToken(for: $0.path) }.joined(separator: " ")
        sendText(text + " ")
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

    private static func shellToken(for path: String) -> String {
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/")
        if !path.isEmpty, path.allSatisfy({ safe.contains($0) }) {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Layer-backed progress indicator used for OSC 9;4 reports. It deliberately
/// ignores hit testing so terminal selection and clicks pass through it.
final class KeroTerminalProgressBarView: NSView {
    private let trackLayer = CALayer()
    private let barLayer = CALayer()
    private let indeterminateAnimationKey = "keroTerminalProgressIndeterminate"

    private var state: TerminalProgressState = .remove
    private var progress: Int?
    private var lastProgressValue: Int?
    private var reportTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        layer?.masksToBounds = true
        trackLayer.isHidden = true
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(barLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        reportTimer?.invalidate()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        updateForCurrentState(animated: false)
    }

    func applyReport(state: TerminalProgressState, percent: Int?) {
        if case .remove = state {
            clearReport()
            return
        }

        let resolved: Int?
        switch state {
        case .remove:
            resolved = nil
        case .set:
            resolved = percent ?? 0
        case .error:
            resolved = percent ?? lastProgressValue
        case .indeterminate:
            resolved = nil
        case .pause:
            resolved = percent ?? lastProgressValue ?? 100
        }
        let clamped = resolved.map { min(max($0, 0), 100) }
        if let clamped {
            lastProgressValue = clamped
        }

        let displayProgress: Int?
        if case .indeterminate = state {
            displayProgress = nil
        } else {
            displayProgress = clamped
        }
        apply(state: state, progress: displayProgress)
        reportTimer?.invalidate()
        reportTimer = Timer.scheduledTimer(
            withTimeInterval: 15, repeats: false
        ) { [weak self] _ in
            self?.clearReport()
        }
    }

    private func clearReport() {
        reportTimer?.invalidate()
        reportTimer = nil
        lastProgressValue = nil
        apply(state: .remove, progress: nil)
    }

    private func apply(state: TerminalProgressState, progress: Int?) {
        self.state = state
        self.progress = progress

        if case .remove = state {
            isHidden = true
            stopIndeterminateAnimation()
            return
        }

        isHidden = false
        let color: NSColor
        switch state {
        case .error:
            color = .systemRed
        case .pause:
            color = .systemOrange
        default:
            color = .controlAccentColor
        }
        barLayer.backgroundColor = color.cgColor
        trackLayer.backgroundColor = color.withAlphaComponent(0.3).cgColor
        updateForCurrentState(animated: true)
    }

    private func updateForCurrentState(animated: Bool) {
        guard !isHidden else { return }
        trackLayer.frame = bounds
        if let progress {
            updateDeterminate(progress: progress, animated: animated)
        } else {
            updateIndeterminate()
        }
    }

    private func updateDeterminate(progress: Int, animated: Bool) {
        trackLayer.isHidden = true
        stopIndeterminateAnimation()
        let width = bounds.width * CGFloat(progress) / 100
        let target = CGRect(x: 0, y: 0, width: width, height: bounds.height)

        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.2)
            CATransaction.setAnimationTimingFunction(
                CAMediaTimingFunction(name: .easeInEaseOut)
            )
        } else {
            CATransaction.setDisableActions(true)
        }
        barLayer.frame = target
        CATransaction.commit()
    }

    private func updateIndeterminate() {
        trackLayer.isHidden = false
        let width = bounds.width * 0.25
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barLayer.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        CATransaction.commit()

        guard width > 0, bounds.width > width else {
            stopIndeterminateAnimation()
            return
        }

        stopIndeterminateAnimation()
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = width / 2
        animation.toValue = bounds.width - width / 2
        animation.duration = 1.2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        barLayer.add(animation, forKey: indeterminateAnimationKey)
    }

    private func stopIndeterminateAnimation() {
        barLayer.removeAnimation(forKey: indeterminateAnimationKey)
    }
}

/// Target for pane-split context-menu items, kept separate from terminal menu
/// validation so these actions remain enabled even when there is no selection.
final class SplitMenuTarget: NSObject {
    var onSplit: ((PaneDropEdge) -> Void)?
    var onNewBrowserTab: ((String?) -> Void)?
    var onNewBrowserPane: ((String?) -> Void)?

    func browserMenuItems(initialURL: String? = nil) -> [NSMenuItem] {
        let tabItem = item(
            String(localized: "New Browser Tab"),
            #selector(newBrowserTab(_:))
        )
        tabItem.representedObject = initialURL
        let paneItem = item(
            String(localized: "New Browser Pane"),
            #selector(newBrowserPane(_:))
        )
        paneItem.representedObject = initialURL
        return [tabItem, paneItem]
    }

    func menuItems() -> [NSMenuItem] {
        [
            item(String(localized: "Split Right"), #selector(splitRight)),
            item(String(localized: "Split Left"), #selector(splitLeft)),
            item(String(localized: "Split Up"), #selector(splitUp)),
            item(String(localized: "Split Down"), #selector(splitDown)),
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
    @objc private func newBrowserTab(_ sender: NSMenuItem) {
        onNewBrowserTab?(sender.representedObject as? String)
    }

    @objc private func newBrowserPane(_ sender: NSMenuItem) {
        onNewBrowserPane?(sender.representedObject as? String)
    }
}
