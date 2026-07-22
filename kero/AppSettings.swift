//
//  AppSettings.swift
//  kero
//

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

    /// Terminal font family name; empty string means the bundled default
    /// (JetBrains Mono).
    @Published var fontFamily: String {
        didSet { save() }
    }

    @Published var fontSize: Double {
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

    private init() {
        let existing = TOML.parse(at: Self.configURL)
        let toml = existing ?? Self.legacyDefaults()
        fontFamily = toml["font-family"]?.string ?? ""
        let size = toml["font-size"]?.double ?? Self.defaultFontSize
        fontSize = Self.fontSizeRange.contains(size) ? size : Self.defaultFontSize
        wrapLines = toml["editor.wrap-lines"]?.bool ?? false
        restoreTerminalHistory = toml["terminal.restore-history"]?.bool ?? false
        if existing == nil { save() }
    }

    func resetFont() {
        fontFamily = ""
        fontSize = Self.defaultFontSize
    }

    func resetToDefaults() {
        resetFont()
        wrapLines = false
        restoreTerminalHistory = false
    }

    private func save() {
        var lines: [String] = []
        if !fontFamily.isEmpty {
            lines.append("font-family = \(TOML.quote(fontFamily))")
        }
        lines.append("font-size = \(TOML.number(fontSize))")
        if wrapLines {
            lines.append("editor.wrap-lines = true")
        }
        if restoreTerminalHistory {
            lines.append("terminal.restore-history = true")
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
