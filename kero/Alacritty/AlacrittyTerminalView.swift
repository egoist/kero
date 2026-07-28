//
//  AlacrittyTerminalView.swift
//  kero
//

import AppKit
import Darwin
import GhosttyTerminal
import GhosttyTheme
import IOSurface
import Metal
import QuartzCore

/// Kero's Alacritty backend: a `TerminalBackendSurface` rendered with Metal
/// from a CoreText glyph atlas on top of the `alacritty_terminal` crate.
///
/// The crate is emulation only — it has no renderer — so everything visible
/// here is Kero's: cell layout, glyph drawing, the cursor, selection, and the
/// key encodings in `AlacrittyKeyMap`. State lives in Rust behind the handle;
/// this view snapshots the visible grid each time it draws.
final class AlacrittyTerminalView: NSView, TerminalBackendSurface, NSUserInterfaceValidations {
    weak var events: (any TerminalBackendEvents)? {
        didSet { flushPendingEvents() }
    }
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
    private let markedTextField = NSTextField(labelWithString: "")
    private var isSurfaceVisible = false
    /// Covers Metal while a parked surface is moving back into a real pane.
    /// The cover lives above the drawable so the GPU can acquire and present
    /// the first correctly-sized frame before the terminal becomes visible.
    private let presentationCoverLayer = CALayer()
    private var isAwaitingVisibleFrame = true
    private var presentationGeneration: UInt64 = 0
    private var lastPresentedSize: CGSize?
    private var lastPresentedScale: CGFloat?
    /// The last drawable's storage can be shown by an ordinary CALayer while
    /// Kero is inactive. Retaining one frame is much cheaper than keeping the
    /// CAMetalLayer and its full triple-sized drawable pool alive.
    private var lastPresentedSurface: IOSurface?
    private var pendingEvents: [(kind: UInt32, payload: Data)] = []
    private var trackingArea: NSTrackingArea?
    private var reportingMouseButton = false
    private var lastReportedFocus: Bool?
    private var cursorTimer: Timer?
    private var cursorBlinking = false
    private var cursorVisible = true
    private let progressBar = KeroTerminalProgressBarView(frame: .zero)

    /// Fractional scroll accumulator, so a trackpad's sub-line deltas add up
    /// to a row instead of being discarded.
    private var scrollAccumulator: CGFloat = 0
    private var selectionAnchor: (line: Int, column: Int)?
    private let findState = AlacrittyFind()

    /// Process metadata is a fallback until a shell reports OSC 7. It keeps
    /// ordinary local shells useful without integration; once OSC arrives it
    /// wins, since only the shell can report an SSH session's remote path.
    private var directoryTimer: Timer?
    private var lastReportedDirectory: String?
    private var usesOSCWorkingDirectory = false

    /// Shared across every pane: one device and one shader library is enough,
    /// and a per-pane device would duplicate the glyph atlas too.
    private static let sharedDevice = MTLCreateSystemDefaultDevice()
    private let metalDevice = AlacrittyTerminalView.sharedDevice
    private var renderScheduled = false
    /// Forces the next frame regardless of emulator damage. Set for changes
    /// the emulator knows nothing about — a resize, a new theme or font, a
    /// selection drag, focus — since those move pixels without touching a cell.
    private var needsUnconditionalRedraw = true
    private var metalRenderer: TerminalMetalRenderer?
    private var kittyPlacements: [AlacrittyKittyPlacement] = []
    private var kittyImageData: [AlacrittyKittyImageKey: Data] = [:]

    override init(frame frameRect: NSRect) {
        metrics = AlacrittyMetrics(
            family: AppSettings.shared.fontFamily,
            size: CGFloat(AppSettings.shared.fontSize),
            fontThicken: AppSettings.shared.fontThicken
        )
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        registerForDraggedTypes([.fileURL])
        markedTextField.isHidden = true
        markedTextField.isBezeled = false
        markedTextField.drawsBackground = true
        markedTextField.lineBreakMode = .byClipping
        addSubview(markedTextField)
        addSubview(progressBar)
        AlacrittyRegistry.shared.register(self, for: token)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive(_:)),
            name: NSApplication.willResignActiveNotification,
            object: nil
        )
        for name in [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(effectiveFocusChanged(_:)),
                name: name,
                object: nil
            )
        }
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
        cursorTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
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
    }

    /// Directory polling and cursor blinking are useful only for the pane the
    /// user can currently interact with. Leaving them running for parked tabs
    /// or while another app is active prevents the terminal heap and Metal
    /// drawable pages from becoming cold enough for macOS to reclaim.
    private func updateActiveTimers() {
        updateDirectoryPolling()
        updateCursorTimer()
    }

    private var shouldKeepMetalLayerActive: Bool {
        isSurfaceVisible && NSApp.isActive && window?.isKeyWindow == true
    }

    private func updateBackingLayerActivity(forceFrame: Bool = false) {
        if shouldKeepMetalLayerActive {
            let needsMetalLayer = !(layer is CAMetalLayer)
            guard needsMetalLayer || forceFrame else { return }
            if needsMetalLayer {
                lastPresentedSurface = nil
                replaceBackingLayer(with: makeBackingLayer())
            }
            isAwaitingVisibleFrame = true
            setPresentationCoverVisible(true)
            needsUnconditionalRedraw = true
            if !renderFrame(waitUntilCompleted: true) {
                scheduleRender(force: true)
            }
        } else {
            freezeVisibleFrame()
        }
    }

    /// Keep the last submitted terminal image visible behind other apps and
    /// Kero windows, but release the CAMetalLayer drawable pool and renderer.
    /// A CAMetal drawable is IOSurface-backed, and CALayer can display that
    /// same surface directly without copying it through the CPU.
    private func freezeVisibleFrame(cursorHasFocus: Bool? = nil) {
        guard isSurfaceVisible, layer is CAMetalLayer else { return }
        let cursorWasVisible = !cursorBlinking || cursorVisible
        // The last active frame may be the hidden half of a cursor blink.
        // Present the steady inactive cursor before retaining that drawable.
        cursorTimer?.invalidate()
        cursorTimer = nil
        cursorVisible = true
        needsUnconditionalRedraw = true
        let renderedInactive = renderFrame(
            waitUntilCompleted: true,
            cursorHasFocus: cursorHasFocus
        )
        cursorTimer?.invalidate()
        cursorTimer = nil
        cursorVisible = true

        presentationCoverLayer.removeFromSuperlayer()
        let frozenLayer = CALayer()
        frozenLayer.isOpaque = true
        frozenLayer.backgroundColor = Theme.background.cgColor
        frozenLayer.contents = lastPresentedSurface
        frozenLayer.contentsScale = lastPresentedScale
            ?? window?.backingScaleFactor
            ?? 2
        frozenLayer.contentsGravity = .topLeft
        frozenLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        if !renderedInactive, !cursorWasVisible {
            addInactiveCursorOverlay(to: frozenLayer)
        }
        metalRenderer = nil
        replaceBackingLayer(with: frozenLayer)
    }

    /// Re-renders the retained image while Kero or its terminal window is not
    /// focused. A normal scheduled frame cannot update this state because the
    /// inactive terminal is backed by a plain `CALayer`, not a `CAMetalLayer`.
    ///
    /// The Metal layer exists only long enough to produce the new retained
    /// frame, so a background script can remain visibly live without restoring
    /// the idle drawable pool between output events.
    private func refreshFrozenFrame() {
        guard isSurfaceVisible, !(layer is CAMetalLayer) else {
            scheduleRender(force: true)
            return
        }
        replaceBackingLayer(with: makeBackingLayer())
        freezeVisibleFrame(cursorHasFocus: false)
    }

    /// AppKit can revoke CAMetalLayer drawables before focus-loss callbacks
    /// finish. If the retained frame caught the hidden blink phase, draw the
    /// steady cursor as ordinary layers over that frozen IOSurface.
    private func addInactiveCursorOverlay(to frozenLayer: CALayer) {
        guard let handle else { return }
        var snapshot = KeroSnapshot()
        kero_alacritty_snapshot(handle, &snapshot)
        guard snapshot.cursor_line >= 0, snapshot.cursor_column >= 0 else { return }

        let cell = CGRect(
            x: Self.padding.x + CGFloat(snapshot.cursor_column) * metrics.cellWidth,
            y: bounds.maxY - Self.padding.y
                - CGFloat(snapshot.cursor_line + 1) * metrics.cellHeight,
            width: metrics.cellWidth,
            height: metrics.cellHeight
        )
        let frames: [CGRect] = switch snapshot.cursor_shape {
        case 1:
            [CGRect(x: 0, y: 0, width: cell.width, height: 2)]
        case 2:
            [CGRect(x: 0, y: 0, width: 2, height: cell.height)]
        default:
            [
                CGRect(x: 0, y: 0, width: cell.width, height: 1),
                CGRect(x: 0, y: cell.height - 1, width: cell.width, height: 1),
                CGRect(x: 0, y: 0, width: 1, height: cell.height),
                CGRect(x: cell.width - 1, y: 0, width: 1, height: cell.height),
            ]
        }

        let overlay = CALayer()
        overlay.frame = cell
        overlay.contentsScale = frozenLayer.contentsScale
        let color = AlacrittyRenderer.color(snapshot.cursor_color)
        for frame in frames {
            let segment = CALayer()
            segment.frame = frame
            segment.backgroundColor = color
            segment.contentsScale = frozenLayer.contentsScale
            overlay.addSublayer(segment)
        }
        frozenLayer.addSublayer(overlay)
    }

    private func updateDirectoryPolling() {
        let shouldPoll =
            !usesOSCWorkingDirectory
            && isSurfaceVisible && NSApp.isActive && window?.isKeyWindow == true
        guard shouldPoll else {
            directoryTimer?.invalidate()
            directoryTimer = nil
            return
        }
        // A parked or inactive pane may have changed directories since its
        // last poll. Catch it up before waiting for the first timer tick.
        reportWorkingDirectory()
        guard directoryTimer == nil else { return }
        directoryTimer = Timer.scheduledTimer(
            withTimeInterval: 1, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportWorkingDirectory() }
        }
    }

    private func reportWorkingDirectory() {
        guard !usesOSCWorkingDirectory, let handle else { return }
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
        cursorTimer?.invalidate()
        cursorTimer = nil
        guard let handle else { return }
        self.handle = nil
        kero_alacritty_free(handle)
    }

    func setSurfaceVisible(_ visible: Bool) {
        // The flag stops wakeups from scheduling frames nothing will
        // composite; parking also drops renderer-owned GPU allocations below.
        let changed = visible != isSurfaceVisible
        guard changed else {
            if visible { updateFocusReport() }
            return
        }
        isSurfaceVisible = visible
        presentationGeneration &+= 1
        if visible {
            updateBackingLayerActivity(forceFrame: true)
            updateActiveTimers()
            updateFocusReport()
        } else {
            // Drop the glyph atlas and row/instance buffers while parked,
            // matching Ghostty's occluded-surface GPU memory behavior.
            metalRenderer = nil
            // CAMetalLayer retains its current display drawable even after
            // `device` becomes nil. Replace the layer entirely so Core
            // Animation releases that drawable and its pool. A 1800×1600
            // BGRA drawable is ~11.5 MiB, so one per parked tab dominates
            // multi-tab memory.
            presentationCoverLayer.removeFromSuperlayer()
            let parkedLayer = CALayer()
            parkedLayer.isOpaque = true
            parkedLayer.backgroundColor = Theme.background.cgColor
            parkedLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            replaceBackingLayer(with: parkedLayer)
            lastPresentedSize = nil
            lastPresentedScale = nil
            lastPresentedSurface = nil
            isAwaitingVisibleFrame = true
            cursorTimer?.invalidate()
            cursorTimer = nil
            cursorBlinking = false
            cursorVisible = true
            directoryTimer?.invalidate()
            directoryTimer = nil
        }
    }

    func applyAppearance() {
        metrics = AlacrittyMetrics(
            family: AppSettings.shared.fontFamily,
            size: CGFloat(AppSettings.shared.fontSize),
            fontThicken: AppSettings.shared.fontThicken
        )
        presentationCoverLayer.backgroundColor = Theme.background.cgColor
        var theme = AlacrittyTheme.current()
        if let handle {
            withUnsafePointer(to: &theme) { kero_alacritty_set_theme(handle, $0) }
        }
        // A new cell size means a different column count.
        synchronizeGridSize()
        refreshFrozenFrame()
    }

    var foregroundPid: pid_t? {
        guard let handle else { return nil }
        let pid = kero_alacritty_foreground_pid(handle)
        return pid > 0 ? pid : nil
    }

    // MARK: - Geometry

    override func layout() {
        super.layout()
        let height: CGFloat = 2
        progressBar.frame = CGRect(
            x: 0, y: bounds.height - height,
            width: bounds.width, height: height
        )
    }

    private func gridSize(for size: CGSize) -> (columns: Int, rows: Int) {
        let usableWidth = size.width - Self.padding.x * 2
        let usableHeight = size.height - Self.padding.y * 2
        return (
            columns: max(1, Int(usableWidth / metrics.cellWidth)),
            rows: max(1, Int(usableHeight / metrics.cellHeight))
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        if changed, isSurfaceVisible, isAwaitingVisibleFrame {
            // Invalidate a startup-sized frame that completed while Auto
            // Layout was still moving this surface out of parking.
            presentationGeneration &+= 1
            setPresentationCoverVisible(true)
        }
        super.setFrameSize(newSize)
        synchronizeGridSize()
        // Padding remainder changes even when the number of rows/columns does
        // not, so a sub-cell resize still needs one host-side frame.
        if changed { scheduleRender(force: true) }
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
        scheduleRender(force: true)
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
        // Terminal frames are cheap enough to keep up with the display link;
        // a third full-window drawable only adds one pane-sized IOSurface
        // (~15 MiB on a large Retina window) without improving throughput.
        layer.maximumDrawableCount = 2
        // Core Animation's default `.resize` gravity can stretch a startup-
        // sized drawable across the real pane for a few frames on first
        // attachment, making restored text flash at a much larger size. Keep
        // any previous drawable pixel-accurate while the correct frame arrives.
        layer.contentsGravity = .topLeft
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.needsDisplayOnBoundsChange = true
        presentationCoverLayer.backgroundColor = Theme.background.cgColor
        presentationCoverLayer.frame = layer.bounds
        presentationCoverLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        presentationCoverLayer.isHidden = false
        layer.addSublayer(presentationCoverLayer)
        return layer
    }

    private func replaceBackingLayer(with newLayer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        newLayer.frame = bounds
        layer = newLayer
        CATransaction.commit()
    }

    /// Coalesces a burst of PTY wakeups into one frame per run-loop turn.
    ///
    /// AppKit's layer-display cycle is not used: it expects to draw into the
    /// layer's backing store, which a `CAMetalLayer` does not have, so a
    /// Metal view drives its own redraws. This is what `needsDisplay` did on
    /// the CoreText path.
    private func scheduleRender(force: Bool = false) {
        if force { needsUnconditionalRedraw = true }
        guard !renderScheduled, isSurfaceVisible else { return }
        renderScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            guard let self else { return }
            renderScheduled = false
            if layer is CAMetalLayer {
                renderFrame()
            } else {
                refreshFrozenFrame()
            }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // A move between displays changes the backing scale, which invalidates
        // every rasterized glyph.
        guard let scale = window?.backingScaleFactor else { return }
        (self.layer as? CAMetalLayer)?.contentsScale = scale
        scheduleRender(force: true)
    }

    @discardableResult
    private func renderFrame(
        waitUntilCompleted: Bool = false,
        cursorHasFocus: Bool? = nil
    ) -> Bool {
        guard let handle, let metalLayer = layer as? CAMetalLayer else { return false }
        // Full-screen TUIs use DEC mode 2026 to replace a frame atomically.
        // A host cursor tick must not expose the cleared intermediate grid.
        if !waitUntilCompleted, kero_alacritty_synchronized_update(handle) {
            return true
        }
        if metalRenderer == nil, let metalDevice {
            metalRenderer = TerminalMetalRenderer(device: metalDevice)
        }
        guard let renderer = metalRenderer else {
            NSLog("kero: no Metal device; the Alacritty backend cannot draw")
            return false
        }

        // A wakeup means bytes arrived, not that the grid moved. Ask the
        // emulator whether anything actually changed before paying for a
        // snapshot and a full instance rebuild — a heartbeat or a cursor
        // query would otherwise cost a whole frame.
        var damage = KeroDamage()
        kero_alacritty_take_damage(handle, &damage)

        // nil means "rebuild every row": a full-damage frame, or a host-side
        // change — resize, theme, selection, focus — that the emulator never
        // saw and so never reported as damage.
        var dirtyRows: [Int]?
        if needsUnconditionalRedraw || damage.kind == KERO_DAMAGE_FULL {
            dirtyRows = nil
        } else if damage.kind == KERO_DAMAGE_PARTIAL, let rows = damage.rows {
            dirtyRows = (0..<damage.rows_len).map { Int(rows[$0]) }
        } else {
            AlacrittyRenderStats.shared.skipped()
            return true
        }
        needsUnconditionalRedraw = false
        let renderStart = CFAbsoluteTimeGetCurrent()
        defer { AlacrittyRenderStats.shared.frame(seconds: CFAbsoluteTimeGetCurrent() - renderStart) }

        let scale = window?.backingScaleFactor ?? 2
        metalLayer.device = metalDevice
        metalLayer.contentsScale = scale
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return false }
        metalLayer.drawableSize = CGSize(
            width: size.width * scale, height: size.height * scale
        )
        guard let drawable = metalLayer.nextDrawable() else { return false }
        // Keep the IOSurface before render schedules this drawable for
        // presentation. Accessing drawable.texture afterward is invalid.
        let drawableSurface = drawable.texture.iosurface

        var snapshot = KeroSnapshot()
        kero_alacritty_snapshot(handle, &snapshot)
        updateKittyGraphics(handle: handle)
        updateMarkedTextOverlay(snapshot: snapshot)
        updateCursorBlinking(snapshot.cursor_blinking)
        if cursorBlinking, !cursorVisible {
            snapshot.cursor_line = -1
            snapshot.cursor_column = -1
        } else if !(cursorHasFocus ?? hasEffectiveTerminalFocus),
            snapshot.cursor_shape == 0
        {
            snapshot.cursor_shape = 3
        }
        let generation = presentationGeneration
        let presentationToken = token
        let tracksPresentedGeometry =
            !waitUntilCompleted
            && (isAwaitingVisibleFrame
                || lastPresentedSize != size
                || lastPresentedScale != scale)
        let onPresented: (@Sendable () -> Void)?
        if tracksPresentedGeometry {
            onPresented = {
                DispatchQueue.main.async {
                    AlacrittyRegistry.shared.view(for: presentationToken)?.didPresentFrame(
                        generation: generation,
                        size: size,
                        scale: scale
                    )
                }
            }
        } else {
            onPresented = nil
        }
        let submitted = renderer.render(
            snapshot: snapshot,
            kittyPlacements: kittyPlacements,
            metrics: metrics,
            padding: Self.padding,
            scale: scale,
            dirtyRows: dirtyRows,
            in: drawable,
            viewportSize: size,
            onPresented: onPresented,
            waitUntilCompleted: waitUntilCompleted
        )
        if submitted {
            lastPresentedSurface = drawableSurface
        }
        if submitted, waitUntilCompleted {
            lastPresentedSize = size
            lastPresentedScale = scale
            isAwaitingVisibleFrame = false
            setPresentationCoverVisible(false)
        }
        AlacrittyRenderStats.shared.rebuilt(rows: dirtyRows?.count ?? snapshot.rows)
        return submitted
    }

    private func updateKittyGraphics(handle: OpaquePointer) {
        var snapshot = KeroKittySnapshot()
        kero_alacritty_kitty_snapshot(handle, &snapshot)
        guard snapshot.placements_len > 0, let placements = snapshot.placements else {
            kittyPlacements = []
            kittyImageData = [:]
            return
        }

        let buffer = UnsafeBufferPointer(
            start: placements,
            count: Int(snapshot.placements_len)
        )
        var activeImageKeys = Set<AlacrittyKittyImageKey>()
        kittyPlacements = buffer.compactMap { placement in
            let key = AlacrittyKittyImageKey(
                imageID: placement.image_id,
                generation: placement.image_generation
            )
            activeImageKeys.insert(key)
            let png: Data
            if let cached = kittyImageData[key] {
                png = cached
            } else if placement.png_len > 0, let bytes = placement.png {
                png = Data(bytes: bytes, count: Int(placement.png_len))
                kittyImageData[key] = png
            } else {
                return nil
            }
            return AlacrittyKittyPlacement(placement, png: png)
        }
        kittyImageData = kittyImageData.filter { activeImageKeys.contains($0.key) }
    }

    private func didPresentFrame(
        generation: UInt64,
        size: CGSize,
        scale: CGFloat
    ) {
        guard generation == presentationGeneration else { return }
        lastPresentedSize = size
        lastPresentedScale = scale
        guard isAwaitingVisibleFrame else { return }
        let currentScale = window?.backingScaleFactor ?? 2
        guard isSurfaceVisible,
              bounds.size == size,
              currentScale == scale
        else {
            // Geometry changed after this command buffer was submitted. Its
            // drawable stays behind the cover; render another at the new size.
            if isSurfaceVisible { scheduleRender(force: true) }
            return
        }
        isAwaitingVisibleFrame = false
        setPresentationCoverVisible(false)
    }

    private func setPresentationCoverVisible(_ visible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        presentationCoverLayer.isHidden = !visible
        CATransaction.commit()
    }

    private func updateMarkedTextOverlay(snapshot: KeroSnapshot) {
        guard !markedText.isEmpty,
              snapshot.cursor_line >= 0,
              snapshot.cursor_column >= 0
        else {
            markedTextField.isHidden = true
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: metrics.regular,
            .foregroundColor: Theme.terminal(
                dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ).foregroundNSColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        let attributed = NSAttributedString(string: markedText, attributes: attributes)
        markedTextField.attributedStringValue = attributed
        markedTextField.backgroundColor = Theme.terminal(
            dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ).backgroundNSColor
        let width = max(
            attributed.size().width.rounded(.up) + 2,
            metrics.cellWidth
        )
        markedTextField.frame = NSRect(
            x: Self.padding.x + CGFloat(snapshot.cursor_column) * metrics.cellWidth,
            y: bounds.height - Self.padding.y
                - CGFloat(snapshot.cursor_line + 1) * metrics.cellHeight,
            width: width,
            height: metrics.cellHeight
        )
        markedTextField.isHidden = false
    }

    private func updateCursorBlinking(_ blinking: Bool) {
        if blinking != cursorBlinking {
            cursorBlinking = blinking
            cursorVisible = true
        }
        updateCursorTimer()
    }

    private func updateCursorTimer() {
        let shouldBlink =
            cursorBlinking && isSurfaceVisible && hasEffectiveTerminalFocus
        guard shouldBlink else {
            cursorTimer?.invalidate()
            cursorTimer = nil
            cursorVisible = true
            return
        }
        guard cursorTimer == nil else { return }
        cursorTimer = Timer.scheduledTimer(
            withTimeInterval: 0.5, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.cursorBlinking else { return }
                self.cursorVisible.toggle()
                self.scheduleRender(force: true)
            }
        }
    }

    private func resetCursorBlink() {
        guard cursorBlinking else { return }
        cursorTimer?.invalidate()
        cursorTimer = nil
        cursorVisible = true
        updateCursorTimer()
        scheduleRender(force: true)
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
        if events == nil,
           kind == KERO_EVENT_TITLE
            || kind == KERO_EVENT_BELL
            || kind == KERO_EVENT_EXIT
            || kind == KERO_EVENT_CLIPBOARD_LOAD
            || kind == KERO_EVENT_WORKING_DIRECTORY
            || kind == KERO_EVENT_NOTIFICATION
            || kind == KERO_EVENT_SHELL_PROMPT_START
            || kind == KERO_EVENT_SHELL_COMMAND_START
            || kind == KERO_EVENT_SHELL_COMMAND_EXECUTING
            || kind == KERO_EVENT_SHELL_COMMAND_FINISHED {
            if pendingEvents.count < 64 {
                pendingEvents.append((kind, payload))
            }
            return
        }

        switch kind {
        case KERO_EVENT_WAKEUP:
            updateFocusReport()
            // Output must not restart the host cursor timer. Animated TUIs can
            // wake the PTY many times per second even while the user is idle.
            if isSurfaceVisible {
                scheduleRender()
                reportScroll()
            }
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
        case KERO_EVENT_CLIPBOARD_LOAD:
            guard payload.count == MemoryLayout<UInt64>.size else { return }
            var requestID: UInt64 = 0
            _ = withUnsafeMutableBytes(of: &requestID) { bytes in
                payload.copyBytes(to: bytes)
            }
            requestID = UInt64(littleEndian: requestID)
            let contents = Self.pasteboardString(from: .general) ?? ""
            events?.terminalDidRequestClipboardConfirmation(
                TerminalClipboardRequest(kind: .programRead, contents: contents) {
                    [weak self] approved in
                    self?.resolveClipboard(
                        requestID: requestID,
                        contents: contents,
                        approved: approved
                    )
                }
            )
        case KERO_EVENT_WORKING_DIRECTORY:
            let path = String(decoding: payload, as: UTF8.self)
            guard !path.isEmpty else { return }
            usesOSCWorkingDirectory = true
            directoryTimer?.invalidate()
            directoryTimer = nil
            guard path != lastReportedDirectory else { return }
            lastReportedDirectory = path
            events?.terminalDidChangeWorkingDirectory(path)
        case KERO_EVENT_PROGRESS:
            guard payload.count == 3,
                  let state = Self.progressState(rawValue: payload[0])
            else { return }
            let percent = payload[2] == 0 ? nil : Int(payload[1])
            progressBar.applyReport(state: state, percent: percent)
        case KERO_EVENT_NOTIFICATION:
            let message = String(decoding: payload, as: UTF8.self)
            guard !message.isEmpty else { return }
            events?.terminalDidRequestDesktopNotification(title: "", body: message)
        case KERO_EVENT_SHELL_PROMPT_START:
            events?.terminalDidReportShellIntegration(.promptStart)
        case KERO_EVENT_SHELL_COMMAND_START:
            events?.terminalDidReportShellIntegration(.commandStart)
        case KERO_EVENT_SHELL_COMMAND_EXECUTING:
            events?.terminalDidReportShellIntegration(.commandExecuting)
        case KERO_EVENT_SHELL_COMMAND_FINISHED:
            guard payload.count == MemoryLayout<Int32>.size else { return }
            var rawExitCode: Int32 = -1
            _ = withUnsafeMutableBytes(of: &rawExitCode) { bytes in
                payload.copyBytes(to: bytes)
            }
            let exitCode = Int32(littleEndian: rawExitCode)
            events?.terminalDidReportShellIntegration(
                .commandFinished(
                    exitCode: exitCode < 0 ? nil : Int(exitCode),
                    durationNanos: nil
                )
            )
        default:
            break
        }
    }

    private static func progressState(rawValue: UInt8) -> TerminalProgressState? {
        switch rawValue {
        case 0: .remove
        case 1: .set
        case 2: .error
        case 3: .indeterminate
        case 4: .pause
        default: nil
        }
    }

    private func flushPendingEvents() {
        guard events != nil, !pendingEvents.isEmpty else { return }
        let queued = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        for event in queued {
            handleEvent(kind: event.kind, payload: event.payload)
        }
    }

    private func resolveClipboard(
        requestID: UInt64, contents: String, approved: Bool
    ) {
        guard let handle else { return }
        let bytes = Array(contents.utf8)
        bytes.withUnsafeBufferPointer { pointer in
            kero_alacritty_resolve_clipboard(
                handle, requestID, pointer.baseAddress, pointer.count, approved
            )
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
        scheduleRender(force: true)
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
        scheduleRender(force: true)
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
        scheduleRender(force: true)
    }

    func endFind() {
        findState.end(handle: handle)
        scheduleRender(force: true)
    }

    func stepFind(forward: Bool) {
        findState.step(forward: forward, handle: handle, events: events)
        scheduleRender(force: true)
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

    /// Writes the bridge's styled VT stream to its own directory under the
    /// temporary directory, which is the contract `TerminalHistorySerializer`
    /// validates before it reads.
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
        resetCursorBlink()
    }

    private func writeControl(_ bytes: [UInt8]) {
        guard let handle, !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { pointer in
            kero_alacritty_write_control(handle, pointer.baseAddress, pointer.count)
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
            updateActiveTimers()
            scheduleRender(force: true)
            updateFocusReport()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateActiveTimers()
                self.updateFocusReport()
                if self.isSurfaceVisible {
                    self.scheduleRender(force: true)
                }
            }
        }
        return resigned
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let window, window.firstResponder === self {
            window.makeFirstResponder(nil)
        }
        super.viewWillMove(toWindow: newWindow)
        DispatchQueue.main.async { [weak self] in
            self?.updateBackingLayerActivity()
            self?.updateActiveTimers()
            self?.updateFocusReport()
        }
    }

    @objc private func applicationWillResignActive(_ notification: Notification) {
        // Once the app is inactive, CAMetalLayer may stop vending drawables.
        // Capture the steady inactive cursor while the active drawable pool is
        // still available, then keep that IOSurface behind the other app.
        freezeVisibleFrame(cursorHasFocus: false)
    }

    @objc private func effectiveFocusChanged(_ notification: Notification) {
        // App/window notifications can arrive before AppKit's active and key
        // flags have settled. Render from the final focus state next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateActiveTimers()
            self.updateFocusReport()
            self.updateBackingLayerActivity()
            if self.shouldKeepMetalLayerActive {
                self.scheduleRender(force: true)
            }
        }
    }

    private func updateFocusReport() {
        let mode = terminalMode
        guard mode.contains(.focusReporting) else {
            lastReportedFocus = nil
            return
        }
        let focused = hasEffectiveTerminalFocus
        guard focused != lastReportedFocus else { return }
        lastReportedFocus = focused
        writeControl(Array((focused ? "\u{1b}[I" : "\u{1b}[O").utf8))
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let handle {
            switch Int(event.keyCode) {
            case 115: // Command-Home
                var snapshot = KeroSnapshot()
                kero_alacritty_snapshot(handle, &snapshot)
                let history = snapshot.total_lines > snapshot.screen_lines
                    ? snapshot.total_lines - snapshot.screen_lines : 0
                kero_alacritty_scroll_to_offset(handle, history)
                scheduleRender(force: true)
                reportScroll()
                return
            case 119: // Command-End
                kero_alacritty_scroll_to_offset(handle, 0)
                scheduleRender(force: true)
                reportScroll()
                return
            case 116, 121: // Command-Page Up / Page Down
                let delta = Int32(max(gridSize.rows, 1)) * (event.keyCode == 116 ? 1 : -1)
                kero_alacritty_scroll(handle, delta)
                scheduleRender(force: true)
                reportScroll()
                return
            default:
                break
            }
        }

        // While an IME is composing, every key belongs to the input context —
        // including arrows, Enter, and Escape that select or cancel.
        if hasMarkedText() {
            _ = inputContext?.handleEvent(event)
            return
        }

        // Ctrl / Option / special keys encode as terminal sequences. Plain
        // text returns nil from the key map so CJK IMEs can start composition
        // instead of each Latin keycap being written straight to the PTY.
        if let bytes = AlacrittyKeyMap.bytes(for: event, mode: terminalMode) {
            write(bytes)
            return
        }

        // First key of a composition, committed Unicode from an input source,
        // or a shortcut Kero's menus own.
        if inputContext?.handleEvent(event) == true {
            return
        }
        interpretKeyEvents([event])
    }

    override func mouseDown(with event: NSEvent) {
        focusForInteraction()
        guard let handle else { return }
        if event.modifierFlags.contains(.command),
           let url = hyperlink(at: gridPoint(for: event)) {
            events?.terminalDidRequestOpenURL(url)
            return
        }
        if shouldReportMouse(event) {
            reportingMouseButton = true
            sendMouse(code: 0, event: event, released: false)
            return
        }
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
        scheduleRender(force: true)
    }

    override func mouseDragged(with event: NSEvent) {
        if reportingMouseButton {
            if terminalMode.contains(.mouseDrag) || terminalMode.contains(.mouseMotion) {
                sendMouse(code: 32, event: event, released: false)
            }
            return
        }
        guard let handle, selectionAnchor != nil else { return }
        let point = gridPoint(for: event)
        kero_alacritty_selection_update(
            handle, Int32(point.line), point.column, point.rightHalf
        )
        scheduleRender(force: true)
    }

    override func mouseUp(with event: NSEvent) {
        if reportingMouseButton {
            reportingMouseButton = false
            sendMouse(code: 0, event: event, released: true)
        }
        selectionAnchor = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        let point = gridPoint(for: event)
        if hyperlink(at: point) != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.iBeam.set()
        }
        if terminalMode.contains(.mouseMotion), shouldReportMouse(event) {
            sendMouse(code: 35, event: event, released: false)
        }
    }

    override func mouseExited(with event: NSEvent) {
        // SwiftUI chrome does not necessarily install a cursor rect, so clear
        // the terminal's explicitly-set text cursor when leaving the surface.
        NSCursor.arrow.set()
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

        let mode = terminalMode
        if mode.contains(.mouseReporting) {
            let code = lines > 0 ? 64 : 65
            for _ in 0..<min(abs(lines), 50) {
                sendMouse(code: code, event: event, released: false)
            }
            return
        }
        if mode.contains(.alternateScreen), mode.contains(.alternateScroll) {
            let sequence = AlacrittyKeyMap.cursor(up: lines > 0, mode: mode)
            for _ in 0..<min(abs(lines), 50) {
                writeControl(sequence)
            }
            return
        }

        kero_alacritty_scroll(handle, Int32(lines))
        scheduleRender(force: true)
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

    private func shouldReportMouse(_ event: NSEvent) -> Bool {
        terminalMode.contains(.mouseReporting)
            && !event.modifierFlags.contains(.shift)
    }

    private func sendMouse(code: Int, event: NSEvent, released: Bool) {
        let mode = terminalMode
        guard mode.contains(.mouseReporting) else { return }
        let point = gridPoint(for: event)
        let x = point.column + 1
        let y = point.line + 1
        let modifiers =
            (event.modifierFlags.contains(.shift) ? 4 : 0)
            + (event.modifierFlags.contains(.option) ? 8 : 0)
            + (event.modifierFlags.contains(.control) ? 16 : 0)

        if mode.contains(.sgrMouse) {
            let suffix = released ? "m" : "M"
            writeControl(Array("\u{1b}[<\(code + modifiers);\(x);\(y)\(suffix)".utf8))
            return
        }

        let legacyCode = (released ? 3 : code) + modifiers + 32
        let legacyX = x + 32
        let legacyY = y + 32
        guard legacyCode <= 255, legacyX <= 255, legacyY <= 255 else { return }
        writeControl([0x1b, UInt8(ascii: "["), UInt8(ascii: "M"),
                      UInt8(legacyCode), UInt8(legacyX), UInt8(legacyY)])
    }

    private func hyperlink(
        at point: (line: Int, column: Int, rightHalf: Bool)
    ) -> String? {
        guard let handle else { return nil }
        let needed = kero_alacritty_hyperlink_at(
            handle, Int32(point.line), point.column, nil, 0
        )
        guard needed > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: needed)
        let written = buffer.withUnsafeMutableBufferPointer { pointer in
            kero_alacritty_hyperlink_at(
                handle, Int32(point.line), point.column,
                pointer.baseAddress, pointer.count
            )
        }
        guard written > 0 else { return nil }
        return String(decoding: buffer[..<written], as: UTF8.self)
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
        let pasteboard = NSPasteboard.general
        guard let text = Self.pasteboardString(from: pasteboard) else {
            // Image-aware TUIs read the native pasteboard after Ctrl-V. The
            // renderer may not display their image protocol, but the paste
            // itself must still reach the app.
            if pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) {
                write([0x16])
            }
            return
        }
        let submitRisk = text.contains("\n") || text.contains("\r")
        guard submitRisk else {
            write(AlacrittyKeyMap.paste(text, mode: terminalMode))
            return
        }
        events?.terminalDidRequestClipboardConfirmation(
            TerminalClipboardRequest(kind: .unsafePaste, contents: text) {
                [weak self] approved in
                guard approved, let self else { return }
                self.write(AlacrittyKeyMap.paste(text, mode: self.terminalMode))
            }
        )
    }

    override func selectAll(_ sender: Any?) {
        guard let handle else { return }
        kero_alacritty_select_all(handle)
        scheduleRender(force: true)
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): hasSelection
        case #selector(paste(_:)):
            Self.pasteboardString(from: .general) != nil
                || NSPasteboard.general.canReadObject(
                    forClasses: [NSImage.self], options: nil
                )
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
        // A drop is semantically a paste, not simulated typing. Image-aware
        // TUIs such as Grok only inspect dropped paths when bracketed paste
        // identifies the complete payload as one event.
        write(AlacrittyKeyMap.paste(text + " ", mode: terminalMode))
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

    private static func pasteboardString(from pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return urls.map { shellToken(for: $0.path) }.joined(separator: " ")
        }
        return pasteboard.string(forType: .string)
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
        scheduleRender(force: true)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        scheduleRender(force: true)
    }

    func unmarkText() {
        markedText = ""
        scheduleRender(force: true)
    }

    func selectedRange() -> NSRange {
        // Insertion point with no selection. `NSNotFound` makes some IMEs
        // refuse to begin composition against this client.
        NSRange(location: 0, length: 0)
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
