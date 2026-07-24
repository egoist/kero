//
//  TerminalHardwareKeyRouter.swift
//  libghostty-spm
//

import Foundation
import GhosttyKit

enum TerminalHardwareKeyDelivery: Equatable {
    case ghostty(ghostty_input_key_e)
    case data(Data)

    var isDirectInput: Bool {
        if case .data = self {
            return true
        }
        return false
    }
}

enum TerminalHardwareKeyRouter {
    static func routeUIKit(
        usage: UInt16,
        backend: TerminalSessionBackend
    ) -> TerminalHardwareKeyDelivery {
        if case .inMemory = backend,
           let data = directControlInputForUIKit(usage: usage)
        {
            return .data(data)
        }

        return .ghostty(ghosttyKeyForUIKit(usage: usage))
    }

    static func routeUIKit(
        usage: UInt16,
        backend: TerminalSessionBackend,
        modifiers: TerminalInputModifiers
    ) -> TerminalHardwareKeyDelivery {
        // Raw host-managed bytes only represent the unmodified control key.
        // Modified synthetic accessory keys need a real Ghostty key event so
        // the backend can emit the correct escape sequence for those modifiers.
        guard modifiers.isEmpty else {
            return .ghostty(ghosttyKeyForUIKit(usage: usage))
        }
        return routeUIKit(usage: usage, backend: backend)
    }

    static func routeAppKit(
        keyCode: UInt16,
        backend: TerminalSessionBackend
    ) -> TerminalHardwareKeyDelivery {
        if case .inMemory = backend,
           let data = directControlInputForAppKit(keyCode: keyCode)
        {
            return .data(data)
        }

        return .ghostty(ghosttyKeyForAppKit(keyCode: keyCode))
    }

    private static func directControlInputForUIKit(usage: UInt16) -> Data? {
        switch usage {
        case 0x2A:
            Data([0x7F])
        case 0x2B:
            Data([0x09])
        case 0x4C:
            Data("\u{1B}[3~".utf8)
        case 0x4A:
            Data("\u{1B}[H".utf8)
        case 0x4D:
            Data("\u{1B}[F".utf8)
        case 0x4B:
            Data("\u{1B}[5~".utf8)
        case 0x4E:
            Data("\u{1B}[6~".utf8)
        case 0x4F:
            Data("\u{1B}[C".utf8)
        case 0x50:
            Data("\u{1B}[D".utf8)
        case 0x51:
            Data("\u{1B}[B".utf8)
        case 0x52:
            Data("\u{1B}[A".utf8)
        default:
            nil
        }
    }

    private static func directControlInputForAppKit(keyCode: UInt16) -> Data? {
        switch keyCode {
        case 0x33:
            Data([0x7F])
        case 0x30:
            Data([0x09])
        case 0x75:
            Data("\u{1B}[3~".utf8)
        case 0x73:
            Data("\u{1B}[H".utf8)
        case 0x77:
            Data("\u{1B}[F".utf8)
        case 0x74:
            Data("\u{1B}[5~".utf8)
        case 0x79:
            Data("\u{1B}[6~".utf8)
        case 0x7B:
            Data("\u{1B}[D".utf8)
        case 0x7C:
            Data("\u{1B}[C".utf8)
        case 0x7D:
            Data("\u{1B}[B".utf8)
        case 0x7E:
            Data("\u{1B}[A".utf8)
        default:
            nil
        }
    }

    private static func ghosttyKeyForUIKit(usage: UInt16) -> ghostty_input_key_e {
        uiKitMap[usage] ?? GHOSTTY_KEY_UNIDENTIFIED
    }

    private static func ghosttyKeyForAppKit(keyCode: UInt16) -> ghostty_input_key_e {
        appKitMap[keyCode] ?? GHOSTTY_KEY_UNIDENTIFIED
    }

    /// Sentinel `keycode` value for keys that have no macOS AppKit
    /// equivalent (e.g. CUT/COPY/PASTE, media keys, CONTEXT_MENU, INSERT on
    /// PC keyboards). Any value outside the 8-bit AppKit virtual keycode
    /// range falls out of libghostty's native-keycode lookup and resolves
    /// to `.unidentified`. The pinned Ghostty keycode table uses 8-bit macOS
    /// keycodes, so `0x1_0000` stays safely outside the native range. Using
    /// plain `0` would instead collide with AppKit's keycode for the `A` key.
    static let unidentifiedAppKitKeyCode: UInt32 = 0x10000

    /// Translate a Ghostty key enum to the macOS AppKit virtual keycode
    /// for the same physical key. This is used by synthetic UIKit key
    /// events that already know the logical Ghostty key but still need to
    /// satisfy libghostty's native-keycode contract.
    static func appKitKeyCode(for ghosttyKey: ghostty_input_key_e) -> UInt32 {
        guard let macKeyCode = ghosttyKeyToAppKitCode[ghosttyKey.rawValue]
        else { return unidentifiedAppKitKeyCode }
        return UInt32(macKeyCode)
    }

    /// Translate a UIKit (USB HID) usage code to the macOS AppKit virtual
    /// keycode for the same physical key. Libghostty's keycode lookup
    /// (`src/input/keycodes.zig`) uses macOS keycodes on both macOS and iOS
    /// builds, so UIKit callers need to translate HID → mac before handing
    /// the keycode to `ghostty_surface_key`. Returns
    /// `unidentifiedAppKitKeyCode` for HID usages with no AppKit counterpart
    /// (keys that do not exist on Mac keyboards).
    static func appKitKeyCodeForUIKit(usage: UInt16) -> UInt32 {
        // Prefer explicit HID -> AppKit overrides before falling back to the
        // shared Ghostty key mapping. Some physical keys do not share the same
        // logical Ghostty enum on UIKit and AppKit.
        if let macKeyCode = uiKitToAppKitKeyCodeOverrides[usage] {
            return UInt32(macKeyCode)
        }
        guard let ghosttyKey = uiKitMap[usage]
        else { return unidentifiedAppKitKeyCode }
        return appKitKeyCode(for: ghosttyKey)
    }

    private static let ghosttyKeyToAppKitCode: [UInt32: UInt16] = {
        var result: [UInt32: UInt16] = [:]
        for (code, key) in appKitMap {
            result[key.rawValue] = code
        }
        return result
    }()

    /// UIKit and AppKit do not always use the same logical Ghostty key for the
    /// same physical key. Prefer the AppKit keycode directly for those cases.
    private static let uiKitToAppKitKeyCodeOverrides: [UInt16: UInt16] = [
        // keyboardNumLock -> kVK_ANSI_KeypadClear
        0x53: 0x47,
        // keyboardNonUSBackslash -> kVK_ISO_Section
        0x64: 0x0A,
    ]

    private typealias Pair = (UInt16, ghostty_input_key_e)

    private static let uiKitMap = buildMap(
        literalPairs: [
            (0x28, GHOSTTY_KEY_ENTER),
            (0x29, GHOSTTY_KEY_ESCAPE),
            (0x2A, GHOSTTY_KEY_BACKSPACE),
            (0x2B, GHOSTTY_KEY_TAB),
            (0x2C, GHOSTTY_KEY_SPACE),
            (0x2D, GHOSTTY_KEY_MINUS),
            (0x2E, GHOSTTY_KEY_EQUAL),
            (0x2F, GHOSTTY_KEY_BRACKET_LEFT),
            (0x30, GHOSTTY_KEY_BRACKET_RIGHT),
            (0x31, GHOSTTY_KEY_BACKSLASH),
            (0x33, GHOSTTY_KEY_SEMICOLON),
            (0x34, GHOSTTY_KEY_QUOTE),
            (0x35, GHOSTTY_KEY_BACKQUOTE),
            (0x36, GHOSTTY_KEY_COMMA),
            (0x37, GHOSTTY_KEY_PERIOD),
            (0x38, GHOSTTY_KEY_SLASH),
            (0x39, GHOSTTY_KEY_CAPS_LOCK),
            (0x46, GHOSTTY_KEY_PRINT_SCREEN),
            (0x47, GHOSTTY_KEY_SCROLL_LOCK),
            (0x48, GHOSTTY_KEY_PAUSE),
            (0x49, GHOSTTY_KEY_INSERT),
            (0x4A, GHOSTTY_KEY_HOME),
            (0x4B, GHOSTTY_KEY_PAGE_UP),
            (0x4C, GHOSTTY_KEY_DELETE),
            (0x4D, GHOSTTY_KEY_END),
            (0x4E, GHOSTTY_KEY_PAGE_DOWN),
            (0x4F, GHOSTTY_KEY_ARROW_RIGHT),
            (0x50, GHOSTTY_KEY_ARROW_LEFT),
            (0x51, GHOSTTY_KEY_ARROW_DOWN),
            (0x52, GHOSTTY_KEY_ARROW_UP),
            (0x53, GHOSTTY_KEY_NUM_LOCK),
            (0x54, GHOSTTY_KEY_NUMPAD_DIVIDE),
            (0x55, GHOSTTY_KEY_NUMPAD_MULTIPLY),
            (0x56, GHOSTTY_KEY_NUMPAD_SUBTRACT),
            (0x57, GHOSTTY_KEY_NUMPAD_ADD),
            (0x58, GHOSTTY_KEY_NUMPAD_ENTER),
            (0x64, GHOSTTY_KEY_INTL_BACKSLASH),
            (0x65, GHOSTTY_KEY_CONTEXT_MENU),
            (0x67, GHOSTTY_KEY_NUMPAD_EQUAL),
            (0x75, GHOSTTY_KEY_HELP),
            (0x7B, GHOSTTY_KEY_CUT),
            (0x7C, GHOSTTY_KEY_COPY),
            (0x7D, GHOSTTY_KEY_PASTE),
            (0x7F, GHOSTTY_KEY_AUDIO_VOLUME_MUTE),
            (0x80, GHOSTTY_KEY_AUDIO_VOLUME_UP),
            (0x81, GHOSTTY_KEY_AUDIO_VOLUME_DOWN),
            (0xE0, GHOSTTY_KEY_CONTROL_LEFT),
            (0xE1, GHOSTTY_KEY_SHIFT_LEFT),
            (0xE2, GHOSTTY_KEY_ALT_LEFT),
            (0xE3, GHOSTTY_KEY_META_LEFT),
            (0xE4, GHOSTTY_KEY_CONTROL_RIGHT),
            (0xE5, GHOSTTY_KEY_SHIFT_RIGHT),
            (0xE6, GHOSTTY_KEY_ALT_RIGHT),
            (0xE7, GHOSTTY_KEY_META_RIGHT),
        ],
        groupedPairs: [
            makeRun(
                startingAt: 0x04,
                keys: [
                    GHOSTTY_KEY_A, GHOSTTY_KEY_B, GHOSTTY_KEY_C, GHOSTTY_KEY_D,
                    GHOSTTY_KEY_E, GHOSTTY_KEY_F, GHOSTTY_KEY_G, GHOSTTY_KEY_H,
                    GHOSTTY_KEY_I, GHOSTTY_KEY_J, GHOSTTY_KEY_K, GHOSTTY_KEY_L,
                    GHOSTTY_KEY_M, GHOSTTY_KEY_N, GHOSTTY_KEY_O, GHOSTTY_KEY_P,
                    GHOSTTY_KEY_Q, GHOSTTY_KEY_R, GHOSTTY_KEY_S, GHOSTTY_KEY_T,
                    GHOSTTY_KEY_U, GHOSTTY_KEY_V, GHOSTTY_KEY_W, GHOSTTY_KEY_X,
                    GHOSTTY_KEY_Y, GHOSTTY_KEY_Z,
                ]
            ),
            makeRun(
                startingAt: 0x1E,
                keys: [
                    GHOSTTY_KEY_DIGIT_1, GHOSTTY_KEY_DIGIT_2, GHOSTTY_KEY_DIGIT_3,
                    GHOSTTY_KEY_DIGIT_4, GHOSTTY_KEY_DIGIT_5, GHOSTTY_KEY_DIGIT_6,
                    GHOSTTY_KEY_DIGIT_7, GHOSTTY_KEY_DIGIT_8, GHOSTTY_KEY_DIGIT_9,
                    GHOSTTY_KEY_DIGIT_0,
                ]
            ),
            makeRun(
                startingAt: 0x3A,
                keys: [
                    GHOSTTY_KEY_F1, GHOSTTY_KEY_F2, GHOSTTY_KEY_F3, GHOSTTY_KEY_F4,
                    GHOSTTY_KEY_F5, GHOSTTY_KEY_F6, GHOSTTY_KEY_F7, GHOSTTY_KEY_F8,
                    GHOSTTY_KEY_F9, GHOSTTY_KEY_F10, GHOSTTY_KEY_F11, GHOSTTY_KEY_F12,
                ]
            ),
            makeRun(
                startingAt: 0x59,
                keys: [
                    GHOSTTY_KEY_NUMPAD_1, GHOSTTY_KEY_NUMPAD_2, GHOSTTY_KEY_NUMPAD_3,
                    GHOSTTY_KEY_NUMPAD_4, GHOSTTY_KEY_NUMPAD_5, GHOSTTY_KEY_NUMPAD_6,
                    GHOSTTY_KEY_NUMPAD_7, GHOSTTY_KEY_NUMPAD_8, GHOSTTY_KEY_NUMPAD_9,
                    GHOSTTY_KEY_NUMPAD_0, GHOSTTY_KEY_NUMPAD_DECIMAL,
                ]
            ),
            makeRun(
                startingAt: 0x68,
                keys: [
                    GHOSTTY_KEY_F13, GHOSTTY_KEY_F14, GHOSTTY_KEY_F15, GHOSTTY_KEY_F16,
                    GHOSTTY_KEY_F17, GHOSTTY_KEY_F18, GHOSTTY_KEY_F19, GHOSTTY_KEY_F20,
                    GHOSTTY_KEY_F21, GHOSTTY_KEY_F22, GHOSTTY_KEY_F23, GHOSTTY_KEY_F24,
                ]
            ),
        ]
    )

    /// JIS keyboard entries are still absent from this table:
    ///   (0x5D, GHOSTTY_KEY_INTL_YEN)   // kVK_JIS_Yen
    ///   (0x5E, GHOSTTY_KEY_INTL_RO)    // kVK_JIS_Underscore
    private static let appKitMap = buildMap(
        literalPairs: [
            (0x00, GHOSTTY_KEY_A), (0x01, GHOSTTY_KEY_S), (0x02, GHOSTTY_KEY_D),
            (0x03, GHOSTTY_KEY_F), (0x04, GHOSTTY_KEY_H), (0x05, GHOSTTY_KEY_G),
            (0x06, GHOSTTY_KEY_Z), (0x07, GHOSTTY_KEY_X), (0x08, GHOSTTY_KEY_C),
            (0x09, GHOSTTY_KEY_V),
            (0x0B, GHOSTTY_KEY_B), (0x0C, GHOSTTY_KEY_Q),
            (0x0D, GHOSTTY_KEY_W), (0x0E, GHOSTTY_KEY_E), (0x0F, GHOSTTY_KEY_R),
            (0x10, GHOSTTY_KEY_Y), (0x11, GHOSTTY_KEY_T), (0x12, GHOSTTY_KEY_DIGIT_1),
            (0x13, GHOSTTY_KEY_DIGIT_2), (0x14, GHOSTTY_KEY_DIGIT_3), (0x15, GHOSTTY_KEY_DIGIT_4),
            (0x16, GHOSTTY_KEY_DIGIT_6), (0x17, GHOSTTY_KEY_DIGIT_5), (0x18, GHOSTTY_KEY_EQUAL),
            (0x19, GHOSTTY_KEY_DIGIT_9), (0x1A, GHOSTTY_KEY_DIGIT_7), (0x1B, GHOSTTY_KEY_MINUS),
            (0x1C, GHOSTTY_KEY_DIGIT_8), (0x1D, GHOSTTY_KEY_DIGIT_0), (0x1E, GHOSTTY_KEY_BRACKET_RIGHT),
            (0x1F, GHOSTTY_KEY_O), (0x20, GHOSTTY_KEY_U), (0x21, GHOSTTY_KEY_BRACKET_LEFT),
            (0x22, GHOSTTY_KEY_I), (0x23, GHOSTTY_KEY_P), (0x24, GHOSTTY_KEY_ENTER),
            (0x25, GHOSTTY_KEY_L), (0x26, GHOSTTY_KEY_J), (0x27, GHOSTTY_KEY_QUOTE),
            (0x28, GHOSTTY_KEY_K), (0x29, GHOSTTY_KEY_SEMICOLON), (0x2A, GHOSTTY_KEY_BACKSLASH),
            (0x2B, GHOSTTY_KEY_COMMA), (0x2C, GHOSTTY_KEY_SLASH), (0x2D, GHOSTTY_KEY_N),
            (0x2E, GHOSTTY_KEY_M), (0x2F, GHOSTTY_KEY_PERIOD), (0x30, GHOSTTY_KEY_TAB),
            (0x31, GHOSTTY_KEY_SPACE), (0x32, GHOSTTY_KEY_BACKQUOTE), (0x33, GHOSTTY_KEY_BACKSPACE),
            (0x35, GHOSTTY_KEY_ESCAPE), (0x36, GHOSTTY_KEY_META_RIGHT), (0x37, GHOSTTY_KEY_META_LEFT),
            (0x38, GHOSTTY_KEY_SHIFT_LEFT), (0x39, GHOSTTY_KEY_CAPS_LOCK), (0x3A, GHOSTTY_KEY_ALT_LEFT),
            (0x3B, GHOSTTY_KEY_CONTROL_LEFT), (0x3C, GHOSTTY_KEY_SHIFT_RIGHT), (0x3D, GHOSTTY_KEY_ALT_RIGHT),
            (0x3E, GHOSTTY_KEY_CONTROL_RIGHT), (0x3F, GHOSTTY_KEY_FN), (0x40, GHOSTTY_KEY_F17),
            (0x41, GHOSTTY_KEY_NUMPAD_DECIMAL),
            (0x43, GHOSTTY_KEY_NUMPAD_MULTIPLY), (0x45, GHOSTTY_KEY_NUMPAD_ADD), (0x47, GHOSTTY_KEY_NUMPAD_CLEAR),
            (0x48, GHOSTTY_KEY_AUDIO_VOLUME_UP), (0x49, GHOSTTY_KEY_AUDIO_VOLUME_DOWN),
            (0x4A, GHOSTTY_KEY_AUDIO_VOLUME_MUTE), (0x4B, GHOSTTY_KEY_NUMPAD_DIVIDE),
            (0x4C, GHOSTTY_KEY_NUMPAD_ENTER), (0x4E, GHOSTTY_KEY_NUMPAD_SUBTRACT),
            (0x4F, GHOSTTY_KEY_F18), (0x50, GHOSTTY_KEY_F19), (0x51, GHOSTTY_KEY_NUMPAD_EQUAL),
            (0x52, GHOSTTY_KEY_NUMPAD_0), (0x53, GHOSTTY_KEY_NUMPAD_1),
            (0x54, GHOSTTY_KEY_NUMPAD_2), (0x55, GHOSTTY_KEY_NUMPAD_3), (0x56, GHOSTTY_KEY_NUMPAD_4),
            (0x57, GHOSTTY_KEY_NUMPAD_5), (0x58, GHOSTTY_KEY_NUMPAD_6), (0x59, GHOSTTY_KEY_NUMPAD_7),
            (0x5A, GHOSTTY_KEY_F20),
            (0x5B, GHOSTTY_KEY_NUMPAD_8), (0x5C, GHOSTTY_KEY_NUMPAD_9), (0x60, GHOSTTY_KEY_F5),
            (0x61, GHOSTTY_KEY_F6), (0x62, GHOSTTY_KEY_F7), (0x63, GHOSTTY_KEY_F3),
            (0x64, GHOSTTY_KEY_F8), (0x65, GHOSTTY_KEY_F9), (0x67, GHOSTTY_KEY_F11),
            (0x69, GHOSTTY_KEY_F13), (0x6A, GHOSTTY_KEY_F16), (0x6B, GHOSTTY_KEY_F14),
            (0x6D, GHOSTTY_KEY_F10), (0x6F, GHOSTTY_KEY_F12), (0x71, GHOSTTY_KEY_F15),
            (0x72, GHOSTTY_KEY_HELP), (0x73, GHOSTTY_KEY_HOME), (0x74, GHOSTTY_KEY_PAGE_UP),
            (0x75, GHOSTTY_KEY_DELETE), (0x76, GHOSTTY_KEY_F4), (0x77, GHOSTTY_KEY_END),
            (0x78, GHOSTTY_KEY_F2), (0x79, GHOSTTY_KEY_PAGE_DOWN), (0x7A, GHOSTTY_KEY_F1),
            (0x7B, GHOSTTY_KEY_ARROW_LEFT), (0x7C, GHOSTTY_KEY_ARROW_RIGHT),
            (0x7D, GHOSTTY_KEY_ARROW_DOWN), (0x7E, GHOSTTY_KEY_ARROW_UP),
        ],
        groupedPairs: []
    )

    private static func buildMap(
        literalPairs: [Pair],
        groupedPairs: [[Pair]]
    ) -> [UInt16: ghostty_input_key_e] {
        var map: [UInt16: ghostty_input_key_e] = [:]
        for (code, key) in literalPairs {
            map[code] = key
        }
        for group in groupedPairs {
            for (code, key) in group {
                map[code] = key
            }
        }
        return map
    }

    private static func makeRun(
        startingAt code: UInt16,
        keys: [ghostty_input_key_e]
    ) -> [Pair] {
        keys.enumerated().map { offset, key in
            (code + UInt16(offset), key)
        }
    }
}
