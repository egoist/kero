//
//  AlacrittyRenderer.swift
//  kero
//

import AppKit
import CoreText

/// Cell geometry and the four font faces a terminal grid needs.
///
/// The advance comes from the font's own digit width rather than
/// `maximumAdvancement`, which on many "monospace" faces is set by a wide
/// symbol and would space the grid out visibly.
struct AlacrittyMetrics {
    let regular: NSFont
    let bold: NSFont
    let italic: NSFont
    let boldItalic: NSFont
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    /// Baseline measured down from the top of the cell.
    let baseline: CGFloat
    let fontThicken: Bool

    init(family: String, size: CGFloat, fontThicken: Bool) {
        let regular = TerminalFont.resolve(family: family, size: size)
        let manager = NSFontManager.shared
        self.regular = regular
        bold = manager.convert(regular, toHaveTrait: .boldFontMask)
        italic = manager.convert(regular, toHaveTrait: .italicFontMask)
        boldItalic = manager.convert(
            manager.convert(regular, toHaveTrait: .boldFontMask),
            toHaveTrait: .italicFontMask
        )

        let advance = AlacrittyMetrics.advance(of: regular)
        // Round to whole points so column positions stay on pixel boundaries
        // and glyphs do not shimmer as the grid scrolls.
        cellWidth = max(1, advance.rounded())
        let ascent = regular.ascender
        let descent = -regular.descender
        let leading = regular.leading
        cellHeight = max(1, (ascent + descent + leading).rounded())
        baseline = (ascent + leading / 2).rounded()
        self.fontThicken = fontThicken
    }

    private static func advance(of font: NSFont) -> CGFloat {
        var glyph = CGGlyph()
        var character: UniChar = 0x30 // "0"
        let ctFont = font as CTFont
        guard CTFontGetGlyphsForCharacters(ctFont, &character, &glyph, 1) else {
            return font.maximumAdvancement.width
        }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
        return advance.width > 0 ? advance.width : font.maximumAdvancement.width
    }

    func font(bold isBold: Bool, italic isItalic: Bool) -> NSFont {
        switch (isBold, isItalic) {
        case (true, true): boldItalic
        case (true, false): bold
        case (false, true): italic
        case (false, false): regular
        }
    }
}

/// Draws one snapshot of the grid with CoreText.
///
/// Cells are painted in two passes — every background rect, then every glyph —
/// so a run of identical background colour collapses into one fill and glyphs
/// are never clipped by the next cell's background.
struct AlacrittyRenderer {
    let metrics: AlacrittyMetrics
    let origin: CGPoint

    func draw(
        snapshot: KeroSnapshot,
        markedText: String,
        in context: CGContext,
        bounds: CGRect
    ) {
        guard let cells = snapshot.cells, snapshot.columns > 0, snapshot.rows > 0 else {
            return
        }
        context.setFillColor(Self.color(snapshot.background))
        context.fill(bounds)

        context.saveGState()
        defer { context.restoreGState() }
        // AppKit hands the view a flipped context; CoreText wants text drawn
        // in an unflipped one, so glyph positions below are computed from the
        // bottom up rather than flipping the CTM per run.
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(true)
        // Glyph positions below are absolute, so the text matrix must start
        // (and stay) identity — see the fallback path in `draw(scalar:…)`.
        context.textMatrix = .identity

        let columns = snapshot.columns
        let rows = snapshot.rows

        for row in 0..<rows {
            drawBackgrounds(
                cells: cells, row: row, columns: columns,
                defaultBackground: snapshot.background, in: context, bounds: bounds
            )
        }

        drawCursor(snapshot: snapshot, in: context, bounds: bounds)

        for row in 0..<rows {
            drawGlyphs(
                cells: cells, row: row, columns: columns,
                cursor: snapshot.cursor_line == row ? snapshot.cursor_column : -1,
                cursorShape: snapshot.cursor_shape,
                background: snapshot.background,
                in: context, bounds: bounds
            )
        }

        if !markedText.isEmpty, snapshot.cursor_line >= 0 {
            drawMarkedText(
                markedText,
                line: Int(snapshot.cursor_line),
                column: Int(max(snapshot.cursor_column, 0)),
                foreground: snapshot.cells?.pointee.fg ?? 0xffffff,
                in: context, bounds: bounds
            )
        }
    }

    // MARK: - Passes

    private func drawBackgrounds(
        cells: UnsafePointer<KeroCell>,
        row: Int,
        columns: Int,
        defaultBackground: UInt32,
        in context: CGContext,
        bounds: CGRect
    ) {
        var column = 0
        while column < columns {
            let cell = cells[row * columns + column]
            let background = Self.background(of: cell, default: defaultBackground)
            var span = 1
            while column + span < columns {
                let next = cells[row * columns + column + span]
                guard Self.background(of: next, default: defaultBackground) == background else {
                    break
                }
                span += 1
            }
            if background != defaultBackground {
                context.setFillColor(Self.color(background))
                context.fill(rect(row: row, column: column, span: span, bounds: bounds))
            }
            column += span
        }
    }

    private func drawGlyphs(
        cells: UnsafePointer<KeroCell>,
        row: Int,
        columns: Int,
        cursor: Int,
        cursorShape: UInt32,
        background: UInt32,
        in context: CGContext,
        bounds: CGRect
    ) {
        let y = bounds.maxY - origin.y - CGFloat(row) * metrics.cellHeight - metrics.baseline

        for column in 0..<columns {
            let cell = cells[row * columns + column]
            guard cell.flags & UInt16(KERO_CELL_HIDDEN) == 0 else { continue }
            // A wide char's trailing spacer carries no glyph of its own.
            guard cell.flags & UInt16(KERO_CELL_WIDE_SPACER) == 0 else { continue }
            guard let scalar = Unicode.Scalar(cell.ch), scalar != " ", cell.ch != 0 else {
                continue
            }

            var foreground = Self.foreground(of: cell, default: background)
            // A block cursor inverts the glyph beneath it so the character
            // stays legible instead of being painted over.
            if column == cursor, cursorShape == 0 {
                foreground = Self.background(of: cell, default: background)
            }

            let isBold = cell.flags & UInt16(KERO_CELL_BOLD) != 0
            let isItalic = cell.flags & UInt16(KERO_CELL_ITALIC) != 0
            let font = metrics.font(bold: isBold, italic: isItalic)
            let x = origin.x + CGFloat(column) * metrics.cellWidth

            draw(
                scalar: scalar, font: font, color: foreground,
                at: CGPoint(x: x, y: y), in: context
            )

            if cell.flags & UInt16(KERO_CELL_UNDERLINE) != 0 {
                line(at: y - metrics.cellHeight * 0.12, x: x, color: foreground, in: context)
            }
            if cell.flags & UInt16(KERO_CELL_STRIKEOUT) != 0 {
                line(at: y + metrics.cellHeight * 0.22, x: x, color: foreground, in: context)
            }
        }
    }

    private func draw(
        scalar: Unicode.Scalar,
        font: NSFont,
        color: UInt32,
        at point: CGPoint,
        in context: CGContext
    ) {
        context.setFillColor(Self.color(color))
        let ctFont = font as CTFont
        var utf16 = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)

        if CTFontGetGlyphsForCharacters(ctFont, &utf16, &glyphs, utf16.count),
           glyphs.allSatisfy({ $0 != 0 }) {
            var position = point
            CTFontDrawGlyphs(ctFont, glyphs, &position, 1, context)
            return
        }

        // No glyph in the chosen face — emoji, box drawing, a Nerd Font icon.
        // CTLine runs the system's font-fallback chain for us.
        let attributed = NSAttributedString(
            string: String(scalar),
            attributes: [
                .font: font,
                .foregroundColor: NSColor(srgbRed: CGFloat((color >> 16) & 0xff) / 255,
                                          green: CGFloat((color >> 8) & 0xff) / 255,
                                          blue: CGFloat(color & 0xff) / 255,
                                          alpha: 1),
            ]
        )
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        // CTLineDraw leaves its own text matrix on the context. Every later
        // CTFontDrawGlyphs would inherit it and collapse into a smear, so put
        // it back — one fallback glyph high up the grid would otherwise take
        // out every row below it.
        context.textMatrix = .identity
    }

    private func line(at y: CGFloat, x: CGFloat, color: UInt32, in context: CGContext) {
        context.setFillColor(Self.color(color))
        context.fill(CGRect(x: x, y: y, width: metrics.cellWidth, height: 1))
    }

    private func drawCursor(snapshot: KeroSnapshot, in context: CGContext, bounds: CGRect) {
        guard snapshot.cursor_line >= 0, snapshot.cursor_column >= 0 else { return }
        let row = Int(snapshot.cursor_line)
        let column = Int(snapshot.cursor_column)
        context.setFillColor(Self.color(snapshot.cursor_color))

        let cell = rect(row: row, column: column, span: 1, bounds: bounds)
        switch snapshot.cursor_shape {
        case 1: // Underline
            context.fill(CGRect(x: cell.minX, y: cell.minY, width: cell.width, height: 2))
        case 2: // Beam
            context.fill(CGRect(x: cell.minX, y: cell.minY, width: 2, height: cell.height))
        default: // Block
            context.fill(cell)
        }
    }

    /// IME preedit, drawn at the cursor and underlined so it reads as
    /// uncommitted the way it does in a native text field.
    private func drawMarkedText(
        _ text: String,
        line row: Int,
        column: Int,
        foreground: UInt32,
        in context: CGContext,
        bounds: CGRect
    ) {
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: metrics.regular,
                .foregroundColor: NSColor.textColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        )
        let y = bounds.maxY - origin.y - CGFloat(row) * metrics.cellHeight - metrics.baseline
        let x = origin.x + CGFloat(column) * metrics.cellWidth
        let ctLine = CTLineCreateWithAttributedString(attributed)
        let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)

        context.setFillColor(NSColor.textBackgroundColor.cgColor)
        context.fill(CGRect(
            x: x, y: y - metrics.cellHeight * 0.25,
            width: CGFloat(width), height: metrics.cellHeight
        ))
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(ctLine, context)
    }

    // MARK: - Geometry

    private func rect(row: Int, column: Int, span: Int, bounds: CGRect) -> CGRect {
        CGRect(
            x: origin.x + CGFloat(column) * metrics.cellWidth,
            y: bounds.maxY - origin.y - CGFloat(row + 1) * metrics.cellHeight,
            width: metrics.cellWidth * CGFloat(span),
            height: metrics.cellHeight
        )
    }

    // MARK: - Colors

    /// Inverse video and SGR 2 are resolved here rather than in the bridge, so
    /// the snapshot keeps the terminal's own colours and the renderer decides
    /// how to present them.
    static func foreground(of cell: KeroCell, default background: UInt32) -> UInt32 {
        var color = cell.flags & UInt16(KERO_CELL_INVERSE) != 0 ? cell.bg : cell.fg
        if cell.flags & UInt16(KERO_CELL_DIM) != 0 {
            color = dim(color)
        }
        if cell.flags & UInt16(KERO_CELL_SELECTED) != 0 {
            // Selection inverts, so the text takes the pane background.
            color = background
        }
        return color
    }

    static func background(of cell: KeroCell, default background: UInt32) -> UInt32 {
        if cell.flags & UInt16(KERO_CELL_SELECTED) != 0 {
            return cell.flags & UInt16(KERO_CELL_INVERSE) != 0 ? cell.bg : cell.fg
        }
        return cell.flags & UInt16(KERO_CELL_INVERSE) != 0 ? cell.fg : cell.bg
    }

    private static func dim(_ value: UInt32) -> UInt32 {
        let scale = { (channel: UInt32) in (channel * 2 / 3) & 0xff }
        return (scale((value >> 16) & 0xff) << 16)
            | (scale((value >> 8) & 0xff) << 8)
            | scale(value & 0xff)
    }

    static func color(_ packed: UInt32) -> CGColor {
        CGColor(
            srgbRed: CGFloat((packed >> 16) & 0xff) / 255,
            green: CGFloat((packed >> 8) & 0xff) / 255,
            blue: CGFloat(packed & 0xff) / 255,
            alpha: 1
        )
    }
}
