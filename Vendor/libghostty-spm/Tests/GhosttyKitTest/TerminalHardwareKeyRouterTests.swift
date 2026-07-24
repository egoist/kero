import AppKit
import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

struct TerminalHardwareKeyRouterTests {
    @Test
    func `routes UI kit arrow keys directly for in memory backends`() {
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        #expect(
            TerminalHardwareKeyRouter.routeUIKit(
                usage: 0x50,
                backend: .inMemory(session)
            ) == .data(Data("\u{1B}[D".utf8))
        )
        #expect(
            TerminalHardwareKeyRouter.routeUIKit(
                usage: 0x52,
                backend: .inMemory(session)
            ) == .data(Data("\u{1B}[A".utf8))
        )
        #expect(
            TerminalHardwareKeyRouter.routeUIKit(
                usage: 0x2A,
                backend: .inMemory(session)
            ) == .data(Data([0x7F]))
        )
        #expect(
            TerminalHardwareKeyRouter.routeUIKit(
                usage: 0x2B,
                backend: .inMemory(session)
            ) == .data(Data([0x09]))
        )
    }

    @Test
    func `routes UI kit keys to ghostty for exec backends`() {
        #expect(
            TerminalHardwareKeyRouter.routeUIKit(
                usage: 0x50,
                backend: .exec
            ) == .ghostty(GHOSTTY_KEY_ARROW_LEFT)
        )
        #expect(
            TerminalHardwareKeyRouter.routeUIKit(
                usage: 0x04,
                backend: .exec
            ) == .ghostty(GHOSTTY_KEY_A)
        )
    }

    @Test
    func `routes modified UI kit arrow keys to ghostty for in memory backends`() {
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        #expect(
            TerminalHardwareKeyRouter.routeUIKit(
                usage: 0x50,
                backend: .inMemory(session),
                modifiers: .alt
            ) == .ghostty(GHOSTTY_KEY_ARROW_LEFT)
        )
        #expect(
            TerminalHardwareKeyRouter.routeUIKit(
                usage: 0x4F,
                backend: .inMemory(session),
                modifiers: .ctrl
            ) == .ghostty(GHOSTTY_KEY_ARROW_RIGHT)
        )
        #expect(
            TerminalHardwareKeyRouter.routeUIKit(
                usage: 0x29,
                backend: .inMemory(session),
                modifiers: .super_
            ) == .ghostty(GHOSTTY_KEY_ESCAPE)
        )
        #expect(
            TerminalHardwareKeyRouter.routeUIKit(
                usage: 0x2B,
                backend: .inMemory(session),
                modifiers: .shift
            ) == .ghostty(GHOSTTY_KEY_TAB)
        )
        #expect(
            TerminalHardwareKeyRouter.routeUIKit(
                usage: 0x2A,
                backend: .inMemory(session),
                modifiers: .alt
            ) == .ghostty(GHOSTTY_KEY_BACKSPACE)
        )
    }

    @Test
    func `routes app kit arrow keys directly for in memory backends`() {
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        #expect(
            TerminalHardwareKeyRouter.routeAppKit(
                keyCode: 0x7B,
                backend: .inMemory(session)
            ) == .data(Data("\u{1B}[D".utf8))
        )
        #expect(
            TerminalHardwareKeyRouter.routeAppKit(
                keyCode: 0x75,
                backend: .inMemory(session)
            ) == .data(Data("\u{1B}[3~".utf8))
        )
        #expect(
            TerminalHardwareKeyRouter.routeAppKit(
                keyCode: 0x30,
                backend: .inMemory(session)
            ) == .data(Data([0x09]))
        )
    }

    @Test
    func `routes app kit keys to ghostty for exec backends`() {
        #expect(
            TerminalHardwareKeyRouter.routeAppKit(
                keyCode: 0x7B,
                backend: .exec
            ) == .ghostty(GHOSTTY_KEY_ARROW_LEFT)
        )
        #expect(
            TerminalHardwareKeyRouter.routeAppKit(
                keyCode: 0x33,
                backend: .exec
            ) == .ghostty(GHOSTTY_KEY_BACKSPACE)
        )
    }

    @Test
    func `app kit interpreted commands are replayed as key events`() {
        #expect(
            TerminalKeyEventHandler.shouldReplayInterpretedCommand(
                #selector(NSResponder.insertTab(_:))
            )
        )
        #expect(
            TerminalKeyEventHandler.shouldReplayInterpretedCommand(
                NSSelectorFromString("insertBacktab:")
            )
        )
        #expect(
            TerminalKeyEventHandler.shouldReplayInterpretedCommand(
                #selector(NSResponder.moveUp(_:))
            )
        )
    }

    /// Quote HID 0x34 must translate to AppKit keycode 0x27, not fall
    /// through to `0` (which is AppKit's keycode for the `A` key) nor to
    /// `GHOSTTY_KEY_QUOTE.rawValue` (which happens to equal AppKit's
    /// keycode for Tab — the original bug).
    @Test
    func `app kit key code for UI kit translates quote to mac keycode`() {
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x34) == 0x27
        )
    }

    @Test
    func `app kit key code for UI kit translates common keys`() {
        // Letter A: HID 0x04 → AppKit 0x00
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x04) == 0x00
        )
        // Tab: HID 0x2B → AppKit 0x30
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x2B) == 0x30
        )
        // Enter: HID 0x28 → AppKit 0x24
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x28) == 0x24
        )
        // ArrowUp: HID 0x52 → AppKit 0x7E
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x52) == 0x7E
        )
    }

    @Test
    func `app kit key code for ghostty keys translates common keys`() {
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_A) == 0x00
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_TAB) == 0x30
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_ESCAPE) == 0x35
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_ARROW_LEFT) == 0x7B
        )
    }

    @Test
    func `app kit key code for ghostty keys translates higher function and volume keys`() {
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_F17) == 0x40
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_F18) == 0x4F
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_F19) == 0x50
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_F20) == 0x5A
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_AUDIO_VOLUME_UP) == 0x48
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_AUDIO_VOLUME_DOWN) == 0x49
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_AUDIO_VOLUME_MUTE) == 0x4A
        )
    }

    @Test
    func `app kit key code for ghostty keys returns sentinel for keys absent from mac`() {
        let sentinel = TerminalHardwareKeyRouter.unidentifiedAppKitKeyCode
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_CONTEXT_MENU) == sentinel
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_INSERT) == sentinel
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_CUT) == sentinel
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCode(for: GHOSTTY_KEY_INTL_BACKSLASH) == sentinel
        )
    }

    /// HID usages that have no AppKit counterpart must not collapse to `0`
    /// (AppKit's keycode for `A`). They must return the sentinel so
    /// libghostty's native-keycode lookup resolves them to `.unidentified`.
    @Test
    func `app kit key code for UI kit returns sentinel for keys absent from mac`() {
        let sentinel = TerminalHardwareKeyRouter.unidentifiedAppKitKeyCode
        // CUT, COPY, PASTE, CONTEXT_MENU, INSERT, PRINT_SCREEN, SCROLL_LOCK,
        // PAUSE and the higher function keys past F20 are in uiKitMap but
        // have no AppKit virtual keycode.
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x7B) == sentinel)
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x7C) == sentinel)
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x7D) == sentinel)
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x65) == sentinel)
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x49) == sentinel)
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x46) == sentinel)
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x47) == sentinel)
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x48) == sentinel)
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x70) == sentinel)
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x71) == sentinel)
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x72) == sentinel)
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x73) == sentinel)
    }

    @Test
    func `app kit key code for UI kit translates divergent and higher function keys`() {
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x53) == 0x47
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x6C) == 0x40
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x6D) == 0x4F
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x6E) == 0x50
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x6F) == 0x5A
        )
    }

    @Test
    func `app kit key code for UI kit translates volume keys`() {
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x7F) == 0x4A
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x80) == 0x48
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x81) == 0x49
        )
    }

    /// The pinned Ghostty keycode table resolves the international backslash
    /// HID usage (`0x64`) to AppKit's ISO section keycode (`0x0A`).
    @Test
    func `app kit key code for UI kit translates intl backslash key`() {
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x64) == 0x0A
        )
        #expect(
            TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x32)
                == TerminalHardwareKeyRouter.unidentifiedAppKitKeyCode
        )
    }

    @Test
    func `route app kit recognizes higher function and volume keys`() {
        #expect(
            TerminalHardwareKeyRouter.routeAppKit(
                keyCode: 0x40,
                backend: .exec
            ) == .ghostty(GHOSTTY_KEY_F17)
        )
        #expect(
            TerminalHardwareKeyRouter.routeAppKit(
                keyCode: 0x5A,
                backend: .exec
            ) == .ghostty(GHOSTTY_KEY_F20)
        )
        #expect(
            TerminalHardwareKeyRouter.routeAppKit(
                keyCode: 0x48,
                backend: .exec
            ) == .ghostty(GHOSTTY_KEY_AUDIO_VOLUME_UP)
        )
        #expect(
            TerminalHardwareKeyRouter.routeAppKit(
                keyCode: 0x4A,
                backend: .exec
            ) == .ghostty(GHOSTTY_KEY_AUDIO_VOLUME_MUTE)
        )
    }

    @Test
    func `app kit key code for UI kit returns sentinel for unknown HID`() {
        // HID usages not in uiKitMap at all.
        let sentinel = TerminalHardwareKeyRouter.unidentifiedAppKitKeyCode
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0xFFFE) == sentinel)
        #expect(TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x0001) == sentinel)
    }

    @Test
    func `app kit direct input requires no modifiers`() {
        #expect(
            TerminalKeyEventHandler.shouldUseDirectInput(
                modifierFlags: []
            )
        )
        #expect(
            !TerminalKeyEventHandler.shouldUseDirectInput(
                modifierFlags: [.shift]
            )
        )
        #expect(
            !TerminalKeyEventHandler.shouldUseDirectInput(
                modifierFlags: [.control]
            )
        )
        #expect(
            !TerminalKeyEventHandler.shouldUseDirectInput(
                modifierFlags: [.option]
            )
        )
        #expect(
            !TerminalKeyEventHandler.shouldUseDirectInput(
                modifierFlags: [.command]
            )
        )
    }
}
