//
//  TerminalHistory.swift
//  kero
//

import AppKit
import Darwin
import Foundation

/// Captures and normalizes styled terminal history without reaching into a
/// terminal backend's buffer representation. A backend writes its screen to a
/// temporary VT file; the rest of this utility operates only on that stream.
enum TerminalHistorySerializer {
    enum CaptureResult {
        case captured(String?)
        case failed
    }

    private static let reset = "\u{1b}[0m"

    /// Captures the screen and scrollback a backend exports, keeping at most
    /// the last `maxLines` rows.
    @MainActor
    static func capture(
        from surface: any TerminalBackendSurface, maxLines: Int
    ) -> CaptureResult {
        guard maxLines > 0,
              let captureFile = validatedCaptureFile(for: surface.exportScreenFile())
        else { return .failed }
        defer { removeCaptureFile(captureFile) }

        guard let capturedVT = try? String(contentsOf: captureFile.fileURL, encoding: .utf8) else {
            return .failed
        }
        return .captured(normalizedHistory(from: capturedVT, maxLines: maxLines))
    }

    /// Plain visible rows for the Ctrl-Tab thumbnail. This uses the backend's
    /// screen export instead of AppKit bitmap caching because a framebuffer-
    /// only Metal layer cannot be captured reliably. Only the tail of a large
    /// export is read, keeping interactive tab switching bounded even when a
    /// session has megabytes of scrollback.
    @MainActor
    static func previewText(
        from surface: any TerminalBackendSurface,
        maxLines: Int,
        maxColumns: Int
    ) -> String? {
        guard maxLines > 0, maxColumns > 0,
              let captureFile = validatedCaptureFile(for: surface.exportScreenFile())
        else { return nil }
        defer { removeCaptureFile(captureFile) }

        guard let handle = try? FileHandle(forReadingFrom: captureFile.fileURL) else {
            return nil
        }
        defer { try? handle.close() }

        // Enough for many full terminal viewports, while staying cheap if the
        // exported file contains Kero's full scrollback allowance.
        let byteLimit: UInt64 = 128 * 1024
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > byteLimit ? end - byteLimit : 0
        do {
            try handle.seek(toOffset: start)
        } catch {
            return nil
        }
        guard let data = try? handle.read(upToCount: Int(end - start)),
              !data.isEmpty
        else { return nil }

        var capture = String(decoding: data, as: UTF8.self)
        // A tail read can start halfway through a UTF-8 scalar or ANSI run.
        // Discard its first partial row so no fragment reaches the thumbnail.
        if start > 0, let newline = capture.firstIndex(of: "\n") {
            capture.removeSubrange(...newline)
        }
        capture = capture
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var lines = capture
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { visibleText(in: String($0)) }

        while let last = lines.last,
              last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return nil }

        return lines.suffix(maxLines).map { line in
            var cropped = String(line.prefix(maxColumns))
            while cropped.last == " " || cropped.last == "\t" {
                cropped.removeLast()
            }
            return cropped
        }
        .joined(separator: "\n")
    }

    /// A positive-only probe for a primary-buffer scrollback snapshot. A
    /// backend does not export scrollback while an alternate buffer is active,
    /// but an empty primary buffer also produces no file, so false is
    /// inconclusive.
    @MainActor
    static func hasPrimaryScrollback(_ surface: any TerminalBackendSurface) -> Bool {
        guard let captureFile = validatedCaptureFile(
            for: surface.exportScrollbackFile()
        ) else { return false }
        removeCaptureFile(captureFile)
        return true
    }

    /// Label shown in the restored-history divider.
    static let restoredBannerLabel = "Session Contents Restored"

    /// The rule that brackets the label on each side of the divider.
    private static let restoredBannerRule = String(repeating: "\u{2500}", count: 4)

    /// The divider's plain, unstyled text — `<rule> <label> <rule>`. `visibleText`
    /// yields exactly this for a divider row, so recognizing one is an equality
    /// check against it.
    private static var restoredBannerText: String {
        "\(restoredBannerRule) \(restoredBannerLabel) \(restoredBannerRule)"
    }

    /// A single-line divider fed into the terminal directly beneath replayed
    /// scrollback, marking where the restored output ends and the live shell
    /// begins. Rendered with default colors so it tracks the light/dark theme:
    /// a fixed run of dim rule characters brackets the normal-weight label.
    ///
    /// The rule is a fixed width rather than one spanning the terminal on
    /// purpose. The column count is not reliably known when the banner is built
    /// — the view has not been laid out at its final size yet — so a full-width
    /// rule sized to the wrong count wraps onto a second line. A short rule
    /// always fits and reads the same at any width.
    static func restoredBanner() -> String {
        let dim = "\u{1b}[2m"
        let normal = "\u{1b}[22m"
        return dim + restoredBannerRule + " " + normal
            + restoredBannerLabel + dim + " " + restoredBannerRule + reset
    }

    /// Normalizes a backend-emitted VT stream for replay into a fresh terminal.
    private static func normalizedHistory(from capture: String, maxLines: Int) -> String? {
        let capture = strippingColorConfigurationOSC(from: capture)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var lines = capture
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !isRestoredBanner($0) }

        // Screen dumps include unused rows below the last prompt. ANSI-only
        // rows (for example a trailing SGR reset) are blank for this purpose.
        while let last = lines.last, isVisiblyBlank(last) {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return nil }

        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }

        let history = lines.joined(separator: "\r\n")
        guard containsANSI(in: history) else { return history }

        // A capped capture may begin in the middle of an attribute run, and a
        // backend dump must never leak its final SGR state into the live prompt.
        var wrapped = history
        if !startsWithReset(wrapped) { wrapped = reset + wrapped }
        if !endsWithReset(wrapped) { wrapped += reset }
        return wrapped
    }

    /// Removes only palette/default-color OSC commands. SGR and semantic OSC
    /// sequences such as hyperlinks remain byte-for-byte intact.
    private static func strippingColorConfigurationOSC(from input: String) -> String {
        let scalars = Array(input.unicodeScalars)
        var output = ""
        var index = 0

        while index < scalars.count {
            guard let sequence = oscSequence(in: scalars, at: index) else {
                output.unicodeScalars.append(scalars[index])
                index += 1
                continue
            }

            if !isColorConfigurationCommand(in: scalars[sequence.payload]) {
                output.unicodeScalars.append(contentsOf: scalars[index..<sequence.end])
            }
            index = sequence.end
        }
        return output
    }

    private static func isColorConfigurationCommand(
        in payload: ArraySlice<Unicode.Scalar>
    ) -> Bool {
        var command = 0
        var digitCount = 0
        var index = payload.startIndex
        while index < payload.endIndex {
            let value = payload[index].value
            guard (48...57).contains(value) else { break }
            digitCount += 1
            // Every color command of interest is at most three digits. Bail
            // out before arithmetic on an attacker-controlled OSC can overflow.
            guard digitCount <= 3 else { return false }
            command = command * 10 + Int(value - 48)
            index += 1
        }

        guard digitCount > 0,
              index == payload.endIndex || payload[index].value == 59
        else { return false }

        switch command {
        case 4, 5, 10...19, 104, 105, 110...119:
            return true
        default:
            return false
        }
    }

    /// Finds a complete OSC introduced by either ESC ] or the C1 OSC scalar.
    /// BEL, ESC \\, and the C1 ST scalar are all accepted terminators.
    private static func oscSequence(
        in scalars: [Unicode.Scalar], at index: Int
    ) -> (payload: Range<Int>, end: Int)? {
        let payloadStart: Int
        if scalars[index].value == 0x9d {
            payloadStart = index + 1
        } else if scalars[index].value == 0x1b,
                  index + 1 < scalars.count,
                  scalars[index + 1].value == 0x5d {
            payloadStart = index + 2
        } else {
            return nil
        }

        var cursor = payloadStart
        while cursor < scalars.count {
            switch scalars[cursor].value {
            case 0x07, 0x9c:
                return (payloadStart..<cursor, cursor + 1)
            case 0x1b where cursor + 1 < scalars.count
                && scalars[cursor + 1].value == 0x5c:
                return (payloadStart..<cursor, cursor + 2)
            default:
                cursor += 1
            }
        }
        return nil
    }

    private static func isRestoredBanner(_ line: String) -> Bool {
        visibleText(in: line).trimmingCharacters(in: .whitespaces) == restoredBannerText
    }

    private static func isVisiblyBlank(_ line: String) -> Bool {
        visibleText(in: line).trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Drops non-printing OSC and CSI sequences for comparisons only. The
    /// original line, including SGR and hyperlinks, is retained in the capture.
    private static func visibleText(in input: String) -> String {
        let scalars = Array(input.unicodeScalars)
        var output = ""
        var index = 0

        while index < scalars.count {
            if let sequence = oscSequence(in: scalars, at: index) {
                index = sequence.end
                continue
            }
            if let end = csiSequenceEnd(in: scalars, at: index) {
                index = end
                continue
            }

            let value = scalars[index].value
            if value >= 0x20 && value != 0x7f {
                output.unicodeScalars.append(scalars[index])
            }
            index += 1
        }
        return output
    }

    private static func csiSequenceEnd(
        in scalars: [Unicode.Scalar], at index: Int
    ) -> Int? {
        let parameterStart: Int
        if scalars[index].value == 0x9b {
            parameterStart = index + 1
        } else if scalars[index].value == 0x1b,
                  index + 1 < scalars.count,
                  scalars[index + 1].value == 0x5b {
            parameterStart = index + 2
        } else {
            return nil
        }

        var cursor = parameterStart
        while cursor < scalars.count {
            if (0x40...0x7e).contains(scalars[cursor].value) {
                return cursor + 1
            }
            cursor += 1
        }
        return nil
    }

    private static func containsANSI(in string: String) -> Bool {
        string.unicodeScalars.contains {
            $0.value == 0x1b || (0x80...0x9f).contains($0.value)
        }
    }

    private static func startsWithReset(_ string: String) -> Bool {
        string.hasPrefix(reset) || string.hasPrefix("\u{1b}[m")
            || string.hasPrefix("\u{9b}0m") || string.hasPrefix("\u{9b}m")
    }

    private static func endsWithReset(_ string: String) -> Bool {
        string.hasSuffix(reset) || string.hasSuffix("\u{1b}[m")
            || string.hasSuffix("\u{9b}0m") || string.hasSuffix("\u{9b}m")
    }

    private struct CaptureFile {
        let fileURL: URL
        let parentURL: URL
    }

    /// Accept only a regular file in a direct, non-symlink child of the OS temp
    /// directory. That child is the unique directory Ghostty creates for this
    /// screen dump and is the only directory cleanup may remove.
    /// Holds a backend's export to its side of the bargain: a regular file,
    /// alone in a fresh subdirectory of the process temporary directory, with
    /// no symlink anywhere on the path. Anything else is refused unread.
    private static func validatedCaptureFile(for emittedPath: String?) -> CaptureFile? {
        guard let emittedPath else { return nil }
        let path = emittedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }

        let manager = FileManager.default
        let unresolvedFile = URL(fileURLWithPath: path).standardizedFileURL
        let unresolvedParent = unresolvedFile.deletingLastPathComponent()
        guard let fileValues = try? unresolvedFile.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              fileValues.isRegularFile == true,
              fileValues.isSymbolicLink != true,
              let parentValues = try? unresolvedParent.resourceValues(
                  forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              parentValues.isDirectory == true,
              parentValues.isSymbolicLink != true
        else { return nil }

        let fileURL = unresolvedFile.resolvingSymlinksInPath()
        let parentURL = fileURL.deletingLastPathComponent()
        let temporaryDirectory = manager.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()

        guard parentURL.deletingLastPathComponent() == temporaryDirectory else {
            return nil
        }
        return CaptureFile(fileURL: fileURL, parentURL: parentURL)
    }

    private static func removeCaptureFile(_ capture: CaptureFile) {
        let manager = FileManager.default
        guard (try? manager.removeItem(at: capture.fileURL)) != nil else { return }

        // `rmdir` is deliberately non-recursive: if anything else appeared in
        // the supposedly unique directory, leave it untouched.
        capture.parentURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            _ = Darwin.rmdir(path)
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
