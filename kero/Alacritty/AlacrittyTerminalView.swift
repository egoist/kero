//
//  AlacrittyTerminalView.swift
//  kero
//

import AppKit
import Darwin
import GhosttyTheme
import Metal
import QuartzCore

/// Kero's Alacritty backend: a `TerminalBackendSurface` drawn with CoreText on
/// top of the `alacritty_terminal` crate.
///
/// The crate is emulation only — it has no renderer — so everything visible
/// here is Kero's: cell layout, glyph drawing, the cursor, selection, and the
/// key encodings in `AlacrittyKeyMap`. State lives in Rust behind the handle;
/// this view snapshots the visible grid each time it draws.
final class AlacrittyTerminalView: NSView, TerminalBackendSurface, NSUserInterfaceValidations {
    weak var events: (any TerminalBackendEvents)?
    var onBecomeFirstResponder: (() -> Void)?
    let splitTarget = SplitMenuTarget()

    /// Matches the window padding Kero's Ghostty panes use, so a pane looks
    /// the same whichever backend drew it.
    private static let padding = CGPoint(x: 10, y: 8)
    private static let scrollbackLines = 10_000

    private var handle: OpaquePointer?
    private let token = AlacrittyRegistry.shared.nextToken()
    private var metrics: AlacrittyMetrics
    private var gridSize = (columns: 0, rows: 0)
    private var markedText = ""
    private var isSurfaceVisible = true

    /// Fractional scroll accumulator, so a trackpad's sub-line deltas add up
    /// to a row instead of being discarded.
    private var scrollAccumulator: CGFloat = 0
    private var selectionAnchor: (line: Int, column: Int)?
    private let findState = AlacrittyFind()

    /// `alacritty_terminal` does not implement OSC 7, so nothing pushes the
    /// shell's directory at us the way Ghostty does. The kernel knows it, so
    /// poll for it — this is what keeps the tab label and the Info panel
    /// following a `cd`.
    private var directoryTimer: Timer?
    private var lastReportedDirectory: String?

    /// Shared across every pane: one device and one shader library is enough,
    /// and a per-pane device would duplicate the glyph atlas too.
    private static let sharedDevice = MTLCreateSystemDefaultDevice()
    private let metalDevice = AlacrittyTerminalView.sharedDevice
    private var renderScheduled = false
    private lazy var metalRenderer: TerminalMetalRenderer? = {
        guard let metalDevice else {
            NSLog("kero: no Metal device; the Alacritty backend cannot draw")
            return nil
        }
        return TerminalMetalRenderer(device: metalDevice)
    }()

    override init(frame frameRect: NSRect) {
        metrics = AlacrittyMetrics(
            family: AppSettings.shared.fontFamily,
            size: CGFloat(AppSettings.shared.fontSize)
        )
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        registerForDraggedTypes([.fileURL])
        AlacrittyRegistry.shared.register(self, for: token)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    convenience init(launch: TerminalLaunch) {
        self.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        start(launch: launch)
    }

    deinit {
        directoryTimer?.invalidate()
        AlacrittyRegistry.shared.unregister(token)
        if let handle { kero_alacritty_free(handle) }
    }

    // MARK: - Lifecycle

    private func start(launch: TerminalLaunch) {
        let size = gridSize(for: bounds.size)
        gridSize = size
        var theme = AlacrittyTheme.current()

        handle = launch.withCConfig(
            columns: UInt16(size.columns),
            rows: UInt16(size.rows),
            cellWidth: UInt16(metrics.cellWidth.rounded()),
            cellHeight: UInt16(metrics.cellHeight.rounded()),
            scrollbackLines: Self.scrollbackLines
        ) { config in
            withUnsafePointer(to: &theme) { themePointer in
                kero_alacritty_new(
                    config,
                    themePointer,
                    alacrittyEventCallback,
                    UnsafeMutableRawPointer(bitPattern: UInt(token))
                )
            }
        }

        if handle == nil {
            NSLog("kero: failed to start the Alacritty backend for \(launch.program)")
            return
        }
        startDirectoryPolling()
    }

    /// A second is well under the time it takes to notice a stale tab label,
    /// and `proc_pidinfo` on one pid is cheap enough to ignore.
    private func startDirectoryPolling() {
        directoryTimer?.invalidate()
        directoryTimer = Timer.scheduledTimer(
            withTimeInterval: 1, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportWorkingDirectory() }
        }
    }

    private func reportWorkingDirectory() {
        guard isSurfaceVisible, let handle else { return }
        // The foreground job's directory, falling back to the shell's — a
        // long-running command should not blank the label.
        let pid = kero_alacritty_foreground_pid(handle)
        guard let path = processWorkingDirectory(pid: pid)
            ?? processWorkingDirectory(pid: kero_alacritty_child_pid(handle))
        else { return }
        guard path != lastReportedDirectory else { return }
        lastReportedDirectory = path
        events?.terminalDidChangeWorkingDirectory(path)
    }

    func detach() {
        directoryTimer?.invalidate()
        directoryTimer = nil
        guard let handle else { return }
        self.handle = nil
        kero_alacritty_free(handle)
    }

    func setSurfaceVisible(_ visible: Bool) {
        // Nothing to release: this backend holds no GPU buffers, only the
        // grid, so a parked pane costs the same either way. The flag stops
        // wakeups from scheduling redraws nothing will composite.
        isSurfaceVisible = visible
    }

    func applyAppearance() {
        metrics = AlacrittyMetrics(
            family: AppSettings.shared.fontFamily,
            size: CGFloat(AppSettings.shared.fontSize)
        )
        var theme = AlacrittyTheme.current()
        if let handle {
            withUnsafePointer(to: &theme) { kero_alacritty_set_theme(handle, $0) }
        }
        // A new cell size means a different column count.
        synchronizeGridSize()
        scheduleRender()
    }

    var foregroundPid: pid_t? {
        guard let handle else { return nil }
        let pid = kero_alacritty_foreground_pid(handle)
        return pid > 0 ? pid : nil
    }

    // MARK: - Geometry

    private func gridSize(for size: CGSize) -> (columns: Int, rows: Int) {
        let usableWidth = size.width - Self.padding.x * 2
        let usableHeight = size.height - Self.padding.y * 2
        return (
            columns: max(1, Int(usableWidth / metrics.cellWidth)),
            rows: max(1, Int(usableHeight / metrics.cellHeight))
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        synchronizeGridSize()
    }

    /// Pushes the current geometry down to the emulator, which resizes the
    /// grid and sends SIGWINCH. No-op when nothing changed, so a layout pass
    /// does not disturb a running TUI.
    private func synchronizeGridSize() {
        guard let handle else { return }
        let size = gridSize(for: bounds.size)
        guard size != gridSize else { return }
        gridSize = size
        kero_alacritty_resize(
            handle,
            UInt16(size.columns), UInt16(size.rows),
            UInt16(metrics.cellWidth.rounded()), UInt16(metrics.cellHeight.rounded())
        )
        scheduleRender()
    }

    override var isFlipped: Bool { false }

    override var isOpaque: Bool { true }

    // MARK: - Drawing

    /// Metal draws into a `CAMetalLayer` rather than the view's context, so
    /// this view has no `draw(_:)`. `needsDisplay` still drives redraws —
    /// AppKit coalesces it per run-loop turn, which is exactly the batching a
    /// burst of PTY output wants.
    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = metalDevice
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        // Resize should not stretch the previous frame while the grid catches
        // up; redraw against the new size instead.
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.needsDisplayOnBoundsChange = true
        return layer
    }

    /// Coalesces a burst of PTY wakeups into one frame per run-loop turn.
    ///
    /// AppKit's layer-display cycle is not used: it expects to draw into the
    /// layer's backing store, which a `CAMetalLayer` does not have, so a
    /// Metal view drives its own redraws. This is what `needsDisplay` did on
    /// the CoreText path.
    private func scheduleRender() {
        guard !renderScheduled, isSurfaceVisible else { return }
        renderScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            guard let self else { return }
            renderScheduled = false
            renderFrame()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // A move between displays changes the backing scale, which invalidates
        // every rasterized glyph.
        guard let scale = window?.backingScaleFactor else { return }
        (self.layer as? CAMetalLayer)?.contentsScale = scale
        scheduleRender()
    }

    private func renderFrame() {
        guard let handle,
              let metalLayer = layer as? CAMetalLayer,
              let renderer = metalRenderer
        else { return }

        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        metalLayer.drawableSize = CGSize(
            width: size.width * scale, height: size.height * scale
        )
        guard let drawable = metalLayer.nextDrawable() else { return }

        var snapshot = KeroSnapshot()
        kero_alacritty_snapshot(handle, &snapshot)
        renderer.render(
            snapshot: snapshot,
            metrics: metrics,
            padding: Self.padding,
            scale: scale,
            in: drawable,
            viewportSize: size
        )
    }

    /// Feeds Kero's overlay scrollbar.
    ///
    /// Deliberately not called from `draw(_:)`: the session republishes into
    /// SwiftUI from here, and mutating view state inside a draw pass makes
    /// AppKit abandon it part-way, leaving stale rows on screen.
    private func reportScroll() {
        guard let handle else { return }
        var snapshot = KeroSnapshot()
        kero_alacritty_snapshot(handle, &snapshot)

        let total = UInt64(snapshot.total_lines)
        let viewport = UInt64(snapshot.screen_lines)
        // `display_offset` counts up as the viewport moves back through the
        // scrollback; Kero's scrollbar measures down from the oldest row.
        let scrolledBack = UInt64(snapshot.display_offset)
        let top = total > viewport
            ? (total - viewport) - min(scrolledBack, total - viewport) : 0
        let position = TerminalScrollPosition(
            totalRows: total, viewportRows: viewport, topRow: top
        )
        events?.terminalDidScroll(position)
    }

    // MARK: - Events from the PTY thread

    /// Always called on the main thread; `alacrittyEventCallback` bounces.
    func handleEvent(kind: UInt32, payload: Data) {
        switch kind {
        case KERO_EVENT_WAKEUP:
            guard isSurfaceVisible else { return }
            scheduleRender()
            reportScroll()
        case KERO_EVENT_TITLE:
            let title = String(decoding: payload, as: UTF8.self)
            if !title.isEmpty { events?.terminalDidChangeTitle(title) }
        case KERO_EVENT_BELL:
            events?.terminalDidRingBell()
        case KERO_EVENT_EXIT:
            if let handle { kero_alacritty_mark_exited(handle) }
            events?.terminalDidClose(processAlive: false)
        case KERO_EVENT_CLIPBOARD_STORE:
            // OSC 52 copy. Reads are refused in the bridge, so this is the
            // only clipboard traffic a program can generate.
            let text = String(decoding: payload, as: UTF8.self)
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        default:
            break
        }
    }

    // MARK: - TerminalBackendSurface

    func sendText(_ text: String) {
        write(Array(text.utf8))
    }

    func clearScreen() {
        guard let handle else { return }
        kero_alacritty_clear(handle)
        // Ask the foreground shell to repaint its prompt at the top.
        write([0x0c])
        scheduleRender()
    }

    func scroll(toFraction fraction: Double) {
        guard let handle else { return }
        var snapshot = KeroSnapshot()
        kero_alacritty_snapshot(handle, &snapshot)
        let history = snapshot.total_lines > snapshot.screen_lines
            ? snapshot.total_lines - snapshot.screen_lines : 0
        // The scrollbar runs oldest-to-newest; display offset runs the other way.
        let fromTop = Int((Double(history) * fraction).rounded())
        kero_alacritty_scroll_to_offset(handle, history - min(fromTop, history))
        scheduleRender()
    }

    var hasSelection: Bool {
        guard let handle else { return false }
        return kero_alacritty_has_selection(handle)
    }

    var hasEffectiveTerminalFocus: Bool {
        NSApp.isActive && window?.isKeyWindow == true && window?.firstResponder === self
    }

    // MARK: - Find

    func beginFind(_ needle: String) {
        findState.begin(needle: needle, handle: handle, events: events)
        scheduleRender()
    }

    func endFind() {
        findState.end(handle: handle)
        scheduleRender()
    }

    func stepFind(forward: Bool) {
        findState.step(forward: forward, handle: handle, events: events)
        scheduleRender()
    }

    func findSelection() {
        guard let handle, kero_alacritty_has_selection(handle) else { return }
        let needed = kero_alacritty_selection_text(handle, nil, 0)
        guard needed > 0 else { return }
        var buffer = [UInt8](repeating: 0, count: needed)
        let written = buffer.withUnsafeMutableBufferPointer { pointer in
            kero_alacritty_selection_text(handle, pointer.baseAddress, needed)
        }
        guard written > 0 else { return }
        let needle = String(decoding: buffer[..<written], as: UTF8.self)
        events?.terminalDidBeginFind(needle: needle)
        beginFind(needle)
    }

    func exportScreenFile() -> String? {
        exportFile(scrollbackOnly: false)
    }

    func exportScrollbackFile() -> String? {
        exportFile(scrollbackOnly: true)
    }

    /// Writes the buffer to its own directory under the temporary directory,
    /// which is the contract `TerminalHistorySerializer` validates before it
    /// reads. Plain text rather than a styled VT stream: this backend has no
    /// styled export, so a restored session comes back uncolored.
    private func exportFile(scrollbackOnly: Bool) -> String? {
        guard let handle else { return nil }
        let needed = kero_alacritty_buffer_text(handle, scrollbackOnly, nil, 0)
        guard needed > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: needed)
        let written = buffer.withUnsafeMutableBufferPointer { pointer in
            kero_alacritty_buffer_text(handle, scrollbackOnly, pointer.baseAddress, needed)
        }
        guard written > 0 else { return nil }

        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("kero-export-\(UUID().uuidString)", isDirectory: true)
        do {
            try manager.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let file = directory.appendingPathComponent("screen.vt")
            try Data(buffer[..<written]).write(to: file, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return file.path
        } catch {
            try? manager.removeItem(at: directory)
            return nil
        }
    }

    // MARK: - Input

    private func write(_ bytes: [UInt8]) {
        guard let handle, !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { pointer in
            kero_alacritty_write(handle, pointer.baseAddress, pointer.count)
        }
    }

    private var terminalMode: AlacrittyTerminalMode {
        guard let handle else { return [] }
        return AlacrittyTerminalMode(rawValue: kero_alacritty_mode(handle))
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onBecomeFirstResponder?()
            scheduleRender()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        scheduleRender()
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if let bytes = AlacrittyKeyMap.bytes(for: event, mode: terminalMode) {
            write(bytes)
            return
        }
        // Anything left is either IME composition or a key Kero's menus own;
        // the input client below turns the former into text.
        interpretKeyEvents([event])
    }

    override func mouseDown(with event: NSEvent) {
        focusForInteraction()
        guard let handle else { return }
        let point = gridPoint(for: event)
        let kind: UInt32 = switch event.clickCount {
        case 2: 1 // word
        case 3: 2 // line
        default: 0
        }
        selectionAnchor = (point.line, point.column)
        kero_alacritty_selection_start(
            handle, Int32(point.line), point.column, kind, point.rightHalf
        )
        scheduleRender()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let handle, selectionAnchor != nil else { return }
        let point = gridPoint(for: event)
        kero_alacritty_selection_update(
            handle, Int32(point.line), point.column, point.rightHalf
        )
        scheduleRender()
    }

    override func mouseUp(with event: NSEvent) {
        selectionAnchor = nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard let handle else { return }
        // Line-mode events already count rows; pixel-mode ones need the cell
        // height applied before they mean anything.
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / metrics.cellHeight
            : event.scrollingDeltaY
        scrollAccumulator += delta
        let lines = Int(scrollAccumulator)
        guard lines != 0 else { return }
        scrollAccumulator -= CGFloat(lines)
        kero_alacritty_scroll(handle, Int32(lines))
        scheduleRender()
        reportScroll()
    }

    private func gridPoint(for event: NSEvent) -> (line: Int, column: Int, rightHalf: Bool) {
        let local = convert(event.locationInWindow, from: nil)
        let x = local.x - Self.padding.x
        // The view is unflipped, so row 0 is at the top of the content box.
        let y = bounds.maxY - Self.padding.y - local.y
        let exactColumn = x / metrics.cellWidth
        let column = min(max(Int(exactColumn.rounded(.down)), 0), max(gridSize.columns - 1, 0))
        let line = min(max(Int((y / metrics.cellHeight).rounded(.down)), 0), max(gridSize.rows - 1, 0))
        return (line, column, exactColumn - CGFloat(column) > 0.5)
    }

    private func focusForInteraction() {
        if window?.firstResponder === self {
            onBecomeFirstResponder?()
        } else {
            window?.makeFirstResponder(self)
        }
    }

    // MARK: - Editing commands

    @objc func copy(_ sender: Any?) {
        guard let handle else { return }
        let needed = kero_alacritty_selection_text(handle, nil, 0)
        guard needed > 0 else { return }
        var buffer = [UInt8](repeating: 0, count: needed)
        let written = buffer.withUnsafeMutableBufferPointer { pointer in
            kero_alacritty_selection_text(handle, pointer.baseAddress, needed)
        }
        guard written > 0 else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            String(decoding: buffer[..<written], as: UTF8.self), forType: .string
        )
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        write(AlacrittyKeyMap.paste(text, mode: terminalMode))
    }

    override func selectAll(_ sender: Any?) {
        guard let handle else { return }
        kero_alacritty_select_all(handle)
        scheduleRender()
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): hasSelection
        case #selector(paste(_:)): NSPasteboard.general.string(forType: .string) != nil
        default: true
        }
    }

    // MARK: - Context menu

    /// Kero reserves right-click for its terminal/pane menu, matching the
    /// Ghostty backend rather than AppKit's default text menu.
    override func rightMouseDown(with event: NSEvent) {
        focusForInteraction()
        NSMenu.popUpContextMenu(contextMenu(), with: event, for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        focusForInteraction()
        return contextMenu()
    }

    private func contextMenu() -> NSMenu {
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

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender) != nil ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = fileURLs(sender), !urls.isEmpty else { return false }
        focusForInteraction()
        let text = urls.map { AlacrittyTerminalView.shellToken(for: $0.path) }
            .joined(separator: " ")
        sendText(text + " ")
        return true
    }

    private func fileURLs(_ sender: any NSDraggingInfo) -> [URL]? {
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

// MARK: - Text input

/// Enough of `NSTextInputClient` for IME: composition is shown inline at the
/// cursor and only committed text reaches the PTY.
extension AlacrittyTerminalView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        markedText = ""
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        guard !text.isEmpty else { return }
        write(Array(text.utf8))
        scheduleRender()
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        scheduleRender()
    }

    func unmarkText() {
        markedText = ""
        scheduleRender()
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        markedText.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: markedText.utf16.count)
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func attributedSubstring(
        forProposedRange range: NSRange, actualRange: NSRangePointer?
    ) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Places the IME candidate window under the cursor.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let handle, let window else { return .zero }
        var snapshot = KeroSnapshot()
        kero_alacritty_snapshot(handle, &snapshot)
        let column = CGFloat(max(snapshot.cursor_column, 0))
        let line = CGFloat(max(snapshot.cursor_line, 0))
        let local = NSRect(
            x: Self.padding.x + column * metrics.cellWidth,
            y: bounds.maxY - Self.padding.y - (line + 1) * metrics.cellHeight,
            width: metrics.cellWidth,
            height: metrics.cellHeight
        )
        return window.convertToScreen(convert(local, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    override func doCommand(by selector: Selector) {
        // Key encoding is handled in `keyDown`; anything reaching here would
        // otherwise beep.
    }
}

// MARK: - Callback plumbing

/// Delivers PTY-thread callbacks to the right view without ever dereferencing
/// a view pointer off the main thread.
///
/// The context handed to Rust is an integer token, not a pointer, so a surface
/// released while the PTY thread still holds a reference resolves to nothing
/// instead of a dangling object.
final class AlacrittyRegistry: @unchecked Sendable {
    static let shared = AlacrittyRegistry()

    private let lock = NSLock()
    private var next: UInt64 = 1
    private var views: [UInt64: WeakView] = [:]

    private struct WeakView {
        weak var view: AlacrittyTerminalView?
    }

    func nextToken() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let token = next
        next += 1
        return token
    }

    func register(_ view: AlacrittyTerminalView, for token: UInt64) {
        lock.lock()
        views[token] = WeakView(view: view)
        lock.unlock()
    }

    func unregister(_ token: UInt64) {
        lock.lock()
        views.removeValue(forKey: token)
        lock.unlock()
    }

    fileprivate func view(for token: UInt64) -> AlacrittyTerminalView? {
        lock.lock()
        defer { lock.unlock() }
        return views[token]?.view
    }

    fileprivate func deliver(token: UInt64, kind: UInt32, payload: Data) {
        view(for: token)?.handleEvent(kind: kind, payload: payload)
    }
}

/// Called on the PTY thread by the Rust bridge.
private nonisolated func alacrittyEventCallback(
    context: UnsafeMutableRawPointer?,
    kind: UInt32,
    data: UnsafePointer<UInt8>?,
    length: Int
) {
    let token = UInt64(UInt(bitPattern: context))
    guard token != 0 else { return }
    // Copied here: the buffer belongs to Rust and does not outlive this call.
    let payload = (data != nil && length > 0) ? Data(bytes: data!, count: length) : Data()
    DispatchQueue.main.async {
        AlacrittyRegistry.shared.deliver(token: token, kind: kind, payload: payload)
    }
}

// MARK: - Configuration bridging

extension TerminalLaunch {
    /// Builds a `KeroConfig` whose C strings stay alive for the call. Cargo's
    /// side copies everything it needs before returning.
    func withCConfig<T>(
        columns: UInt16,
        rows: UInt16,
        cellWidth: UInt16,
        cellHeight: UInt16,
        scrollbackLines: Int,
        _ body: (UnsafePointer<KeroConfig>) -> T
    ) -> T {
        let programCopy = strdup(program)
        let directoryCopy = strdup(workingDirectory)
        let argumentCopies = arguments.map { strdup($0) }
        let environmentCopies = environment.map { strdup("\($0.key)=\($0.value)") }
        defer {
            free(programCopy)
            free(directoryCopy)
            argumentCopies.forEach { free($0) }
            environmentCopies.forEach { free($0) }
        }

        var argumentPointers = argumentCopies.map { UnsafePointer($0) }
        var environmentPointers = environmentCopies.map { UnsafePointer($0) }

        return argumentPointers.withUnsafeMutableBufferPointer { argv in
            environmentPointers.withUnsafeMutableBufferPointer { envp in
                var config = KeroConfig(
                    shell: programCopy,
                    args: argv.baseAddress,
                    args_len: argv.count,
                    working_directory: directoryCopy,
                    env: envp.baseAddress,
                    env_len: envp.count,
                    columns: columns,
                    rows: rows,
                    cell_width: cellWidth,
                    cell_height: cellHeight,
                    scrollback_lines: scrollbackLines
                )
                return withUnsafePointer(to: &config) { body($0) }
            }
        }
    }
}

// MARK: - Theme bridging

enum AlacrittyTheme {
    /// Kero's active terminal theme in the flat form the bridge resolves
    /// colors against, so Alacritty panes match Ghostty panes exactly.
    static func current() -> KeroTheme {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let definition = Theme.terminal(dark: isDark)

        var theme = KeroTheme()
        withUnsafeMutableBytes(of: &theme.palette) { raw in
            let palette = raw.bindMemory(to: UInt32.self)
            for index in 0..<256 {
                palette[index] = definition.palette[index].flatMap(packed(hex:))
                    ?? defaultPalette(index)
            }
        }
        theme.foreground = packed(color: definition.foregroundNSColor)
        theme.background = packed(color: definition.backgroundNSColor)
        theme.cursor = packed(color: definition.cursorNSColor)
        return theme
    }

    /// The xterm 256-color palette: 16 ANSI colors, a 6×6×6 cube, then a
    /// 24-step ramp. Only used where a theme leaves an index undefined.
    private nonisolated static func defaultPalette(_ index: Int) -> UInt32 {
        switch index {
        case 0..<16:
            let base: [UInt32] = [
                0x000000, 0xcd0000, 0x00cd00, 0xcdcd00, 0x0000ee, 0xcd00cd, 0x00cdcd, 0xe5e5e5,
                0x7f7f7f, 0xff0000, 0x00ff00, 0xffff00, 0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff,
            ]
            return base[index]
        case 16..<232:
            let value = index - 16
            let steps: [UInt32] = [0, 95, 135, 175, 215, 255]
            let red = steps[(value / 36) % 6]
            let green = steps[(value / 6) % 6]
            let blue = steps[value % 6]
            return (red << 16) | (green << 8) | blue
        default:
            let level = UInt32(8 + (index - 232) * 10)
            return (level << 16) | (level << 8) | level
        }
    }

    private nonisolated static func packed(hex: String) -> UInt32? {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return value
    }

    private static func packed(color: NSColor) -> UInt32 {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let red = UInt32((srgb.redComponent * 255).rounded())
        let green = UInt32((srgb.greenComponent * 255).rounded())
        let blue = UInt32((srgb.blueComponent * 255).rounded())
        return (red << 16) | (green << 8) | blue
    }
}
