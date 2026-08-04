//
//  AlacrittyKeyMap.swift
//  kero
//

import AppKit

/// Terminal modes that change how a key is encoded, mirroring the
/// `KERO_MODE_*` bits the Rust bridge reports.
struct AlacrittyTerminalMode: OptionSet {
    let rawValue: UInt32

    static let applicationCursor = AlacrittyTerminalMode(rawValue: 1 << 0)
    static let applicationKeypad = AlacrittyTerminalMode(rawValue: 1 << 1)
    static let alternateScreen = AlacrittyTerminalMode(rawValue: 1 << 2)
    static let bracketedPaste = AlacrittyTerminalMode(rawValue: 1 << 3)
    static let mouseReporting = AlacrittyTerminalMode(rawValue: 1 << 4)
    static let focusReporting = AlacrittyTerminalMode(rawValue: 1 << 5)
    static let mouseClick = AlacrittyTerminalMode(rawValue: 1 << 6)
    static let mouseDrag = AlacrittyTerminalMode(rawValue: 1 << 7)
    static let mouseMotion = AlacrittyTerminalMode(rawValue: 1 << 8)
    static let sgrMouse = AlacrittyTerminalMode(rawValue: 1 << 9)
    static let alternateScroll = AlacrittyTerminalMode(rawValue: 1 << 10)
}

/// Translates AppKit key events into the bytes a PTY expects.
///
/// `alacritty_terminal` parses input but does not encode it — that belongs to
/// whatever owns the keyboard, which here is Kero. This covers the xterm
/// encodings a shell and the usual TUIs rely on; the Kitty keyboard protocol
/// is deliberately not implemented, matching the `kitty_keyboard: false`
/// default the bridge configures.
enum AlacrittyKeyMap {
    /// Bytes for `event`, or nil when the key should fall through to AppKit
    /// (IME composition, or a shortcut Kero's menus own).
    static func bytes(
        for event: NSEvent,
        mode: AlacrittyTerminalMode,
        optionAsAlt: Bool
    ) -> [UInt8]? {
        let flags = event.modifierFlags
        if flags.contains(.command) {
            // Match the terminal-local bindings installed for Ghostty. Other
            // Command shortcuts still fall through to Kero's menus.
            switch Int(event.keyCode) {
            case 123: return [0x01] // Command-Left: beginning of line.
            case 124: return [0x05] // Command-Right: end of line.
            case 51: return [0x15] // Command-Backspace: delete to line start.
            default: return nil
            }
        }

        let control = flags.contains(.control)
        let option = flags.contains(.option)
        // When Option-as-Alt is disabled, leave Option-modified text to
        // NSTextInputClient so the active macOS input source can compose it.
        let alt = optionAsAlt && option
        let shift = flags.contains(.shift)

        if let special = specialKey(
            event,
            mode: mode,
            shift: shift,
            control: control,
            alt: alt,
            option: option
        ) {
            return special
        }

        if control {
            guard let characters = event.charactersIgnoringModifiers,
                  !characters.isEmpty
            else { return nil }
            if let encoded = controlled(characters) {
                return alt ? [0x1b] + encoded : encoded
            }
        }

        // Option-as-Alt: ESC-prefix the base character. Don't fall through to
        // the IME — Option is a Meta modifier here, matching Ghostty's
        // `macos-option-as-alt`.
        if alt {
            guard let typed = event.charactersIgnoringModifiers, !typed.isEmpty
            else { return nil }
            return [0x1b] + Array(typed.utf8)
        }

        // Unmodified (and Shift-only) text must reach `NSTextInputClient` so
        // CJK IMEs can compose. Writing `event.characters` straight to the
        // PTY starves composition: Latin keycaps still report as "n"/"i" while
        // the input source is building 你. Committed text arrives via
        // `insertText`.
        return nil
    }

    /// Ctrl-<key> for the range a terminal encodes as a C0 control code.
    private static func controlled(_ characters: String) -> [UInt8]? {
        guard let scalar = characters.unicodeScalars.first,
              characters.unicodeScalars.count == 1
        else { return nil }

        switch scalar {
        case "a"..."z":
            return [UInt8(scalar.value - 0x60)]
        case "A"..."Z":
            return [UInt8(scalar.value - 0x40)]
        case "@", " ", "2":
            return [0x00]
        case "[", "3":
            return [0x1b]
        case "\\", "4":
            return [0x1c]
        case "]", "5":
            return [0x1d]
        case "^", "6":
            return [0x1e]
        case "_", "/", "7":
            return [0x1f]
        case "?", "8":
            return [0x7f]
        case "0", "1", "9":
            return [UInt8(scalar.value)]
        default:
            return nil
        }
    }

    private static func specialKey(
        _ event: NSEvent,
        mode: AlacrittyTerminalMode,
        shift: Bool,
        control: Bool,
        alt: Bool,
        option: Bool
    ) -> [UInt8]? {
        // The CSI parameter xterm uses to carry modifiers: 1 + a bitmask of
        // shift/alt/control. Only emitted when something is actually held.
        let modifier = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (control ? 4 : 0)
        let modified = modifier > 1

        // Match Ghostty's explicit Option-arrow word movement bindings rather
        // than relying on each shell to understand xterm modifier parameters.
        if option, !shift, !control {
            switch Int(event.keyCode) {
            case 123: return [0x1b, UInt8(ascii: "b")]
            case 124: return [0x1b, UInt8(ascii: "f")]
            default: break
            }
        }

        func csi(_ final: String, applicationCapable: Bool = false) -> [UInt8] {
            if modified {
                return Array("\u{1b}[1;\(modifier)\(final)".utf8)
            }
            if applicationCapable, mode.contains(.applicationCursor) {
                return Array("\u{1b}O\(final)".utf8)
            }
            return Array("\u{1b}[\(final)".utf8)
        }

        func tilde(_ number: Int) -> [UInt8] {
            modified
                ? Array("\u{1b}[\(number);\(modifier)~".utf8)
                : Array("\u{1b}[\(number)~".utf8)
        }

        func modifyOtherKeys(_ codepoint: Int) -> [UInt8] {
            Array("\u{1b}[27;\(modifier);\(codepoint)~".utf8)
        }

        if mode.contains(.applicationKeypad),
           let suffix = applicationKeypadSuffix(keyCode: Int(event.keyCode)) {
            return modified
                ? Array("\u{1b}O\(modifier)\(suffix)".utf8)
                : Array("\u{1b}O\(suffix)".utf8)
        }

        switch Int(event.keyCode) {
        case 36, 76: // Return, keypad Enter
            // Ghostty distinguishes modified Return with xterm's
            // modifyOtherKeys encoding. TUIs such as Claude use this to make
            // Shift-Return insert a newline without changing plain Return.
            return modified ? modifyOtherKeys(13) : [0x0d]
        case 48: // Tab
            if shift, !control, !alt { return Array("\u{1b}[Z".utf8) }
            if alt, !shift, !control { return [0x1b, 0x09] }
            return modified ? modifyOtherKeys(9) : [0x09]
        case 51: // Delete (backspace)
            // Terminals send DEL, and Ctrl-Backspace is conventionally the
            // "delete previous word" BS.
            let byte: UInt8 = control ? 0x08 : 0x7f
            return alt ? [0x1b, byte] : [byte]
        case 53: // Escape
            if alt, !shift, !control { return [0x1b, 0x1b] }
            return modified ? modifyOtherKeys(27) : [0x1b]
        case 117: // Forward delete
            return tilde(3)
        case 115: // Home
            return csi("H", applicationCapable: true)
        case 119: // End
            return csi("F", applicationCapable: true)
        case 116: // Page up
            return tilde(5)
        case 121: // Page down
            return tilde(6)
        case 126: // Up
            return csi("A", applicationCapable: true)
        case 125: // Down
            return csi("B", applicationCapable: true)
        case 124: // Right
            return csi("C", applicationCapable: true)
        case 123: // Left
            return csi("D", applicationCapable: true)
        default:
            break
        }

        if let function = functionKey(keyCode: Int(event.keyCode)) {
            switch function {
            case 1: return modified ? Array("\u{1b}[1;\(modifier)P".utf8) : Array("\u{1b}OP".utf8)
            case 2: return modified ? Array("\u{1b}[1;\(modifier)Q".utf8) : Array("\u{1b}OQ".utf8)
            case 3: return modified ? Array("\u{1b}[1;\(modifier)R".utf8) : Array("\u{1b}OR".utf8)
            case 4: return modified ? Array("\u{1b}[1;\(modifier)S".utf8) : Array("\u{1b}OS".utf8)
            case 5: return tilde(15)
            case 6: return tilde(17)
            case 7: return tilde(18)
            case 8: return tilde(19)
            case 9: return tilde(20)
            case 10: return tilde(21)
            case 11: return tilde(23)
            case 12: return tilde(24)
            default: return nil
            }
        }

        return nil
    }

    private static func applicationKeypadSuffix(keyCode: Int) -> String? {
        switch keyCode {
        case 65: "n" // Decimal.
        case 67: "j" // Multiply.
        case 69: "k" // Add.
        case 75: "o" // Divide.
        case 76: "M" // Enter.
        case 78: "m" // Subtract.
        case 81: "X" // Equal.
        case 82: "p" // 0.
        case 83: "q" // 1.
        case 84: "r" // 2.
        case 85: "s" // 3.
        case 86: "t" // 4.
        case 87: "u" // 5.
        case 88: "v" // 6.
        case 89: "w" // 7.
        case 91: "x" // 8.
        case 92: "y" // 9.
        default: nil
        }
    }

    private static func functionKey(keyCode: Int) -> Int? {
        switch keyCode {
        case 122: 1
        case 120: 2
        case 99: 3
        case 118: 4
        case 96: 5
        case 97: 6
        case 98: 7
        case 100: 8
        case 101: 9
        case 109: 10
        case 103: 11
        case 111: 12
        default: nil
        }
    }

    /// Wraps pasted text in bracketed-paste markers when the program asked for
    /// them, so an editor can tell a paste from fast typing.
    static func paste(_ text: String, mode: AlacrittyTerminalMode) -> [UInt8] {
        // Carriage returns are what a terminal delivers for Enter; a raw \n
        // pasted into a shell reads as a literal newline instead of submit.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        guard mode.contains(.bracketedPaste) else { return Array(normalized.utf8) }
        return Array("\u{1b}[200~".utf8) + Array(normalized.utf8) + Array("\u{1b}[201~".utf8)
    }

    static func cursor(up: Bool, mode: AlacrittyTerminalMode) -> [UInt8] {
        let final = up ? "A" : "B"
        let sequence = mode.contains(.applicationCursor)
            ? "\u{1b}O\(final)" : "\u{1b}[\(final)"
        return Array(sequence.utf8)
    }
}
