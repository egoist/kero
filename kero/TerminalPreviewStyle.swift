//
//  TerminalPreviewStyle.swift
//  kero
//

import AppKit
import GhosttyTheme

/// Renders a terminal screen export as styled text.
///
/// A backend's export is a VT stream, so the colors an agent drew with are
/// still in it — `TerminalHistorySerializer.previewText` simply discards every
/// escape to produce plain rows. Anything showing that export to a human wants
/// them back: a coding agent's UI is largely color (a highlighted prompt, a
/// red diff, an orange warning), and stripped of it the screen reads as an
/// undifferentiated wall.
///
/// Only SGR is interpreted. Cursor motion, scroll regions, and the rest of the
/// VT vocabulary are skipped rather than emulated: this renders the export a
/// backend already flattened into rows, not a terminal.
enum TerminalPreviewStyle {
    /// Character attributes carried across a run of the stream. SGR state
    /// persists over newlines, so this is threaded through the whole capture
    /// rather than reset per row.
    private struct Attributes: Equatable {
        var foreground: NSColor?
        var background: NSColor?
        var bold = false
        var dim = false
        var italic = false
        var underline = false
        var inverse = false

        mutating func reset() { self = Attributes() }
    }

    static func attributedPreview(
        vt: String,
        maxLines: Int,
        maxColumns: Int,
        theme: GhosttyThemeDefinition,
        font: NSFont
    ) -> NSAttributedString? {
        guard maxLines > 0, maxColumns > 0 else { return nil }

        let defaultForeground = theme.foregroundNSColor
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)

        let scalars = Array(vt.unicodeScalars)
        var attributes = Attributes()
        var lines: [NSAttributedString] = []
        var line = NSMutableAttributedString()
        var pending = ""
        var pendingAttributes = attributes
        var columns = 0
        var index = 0

        func flush() {
            guard !pending.isEmpty else { return }
            line.append(NSAttributedString(
                string: pending,
                attributes: cocoaAttributes(
                    pendingAttributes,
                    theme: theme,
                    defaultForeground: defaultForeground,
                    font: font,
                    boldFont: boldFont,
                    italicFont: italicFont
                )
            ))
            pending = ""
        }

        func endLine() {
            flush()
            lines.append(NSAttributedString(attributedString: line))
            line = NSMutableAttributedString()
            columns = 0
        }

        while index < scalars.count {
            let value = scalars[index].value

            if let end = oscSequenceEnd(in: scalars, at: index) {
                index = end
                continue
            }
            if let sequence = csiSequence(in: scalars, at: index) {
                if sequence.final == "m" {
                    flush()
                    apply(
                        parameters: sequence.parameters,
                        to: &attributes,
                        theme: theme
                    )
                    pendingAttributes = attributes
                }
                index = sequence.end
                continue
            }

            if value == 0x0a {
                endLine()
                index += 1
                continue
            }

            // Printable only, matching the plain-text serializer: C0 controls
            // and DEL never reach the preview.
            if value >= 0x20, value != 0x7f {
                if columns < maxColumns {
                    if pendingAttributes != attributes {
                        flush()
                        pendingAttributes = attributes
                    }
                    pending.unicodeScalars.append(scalars[index])
                    columns += 1
                }
                // Past the column budget the glyph is dropped, but the scan
                // continues so escapes still update state for the next row.
            }
            index += 1
        }
        endLine()
        lines = condense(lines)
        guard !lines.isEmpty else { return nil }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        // Terminal rows are already laid out; keep them on a fixed rhythm so
        // box drawing lines up vertically.
        paragraph.minimumLineHeight = ceil(font.ascender - font.descender)
        paragraph.maximumLineHeight = paragraph.minimumLineHeight

        let output = NSMutableAttributedString()
        for (offset, styled) in lines.suffix(maxLines).enumerated() {
            if offset > 0 {
                output.append(NSAttributedString(string: "\n"))
            }
            output.append(styled)
        }
        output.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: 0, length: output.length)
        )
        return output
    }

    /// Drops blank rows from both ends and collapses interior runs to a single
    /// separator.
    ///
    /// A full-screen agent lays its UI out over the whole terminal: a header at
    /// the top, a prompt pinned to the bottom, and a tall empty conversation
    /// area between them. Reproduced faithfully in a pane a fraction of that
    /// height, the empty area *is* the preview — the reader gets a rectangle of
    /// nothing while the two informative bands sit off-screen. Squeezing the
    /// gaps is what makes both visible at once, and blank rows carry no
    /// information worth the space anyway.
    private static func condense(
        _ lines: [NSAttributedString]
    ) -> [NSAttributedString] {
        func isBlank(_ line: NSAttributedString) -> Bool {
            line.string.trimmingCharacters(in: .whitespaces).isEmpty
        }

        var trimmed = lines[...]
        while let first = trimmed.first, isBlank(first) {
            trimmed = trimmed.dropFirst()
        }
        while let last = trimmed.last, isBlank(last) {
            trimmed = trimmed.dropLast()
        }

        var condensed: [NSAttributedString] = []
        condensed.reserveCapacity(trimmed.count)
        var blankRun = 0
        for line in trimmed {
            if isBlank(line) {
                blankRun += 1
                // Keep one, so the bands stay visually separated.
                if blankRun > 1 { continue }
            } else {
                blankRun = 0
            }
            condensed.append(line)
        }
        return condensed
    }

    private static func cocoaAttributes(
        _ attributes: Attributes,
        theme: GhosttyThemeDefinition,
        defaultForeground: NSColor,
        font: NSFont,
        boldFont: NSFont,
        italicFont: NSFont
    ) -> [NSAttributedString.Key: Any] {
        var foreground = attributes.foreground ?? defaultForeground
        var background = attributes.background

        if attributes.inverse {
            let swapped = background ?? theme.backgroundNSColor
            background = foreground
            foreground = swapped
        }
        if attributes.dim {
            foreground = foreground.withAlphaComponent(0.6)
        }

        var result: [NSAttributedString.Key: Any] = [
            .foregroundColor: foreground,
            .font: attributes.bold ? boldFont : (attributes.italic ? italicFont : font),
        ]
        if let background {
            result[.backgroundColor] = background
        }
        if attributes.underline {
            result[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return result
    }

    private static func apply(
        parameters: [Int],
        to attributes: inout Attributes,
        theme: GhosttyThemeDefinition
    ) {
        // A bare `ESC [ m` is a reset, same as `ESC [ 0 m`.
        guard !parameters.isEmpty else {
            attributes.reset()
            return
        }

        var index = 0
        while index < parameters.count {
            let code = parameters[index]
            switch code {
            case 0: attributes.reset()
            case 1: attributes.bold = true
            case 2: attributes.dim = true
            case 3: attributes.italic = true
            case 4: attributes.underline = true
            case 7: attributes.inverse = true
            case 22: attributes.bold = false; attributes.dim = false
            case 23: attributes.italic = false
            case 24: attributes.underline = false
            case 27: attributes.inverse = false
            case 30...37:
                attributes.foreground = paletteColor(code - 30, theme: theme)
            case 39: attributes.foreground = nil
            case 40...47:
                attributes.background = paletteColor(code - 40, theme: theme)
            case 49: attributes.background = nil
            case 90...97:
                attributes.foreground = paletteColor(code - 90 + 8, theme: theme)
            case 100...107:
                attributes.background = paletteColor(code - 100 + 8, theme: theme)
            case 38, 48:
                let (color, consumed) = extendedColor(
                    parameters, from: index + 1, theme: theme
                )
                if code == 38 {
                    attributes.foreground = color
                } else {
                    attributes.background = color
                }
                index += consumed
            default:
                break
            }
            index += 1
        }
    }

    /// `38;5;n` indexed and `38;2;r;g;b` direct forms. Returns how many extra
    /// parameters were consumed so the caller can resume after them.
    private static func extendedColor(
        _ parameters: [Int], from start: Int, theme: GhosttyThemeDefinition
    ) -> (NSColor?, Int) {
        guard start < parameters.count else { return (nil, 0) }
        switch parameters[start] {
        case 5:
            guard start + 1 < parameters.count else { return (nil, 1) }
            return (indexedColor(parameters[start + 1], theme: theme), 2)
        case 2:
            guard start + 3 < parameters.count else { return (nil, 1) }
            return (
                NSColor(
                    srgbRed: CGFloat(clampByte(parameters[start + 1])) / 255,
                    green: CGFloat(clampByte(parameters[start + 2])) / 255,
                    blue: CGFloat(clampByte(parameters[start + 3])) / 255,
                    alpha: 1
                ),
                4
            )
        default:
            return (nil, 1)
        }
    }

    /// xterm's 256-color layout: the themed 16, a 6×6×6 cube, then 24 greys.
    private static func indexedColor(
        _ value: Int, theme: GhosttyThemeDefinition
    ) -> NSColor? {
        switch value {
        case 0...15:
            return paletteColor(value, theme: theme)
        case 16...231:
            let offset = value - 16
            let steps: [CGFloat] = [0, 95, 135, 175, 215, 255]
            return NSColor(
                srgbRed: steps[(offset / 36) % 6] / 255,
                green: steps[(offset / 6) % 6] / 255,
                blue: steps[offset % 6] / 255,
                alpha: 1
            )
        case 232...255:
            let level = CGFloat(8 + (value - 232) * 10) / 255
            return NSColor(srgbRed: level, green: level, blue: level, alpha: 1)
        default:
            return nil
        }
    }

    /// The user's own terminal theme owns these sixteen, so a preview matches
    /// the pane it was captured from. The xterm defaults only cover a theme
    /// that left an entry undefined.
    private static func paletteColor(
        _ index: Int, theme: GhosttyThemeDefinition
    ) -> NSColor? {
        if let hex = theme.palette[index], let color = nsColor(hex) {
            return color
        }
        guard index >= 0, index < fallbackPalette.count else { return nil }
        return nsColor(fallbackPalette[index])
    }

    private static let fallbackPalette = [
        "#000000", "#cc0000", "#4e9a06", "#c4a000",
        "#3465a4", "#75507b", "#06989a", "#d3d7cf",
        "#555753", "#ef2929", "#8ae234", "#fce94f",
        "#729fcf", "#ad7fa8", "#34e2e2", "#eeeeec",
    ]

    private static func clampByte(_ value: Int) -> Int {
        min(max(value, 0), 255)
    }

    private static func nsColor(_ hex: String) -> NSColor? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = Int(digits, radix: 16) else {
            return nil
        }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }

    // MARK: - VT scanning

    private struct CSISequence {
        let end: Int
        let parameters: [Int]
        let final: Unicode.Scalar
    }

    /// Mirrors the serializer's own CSI scan, additionally returning the
    /// numeric parameters and the final byte so SGR can be interpreted.
    private static func csiSequence(
        in scalars: [Unicode.Scalar], at index: Int
    ) -> CSISequence? {
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
            let value = scalars[cursor].value
            if (0x40...0x7e).contains(value) {
                let body = String(String.UnicodeScalarView(
                    scalars[parameterStart..<cursor]
                ))
                // A private-parameter marker such as `?` is not SGR; leaving
                // the parameters empty makes it a no-op rather than a reset.
                let parameters = body.hasPrefix("?")
                    ? [-1]
                    : body.split(separator: ";", omittingEmptySubsequences: false)
                        .map { Int($0) ?? 0 }
                return CSISequence(
                    end: cursor + 1,
                    parameters: body.isEmpty ? [] : parameters,
                    final: scalars[cursor]
                )
            }
            cursor += 1
        }
        return nil
    }

    /// OSC runs to BEL or ST and can legally contain semicolons and text, so
    /// it has to be skipped whole before CSI scanning sees its payload.
    private static func oscSequenceEnd(
        in scalars: [Unicode.Scalar], at index: Int
    ) -> Int? {
        let start: Int
        if scalars[index].value == 0x9d {
            start = index + 1
        } else if scalars[index].value == 0x1b,
                  index + 1 < scalars.count,
                  scalars[index + 1].value == 0x5d {
            start = index + 2
        } else {
            return nil
        }

        var cursor = start
        while cursor < scalars.count {
            let value = scalars[cursor].value
            if value == 0x07 { return cursor + 1 }
            if value == 0x9c { return cursor + 1 }
            if value == 0x1b,
               cursor + 1 < scalars.count,
               scalars[cursor + 1].value == 0x5c {
                return cursor + 2
            }
            cursor += 1
        }
        return nil
    }
}
