//
//  AppSettings.swift
//  mitty
//

import Combine
import Foundation

/// User-configurable settings, persisted in UserDefaults. Views observe
/// this directly; `TerminalManager` re-themes live sessions on any change.
@MainActor
final class AppSettings: nonisolated ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let fontFamily = "terminalFontFamily"
        static let fontSize = "terminalFontSize"
    }

    static let defaultFontSize: Double = 13
    static let fontSizeRange: ClosedRange<Double> = 8...32

    /// Terminal font family name; empty string means the bundled default
    /// (JetBrains Mono).
    @Published var fontFamily: String {
        didSet { UserDefaults.standard.set(fontFamily, forKey: Keys.fontFamily) }
    }

    @Published var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Keys.fontSize) }
    }

    private init() {
        let defaults = UserDefaults.standard
        fontFamily = defaults.string(forKey: Keys.fontFamily) ?? ""
        let size = defaults.double(forKey: Keys.fontSize)
        fontSize = Self.fontSizeRange.contains(size) ? size : Self.defaultFontSize
    }

    func resetFont() {
        fontFamily = ""
        fontSize = Self.defaultFontSize
    }
}
