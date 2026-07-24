//
//  TerminalKeyEventHandler@AppKit.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//  Reference:
//  - ghostty-org/ghostty
//  - macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift
//  Translation modifiers, interpretKeyEvents dispatch, and text emission are
//  kept close to Ghostty's native AppKit implementation to reduce long-term
//  drift from upstream keyboard/IME semantics.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import GhosttyKit

    @MainActor
    final class TerminalKeyEventHandler {
        private weak var view: AppTerminalView?
        var inputMethodHandler: TerminalTextInputHandler?
        private var interpretedCommandSelector: Selector?

        init(view: AppTerminalView) {
            self.view = view
            inputMethodHandler = TerminalTextInputHandler(view: view)
        }

        nonisolated static func shouldUseDirectInput(
            modifierFlags: NSEvent.ModifierFlags
        ) -> Bool {
            modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty
        }

        nonisolated static func shouldReplayInterpretedCommand(
            _ selector: Selector
        ) -> Bool {
            // AppKit sometimes resolves non-text keys into editing commands
            // (for example Shift-Tab -> insertBacktab:). In a terminal, those
            // commands still need to reach Ghostty as the original hardware key.
            let _ = selector
            return true
        }

        func handleKeyDown(with event: NSEvent) {
            guard let view, let surface = view.surface else { return }

            if handleDirectInputIfNeeded(event) {
                return
            }

            let action: ghostty_input_action_e = event.isARepeat
                ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
            let translationEvent = translatedEvent(for: event, on: surface)

            inputMethodHandler?.startCollectingText()
            interpretedCommandSelector = nil
            let markedTextBefore = inputMethodHandler?.hasMarkedText == true
            let keyboardIdBefore = markedTextBefore ? nil : KeyboardLayout.id
            view.lastPerformKeyEvent = nil
            view.interpretKeyEvents([translationEvent])
            if !markedTextBefore, keyboardIdBefore != KeyboardLayout.id {
                _ = inputMethodHandler?.finishCollectingText()
                return
            }
            inputMethodHandler?.syncPreedit(clearIfNeeded: markedTextBefore)

            if let collected = inputMethodHandler?.finishCollectingText() {
                var input = event.buildKeyInput(
                    action: action,
                    translationModifiers: translationEvent.modifierFlags
                )
                for text in collected {
                    text.withCString { ptr in
                        input.text = ptr
                        surface.sendKeyEvent(input)
                    }
                }
                return
            }

            if let selector = interpretedCommandSelector {
                interpretedCommandSelector = nil
                if Self.shouldReplayInterpretedCommand(selector) {
                    sendKeyEvent(
                        for: event,
                        translationEvent: translationEvent,
                        action: action,
                        to: surface,
                        includeText: false,
                        composing: inputMethodHandler?.hasMarkedText == true || markedTextBefore
                    )
                    return
                }
            }

            sendKeyEvent(
                for: event,
                translationEvent: translationEvent,
                action: action,
                to: surface,
                includeText: true,
                composing: inputMethodHandler?.hasMarkedText == true || markedTextBefore
            )
        }

        func handleKeyUp(with event: NSEvent) {
            guard let view, let surface = view.surface else { return }
            if shouldBypassGhosttyForDirectInput(event) {
                return
            }
            var input = event.buildKeyInput(action: GHOSTTY_ACTION_RELEASE)
            input.text = nil
            surface.sendKeyEvent(input)
        }

        func handleFlagsChanged(with event: NSEvent) {
            guard let surface = view?.surface else { return }
            guard inputMethodHandler?.hasMarkedText != true else { return }

            let mod: UInt32
            switch event.keyCode {
            case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
            case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
            case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
            case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
            case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
            default: return
            }

            let mods = TerminalInputModifiers(from: event.modifierFlags).ghosttyMods

            var action = GHOSTTY_ACTION_RELEASE
            if mods.rawValue & mod != 0 {
                let sidePressed: Bool = switch event.keyCode {
                case 0x3C:
                    event.modifierFlags.rawValue
                        & UInt(NX_DEVICERSHIFTKEYMASK) != 0
                case 0x3E:
                    event.modifierFlags.rawValue
                        & UInt(NX_DEVICERCTLKEYMASK) != 0
                case 0x3D:
                    event.modifierFlags.rawValue
                        & UInt(NX_DEVICERALTKEYMASK) != 0
                case 0x36:
                    event.modifierFlags.rawValue
                        & UInt(NX_DEVICERCMDKEYMASK) != 0
                default:
                    true
                }

                if sidePressed {
                    action = GHOSTTY_ACTION_PRESS
                }
            }

            var input = event.buildKeyInput(action: action)
            input.text = nil
            surface.sendKeyEvent(input)
        }

        private func sendKeyEvent(
            for event: NSEvent,
            translationEvent: NSEvent,
            action: ghostty_input_action_e,
            to surface: TerminalSurface,
            includeText: Bool,
            composing: Bool = false
        ) {
            var input = event.buildKeyInput(
                action: action,
                translationModifiers: translationEvent.modifierFlags
            )
            input.composing = composing
            guard includeText,
                  let chars = translationEvent.filteredCharacters,
                  !chars.isEmpty
            else {
                surface.sendKeyEvent(input)
                return
            }

            chars.withCString { ptr in
                input.text = ptr
                surface.sendKeyEvent(input)
            }
        }

        private func handleDirectInputIfNeeded(_ event: NSEvent) -> Bool {
            guard let view else { return false }
            // During IME composition, AppKit needs to keep ownership of editing
            // commands so marked text can shrink, cancel, and move correctly.
            guard inputMethodHandler?.hasMarkedText != true else { return false }
            guard Self.shouldUseDirectInput(modifierFlags: event.modifierFlags) else {
                return false
            }
            let delivery = TerminalHardwareKeyRouter.routeAppKit(
                keyCode: event.keyCode,
                backend: view.configuration.backend
            )
            guard case let .data(sequence) = delivery else { return false }
            guard case let .inMemory(session) = view.configuration.backend else { return false }

            session.sendInput(sequence)
            return true
        }

        private func shouldBypassGhosttyForDirectInput(_ event: NSEvent) -> Bool {
            guard let view else { return false }
            guard Self.shouldUseDirectInput(modifierFlags: event.modifierFlags) else {
                return false
            }
            return TerminalHardwareKeyRouter.routeAppKit(
                keyCode: event.keyCode,
                backend: view.configuration.backend
            ).isDirectInput
        }

        private func translatedEvent(
            for event: NSEvent,
            on surface: TerminalSurface
        ) -> NSEvent {
            guard let rawSurface = surface.rawValue else {
                return event
            }

            let translatedMods = eventModifierFlags(
                from: ghostty_surface_key_translation_mods(
                    rawSurface,
                    TerminalInputModifiers(from: event.modifierFlags).ghosttyMods
                )
            )

            var finalModifiers = event.modifierFlags
            for flag in [
                NSEvent.ModifierFlags.shift,
                .control,
                .option,
                .command,
            ] {
                if translatedMods.contains(flag) {
                    finalModifiers.insert(flag)
                } else {
                    finalModifiers.remove(flag)
                }
            }

            guard finalModifiers != event.modifierFlags else {
                return event
            }

            return NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: finalModifiers,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: finalModifiers) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        private func eventModifierFlags(from mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
            var flags = NSEvent.ModifierFlags()
            if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
            if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
            if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
            if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
            return flags
        }

        func recordInterpretedCommand(_ selector: Selector) {
            interpretedCommandSelector = selector
        }
    }

    // MARK: - NSEvent Terminal Input Helpers

    extension NSEvent {
        func buildKeyInput(
            action: ghostty_input_action_e,
            translationModifiers: NSEvent.ModifierFlags? = nil
        ) -> ghostty_input_key_s {
            var input = ghostty_input_key_s()
            input.action = action
            input.keycode = UInt32(keyCode)
            input.composing = false
            input.text = nil

            input.mods = TerminalInputModifiers(from: modifierFlags).ghosttyMods

            // Consumed modifiers: modifiers the key binding system should
            // treat as already handled by text generation. We pass through
            // all modifiers except control and command, which should remain
            // available for keybind matching.
            var consumedFlags = translationModifiers ?? modifierFlags
            consumedFlags.remove(.control)
            consumedFlags.remove(.command)
            input.consumed_mods = TerminalInputModifiers(from: consumedFlags).ghosttyMods

            if type == .keyDown || type == .keyUp,
               let chars = characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first
            {
                input.unshifted_codepoint = codepoint.value
            }

            return input
        }

        var filteredCharacters: String? {
            guard let filtered = TerminalInputText.filteredFunctionKeyText(characters) else {
                return nil
            }
            guard filtered.count == 1,
                  let scalar = filtered.unicodeScalars.first
            else {
                return filtered
            }

            // macOS encodes function keys as Private Use Area scalars —
            // these have no printable representation.
            // When the control modifier produces a raw control character,
            // re-derive printable text without the control modifier so
            // Ghostty can map the physical key correctly.
            if scalar.isASCIIControl {
                var flags = modifierFlags
                flags.remove(.control)
                return TerminalInputText.filteredFunctionKeyText(
                    characters(byApplyingModifiers: flags)
                )
            }

            return filtered
        }
    }

    extension UnicodeScalar {
        var isASCIIControl: Bool {
            value < 0x20
        }
    }
#endif
