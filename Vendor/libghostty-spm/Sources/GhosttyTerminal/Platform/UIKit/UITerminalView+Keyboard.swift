//
//  UITerminalView+Keyboard.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(UIKit)
    import GhosttyKit
    import UIKit

    extension UITerminalView {
        override open func pressesBegan(
            _ presses: Set<UIPress>,
            with _: UIPressesEvent?
        ) {
            for press in presses {
                guard let key = press.key else { continue }
                handleKeyPress(key, action: GHOSTTY_ACTION_PRESS)
            }
        }

        override open func pressesEnded(
            _ presses: Set<UIPress>,
            with _: UIPressesEvent?
        ) {
            for press in presses {
                guard let key = press.key else { continue }
                handleKeyPress(key, action: GHOSTTY_ACTION_RELEASE)
            }
            hardwareKeyHandled = false
        }

        override open func pressesCancelled(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent?
        ) {
            hardwareKeyHandled = false
            super.pressesCancelled(presses, with: event)
        }

        func handleKeyPress(
            _ key: UIKey,
            action: ghostty_input_action_e
        ) {
            guard let surface else {
                TerminalDebugLog.log(.input, "uikit key ignored: missing surface")
                return
            }

            let filteredModifierFlags = filteredModifierFlags(for: key)
            let isCommandModified = filteredModifierFlags.contains(.command)
            let mods = TerminalInputModifiers(from: filteredModifierFlags)
            let keyboardZoomDirection = commandZoomDirection(
                for: key,
                action: action,
                filteredModifierFlags: filteredModifierFlags
            )

            if action == GHOSTTY_ACTION_PRESS,
               shouldSuppressUIKeyInput(for: key, isCommandModified: isCommandModified)
            {
                hardwareKeyHandled = true
            }

            let delivery = TerminalHardwareKeyRouter.routeUIKit(
                usage: UInt16(key.keyCode.rawValue),
                backend: configuration.backend,
                modifiers: mods
            )

            TerminalDebugLog.log(
                .input,
                "uikit key action=\(TerminalDebugLog.describe(action)) code=\(key.keyCode.rawValue) chars=\(TerminalDebugLog.describe(key.characters)) ignoring=\(TerminalDebugLog.describe(key.charactersIgnoringModifiers)) mods=0x\(String(filteredModifierFlags.rawValue, radix: 16)) delivery=\(delivery.debugSummary) marked=\(inputHandler.hasMarkedText)"
            )

            if action == GHOSTTY_ACTION_RELEASE, delivery.isDirectInput {
                return
            }

            if handleDirectInputIfNeeded(
                delivery,
                action: action,
                isCommandModified: isCommandModified,
                filteredModifierFlags: filteredModifierFlags
            ) {
                if let keyboardZoomDirection {
                    scheduleViewportRefreshAfterKeyboardZoom(keyboardZoomDirection)
                }
                return
            }

            var keyEvent = ghostty_input_key_s()
            keyEvent.action = action
            keyEvent.mods = mods.ghosttyMods
            // Ghostty expects a platform-native keycode, which it resolves
            // to its internal Key enum via src/input/keycodes.zig. On iOS
            // that table uses macOS virtual keycodes (native_idx = 4), so
            // translate the documented HID usage value from UIKey into the
            // corresponding AppKit keycode here.
            keyEvent.keycode = TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(
                usage: UInt16(key.keyCode.rawValue)
            )
            keyEvent.composing = inputHandler.hasMarkedText

            var consumedFlags = filteredModifierFlags
            consumedFlags.remove(.control)
            consumedFlags.remove(.command)
            keyEvent.consumed_mods = TerminalInputModifiers(from: consumedFlags).ghosttyMods

            guard action == GHOSTTY_ACTION_PRESS || action == GHOSTTY_ACTION_REPEAT else {
                _ = surface.sendKeyEvent(keyEvent)
                return
            }

            let filteredIgnoringModifiers = TerminalInputText.filteredFunctionKeyText(
                key.charactersIgnoringModifiers
            )

            if let codepoint = filteredIgnoringModifiers?.unicodeScalars.first {
                keyEvent.unshifted_codepoint = codepoint.value
            }

            guard !isCommandModified else {
                _ = surface.sendKeyEvent(keyEvent)
                if let keyboardZoomDirection {
                    scheduleViewportRefreshAfterKeyboardZoom(keyboardZoomDirection)
                }
                return
            }

            guard let text = TerminalInputText.filteredFunctionKeyText(key.characters),
                  !text.isEmpty
            else {
                _ = surface.sendKeyEvent(keyEvent)
                return
            }

            text.withCString { ptr in
                keyEvent.text = ptr
                _ = surface.sendKeyEvent(keyEvent)
            }
        }

        func shouldSuppressUIKeyInput(
            for key: UIKey,
            isCommandModified: Bool
        ) -> Bool {
            guard !isCommandModified else { return false }
            guard key.modifierFlags.intersection([.alternate, .control]).isEmpty else {
                return false
            }
            guard !key.characters.isEmpty else {
                return key.keyCode == .keyboardDeleteOrBackspace
            }
            return true
        }

        private func handleDirectInputIfNeeded(
            _ delivery: TerminalHardwareKeyDelivery,
            action: ghostty_input_action_e,
            isCommandModified: Bool,
            filteredModifierFlags: UIKeyModifierFlags
        ) -> Bool {
            // When IME composition is active, UIKit must own editing keys such as
            // backspace and arrows so candidate text stays in sync.
            guard !inputHandler.hasMarkedText else { return false }
            guard !isCommandModified else { return false }
            guard filteredModifierFlags.intersection([.alternate, .control]).isEmpty else {
                return false
            }
            guard action == GHOSTTY_ACTION_PRESS || action == GHOSTTY_ACTION_REPEAT else {
                return false
            }
            guard case let .data(sequence) = delivery else { return false }
            guard case let .inMemory(session) = configuration.backend else { return false }

            session.sendInput(sequence)
            return true
        }

        private func filteredModifierFlags(for key: UIKey) -> UIKeyModifierFlags {
            var flags = key.modifierFlags
            let isFunctionKey =
                TerminalInputText.filteredFunctionKeyText(key.characters) == nil ||
                TerminalInputText.filteredFunctionKeyText(key.charactersIgnoringModifiers) == nil
            if isFunctionKey {
                flags.remove(.numericPad)
            }
            return flags
        }

        private func commandZoomDirection(
            for key: UIKey,
            action: ghostty_input_action_e,
            filteredModifierFlags: UIKeyModifierFlags
        ) -> KeyboardZoomDirection? {
            guard action == GHOSTTY_ACTION_PRESS || action == GHOSTTY_ACTION_REPEAT else {
                return nil
            }
            guard filteredModifierFlags.contains(.command) else { return nil }

            let candidates = [
                key.characters,
                key.charactersIgnoringModifiers,
            ]
            if candidates.contains(where: { $0 == "+" || $0 == "=" }) {
                return .increase
            }
            if candidates.contains(where: { $0 == "-" || $0 == "_" }) {
                return .decrease
            }
            return nil
        }

        private func scheduleViewportRefreshAfterKeyboardZoom(
            _ direction: KeyboardZoomDirection
        ) {
            TerminalDebugLog.log(
                .actions,
                "keyboard zoom shortcut direction=\(direction.rawValue)"
            )
            #if !targetEnvironment(macCatalyst)
                switch direction {
                case .increase:
                    currentFontSize = min(currentFontSize + 1, Self.maxFontSize)
                case .decrease:
                    currentFontSize = max(currentFontSize - 1, Self.minFontSize)
                }
            #endif

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                core.synchronizeMetrics()
                refreshTextInputGeometry(
                    reason: "keyboard-zoom-\(direction.rawValue)"
                )
            }
        }

        private enum KeyboardZoomDirection: String {
            case increase
            case decrease
        }
    }
#endif
