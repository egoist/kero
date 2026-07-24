//
//  TerminalStickyModifierState.swift
//  libghostty-spm
//

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
    import Foundation

    @MainActor
    final class TerminalStickyModifierState {
        enum Activation { case inactive, armed, locked }
        enum Modifier { case ctrl, alt, command }

        private(set) var ctrl: Activation = .inactive
        private(set) var alt: Activation = .inactive
        private(set) var command: Activation = .inactive

        var onChange: (() -> Void)?

        private var lastCtrlTap: Date = .distantPast
        private var lastAltTap: Date = .distantPast
        private var lastCommandTap: Date = .distantPast
        private let doubleTapInterval: TimeInterval = 0.3

        func toggle(_ modifier: Modifier) {
            switch modifier {
            case .ctrl:
                ctrl = nextActivation(ctrl, lastTap: lastCtrlTap)
                lastCtrlTap = Date()
            case .alt:
                alt = nextActivation(alt, lastTap: lastAltTap)
                lastAltTap = Date()
            case .command:
                command = nextActivation(command, lastTap: lastCommandTap)
                lastCommandTap = Date()
            }
            onChange?()
        }

        func consumeForNextKey() -> TerminalInputModifiers {
            var mods = TerminalInputModifiers()
            if ctrl != .inactive { mods.insert(.ctrl) }
            if alt != .inactive { mods.insert(.alt) }
            if command != .inactive { mods.insert(.super_) }
            if ctrl == .armed { ctrl = .inactive }
            if alt == .armed { alt = .inactive }
            if command == .armed { command = .inactive }
            onChange?()
            return mods
        }

        var hasActiveModifiers: Bool {
            ctrl != .inactive || alt != .inactive || command != .inactive
        }

        func reset() {
            guard hasActiveModifiers else { return }
            ctrl = .inactive
            alt = .inactive
            command = .inactive
            onChange?()
        }

        private func nextActivation(
            _ current: Activation,
            lastTap: Date
        ) -> Activation {
            switch current {
            case .inactive:
                return .armed
            case .armed:
                if Date().timeIntervalSince(lastTap) < doubleTapInterval {
                    return .locked
                }
                return .inactive
            case .locked:
                return .inactive
            }
        }
    }
#endif
