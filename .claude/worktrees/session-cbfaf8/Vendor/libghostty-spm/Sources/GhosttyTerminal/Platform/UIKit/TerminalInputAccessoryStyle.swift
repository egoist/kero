//
//  TerminalInputAccessoryStyle.swift
//  libghostty-spm
//

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
    import UIKit

    public struct TerminalInputAccessoryStyle: Sendable {
        public var regularBackground: UIColor
        public var regularForeground: UIColor
        public var activeBackground: UIColor
        public var activeForeground: UIColor

        public init(
            regularBackground: UIColor = UIColor.systemGray5.withAlphaComponent(0.92),
            regularForeground: UIColor = .label,
            activeBackground: UIColor = .systemBlue,
            activeForeground: UIColor = .white
        ) {
            self.regularBackground = regularBackground
            self.regularForeground = regularForeground
            self.activeBackground = activeBackground
            self.activeForeground = activeForeground
        }

        public static let `default` = TerminalInputAccessoryStyle()
    }
#endif
