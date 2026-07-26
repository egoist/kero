//
//  AppSettings.swift
//  kero
//

import AppKit
import Combine
import Foundation

/// User-configurable settings, persisted to `$HOME/.config/kero/config.toml`.
/// Views observe this directly; `TerminalManager` re-themes live sessions on
/// any change.
@MainActor
final class AppSettings: nonisolated ObservableObject {
    static let shared = AppSettings()

    /// Development (Debug) builds store their config under `~/.config/kero-dev`
    /// instead of `~/.config/kero`, so running a dev build alongside an
    /// installed production build doesn't clobber its settings. This mirrors
    /// the separate `sh.kero.dev` bundle identifier that keeps the two apps'
    /// `UserDefaults` (session snapshot, sidebar widths, Sparkle) apart.
    static let configURL: URL = {
        #if DEBUG
        let directory = "kero-dev"
        #else
        let directory = "kero"
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/\(directory)/config.toml")
    }()

    static let defaultFontSize: Double = 13
    static let fontSizeRange: ClosedRange<Double> = 8...32

    /// Light/dark appearance override; `system` follows macOS.
    @Published var theme: AppTheme {
        didSet {
            applyAppearance()
            save()
        }
    }

    /// Color theme names, one per appearance; the terminal, window chrome,
    /// and editor all derive from them. `Theme` keeps the resolved
    /// definitions (kero built-ins plus the ghostty catalog).
    @Published var themeDark: String {
        didSet {
            reloadThemeSelection()
            save()
        }
    }

    @Published var themeLight: String {
        didSet {
            reloadThemeSelection()
            save()
        }
    }

    /// Terminal font family name; empty string means the bundled default
    /// (JetBrains Mono).
    @Published var fontFamily: String {
        didSet { save() }
    }

    @Published var fontSize: Double {
        didSet { save() }
    }

    /// Ghostty's `font-thicken`: render glyphs with slightly heavier strokes,
    /// like classic macOS font smoothing. Off by default so kero's text
    /// matches a stock Ghostty install.
    @Published var fontThicken: Bool {
        didSet { save() }
    }

    /// Soft-wrap file editor lines to the viewport width. Off by default so
    /// long lines scroll horizontally.
    @Published var wrapLines: Bool {
        didSet { save() }
    }

    /// Restore each terminal's previous scrollback (as static, styled text)
    /// when the app relaunches, above the freshly started shell. Off by
    /// default: opt-in, and it writes captured output to disk.
    @Published var restoreTerminalHistory: Bool {
        didSet { save() }
    }

    /// Which emulator drives terminal panes. Only ever holds a backend this
    /// build ships a surface for — see `TerminalBackend` — and a session binds
    /// its backend at creation, so a change here reaches terminals opened
    /// afterwards rather than live ones.
    @Published var terminalBackend: TerminalBackend {
        didSet { save() }
    }

    private init() {
        let existing = TOML.parse(at: Self.configURL)
        let toml = existing ?? Self.legacyDefaults()
        theme = toml["theme"]?.string.flatMap(AppTheme.init(rawValue:)) ?? .system
        themeDark = Self.knownTheme(
            toml["theme-dark"]?.string, fallback: Theme.defaultDarkThemeName
        )
        themeLight = Self.knownTheme(
            toml["theme-light"]?.string, fallback: Theme.defaultLightThemeName
        )
        fontFamily = toml["font-family"]?.string ?? ""
        let size = toml["font-size"]?.double ?? Self.defaultFontSize
        fontSize = Self.fontSizeRange.contains(size) ? size : Self.defaultFontSize
        fontThicken = toml["font-thicken"]?.bool ?? false
        wrapLines = toml["editor.wrap-lines"]?.bool ?? false
        restoreTerminalHistory = toml["terminal.restore-history"]?.bool ?? false
        terminalBackend = TerminalBackend(persisted: toml["terminal.backend"]?.string)
        applyAppearance()
        reloadThemeSelection()
        if existing == nil { save() }
    }

    /// Pushes the current names into `Theme`, which resolves and caches the
    /// definitions. Called from `init` because `didSet` doesn't run there.
    private func reloadThemeSelection() {
        Theme.reloadSelection(light: themeLight, dark: themeDark)
    }

    /// A saved theme name, or `fallback` when it's absent or names neither a
    /// kero built-in nor a catalog theme (so the Settings pickers never show
    /// an empty selection).
    private static func knownTheme(_ name: String?, fallback: String) -> String {
        guard let name, Theme.definition(named: name) != nil else {
            return fallback
        }
        return name
    }

    /// Overrides the app-wide appearance so every window — and the terminal
    /// theme, which reads `NSApp.effectiveAppearance` — follows the choice.
    /// Called from `init` because `didSet` doesn't run during initialization.
    func applyAppearance() {
        NSApp?.appearance = theme.nsAppearance
    }

    func resetFont() {
        fontFamily = ""
        fontSize = Self.defaultFontSize
        fontThicken = false
    }

    func resetToDefaults() {
        resetFont()
        theme = .system
        themeDark = Theme.defaultDarkThemeName
        themeLight = Theme.defaultLightThemeName
        wrapLines = false
        restoreTerminalHistory = false
        terminalBackend = .fallback
    }

    private func save() {
        var lines: [String] = []
        if theme != .system {
            lines.append("theme = \(TOML.quote(theme.rawValue))")
        }
        // Top-level like `theme`: the color theme drives the whole window,
        // not just the terminal.
        if themeDark != Theme.defaultDarkThemeName {
            lines.append("theme-dark = \(TOML.quote(themeDark))")
        }
        if themeLight != Theme.defaultLightThemeName {
            lines.append("theme-light = \(TOML.quote(themeLight))")
        }
        if !fontFamily.isEmpty {
            lines.append("font-family = \(TOML.quote(fontFamily))")
        }
        lines.append("font-size = \(TOML.number(fontSize))")
        if fontThicken {
            lines.append("font-thicken = true")
        }
        if wrapLines {
            lines.append("editor.wrap-lines = true")
        }
        if restoreTerminalHistory {
            lines.append("terminal.restore-history = true")
        }
        if terminalBackend != .fallback {
            lines.append("terminal.backend = \(TOML.quote(terminalBackend.rawValue))")
        }
        let dir = Self.configURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n")
                .write(to: Self.configURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("kero: failed to write \(Self.configURL.path): \(error)")
        }
    }

    /// Settings from releases that stored config in UserDefaults.
    private static func legacyDefaults() -> [String: TOML.Value] {
        var toml: [String: TOML.Value] = [:]
        let defaults = UserDefaults.standard
        if let family = defaults.string(forKey: "terminalFontFamily") {
            toml["font-family"] = .string(family)
        }
        if defaults.object(forKey: "terminalFontSize") != nil {
            toml["font-size"] = .number(defaults.double(forKey: "terminalFontSize"))
        }
        return toml
    }
}

/// Minimal TOML support covering what the config file uses: flat and dotted
/// keys (`font-size = 15`, `terminal.restore-history = true`), string/number/
/// bool values, and `#` comments. `[table]` headers are also accepted and
/// flattened to `table.key`, matching the dotted form.
enum TOML {
    enum Value {
        case string(String)
        case number(Double)
        case bool(Bool)

        var string: String? {
            if case .string(let s) = self { return s }
            return nil
        }

        var double: Double? {
            if case .number(let n) = self { return n }
            return nil
        }

        var bool: Bool? {
            if case .bool(let b) = self { return b }
            return nil
        }
    }

    static func parse(at url: URL) -> [String: Value]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        var table = ""
        var result: [String: Value] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                table = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, let value = parseValue(rawValue) else { continue }
            result[table.isEmpty ? key : "\(table).\(key)"] = value
        }
        return result
    }

    private static func parseValue(_ raw: String) -> Value? {
        if raw.hasPrefix("\"") {
            var out = ""
            var escaped = false
            for ch in raw.dropFirst() {
                if escaped {
                    switch ch {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    default: out.append(ch)
                    }
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    return .string(out)
                } else {
                    out.append(ch)
                }
            }
            return nil
        }
        // Unquoted: strip a trailing comment, then try bool/number.
        let bare = raw.split(separator: "#", maxSplits: 1)[0]
            .trimmingCharacters(in: .whitespaces)
        switch bare {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: return Double(bare).map(Value.number)
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\"", "\\": out.append("\\\(ch)")
            case "\n": out.append("\\n")
            case "\t": out.append("\\t")
            default: out.append(ch)
            }
        }
        return out + "\""
    }

    static func number(_ n: Double) -> String {
        n == n.rounded() && abs(n) < 1e15
            ? String(Int(n)) : String(n)
    }
}
