//
//  AppTerminalView+Input.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import GhosttyKit

    extension AppTerminalView {
        override open func keyDown(with event: NSEvent) {
            inputHandler?.handleKeyDown(with: event)
        }

        override open func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.type == .keyDown else { return false }
            guard window?.firstResponder === self else { return false }
            guard let surface else { return false }

            if keyIsBinding(event, on: surface) {
                keyDown(with: event)
                return true
            }

            let equivalent: String
            switch event.charactersIgnoringModifiers {
            case "\r":
                guard event.modifierFlags.contains(.control) else {
                    return false
                }
                equivalent = "\r"

            case "/":
                guard event.modifierFlags.contains(.control),
                      event.modifierFlags.isDisjoint(with: [.shift, .command, .option])
                else {
                    return false
                }
                equivalent = "_"

            default:
                if event.timestamp == 0 {
                    return false
                }

                if !event.modifierFlags.contains(.command),
                   !event.modifierFlags.contains(.control)
                {
                    lastPerformKeyEvent = nil
                    return false
                }

                if let lastPerformKeyEvent,
                   lastPerformKeyEvent == event.timestamp
                {
                    self.lastPerformKeyEvent = nil
                    equivalent = event.characters ?? ""
                    break
                }

                lastPerformKeyEvent = event.timestamp
                return false
            }

            guard let translatedEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: event.locationInWindow,
                modifierFlags: event.modifierFlags,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: equivalent,
                charactersIgnoringModifiers: equivalent,
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) else {
                return false
            }

            keyDown(with: translatedEvent)
            return true
        }

        override open func keyUp(with event: NSEvent) {
            inputHandler?.handleKeyUp(with: event)
        }

        override open func flagsChanged(with event: NSEvent) {
            inputHandler?.handleFlagsChanged(with: event)
        }

        override open func doCommand(by selector: Selector) {
            if let lastPerformKeyEvent,
               let current = NSApp.currentEvent,
               lastPerformKeyEvent == current.timestamp
            {
                NSApp.sendEvent(current)
                return
            }

            if TerminalKeyEventHandler.shouldReplayInterpretedCommand(selector) {
                inputHandler?.recordInterpretedCommand(selector)
            }
        }

        @IBAction open func copy(_: Any?) {
            _ = copySelectedTextToPasteboard()
        }

        @IBAction func paste(_: Any?) {
            if let text = NSPasteboard.general.string(forType: .string) {
                TerminalDebugLog.log(
                    .input,
                    "paste binding bytes=\(text.utf8.count) lines=\(TerminalInputText.lineCount(in: text))"
                )
            }
            _ = surface?.performBindingAction("paste_from_clipboard")
        }

        @IBAction override open func selectAll(_: Any?) {
            _ = surface?.performBindingAction("select_all")
        }

        internal func mousePoint(from event: NSEvent) -> (x: CGFloat, y: CGFloat) {
            let point = convert(event.locationInWindow, from: nil)
            return (point.x, bounds.height - point.y)
        }

        override open func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            pointerSelectionStartPoint = CGPoint(x: x, y: y)
            pendingSelectionMenuPoint = nil
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_PRESS,
                button: GHOSTTY_MOUSE_LEFT,
                mods: mods.ghosttyMods
            )
        }

        override open func mouseUp(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_RELEASE,
                button: GHOSTTY_MOUSE_LEFT,
                mods: mods.ghosttyMods
            )
            finishPointerSelection(at: CGPoint(x: x, y: y))
        }

        override open func rightMouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            if let menuPoint = selectionMenuPoint(at: CGPoint(x: x, y: y)) {
                pendingSelectionMenuPoint = menuPoint
                return
            }
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_PRESS,
                button: GHOSTTY_MOUSE_RIGHT,
                mods: mods.ghosttyMods
            )
        }

        override open func rightMouseUp(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            if pendingSelectionMenuPoint != nil {
                pendingSelectionMenuPoint = nil
                showSelectionCopyMenu(with: event)
                return
            }
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_RELEASE,
                button: GHOSTTY_MOUSE_RIGHT,
                mods: mods.ghosttyMods
            )
        }

        override open func menu(for event: NSEvent) -> NSMenu? {
            let (x, y) = mousePoint(from: event)
            guard selectionMenuPoint(at: CGPoint(x: x, y: y)) != nil else {
                return super.menu(for: event)
            }
            return selectionContextMenu()
        }

        override open func otherMouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_PRESS,
                button: GHOSTTY_MOUSE_MIDDLE,
                mods: mods.ghosttyMods
            )
        }

        override open func otherMouseUp(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_RELEASE,
                button: GHOSTTY_MOUSE_MIDDLE,
                mods: mods.ghosttyMods
            )
        }

        override open func mouseMoved(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
        }

        override open func mouseDragged(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            updatePointerSelectionRect(to: CGPoint(x: x, y: y))
            mouseMoved(with: event)
        }

        override open func rightMouseDragged(with event: NSEvent) {
            mouseMoved(with: event)
        }

        override open func otherMouseDragged(with event: NSEvent) {
            mouseMoved(with: event)
        }

        override open func scrollWheel(with event: NSEvent) {
            let scrollMods = TerminalScrollModifiers(
                precision: event.hasPreciseScrollingDeltas,
                momentum: TerminalScrollModifiers.momentumFrom(phase: event.momentumPhase)
            )
            surface?.sendMouseScroll(
                x: event.scrollingDeltaX,
                y: event.scrollingDeltaY,
                mods: scrollMods.rawValue
            )
        }

        private func updatePointerSelectionRect(to point: CGPoint) {
            guard let start = pointerSelectionStartPoint else { return }
            lastPointerSelectionRect = CGRect(
                x: min(start.x, point.x),
                y: min(start.y, point.y),
                width: abs(start.x - point.x),
                height: abs(start.y - point.y)
            ).insetBy(dx: -2, dy: -2)
        }

        private func finishPointerSelection(at point: CGPoint) {
            defer { pointerSelectionStartPoint = nil }
            guard let start = pointerSelectionStartPoint else { return }
            let dragDistance = hypot(point.x - start.x, point.y - start.y)
            if dragDistance < 2 {
                lastPointerSelectionRect = nil
            } else {
                updatePointerSelectionRect(to: point)
            }
        }

        private func showSelectionCopyMenu(with event: NSEvent) {
            let menu = selectionContextMenu()
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        private func keyIsBinding(
            _ event: NSEvent,
            on surface: TerminalSurface
        ) -> Bool {
            guard let rawSurface = surface.rawValue else {
                return false
            }

            var keyEvent = event.buildKeyInput(action: GHOSTTY_ACTION_PRESS)
            var bindingFlags = ghostty_binding_flags_e(rawValue: 0)
            let text = event.characters ?? ""
            return text.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key_is_binding(rawSurface, keyEvent, &bindingFlags)
            }
        }
    }
#endif
