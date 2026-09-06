//
//  GlobalHotKey.swift
//  kero
//

import AppKit
import Carbon
import Combine

struct GlobalShortcut: Equatable, Sendable {
    struct Modifiers: OptionSet, Equatable, Sendable {
        let rawValue: UInt8
        init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        static let command = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let control = Modifiers(rawValue: 1 << 2)
        static let shift = Modifiers(rawValue: 1 << 3)

        var carbonValue: UInt32 {
            var value: UInt32 = 0
            if contains(.command) { value |= UInt32(cmdKey) }
            if contains(.option) { value |= UInt32(optionKey) }
            if contains(.control) { value |= UInt32(controlKey) }
            if contains(.shift) { value |= UInt32(shiftKey) }
            return value
        }

        init(eventFlags: NSEvent.ModifierFlags) {
            var value: Modifiers = []
            if eventFlags.contains(.command) { value.insert(.command) }
            if eventFlags.contains(.option) { value.insert(.option) }
            if eventFlags.contains(.control) { value.insert(.control) }
            if eventFlags.contains(.shift) { value.insert(.shift) }
            self = value
        }
    }

    let keyCode: UInt32
    let modifiers: Modifiers

    init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        let modifiers = Modifiers(eventFlags: event.modifierFlags)
        guard !modifiers.intersection([.command, .option, .control]).isEmpty else {
            return nil
        }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }

    init?(persistedValue: String) {
        let components = persistedValue.lowercased().split(separator: "+").map(String.init)
        guard let keyName = components.last,
              let keyCode = Self.keyCodesByName[keyName]
                ?? Self.numericKeyCode(from: keyName)
        else { return nil }

        var modifiers: Modifiers = []
        for component in components.dropLast() {
            switch component {
            case "command": modifiers.insert(.command)
            case "option": modifiers.insert(.option)
            case "control": modifiers.insert(.control)
            case "shift": modifiers.insert(.shift)
            default: return nil
            }
        }
        guard !modifiers.intersection([.command, .option, .control]).isEmpty else {
            return nil
        }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }

    var persistedValue: String {
        var components: [String] = []
        if modifiers.contains(.control) { components.append("control") }
        if modifiers.contains(.option) { components.append("option") }
        if modifiers.contains(.shift) { components.append("shift") }
        if modifiers.contains(.command) { components.append("command") }
        components.append(Self.keyNamesByCode[keyCode] ?? "keycode-\(keyCode)")
        return components.joined(separator: "+")
    }

    var displayName: String {
        var value = ""
        if modifiers.contains(.control) { value += "⌃" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.shift) { value += "⇧" }
        if modifiers.contains(.command) { value += "⌘" }
        value += Self.keyDisplayNames[keyCode]
            ?? Self.keyNamesByCode[keyCode]?.uppercased()
            ?? String(localized: "Key \(keyCode)")
        return value
    }

    private static func numericKeyCode(from value: String) -> UInt32? {
        guard value.hasPrefix("keycode-") else { return nil }
        return UInt32(value.dropFirst("keycode-".count))
    }

    private static let keyCodesByName: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6,
        "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "equal": 24, "9": 25,
        "7": 26, "minus": 27, "8": 28, "0": 29, "right-bracket": 30,
        "o": 31, "u": 32, "left-bracket": 33, "i": 34, "p": 35,
        "return": 36, "l": 37, "j": 38, "quote": 39, "k": 40,
        "semicolon": 41, "backslash": 42, "comma": 43, "slash": 44,
        "n": 45, "m": 46, "period": 47, "tab": 48, "space": 49,
        "grave": 50, "delete": 51, "escape": 53, "command": 55,
        "shift": 56, "caps-lock": 57, "option": 58, "control": 59,
        "right-shift": 60, "right-option": 61, "right-control": 62,
        "function": 63, "f17": 64, "keypad-decimal": 65,
        "keypad-multiply": 67, "keypad-plus": 69, "keypad-clear": 71,
        "volume-up": 72, "volume-down": 73, "mute": 74,
        "keypad-divide": 75, "keypad-enter": 76, "keypad-minus": 78,
        "f18": 79, "f19": 80, "keypad-equal": 81, "keypad-0": 82,
        "keypad-1": 83, "keypad-2": 84, "keypad-3": 85,
        "keypad-4": 86, "keypad-5": 87, "keypad-6": 88,
        "keypad-7": 89, "f20": 90, "keypad-8": 91, "keypad-9": 92,
        "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100,
        "f9": 101, "f11": 103, "f13": 105, "f16": 106, "f14": 107,
        "f10": 109, "f12": 111, "f15": 113, "help": 114, "home": 115,
        "page-up": 116, "forward-delete": 117, "f4": 118, "end": 119,
        "f2": 120, "page-down": 121, "f1": 122, "left": 123,
        "right": 124, "down": 125, "up": 126,
    ]

    private static let keyNamesByCode = Dictionary(
        uniqueKeysWithValues: keyCodesByName.map { ($0.value, $0.key) }
    )

    private static let keyDisplayNames: [UInt32: String] = [
        24: "=", 27: "−", 30: "]", 33: "[", 36: "↩", 39: "'",
        41: ";", 42: "\\", 43: ",", 44: "/", 47: ".", 48: "⇥",
        49: "Space", 50: "`", 51: "⌫", 53: "⎋", 65: ".", 67: "×",
        69: "+", 71: "Clear", 75: "÷", 76: "⌤", 78: "−", 81: "=",
        114: "Help", 115: "↖", 116: "⇞", 117: "⌦", 119: "↘",
        121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}

@MainActor
final class GlobalHotKeyController {
    static let shared = GlobalHotKeyController()

    nonisolated fileprivate static let hotKeyID = EventHotKeyID(
        signature: fourCharacterCode("KERO"),
        id: 1
    )

    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var settingsObserver: AnyCancellable?
    private var isSuspended = false
    private var isStarted = false

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            globalHotKeyEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard status == noErr else {
            NSLog("kero: failed to install global hotkey handler (status \(status))")
            return
        }

        settingsObserver = AppSettings.shared.$globalShortcut
            .removeDuplicates()
            .sink { [weak self] shortcut in
                self?.register(shortcut)
            }
    }

    func setRecording(_ isRecording: Bool) {
        isSuspended = isRecording
        register(isRecording ? nil : AppSettings.shared.globalShortcut)
    }

    fileprivate func handlePress() {
        guard !isSuspended else { return }
        if NSApp.isActive {
            NSApp.hide(nil)
        } else {
            NSApp.activate()
        }
    }

    private func register(_ shortcut: GlobalShortcut?) {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        guard !isSuspended, let shortcut else { return }

        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers.carbonValue,
            Self.hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        if status != noErr {
            self.hotKey = nil
            NSLog("kero: failed to register global shortcut \(shortcut.persistedValue) (status \(status))")
        }
    }
}

private let globalHotKeyEventHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr,
          hotKeyID.signature == GlobalHotKeyController.hotKeyID.signature,
          hotKeyID.id == GlobalHotKeyController.hotKeyID.id
    else { return OSStatus(eventNotHandledErr) }

    let controller = Unmanaged<GlobalHotKeyController>
        .fromOpaque(userData)
        .takeUnretainedValue()
    MainActor.assumeIsolated {
        controller.handlePress()
    }
    return noErr
}

private func fourCharacterCode(_ value: String) -> FourCharCode {
    value.utf8.reduce(0) { ($0 << 8) + FourCharCode($1) }
}
