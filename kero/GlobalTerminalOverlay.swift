//
//  GlobalTerminalOverlay.swift
//  kero
//

import AppKit
import Carbon.HIToolbox

struct QuickTerminalShortcut: Equatable {
    static let defaultValue = QuickTerminalShortcut(
        keyCode: UInt32(kVK_ANSI_I),
        modifiers: UInt32(cmdKey)
    )

    let keyCode: UInt32
    let modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.supportedModifiers
    }

    init?(persistedValue: String?) {
        guard let persistedValue else { return nil }
        let components = persistedValue.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2,
              let keyCode = UInt32(components[0]),
              let modifiers = UInt32(components[1]),
              Self.isValid(modifiers: modifiers)
        else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }

    init?(event: NSEvent) {
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        guard Self.isValid(modifiers: modifiers) else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }

    var persistedValue: String { "\(keyCode):\(modifiers)" }

    var displayString: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + (Self.keyLabels[keyCode] ?? "Key \(keyCode)")
    }

    private static let supportedModifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
    private static let requiredModifiers = UInt32(cmdKey | optionKey | controlKey)

    private static func isValid(modifiers: UInt32) -> Bool {
        modifiers & requiredModifiers != 0
    }

    private static let keyLabels: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B",
        UInt32(kVK_ANSI_C): "C", UInt32(kVK_ANSI_D): "D",
        UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H",
        UInt32(kVK_ANSI_I): "I", UInt32(kVK_ANSI_J): "J",
        UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N",
        UInt32(kVK_ANSI_O): "O", UInt32(kVK_ANSI_P): "P",
        UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T",
        UInt32(kVK_ANSI_U): "U", UInt32(kVK_ANSI_V): "V",
        UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1",
        UInt32(kVK_ANSI_2): "2", UInt32(kVK_ANSI_3): "3",
        UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7",
        UInt32(kVK_ANSI_8): "8", UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "Return",
        UInt32(kVK_Tab): "Tab", UInt32(kVK_Delete): "Delete",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
    ]
}

/// The independent quick terminal. An unpinned overlay owns a temporary shell
/// only while it is focused; pinning changes that lifetime explicitly.
@MainActor
final class GlobalTerminalOverlay: NSObject {
    static let shared = GlobalTerminalOverlay()

    private static let hotkeySignature = OSType(0x4B45524F)
    private static let hotkeyIdentifier: UInt32 = 1
    private static let hotkeyHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return noErr }

        var receivedIdentifier = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &receivedIdentifier
        )
        guard status == noErr,
              receivedIdentifier.signature == hotkeySignature,
              receivedIdentifier.id == hotkeyIdentifier
        else {
            return noErr
        }

        let overlay = Unmanaged<GlobalTerminalOverlay>
            .fromOpaque(userData)
            .takeUnretainedValue()
        Task { @MainActor in overlay.toggle() }
        return noErr
    }

    private var hotkey: EventHotKeyRef?
    private var hotkeyHandlerRef: EventHandlerRef?
    private var terminalSession: TerminalSession?
    private var terminalWindow: GlobalTerminalOverlayWindow?
    private var backdropWindow: GlobalTerminalBackdropWindow?
    private var previousApplication: NSRunningApplication?
    private var isPinned = false

    func start() {
        guard hotkeyHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handler: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.hotkeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        guard handlerStatus == noErr else {
            NSLog("kero: could not install global terminal hotkey handler (\(handlerStatus))")
            return
        }
        hotkeyHandlerRef = handler

        _ = registerHotkey(AppSettings.shared.quickTerminalShortcut)
    }

    func stop() {
        dismiss(restorePreviousApplication: false)
        unregisterHotkey()
        if let hotkeyHandlerRef { RemoveEventHandler(hotkeyHandlerRef) }
        hotkeyHandlerRef = nil
        backdropWindow?.close()
        terminalWindow?.close()
        terminalSession?.terminate()
        backdropWindow = nil
        terminalWindow = nil
        terminalSession = nil
    }

    func beginHotkeyRecording() {
        unregisterHotkey()
    }

    func endHotkeyRecording() {
        guard hotkey == nil else { return }
        _ = registerHotkey(AppSettings.shared.quickTerminalShortcut)
    }

    func reloadHotkey() {
        guard hotkeyHandlerRef != nil else { return }
        unregisterHotkey()
        _ = registerHotkey(AppSettings.shared.quickTerminalShortcut)
    }

    func setHotkey(_ shortcut: QuickTerminalShortcut) -> Bool {
        guard hotkeyHandlerRef != nil else {
            AppSettings.shared.quickTerminalShortcut = shortcut
            return true
        }

        unregisterHotkey()
        guard registerHotkey(shortcut) else {
            _ = registerHotkey(AppSettings.shared.quickTerminalShortcut)
            return false
        }
        AppSettings.shared.quickTerminalShortcut = shortcut
        return true
    }

    private func registerHotkey(_ shortcut: QuickTerminalShortcut) -> Bool {
        guard hotkey == nil else { return true }

        var registeredHotkey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            EventHotKeyID(signature: Self.hotkeySignature, id: Self.hotkeyIdentifier),
            GetApplicationEventTarget(),
            0,
            &registeredHotkey
        )
        guard status == noErr else {
            NSLog("kero: could not register global terminal hotkey \(shortcut.displayString) (\(status))")
            return false
        }
        hotkey = registeredHotkey
        return true
    }

    private func unregisterHotkey() {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        hotkey = nil
    }

    private func toggle() {
        if terminalWindow?.isVisible == true {
            dismiss()
        } else {
            show()
        }
    }

    private func show() {
        guard let screen = screenAtPointer() else { return }
        if terminalSession == nil {
            terminalSession = TerminalSession()
        }
        guard let terminalSession else { return }

        if terminalWindow == nil {
            let window = GlobalTerminalOverlayWindow(
                session: terminalSession,
                defaultSize: AppSettings.shared.quickTerminalSize,
                defaultOpacity: AppSettings.shared.quickTerminalOpacity,
                onPinChanged: { [weak self] pinned in
                    self?.setPinned(pinned)
                }
            )
            window.delegate = self
            terminalWindow = window
        }
        guard let terminalWindow else { return }

        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        previousApplication = frontmostApplication?.processIdentifier
            == ProcessInfo.processInfo.processIdentifier
            ? nil
            : frontmostApplication

        terminalWindow.prepareForPresentation(on: screen)
        terminalSession.applyTheme()
        terminalWindow.orderFrontRegardless()
        terminalWindow.makeKey()
        terminalWindow.revealTerminal()
        updateBackdrop(on: screen)
    }

    private func dismiss(restorePreviousApplication: Bool = true) {
        guard let terminalWindow, terminalWindow.isVisible else { return }

        backdropWindow?.orderOut(nil)
        terminalSession?.surface.setSurfaceVisible(false)
        terminalWindow.orderOut(nil)

        let application = previousApplication
        previousApplication = nil
        terminalSession?.terminate()
        terminalSession = nil
        terminalWindow.close()
        self.terminalWindow = nil
        isPinned = false

        guard restorePreviousApplication,
              NSApp.isActive,
              let application,
              !application.isTerminated
        else { return }
        DispatchQueue.main.async {
            application.activate(options: [])
        }
    }

    private func setPinned(_ pinned: Bool) {
        isPinned = pinned
        guard let terminalWindow, terminalWindow.isVisible,
              let screen = screenForWindow(terminalWindow)
        else { return }
        updateBackdrop(on: screen)
    }

    private func updateBackdrop(on screen: NSScreen) {
        guard !isPinned, let terminalWindow, terminalWindow.isVisible else {
            backdropWindow?.orderOut(nil)
            return
        }
        if backdropWindow == nil {
            backdropWindow = GlobalTerminalBackdropWindow { [weak self] in
                self?.dismiss()
            }
        }
        guard let backdropWindow else { return }
        backdropWindow.setFrame(screen.frame, display: false)
        backdropWindow.orderFront(nil)
        backdropWindow.order(.below, relativeTo: terminalWindow.windowNumber)
    }

    func dismissFromWindow() {
        dismiss()
    }

    private func screenAtPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
    }

    private func screenForWindow(_ window: NSWindow) -> NSScreen? {
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
    }
}

extension GlobalTerminalOverlay: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        guard !isPinned else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let window = self.terminalWindow,
                  window.isVisible,
                  !window.isKeyWindow,
                  !window.isShowingSettings
            else { return }
            self.dismiss()
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard let terminalWindow,
              terminalWindow.isVisible,
              let screen = screenForWindow(terminalWindow)
        else { return }
        updateBackdrop(on: screen)
    }
}

@MainActor
private final class GlobalTerminalOverlayWindow: NSPanel {
    private var content: GlobalTerminalContentView!
    private let defaultSize: CGFloat
    private var areaFraction: CGFloat
    private var resizeStartFrame: NSRect?
    private var resizeStartMouse: NSPoint?
    private var settingsPopover: NSPopover?
    private(set) var isPinned = false
    private var hasConfiguredFrame = false

    init(
        session: TerminalSession,
        defaultSize: Double,
        defaultOpacity: Double,
        onPinChanged: @escaping (Bool) -> Void
    ) {
        self.defaultSize = CGFloat(defaultSize)
        areaFraction = CGFloat(defaultSize)
        self.onPinChanged = onPinChanged
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .statusBar
        collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = true
        isMovableByWindowBackground = false
        minSize = NSSize(width: 420, height: 260)

        content = GlobalTerminalContentView(
            session: session,
            opacity: CGFloat(defaultOpacity),
            isPinned: false,
            togglePinned: { [weak self] in
                guard let self else { return }
                self.setPinned(!self.isPinned)
            },
            showSettings: { [weak self] button in self?.showSettings(from: button) },
            beginResize: { [weak self] event in self?.beginResize(with: event) },
            resize: { [weak self] event in self?.resize(with: event) },
            endResize: { [weak self] in self?.endResize() }
        )
        contentView = content
        content.setBackgroundOpacity(CGFloat(defaultOpacity))
        content.setPinState(false)
    }

    private let onPinChanged: (Bool) -> Void

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape) {
            GlobalTerminalOverlay.shared.dismissFromWindow()
            return
        }
        super.sendEvent(event)
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        content.setPinState(pinned)
        onPinChanged(pinned)
    }

    func prepareForPresentation(on screen: NSScreen) {
        if !hasConfiguredFrame {
            let visibleFrame = screen.visibleFrame
            let scale = sqrt(max(defaultSize, 0.01))
            let size = NSSize(
                width: visibleFrame.width * scale,
                height: visibleFrame.height * scale
            )
            setFrame(
                NSRect(
                    x: visibleFrame.midX - size.width / 2,
                    y: visibleFrame.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                ),
                display: false
            )
            hasConfiguredFrame = true
        } else if !screen.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) {
            let visibleFrame = screen.visibleFrame
            setFrameOrigin(NSPoint(
                x: visibleFrame.midX - frame.width / 2,
                y: visibleFrame.midY - frame.height / 2
            ))
            resizeForAreaFraction(areaFraction)
        }
    }

    func revealTerminal() {
        content.revealTerminal()
    }

    var isShowingSettings: Bool {
        settingsPopover?.isShown == true
    }

    private func showSettings(from button: NSButton) {
        let popover = settingsPopover ?? NSPopover()
        popover.behavior = .transient
        popover.contentViewController = GlobalTerminalAdjustmentsViewController(
            size: { [weak self] in self?.currentAreaFraction ?? self?.areaFraction ?? 0.75 },
            setSize: { [weak self] value in self?.resizeForAreaFraction(value) },
            opacity: { [weak self] in self?.content.backgroundOpacity ?? 0.5 },
            setOpacity: { [weak self] value in self?.content.setBackgroundOpacity(value) }
        )
        settingsPopover = popover
        popover.show(
            relativeTo: button.bounds,
            of: button,
            preferredEdge: .maxY
        )
    }

    private var currentAreaFraction: CGFloat {
        guard let screen = screenContainingCenter else {
            return areaFraction
        }
        let visible = screen.visibleFrame
        return min(
            max((frame.width * frame.height) / (visible.width * visible.height),
                CGFloat(AppSettings.quickTerminalSizeRange.lowerBound)),
            CGFloat(AppSettings.quickTerminalSizeRange.upperBound)
        )
    }

    private func resizeForAreaFraction(_ value: CGFloat) {
        let fraction = min(
            max(value, CGFloat(AppSettings.quickTerminalSizeRange.lowerBound)),
            CGFloat(AppSettings.quickTerminalSizeRange.upperBound)
        )
        areaFraction = fraction
        guard let screen = screenContainingCenter else {
            return
        }
        let visible = screen.visibleFrame
        let aspect = max(frame.width / max(frame.height, 1), 0.5)
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let maxWidth = max(minSize.width, 2 * min(center.x - visible.minX, visible.maxX - center.x))
        let maxHeight = max(minSize.height, 2 * min(center.y - visible.minY, visible.maxY - center.y))
        let height = sqrt(visible.width * visible.height * fraction / aspect)
        let scale = min(1, maxWidth / (height * aspect), maxHeight / height)
        let size = NSSize(width: height * aspect * scale, height: height * scale)
        setFrame(
            NSRect(
                x: center.x - size.width / 2,
                y: center.y - size.height / 2,
                width: size.width,
                height: size.height
            ),
            display: true
        )
    }

    private func beginResize(with event: NSEvent) {
        resizeStartFrame = frame
        resizeStartMouse = NSEvent.mouseLocation
    }

    private func resize(with event: NSEvent) {
        guard let startFrame = resizeStartFrame,
              let startMouse = resizeStartMouse,
              let screen = screenContaining(center: NSPoint(
                  x: startFrame.midX,
                  y: startFrame.midY
              ))
        else { return }
        let mouse = NSEvent.mouseLocation
        let visible = screen.visibleFrame
        let center = NSPoint(x: startFrame.midX, y: startFrame.midY)
        let maxWidth = max(minSize.width, 2 * min(center.x - visible.minX, visible.maxX - center.x))
        let maxHeight = max(minSize.height, 2 * min(center.y - visible.minY, visible.maxY - center.y))
        let width = min(
            max(minSize.width, startFrame.width + 2 * (mouse.x - startMouse.x)),
            maxWidth
        )
        let height = min(
            max(minSize.height, startFrame.height + 2 * (startMouse.y - mouse.y)),
            maxHeight
        )
        setFrame(
            NSRect(
                x: center.x - width / 2,
                y: center.y - height / 2,
                width: width,
                height: height
            ),
            display: true
        )
        areaFraction = currentAreaFraction
    }

    private func endResize() {
        resizeStartFrame = nil
        resizeStartMouse = nil
    }

    private var screenContainingCenter: NSScreen? {
        screenContaining(center: NSPoint(x: frame.midX, y: frame.midY))
    }

    private func screenContaining(center: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
    }
}

@MainActor
private final class GlobalTerminalContentView: NSView {
    private let terminal: any TerminalBackendSurface
    private let materialBackground: NSVisualEffectView
    private let titlebar: GlobalTerminalTitlebarView
    private let resizeHandle: GlobalTerminalResizeHandle
    private var shouldActivateTerminal = false
    private(set) var backgroundOpacity: CGFloat

    init(
        session: TerminalSession,
        opacity: CGFloat,
        isPinned: Bool,
        togglePinned: @escaping () -> Void,
        showSettings: @escaping (NSButton) -> Void,
        beginResize: @escaping (NSEvent) -> Void,
        resize: @escaping (NSEvent) -> Void,
        endResize: @escaping () -> Void
    ) {
        terminal = session.surface
        materialBackground = NSVisualEffectView()
        backgroundOpacity = opacity
        titlebar = GlobalTerminalTitlebarView(
            isPinned: isPinned,
            togglePinned: togglePinned,
            showSettings: showSettings
        )
        resizeHandle = GlobalTerminalResizeHandle(
            beginResize: beginResize,
            resize: resize,
            endResize: endResize
        )
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.25).cgColor

        materialBackground.material = .hudWindow
        materialBackground.blendingMode = .behindWindow
        materialBackground.state = .active
        materialBackground.alphaValue = 1
        materialBackground.translatesAutoresizingMaskIntoConstraints = false
        titlebar.translatesAutoresizingMaskIntoConstraints = false
        terminal.translatesAutoresizingMaskIntoConstraints = false
        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        terminal.setBackgroundOpacity(backgroundOpacity)
        addSubview(materialBackground)
        addSubview(titlebar)
        addSubview(terminal)
        addSubview(resizeHandle)
        NSLayoutConstraint.activate([
            materialBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            materialBackground.topAnchor.constraint(equalTo: topAnchor),
            materialBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
            titlebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            titlebar.trailingAnchor.constraint(equalTo: trailingAnchor),
            titlebar.topAnchor.constraint(equalTo: topAnchor),
            titlebar.heightAnchor.constraint(equalToConstant: 32),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            terminal.topAnchor.constraint(equalTo: titlebar.bottomAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            resizeHandle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            resizeHandle.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            resizeHandle.widthAnchor.constraint(equalToConstant: 16),
            resizeHandle.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setPinState(_ pinned: Bool) {
        titlebar.setPinState(pinned)
    }

    func setBackgroundOpacity(_ opacity: CGFloat) {
        backgroundOpacity = min(
            max(opacity, CGFloat(AppSettings.quickTerminalOpacityRange.lowerBound)),
            CGFloat(AppSettings.quickTerminalOpacityRange.upperBound)
        )
        terminal.setBackgroundOpacity(backgroundOpacity)
    }

    func revealTerminal() {
        shouldActivateTerminal = true
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        guard shouldActivateTerminal,
              let window,
              terminal.window === window,
              terminal.bounds.width > 0,
              terminal.bounds.height > 0
        else { return }

        shouldActivateTerminal = false
        terminal.setSurfaceVisible(true)
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let window = self.window,
                  window.isKeyWindow,
                  self.terminal.window === window
            else { return }
            window.makeFirstResponder(self.terminal)
        }
    }
}

@MainActor
private final class GlobalTerminalTitlebarView: NSView {
    private let pinButton = NSButton()
    private let settingsButton = NSButton()
    private let togglePinned: () -> Void
    private let showSettings: (NSButton) -> Void

    init(
        isPinned: Bool,
        togglePinned: @escaping () -> Void,
        showSettings: @escaping (NSButton) -> Void
    ) {
        self.togglePinned = togglePinned
        self.showSettings = showSettings
        super.init(frame: .zero)

        configure(
            pinButton,
            imageName: isPinned ? "pin.fill" : "pin",
            label: String(localized: "Pin quick terminal"),
            tooltip: String(localized: "Pin quick terminal")
        )
        configure(
            settingsButton,
            imageName: "gearshape",
            label: String(localized: "Temporary terminal settings"),
            tooltip: String(localized: "Temporary terminal settings")
        )
        pinButton.target = self
        pinButton.action = #selector(pinPressed)
        settingsButton.target = self
        settingsButton.action = #selector(settingsPressed)

        pinButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pinButton)
        addSubview(settingsButton)
        NSLayoutConstraint.activate([
            pinButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            pinButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: 24),
            pinButton.heightAnchor.constraint(equalToConstant: 24),
            settingsButton.leadingAnchor.constraint(equalTo: pinButton.trailingAnchor, constant: 2),
            settingsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 24),
            settingsButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setPinState(_ pinned: Bool) {
        pinButton.image = NSImage(
            systemSymbolName: pinned ? "pin.fill" : "pin",
            accessibilityDescription: nil
        )
        pinButton.toolTip = String(localized: pinned ? "Unpin quick terminal" : "Pin quick terminal")
        pinButton.setAccessibilityLabel(
            String(localized: pinned ? "Unpin quick terminal" : "Pin quick terminal")
        )
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    @objc private func pinPressed() {
        togglePinned()
    }

    @objc private func settingsPressed() {
        showSettings(settingsButton)
    }

    private func configure(
        _ button: NSButton,
        imageName: String,
        label: String,
        tooltip: String
    ) {
        button.image = NSImage(systemSymbolName: imageName, accessibilityDescription: nil)
        button.isBordered = false
        button.bezelStyle = .recessed
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.focusRingType = .none
        button.toolTip = tooltip
        button.setAccessibilityLabel(label)
    }
}

@MainActor
private final class GlobalTerminalResizeHandle: NSView {
    private let beginResize: (NSEvent) -> Void
    private let resize: (NSEvent) -> Void
    private let endResize: () -> Void

    init(
        beginResize: @escaping (NSEvent) -> Void,
        resize: @escaping (NSEvent) -> Void,
        endResize: @escaping () -> Void
    ) {
        self.beginResize = beginResize
        self.resize = resize
        self.endResize = endResize
        super.init(frame: .zero)
        toolTip = String(localized: "Resize quick terminal")
        setAccessibilityLabel(String(localized: "Resize quick terminal"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        beginResize(event)
    }

    override func mouseDragged(with event: NSEvent) {
        resize(event)
    }

    override func mouseUp(with event: NSEvent) {
        endResize()
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        path.lineWidth = 1
        for offset in stride(from: 5, through: 11, by: 3) {
            path.move(to: NSPoint(x: offset, y: 2))
            path.line(to: NSPoint(x: 14, y: 14 - offset + 2))
        }
        NSColor.secondaryLabelColor.withAlphaComponent(0.55).setStroke()
        path.stroke()
    }
}

@MainActor
private final class GlobalTerminalBackdropWindow: NSPanel {
    init(dismiss: @escaping () -> Void) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        contentView = GlobalTerminalBackdropView(dismiss: dismiss)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class GlobalTerminalBackdropView: NSView {
    private let dismissAction: () -> Void

    init(dismiss: @escaping () -> Void) {
        dismissAction = dismiss
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) { dismissAction() }
    override func rightMouseDown(with event: NSEvent) { dismissAction() }
    override func otherMouseDown(with event: NSEvent) { dismissAction() }
}

@MainActor
private final class GlobalTerminalAdjustmentsViewController: NSViewController {
    private let readSize: () -> CGFloat
    private let setSize: (CGFloat) -> Void
    private let readOpacity: () -> CGFloat
    private let setOpacity: (CGFloat) -> Void
    private let sizeSlider = NSSlider()
    private let opacitySlider = NSSlider()
    private let sizeValue = NSTextField(labelWithString: "")
    private let opacityValue = NSTextField(labelWithString: "")

    init(
        size: @escaping () -> CGFloat,
        setSize: @escaping (CGFloat) -> Void,
        opacity: @escaping () -> CGFloat,
        setOpacity: @escaping (CGFloat) -> Void
    ) {
        readSize = size
        self.setSize = setSize
        readOpacity = opacity
        self.setOpacity = setOpacity
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        sizeSlider.minValue = AppSettings.quickTerminalSizeRange.lowerBound
        sizeSlider.maxValue = AppSettings.quickTerminalSizeRange.upperBound
        sizeSlider.isContinuous = true
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged)
        sizeSlider.setAccessibilityLabel(String(localized: "Temporary terminal size"))

        opacitySlider.minValue = AppSettings.quickTerminalOpacityRange.lowerBound
        opacitySlider.maxValue = AppSettings.quickTerminalOpacityRange.upperBound
        opacitySlider.isContinuous = true
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged)
        opacitySlider.setAccessibilityLabel(String(localized: "Temporary terminal opacity"))

        [sizeValue, opacityValue].forEach {
            $0.alignment = .right
            $0.font = .monospacedDigitSystemFont(
                ofSize: NSFont.smallSystemFontSize,
                weight: .regular
            )
            $0.textColor = .secondaryLabelColor
            $0.widthAnchor.constraint(equalToConstant: 42).isActive = true
        }

        let stack = NSStackView(views: [
            row(title: String(localized: "Size"), slider: sizeSlider, value: sizeValue),
            row(title: String(localized: "Opacity"), slider: opacitySlider, value: opacityValue),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 74))
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        view = root
        updateValues()
    }

    @objc private func sizeChanged() {
        setSize(sizeSlider.cgFloatValue)
        updateValues()
    }

    @objc private func opacityChanged() {
        setOpacity(opacitySlider.cgFloatValue)
        updateValues()
    }

    private func updateValues() {
        sizeSlider.doubleValue = Double(readSize())
        opacitySlider.doubleValue = Double(readOpacity())
        sizeValue.stringValue = "\(Int((sizeSlider.doubleValue * 100).rounded()))%"
        opacityValue.stringValue = "\(Int((opacitySlider.doubleValue * 100).rounded()))%"
    }

    private func row(
        title: String,
        slider: NSSlider,
        value: NSTextField
    ) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 58).isActive = true
        slider.widthAnchor.constraint(equalToConstant: 145).isActive = true
        let row = NSStackView(views: [label, slider, value])
        row.orientation = .horizontal
        row.spacing = 7
        return row
    }
}

private extension NSSlider {
    var cgFloatValue: CGFloat { CGFloat(doubleValue) }
}
