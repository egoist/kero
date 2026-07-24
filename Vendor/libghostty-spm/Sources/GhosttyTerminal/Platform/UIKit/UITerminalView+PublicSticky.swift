//
//  UITerminalView+PublicSticky.swift
//  libghostty-spm
//
//  Public wrappers around the iOS sticky-modifier state machine so
//  hosts that suppress `inputAccessoryView` (and supply their own chip
//  pill UI) can still drive the same Ctrl/Alt/Cmd sticky path that the
//  bundled `TerminalInputAccessoryView` uses.
//
//  Without this surface a host with a custom keyboard accessory has to
//  either:
//    * reimplement the full sticky state machine + IME compose handshake
//      in app code (fragile, has to mirror libghostty internals), OR
//    * intercept the outbound surface byte stream and try to transform
//      bytes after-the-fact (breaks because libghostty wraps every
//      `surface.sendText` call in bracketed-paste markers when the
//      remote shell enabled mode 2004).
//
//  Forwarding to the existing internal `stickyModifiers` keeps a
//  single source of truth — the bundled accessory and the host's
//  custom chip UI both end up calling the same `toggle(_:)` /
//  `consumeForNextKey()` codepath that `insertText` already respects.
//

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
    import Foundation
    import UIKit

    /// Public mirror of the internal `TerminalStickyModifierState.Modifier`
    /// enum. Decoupled so the internal type stays free to evolve.
    public enum TerminalPublicStickyModifier: String, Sendable {
        case ctrl
        case alt
        case command
    }

    /// Public mirror of `TerminalStickyModifierState.Activation`.
    public enum TerminalPublicStickyActivation: String, Sendable {
        case inactive
        case armed
        case locked
    }

    @MainActor
    extension UITerminalView {
        /// Toggle the sticky activation for `modifier`. Tap-to-arm,
        /// double-tap-to-lock semantics match the bundled accessory.
        /// Safe to call regardless of whether `inputAccessoryView` is
        /// currently shown — only mutates the internal state machine,
        /// which `insertText` consults on every keystroke.
        public func toggleStickyModifier(_ modifier: TerminalPublicStickyModifier) {
            stickyModifiers.toggle(internalModifier(for: modifier))
        }

        /// Read current activation for inspection / sync (e.g. host UI
        /// reflecting state changes triggered by the bundled accessory).
        public func stickyActivation(
            for modifier: TerminalPublicStickyModifier
        ) -> TerminalPublicStickyActivation {
            switch modifier {
            case .ctrl: publicActivation(stickyModifiers.ctrl)
            case .alt: publicActivation(stickyModifiers.alt)
            case .command: publicActivation(stickyModifiers.command)
            }
        }

        /// True iff any modifier is `.armed` or `.locked`.
        public var hasActiveStickyModifiers: Bool {
            stickyModifiers.hasActiveModifiers
        }

        /// Clear all sticky activation. No-op when nothing is active.
        public func resetStickyModifiers() {
            stickyModifiers.reset()
        }

        /// Subscribe to sticky-state changes. Called on every transition
        /// (toggle / consume / reset). Replaces any prior closure — pass
        /// `nil` to detach. Useful for host UIs that mirror the activation
        /// in their own chip pill.
        public func setStickyModifierChangeHandler(_ handler: (() -> Void)?) {
            stickyModifiers.onChange = handler
        }

        // MARK: - Internal mappers

        private func internalModifier(
            for modifier: TerminalPublicStickyModifier
        ) -> TerminalStickyModifierState.Modifier {
            switch modifier {
            case .ctrl: .ctrl
            case .alt: .alt
            case .command: .command
            }
        }

        private func publicActivation(
            _ activation: TerminalStickyModifierState.Activation
        ) -> TerminalPublicStickyActivation {
            switch activation {
            case .inactive: .inactive
            case .armed: .armed
            case .locked: .locked
            }
        }
    }
#endif
