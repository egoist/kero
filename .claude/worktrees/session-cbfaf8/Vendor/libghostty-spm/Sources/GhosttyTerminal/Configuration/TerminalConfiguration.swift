//
//  TerminalConfiguration.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

public enum TerminalCursorStyle: String, Sendable, Hashable {
    case block
    case bar
    case underline
}

public enum TerminalConfigCommand: Sendable, Hashable {
    // Font
    case fontFamily(String)
    case fontSize(Float)
    case fontThicken(Bool)
    case fontThickenStrength(Int)

    // Cursor
    case cursorStyle(TerminalCursorStyle)
    case cursorStyleBlink(Bool)
    case cursorColor(String)
    case cursorText(String)
    case cursorOpacity(Double)

    // Colors
    case background(String)
    case foreground(String)
    case selectionBackground(String)
    case selectionForeground(String)
    case boldColor(String)
    case palette(index: Int, color: String)
    case minimumContrast(Double)

    // Background
    case backgroundOpacity(Double)
    case backgroundBlur(Int)

    // Layout
    case windowPaddingX(Int)
    case windowPaddingY(Int)

    /// Escape hatch
    case custom(key: String, value: String)

    var renderedLine: String {
        switch self {
        case let .fontFamily(value):
            "font-family = \(value)"

        case let .fontSize(value):
            "font-size = \(value.formatted(.number.precision(.fractionLength(0 ... 2))))"

        case let .fontThicken(enabled):
            "font-thicken = \(enabled)"

        case let .fontThickenStrength(value):
            "font-thicken-strength = \(value)"

        case let .cursorStyle(style):
            "cursor-style = \(style.rawValue)"

        case let .cursorStyleBlink(enabled):
            "cursor-style-blink = \(enabled)"

        case let .cursorColor(value):
            "cursor-color = \(value)"

        case let .cursorText(value):
            "cursor-text = \(value)"

        case let .cursorOpacity(value):
            "cursor-opacity = \(value.formatted(.number.precision(.fractionLength(0 ... 3))))"

        case let .background(value):
            "background = \(value)"

        case let .foreground(value):
            "foreground = \(value)"

        case let .selectionBackground(value):
            "selection-background = \(value)"

        case let .selectionForeground(value):
            "selection-foreground = \(value)"

        case let .boldColor(value):
            "bold-color = \(value)"

        case let .palette(index, color):
            "palette = \(index)=\(color)"

        case let .minimumContrast(value):
            "minimum-contrast = \(value.formatted(.number.precision(.fractionLength(0 ... 2))))"

        case let .backgroundOpacity(value):
            "background-opacity = \(value.formatted(.number.precision(.fractionLength(0 ... 3))))"

        case let .backgroundBlur(value):
            "background-blur = \(value)"

        case let .windowPaddingX(value):
            "window-padding-x = \(value)"

        case let .windowPaddingY(value):
            "window-padding-y = \(value)"

        case let .custom(key, value):
            "\(key) = \(value)"
        }
    }
}

public struct TerminalConfiguration: Sendable, Hashable {
    public struct Builder {
        var commands: [TerminalConfigCommand] = []

        public init() {}

        init(commands: [TerminalConfigCommand]) {
            self.commands = commands
        }

        /// Font
        public mutating func withFontFamily(_ value: String) {
            commands.append(.fontFamily(value))
        }

        public mutating func withFontSize(_ value: Float) {
            commands.append(.fontSize(value))
        }

        public mutating func withFontThicken(_ enabled: Bool) {
            commands.append(.fontThicken(enabled))
        }

        public mutating func withFontThickenStrength(_ value: Int) {
            commands.append(.fontThickenStrength(value))
        }

        /// Cursor
        public mutating func withCursorStyle(_ style: TerminalCursorStyle) {
            commands.append(.cursorStyle(style))
        }

        public mutating func withCursorStyleBlink(_ enabled: Bool) {
            commands.append(.cursorStyleBlink(enabled))
        }

        public mutating func withCursorColor(_ value: String) {
            commands.append(.cursorColor(value))
        }

        public mutating func withCursorText(_ value: String) {
            commands.append(.cursorText(value))
        }

        public mutating func withCursorOpacity(_ value: Double) {
            commands.append(.cursorOpacity(value))
        }

        /// Colors
        public mutating func withBackground(_ value: String) {
            commands.append(.background(value))
        }

        public mutating func withForeground(_ value: String) {
            commands.append(.foreground(value))
        }

        public mutating func withSelectionBackground(_ value: String) {
            commands.append(.selectionBackground(value))
        }

        public mutating func withSelectionForeground(_ value: String) {
            commands.append(.selectionForeground(value))
        }

        public mutating func withBoldColor(_ value: String) {
            commands.append(.boldColor(value))
        }

        public mutating func withPalette(_ index: Int, color: String) {
            commands.append(.palette(index: index, color: color))
        }

        public mutating func withMinimumContrast(_ value: Double) {
            commands.append(.minimumContrast(value))
        }

        /// Background
        public mutating func withBackgroundOpacity(_ value: Double) {
            commands.append(.backgroundOpacity(value))
        }

        public mutating func withBackgroundBlur(_ value: Int) {
            commands.append(.backgroundBlur(value))
        }

        /// Layout
        public mutating func withWindowPaddingX(_ value: Int) {
            commands.append(.windowPaddingX(value))
        }

        public mutating func withWindowPaddingY(_ value: Int) {
            commands.append(.windowPaddingY(value))
        }

        /// Escape hatch
        public mutating func withCustom(_ key: String, _ value: String) {
            commands.append(.custom(key: key, value: value))
        }
    }

    let commands: [TerminalConfigCommand]

    public init() {
        commands = []
    }

    public init(configure: (inout Builder) -> Void) {
        self.init(startingFrom: .init(), configure: configure)
    }

    public init(
        startingFrom base: TerminalConfiguration,
        configure: (inout Builder) -> Void
    ) {
        var builder = Builder(commands: base.commands)
        configure(&builder)
        commands = builder.commands
    }

    public func appending(_ command: TerminalConfigCommand) -> TerminalConfiguration {
        TerminalConfiguration(commands: commands + [command])
    }

    // MARK: - Font

    public func fontFamily(_ value: String) -> TerminalConfiguration {
        appending(.fontFamily(value))
    }

    public func fontSize(_ value: Float) -> TerminalConfiguration {
        appending(.fontSize(value))
    }

    public func fontThicken(_ enabled: Bool) -> TerminalConfiguration {
        appending(.fontThicken(enabled))
    }

    public func fontThickenStrength(_ value: Int) -> TerminalConfiguration {
        appending(.fontThickenStrength(value))
    }

    // MARK: - Cursor

    public func cursorStyle(_ style: TerminalCursorStyle) -> TerminalConfiguration {
        appending(.cursorStyle(style))
    }

    public func cursorStyleBlink(_ enabled: Bool) -> TerminalConfiguration {
        appending(.cursorStyleBlink(enabled))
    }

    public func cursorColor(_ value: String) -> TerminalConfiguration {
        appending(.cursorColor(value))
    }

    public func cursorText(_ value: String) -> TerminalConfiguration {
        appending(.cursorText(value))
    }

    public func cursorOpacity(_ value: Double) -> TerminalConfiguration {
        appending(.cursorOpacity(value))
    }

    // MARK: - Colors

    public func background(_ value: String) -> TerminalConfiguration {
        appending(.background(value))
    }

    public func foreground(_ value: String) -> TerminalConfiguration {
        appending(.foreground(value))
    }

    public func selectionBackground(_ value: String) -> TerminalConfiguration {
        appending(.selectionBackground(value))
    }

    public func selectionForeground(_ value: String) -> TerminalConfiguration {
        appending(.selectionForeground(value))
    }

    public func boldColor(_ value: String) -> TerminalConfiguration {
        appending(.boldColor(value))
    }

    public func palette(_ index: Int, color: String) -> TerminalConfiguration {
        appending(.palette(index: index, color: color))
    }

    public func minimumContrast(_ value: Double) -> TerminalConfiguration {
        appending(.minimumContrast(value))
    }

    // MARK: - Background

    public func backgroundOpacity(_ value: Double) -> TerminalConfiguration {
        appending(.backgroundOpacity(value))
    }

    public func backgroundBlur(_ value: Int) -> TerminalConfiguration {
        appending(.backgroundBlur(value))
    }

    // MARK: - Layout

    public func windowPaddingX(_ value: Int) -> TerminalConfiguration {
        appending(.windowPaddingX(value))
    }

    public func windowPaddingY(_ value: Int) -> TerminalConfiguration {
        appending(.windowPaddingY(value))
    }

    // MARK: - Escape Hatch

    public func custom(_ key: String, _ value: String) -> TerminalConfiguration {
        appending(.custom(key: key, value: value))
    }

    // MARK: - Defaults

    public static let `default` = TerminalConfiguration { builder in
        builder.withCursorStyle(.block)
        builder.withCursorStyleBlink(true)
        #if os(iOS)
            builder.withFontSize(10)
        #else
            builder.withFontSize(14)
        #endif
        builder.withFontThicken(true)
    }

    public var rendered: String {
        commands.map(\.renderedLine).joined(separator: "\n")
    }

    var isEmpty: Bool {
        commands.isEmpty
    }

    init(commands: [TerminalConfigCommand]) {
        self.commands = commands
    }
}
