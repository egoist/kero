//
//  TerminalHistory.swift
//  kero
//

import Foundation
import SwiftTerm

/// Serializes a terminal's scrollback + on-screen buffer to an ANSI byte
/// stream that can be fed back into a fresh terminal to reproduce what the
/// user saw — colors and text styles included. This is how a relaunched
/// session shows its previous output above the new shell prompt.
///
/// Only the *normal* buffer is captured: a full-screen program (vim, less)
/// runs on the alternate buffer, and replaying that as static text would be
/// meaningless — `TerminalSession` handles that case by reusing the last
/// normal-buffer capture instead.
enum TerminalHistorySerializer {
    /// Builds the ANSI history for `terminal`, keeping at most the last
    /// `maxLines` non-empty lines. Returns nil when there is nothing to save.
    static func serialize(terminal: Terminal, maxLines: Int) -> String? {
        guard maxLines > 0 else { return nil }

        // `getScrollInvariantLine` indexes from the top of the scrollback,
        // which starts at `totalLinesTrimmed` (lines already evicted from the
        // ring). Walk upward until it runs off the end.
        let start = terminal.buffer.totalLinesTrimmed
        var lines: [String] = []
        var row = start
        while let line = terminal.getScrollInvariantLine(row: row) {
            lines.append(encode(line: line))
            row += 1
        }

        // The bottom of the buffer is usually blank rows below the last prompt;
        // dropping them keeps the restored prompt from starting pages down.
        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return nil }

        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        return lines.joined(separator: "\r\n")
    }

    /// Encodes one buffer line: the shortest run of SGR escapes that reproduces
    /// its per-cell colors and styles, followed by the characters. Trailing
    /// blank cells are dropped and a reset is appended only when the line ends
    /// mid-attribute.
    private static func encode(line: BufferLine) -> String {
        let length = line.getTrimmedLength()
        guard length > 0 else { return "" }

        var out = ""
        var current = Attribute.empty
        var dirty = false
        for col in 0..<length {
            let cell = line[col]
            // The trailing half of a wide (CJK/emoji) cell carries no glyph.
            if cell.width == 0 { continue }
            let attribute = cell.attribute
            if attribute != current {
                out += sgr(for: attribute)
                current = attribute
                dirty = true
            }
            let character = cell.getCharacter()
            // Interior null cells (gaps) render as spaces, never a raw NUL.
            out.append(character == "\0" ? " " : character)
        }
        if dirty && current != Attribute.empty {
            out += "\u{1b}[0m"
        }
        return out
    }

    /// The SGR sequence that establishes `attribute` from a clean slate. Always
    /// starts with a reset (`0`) so each run fully specifies its own state.
    private static func sgr(for attribute: Attribute) -> String {
        var codes = "0"
        let style = attribute.style
        if style.contains(.bold) { codes += ";1" }
        if style.contains(.dim) { codes += ";2" }
        if style.contains(.italic) { codes += ";3" }
        if style.contains(.underline) { codes += ";4" }
        if style.contains(.blink) { codes += ";5" }
        if style.contains(.inverse) { codes += ";7" }
        if style.contains(.invisible) { codes += ";8" }
        if style.contains(.crossedOut) { codes += ";9" }
        codes += colorCode(attribute.fg, foreground: true)
        codes += colorCode(attribute.bg, foreground: false)
        return "\u{1b}[\(codes)m"
    }

    /// SGR fragment for one color slot. Default colors emit nothing — the
    /// leading reset already selects them.
    private static func colorCode(_ color: Attribute.Color, foreground: Bool) -> String {
        switch color {
        case .ansi256(let code) where code < 8:
            return ";\((foreground ? 30 : 40) + Int(code))"
        case .ansi256(let code) where code < 16:
            return ";\((foreground ? 90 : 100) + Int(code) - 8)"
        case .ansi256(let code):
            return ";\(foreground ? 38 : 48);5;\(code)"
        case .trueColor(let r, let g, let b):
            return ";\(foreground ? 38 : 48);2;\(r);\(g);\(b)"
        case .defaultColor, .defaultInvertedColor:
            return ""
        }
    }
}

/// Persists per-session terminal history to a sidecar file, keyed by an opaque
/// string that the session layout snapshot (in `UserDefaults`) references. Kept
/// out of the snapshot itself so `UserDefaults` never holds large blobs.
///
/// Each save rewrites the whole file from the live set of sessions, so keys
/// belonging to sessions that no longer exist are pruned automatically.
enum TerminalHistoryStore {
    /// Debug builds keep their state under `kero-dev`, matching `AppSettings`
    /// and the separate `sh.kero.dev` bundle id, so a dev build never clobbers
    /// an installed production build's history.
    private static let fileURL: URL = {
        #if DEBUG
        let directory = "kero-dev"
        #else
        let directory = "kero"
        #endif
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent("terminal-history.json")
    }()

    static func save(_ histories: [String: String]) {
        // Nothing to persist: remove the file so a later restore finds nothing
        // rather than replaying stale output.
        guard !histories.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? JSONEncoder().encode(histories) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("kero: failed to write \(fileURL.path): \(error)")
        }
    }

    static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let histories = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return histories
    }
}
