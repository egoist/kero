//
//  UITerminalView+InputAccessory.swift
//  libghostty-spm
//

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
    import GhosttyKit
    import UIKit

    extension UITerminalView {
        override open var inputAccessoryView: UIView? {
            inputAccessoryItems.isEmpty ? nil : terminalInputAccessory
        }

        func handleInputBarKey(_ key: TerminalInputBarKey) {
            commitMarkedTextIfStickyModifiersAreActive()

            switch key {
            case let .symbol(text):
                _ = handleStickyTextInput(text)

            case .paste:
                _ = stickyModifiers.consumeForNextKey()
                if let text = UIPasteboard.general.string, !text.isEmpty {
                    inputHandler.insertText(text)
                }

            case .esc:
                let mods = stickyModifiers.consumeForNextKey()
                sendSyntheticKey(usage: 0x29, additionalMods: mods)

            case .tab:
                let mods = stickyModifiers.consumeForNextKey()
                sendSyntheticKey(usage: 0x2B, additionalMods: mods)

            case .arrowLeft:
                let mods = stickyModifiers.consumeForNextKey()
                sendSyntheticKey(usage: 0x50, additionalMods: mods)

            case .arrowRight:
                let mods = stickyModifiers.consumeForNextKey()
                sendSyntheticKey(usage: 0x4F, additionalMods: mods)

            case .arrowUp:
                let mods = stickyModifiers.consumeForNextKey()
                sendSyntheticKey(usage: 0x52, additionalMods: mods)

            case .arrowDown:
                let mods = stickyModifiers.consumeForNextKey()
                sendSyntheticKey(usage: 0x51, additionalMods: mods)
            }
        }

        private func commitMarkedTextIfStickyModifiersAreActive() {
            guard stickyModifiers.hasActiveModifiers, inputHandler.hasMarkedText else { return }
            inputHandler.unmarkText(applyingStickyModifiers: false)
        }

        func sendSyntheticKey(
            usage: UInt16,
            additionalMods: TerminalInputModifiers = []
        ) {
            guard let surface else { return }

            if inputHandler.hasMarkedText {
                inputHandler.unmarkText()
            }

            // Unmodified accessory arrows/Esc/Tab can still use the direct
            // in-memory byte path, but sticky modifiers must round-trip
            // through Ghostty so modifier-aware escape sequences are preserved.
            let delivery = TerminalHardwareKeyRouter.routeUIKit(
                usage: usage,
                backend: configuration.backend,
                modifiers: additionalMods
            )

            if !additionalMods.isEmpty, let ghosttyKey = ghosttyKey(from: delivery) {
                var event = ghostty_input_key_s()
                event.action = GHOSTTY_ACTION_PRESS
                event.keycode = TerminalHardwareKeyRouter.appKitKeyCode(
                    for: ghosttyKey
                )
                event.mods = additionalMods.ghosttyMods
                _ = surface.sendKeyEvent(event)
                return
            }

            switch delivery {
            case let .data(data):
                guard case let .inMemory(session) = configuration.backend else { return }
                session.sendInput(data)

            case let .ghostty(ghosttyKey):
                var event = ghostty_input_key_s()
                event.action = GHOSTTY_ACTION_PRESS
                event.keycode = TerminalHardwareKeyRouter.appKitKeyCode(
                    for: ghosttyKey
                )
                event.mods = additionalMods.ghosttyMods
                _ = surface.sendKeyEvent(event)
            }
        }

        @discardableResult
        func handleStickyTextInput(_ text: String) -> Bool {
            handleStickyTextInput(text) { [weak self] text in
                self?.inputHandler.insertText(text)
            }
        }

        @discardableResult
        func handleStickyCommittedText(_ text: String) -> Bool {
            handleStickyTextInput(text) { [weak self] text in
                self?.surface?.sendText(text)
            }
        }

        @discardableResult
        func handleStickyMarkedText(_ text: String) -> Bool {
            guard stickyModifiers.hasActiveModifiers else { return false }

            let keyText = String(text.prefix(1))
            guard !keyText.isEmpty else {
                stickyModifiers.reset()
                return false
            }

            let mods = stickyModifiers.consumeForNextKey()
            let handled: Bool
            if mods == .ctrl, let controlByte = controlByte(for: keyText) {
                sendControlByte(controlByte, modifiers: mods)
                handled = true
            } else {
                handled = sendModifiedTextKey(keyText, modifiers: mods)
            }

            stickyModifiers.reset()
            return handled
        }

        @discardableResult
        private func handleStickyTextInput(
            _ text: String,
            fallback: (String) -> Void
        ) -> Bool {
            commitMarkedTextIfStickyModifiersAreActive()

            guard stickyModifiers.hasActiveModifiers else {
                fallback(text)
                return false
            }

            let mods = stickyModifiers.consumeForNextKey()
            if mods == .ctrl, let controlByte = controlByte(for: text) {
                sendControlByte(controlByte, modifiers: mods)
                return true
            }

            if sendModifiedTextKey(text, modifiers: mods) {
                return true
            }

            fallback(text)
            return false
        }

        func sendControlByte(
            _ byte: UInt8,
            modifiers: TerminalInputModifiers = .ctrl
        ) {
            if inputHandler.hasMarkedText {
                inputHandler.unmarkText()
            }

            if case let .inMemory(session) = configuration.backend {
                session.sendInput(Data([byte]))
            } else if let surface {
                var event = ghostty_input_key_s()
                event.action = GHOSTTY_ACTION_PRESS
                event.mods = modifiers.ghosttyMods
                let char = Character(UnicodeScalar(byte | 0x60))
                let ghosttyKey = ghosttyKeyForCharacter(char)
                event.keycode = TerminalHardwareKeyRouter.appKitKeyCode(
                    for: ghosttyKey
                )
                _ = surface.sendKeyEvent(event)
            }
        }

        private func controlByte(for text: String) -> UInt8? {
            guard text.count == 1 else { return nil }
            guard let ascii = text.lowercased().utf8.first else { return nil }
            guard ascii >= 0x61, ascii <= 0x7A else { return nil }
            return ascii & 0x1F
        }

        private func sendModifiedTextKey(
            _ text: String,
            modifiers: TerminalInputModifiers
        ) -> Bool {
            guard let surface else { return false }

            if inputHandler.hasMarkedText {
                inputHandler.unmarkText()
            }

            guard let mapping = keyMapping(for: text) else { return false }

            var event = ghostty_input_key_s()
            event.action = GHOSTTY_ACTION_PRESS
            event.keycode = TerminalHardwareKeyRouter.appKitKeyCode(
                for: mapping.key
            )
            event.mods = modifiers.union(mapping.extraModifiers).ghosttyMods

            if !modifiers.contains(.super_) {
                text.withCString { ptr in
                    event.text = ptr
                    _ = surface.sendKeyEvent(event)
                }
            } else {
                _ = surface.sendKeyEvent(event)
            }

            return true
        }

        private func ghosttyKey(from delivery: TerminalHardwareKeyDelivery) -> ghostty_input_key_e? {
            guard case let .ghostty(ghosttyKey) = delivery else { return nil }
            return ghosttyKey
        }

        private func keyMapping(
            for text: String
        ) -> (key: ghostty_input_key_e, extraModifiers: TerminalInputModifiers)? {
            guard text.count == 1, let char = text.first else { return nil }
            switch char {
            case "a" ... "z":
                return (ghosttyKeyForCharacter(char), [])
            case "A" ... "Z":
                return (ghosttyKeyForCharacter(Character(char.lowercased())), [.shift])
            case "0": return (GHOSTTY_KEY_DIGIT_0, [])
            case "1": return (GHOSTTY_KEY_DIGIT_1, [])
            case "2": return (GHOSTTY_KEY_DIGIT_2, [])
            case "3": return (GHOSTTY_KEY_DIGIT_3, [])
            case "4": return (GHOSTTY_KEY_DIGIT_4, [])
            case "5": return (GHOSTTY_KEY_DIGIT_5, [])
            case "6": return (GHOSTTY_KEY_DIGIT_6, [])
            case "7": return (GHOSTTY_KEY_DIGIT_7, [])
            case "8": return (GHOSTTY_KEY_DIGIT_8, [])
            case "9": return (GHOSTTY_KEY_DIGIT_9, [])
            case "`": return (GHOSTTY_KEY_BACKQUOTE, [])
            case "~": return (GHOSTTY_KEY_BACKQUOTE, [.shift])
            case "-": return (GHOSTTY_KEY_MINUS, [])
            case "_": return (GHOSTTY_KEY_MINUS, [.shift])
            case "=": return (GHOSTTY_KEY_EQUAL, [])
            case "+": return (GHOSTTY_KEY_EQUAL, [.shift])
            case "[": return (GHOSTTY_KEY_BRACKET_LEFT, [])
            case "{": return (GHOSTTY_KEY_BRACKET_LEFT, [.shift])
            case "]": return (GHOSTTY_KEY_BRACKET_RIGHT, [])
            case "}": return (GHOSTTY_KEY_BRACKET_RIGHT, [.shift])
            case "\\": return (GHOSTTY_KEY_BACKSLASH, [])
            case "|": return (GHOSTTY_KEY_BACKSLASH, [.shift])
            case ";": return (GHOSTTY_KEY_SEMICOLON, [])
            case ":": return (GHOSTTY_KEY_SEMICOLON, [.shift])
            case "'": return (GHOSTTY_KEY_QUOTE, [])
            case "\"": return (GHOSTTY_KEY_QUOTE, [.shift])
            case ",": return (GHOSTTY_KEY_COMMA, [])
            case "<": return (GHOSTTY_KEY_COMMA, [.shift])
            case ".": return (GHOSTTY_KEY_PERIOD, [])
            case ">": return (GHOSTTY_KEY_PERIOD, [.shift])
            case "/": return (GHOSTTY_KEY_SLASH, [])
            case "?": return (GHOSTTY_KEY_SLASH, [.shift])
            case " ": return (GHOSTTY_KEY_SPACE, [])
            default:
                return nil
            }
        }

        private func ghosttyKeyForCharacter(_ char: Character) -> ghostty_input_key_e {
            switch char {
            case "a": GHOSTTY_KEY_A
            case "b": GHOSTTY_KEY_B
            case "c": GHOSTTY_KEY_C
            case "d": GHOSTTY_KEY_D
            case "e": GHOSTTY_KEY_E
            case "f": GHOSTTY_KEY_F
            case "g": GHOSTTY_KEY_G
            case "h": GHOSTTY_KEY_H
            case "i": GHOSTTY_KEY_I
            case "j": GHOSTTY_KEY_J
            case "k": GHOSTTY_KEY_K
            case "l": GHOSTTY_KEY_L
            case "m": GHOSTTY_KEY_M
            case "n": GHOSTTY_KEY_N
            case "o": GHOSTTY_KEY_O
            case "p": GHOSTTY_KEY_P
            case "q": GHOSTTY_KEY_Q
            case "r": GHOSTTY_KEY_R
            case "s": GHOSTTY_KEY_S
            case "t": GHOSTTY_KEY_T
            case "u": GHOSTTY_KEY_U
            case "v": GHOSTTY_KEY_V
            case "w": GHOSTTY_KEY_W
            case "x": GHOSTTY_KEY_X
            case "y": GHOSTTY_KEY_Y
            case "z": GHOSTTY_KEY_Z
            default: GHOSTTY_KEY_UNIDENTIFIED
            }
        }
    }
#endif
