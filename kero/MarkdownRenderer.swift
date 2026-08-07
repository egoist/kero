//
//  MarkdownRenderer.swift
//  kero
//

import AppKit
import Markdown

/// Fonts and colors the markdown preview draws with, derived from the selected
/// ghostty theme so a rendered README sits in the same palette as the source
/// editor it toggles against.
@MainActor
struct MarkdownStyle {
    var bodyFont: NSFont
    var codeFont: NSFont
    var text: NSColor
    var secondary: NSColor
    var link: NSColor
    var codeBackground: NSColor
    var rule: NSColor
    var quoteBar: NSColor
    var tableBorder: NSColor
    var tableHeaderBackground: NSColor

    /// Prose is proportional (a rendered document is for reading, not for
    /// column alignment) while code keeps the terminal font, so a fenced block
    /// in the preview matches the same block in the editor.
    static func theme(dark: Bool) -> MarkdownStyle {
        let theme = Theme.terminal(dark: dark)
        let bodySize: CGFloat = 14
        let terminal = TerminalFont.current()
        return MarkdownStyle(
            bodyFont: .systemFont(ofSize: bodySize),
            codeFont: NSFont(descriptor: terminal.fontDescriptor, size: bodySize * 0.92) ?? terminal,
            text: theme.foregroundNSColor,
            secondary: theme.surfaceNSColor(elevation: 0.45),
            link: theme.accentNSColor,
            codeBackground: theme.surfaceNSColor(elevation: 0.06),
            rule: theme.surfaceNSColor(elevation: 0.18),
            quoteBar: theme.surfaceNSColor(elevation: 0.3),
            tableBorder: theme.surfaceNSColor(elevation: 0.22),
            tableHeaderBackground: theme.surfaceNSColor(elevation: 0.04)
        )
    }
}

/// Turns a parsed markdown document into an `NSAttributedString` for the
/// preview's text view.
///
/// Block structure — blockquote bars, fenced-code backgrounds, GFM table grids
/// — is expressed with `NSTextBlock`/`NSTextTable`, which is why the preview
/// runs on TextKit 1 (see `MarkdownPreviewView`). TextKit 2 ignores text blocks
/// entirely, and hand-rolling table layout to avoid them would cost far more
/// code than the preview is worth.
///
/// The visitor keeps a `blockStack` rather than folding indentation into each
/// paragraph style: nesting (a table inside a blockquote, a fence inside a list)
/// then composes by construction instead of by arithmetic.
/// The conformance is main-actor isolated because the walk reaches the image
/// cache and the shared code highlighter, both of which live on the main actor.
/// Rendering runs there anyway — its output goes straight into a text view.
@MainActor
struct MarkdownRenderer: @MainActor MarkupVisitor {
    typealias Result = NSAttributedString

    let style: MarkdownStyle
    /// Directory the document was loaded from, so relative image sources
    /// resolve the way they do on disk.
    let baseURL: URL
    /// Width available to the text, used to size images down to fit.
    let contentWidth: CGFloat
    /// Supplies images already in hand and starts fetching the ones that are
    /// not; the view re-renders when they land.
    let images: MarkdownImageLoader

    /// Enclosing text blocks, outermost first. Every paragraph style built
    /// during the walk carries the current stack.
    private var blockStack: [NSTextBlock] = []
    /// Extra head indent from enclosing lists, in points.
    private var listIndent: CGFloat = 0

    init(
        style: MarkdownStyle,
        baseURL: URL,
        contentWidth: CGFloat,
        images: MarkdownImageLoader
    ) {
        self.style = style
        self.baseURL = baseURL
        self.contentWidth = contentWidth
        self.images = images
    }

    static func render(
        _ source: String,
        style: MarkdownStyle,
        baseURL: URL,
        contentWidth: CGFloat,
        images: MarkdownImageLoader
    ) -> NSAttributedString {
        let document = Document(parsing: source)
        var renderer = MarkdownRenderer(
            style: style,
            baseURL: baseURL,
            contentWidth: contentWidth,
            images: images
        )
        return renderer.visit(document)
    }

    // MARK: - Container defaults

    mutating func defaultVisit(_ markup: any Markup) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for child in markup.children {
            result.append(visit(child))
        }
        return result
    }

    mutating func visitDocument(_ document: Document) -> NSAttributedString {
        defaultVisit(document)
    }

    // MARK: - Blocks

    mutating func visitParagraph(_ paragraph: Paragraph) -> NSAttributedString {
        // Items in a list sit closer together than free-standing paragraphs, or
        // a short list reads as a stack of unrelated lines.
        block(defaultVisit(paragraph), spacingAfter: listIndent > 0 ? 4 : 10)
    }

    mutating func visitHeading(_ heading: Heading) -> NSAttributedString {
        // Descending scale with a floor at body size; h6 drops to the secondary
        // color instead of shrinking below the prose it labels.
        let scales: [CGFloat] = [1.75, 1.45, 1.22, 1.08, 1.0, 1.0]
        let scale = scales[min(max(heading.level, 1), 6) - 1]
        let size = style.bodyFont.pointSize * scale
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)

        let content = NSMutableAttributedString(attributedString: defaultVisit(heading))
        content.addAttribute(
            .font,
            value: font,
            range: NSRange(location: 0, length: content.length)
        )
        if heading.level >= 6 {
            content.addAttribute(
                .foregroundColor,
                value: style.secondary,
                range: NSRange(location: 0, length: content.length)
            )
        }
        // A heading that opens the document needs no space above it.
        let isFirst = heading.indexInParent == 0 && heading.parent is Document
        return block(content, spacingBefore: isFirst ? 0 : 18, spacingAfter: 8)
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> NSAttributedString {
        let rule = NSTextBlock()
        // A text block defaults to zero content width, which collapses its text
        // to one character per line; every block kero builds has to claim the
        // width it was given.
        rule.setContentWidth(100, type: .percentageValueType)
        rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
        rule.setBorderColor(style.rule, for: .minY)
        rule.setWidth(0, type: .absoluteValueType, for: .padding)

        let paragraph = NSMutableParagraphStyle()
        paragraph.textBlocks = blockStack + [rule]
        paragraph.paragraphSpacingBefore = 10
        paragraph.paragraphSpacing = 10
        // A non-breaking space keeps the paragraph from collapsing to nothing,
        // which would take the border with it.
        return NSAttributedString(
            string: "\u{00A0}\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 1),
                .paragraphStyle: paragraph,
                .foregroundColor: NSColor.clear,
            ]
        )
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> NSAttributedString {
        let bar = NSTextBlock()
        bar.setContentWidth(100, type: .percentageValueType)
        bar.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        bar.setBorderColor(style.quoteBar, for: .minX)
        bar.setWidth(14, type: .absoluteValueType, for: .padding, edge: .minX)
        bar.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minY)
        bar.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxY)

        // The block owns the inset, so list indent restarts inside it.
        let outerIndent = listIndent
        listIndent = 0
        blockStack.append(bar)
        let content = NSMutableAttributedString(attributedString: defaultVisit(blockQuote))
        blockStack.removeLast()
        listIndent = outerIndent

        content.addAttribute(
            .foregroundColor,
            value: style.secondary,
            range: NSRange(location: 0, length: content.length)
        )
        return content
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> NSAttributedString {
        let background = NSTextBlock()
        background.setContentWidth(100, type: .percentageValueType)
        background.backgroundColor = style.codeBackground
        background.setWidth(10, type: .absoluteValueType, for: .padding)

        // Trailing newline is the fence's own terminator, not a blank code line.
        var code = codeBlock.code
        if code.hasSuffix("\n") { code.removeLast() }

        let highlighted = MarkdownCodeHighlighter.shared.attributedCode(
            code,
            language: codeBlock.language,
            font: style.codeFont,
            color: style.text
        )

        let paragraph = NSMutableParagraphStyle()
        paragraph.textBlocks = blockStack + [background]
        paragraph.paragraphSpacingBefore = 8
        paragraph.paragraphSpacing = 12
        paragraph.lineHeightMultiple = 1.2
        // Long lines wrap rather than clipping: the preview has no horizontal
        // scroller, unlike the editor.
        paragraph.lineBreakMode = .byWordWrapping

        let result = NSMutableAttributedString(attributedString: highlighted)
        result.append(NSAttributedString(string: "\n"))
        result.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> NSAttributedString {
        // Raw HTML is shown as its source, never interpreted — the preview is a
        // text view, and rendering embedded markup would mean a web engine.
        var source = html.rawHTML
        if source.hasSuffix("\n") { source.removeLast() }
        return block(
            NSAttributedString(
                string: source,
                attributes: [.font: style.codeFont, .foregroundColor: style.secondary]
            ),
            spacingAfter: 10
        )
    }

    // MARK: - Lists

    mutating func visitUnorderedList(_ list: UnorderedList) -> NSAttributedString {
        // Depth drives both the bullet glyph and the indent, so nested lists
        // read as nested without needing a different renderer path.
        let depth = Self.listDepth(of: list)
        let bullets = ["•", "◦", "▪"]
        let bullet = bullets[depth % bullets.count]
        return renderList(list) { item, _ in
            switch item.checkbox {
            case .checked: return "☑"
            case .unchecked: return "☐"
            case .none: return bullet
            }
        }
    }

    mutating func visitOrderedList(_ list: OrderedList) -> NSAttributedString {
        let start = Int(list.startIndex)
        return renderList(list) { item, offset in
            switch item.checkbox {
            case .checked: return "☑"
            case .unchecked: return "☐"
            case .none: return "\(start + offset)."
            }
        }
    }

    /// Shared list body: each item is laid out as `marker \t content`, with a
    /// tab stop at the item's text indent so wrapped lines and nested blocks
    /// line up under the first character rather than under the marker.
    private mutating func renderList(
        _ list: any ListItemContainer,
        marker: (ListItem, Int) -> String
    ) -> NSAttributedString {
        let indentStep: CGFloat = 22
        let outerIndent = listIndent
        let textIndent = outerIndent + indentStep

        let result = NSMutableAttributedString()
        for (offset, item) in list.listItems.enumerated() {
            listIndent = textIndent
            let content = NSMutableAttributedString(attributedString: defaultVisit(item))
            listIndent = outerIndent

            // Only the paragraph the marker joins is rewritten. Anything deeper
            // in the item — a nested list, a fence, a quote — was rendered with
            // its own absolute indent already, and reindenting it here is what
            // would flatten every nesting level onto the first.
            let ownStyle = content.length > 0
                ? content.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
                : nil
            let hanging = (ownStyle?.mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            hanging.headIndent = textIndent
            hanging.firstLineHeadIndent = outerIndent
            hanging.tabStops = [NSTextTab(textAlignment: .left, location: textIndent)]

            content.insert(
                NSAttributedString(
                    string: "\(marker(item, offset))\t",
                    attributes: [
                        .font: style.bodyFont,
                        .foregroundColor: item.checkbox == nil ? style.secondary : style.text,
                    ]
                ),
                at: 0
            )
            // Applied across the marker too: a paragraph takes its style from
            // its first character, so leaving the marker unstyled would drop
            // the whole line back to the default indent.
            content.addAttribute(
                .paragraphStyle,
                value: hanging,
                range: NSRange(location: 0, length: Self.firstParagraphEnd(of: content))
            )
            result.append(content)
        }
        return result
    }

    /// End of the run of text that carries the item's marker, so only that
    /// paragraph gets the hanging first line.
    private static func firstParagraphEnd(of string: NSAttributedString) -> Int {
        let newline = (string.string as NSString).range(of: "\n")
        return newline.location == NSNotFound ? string.length : newline.location + 1
    }

    /// How many lists enclose this one, counted through the AST rather than
    /// tracked in visitor state so it stays right regardless of visit order.
    private static func listDepth(of list: any Markup) -> Int {
        var depth = 0
        var parent = list.parent
        while let current = parent {
            if current is UnorderedList || current is OrderedList { depth += 1 }
            parent = current.parent
        }
        return depth
    }

    // MARK: - Tables

    mutating func visitTable(_ table: Markdown.Table) -> NSAttributedString {
        let columnCount = max(table.maxColumnCount, 1)
        let textTable = NSTextTable()
        textTable.numberOfColumns = columnCount
        textTable.setContentWidth(100, type: .percentageValueType)
        textTable.layoutAlgorithm = .automaticLayoutAlgorithm
        textTable.collapsesBorders = true
        textTable.hidesEmptyCells = false

        let rows = Array(table.body.rows)
        let lastRow = rows.count
        let result = NSMutableAttributedString()
        result.append(
            renderRow(
                table.head.cells,
                table: textTable,
                row: 0,
                columnCount: columnCount,
                alignments: table.columnAlignments,
                isHeader: true,
                // Spacing lives on the outermost row of the grid, so the table
                // is separated from the prose around it rather than butting
                // straight against the paragraph above.
                spacingBefore: 10,
                spacingAfter: lastRow == 0 ? 12 : 0
            )
        )
        for (offset, bodyRow) in rows.enumerated() {
            result.append(
                renderRow(
                    bodyRow.cells,
                    table: textTable,
                    row: offset + 1,
                    columnCount: columnCount,
                    alignments: table.columnAlignments,
                    isHeader: false,
                    spacingBefore: 0,
                    spacingAfter: offset == lastRow - 1 ? 12 : 0
                )
            )
        }
        return result
    }

    private mutating func renderRow(
        _ cells: some Sequence<Markdown.Table.Cell>,
        table: NSTextTable,
        row: Int,
        columnCount: Int,
        alignments: [Markdown.Table.ColumnAlignment?],
        isHeader: Bool,
        spacingBefore: CGFloat,
        spacingAfter: CGFloat
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var column = 0
        for cell in cells {
            guard column < columnCount else { break }
            let span = max(Int(cell.colspan), 1)
            result.append(
                renderCell(
                    cell,
                    table: table,
                    row: row,
                    column: column,
                    span: min(span, columnCount - column),
                    alignment: column < alignments.count ? alignments[column] : nil,
                    isHeader: isHeader,
                    spacingBefore: spacingBefore,
                    spacingAfter: spacingAfter
                )
            )
            column += span
        }
        // A short row still has to close every column, or the table's remaining
        // cells shift up into it.
        while column < columnCount {
            result.append(
                renderEmptyCell(
                    table: table,
                    row: row,
                    column: column,
                    isHeader: isHeader,
                    spacingBefore: spacingBefore,
                    spacingAfter: spacingAfter
                )
            )
            column += 1
        }
        return result
    }

    private mutating func renderCell(
        _ cell: Markdown.Table.Cell,
        table: NSTextTable,
        row: Int,
        column: Int,
        span: Int,
        alignment: Markdown.Table.ColumnAlignment?,
        isHeader: Bool,
        spacingBefore: CGFloat,
        spacingAfter: CGFloat
    ) -> NSAttributedString {
        let block = cellBlock(
            table: table,
            row: row,
            column: column,
            span: span,
            isHeader: isHeader
        )

        // Cell contents are inline-only, and the enclosing list indent must not
        // follow them into the table's own coordinate space.
        let outerIndent = listIndent
        let outerStack = blockStack
        listIndent = 0
        blockStack = blockStack + [block]
        let content = NSMutableAttributedString(attributedString: defaultVisit(cell))
        blockStack = outerStack
        listIndent = outerIndent

        if isHeader {
            content.enumerateAttribute(
                .font,
                in: NSRange(location: 0, length: content.length)
            ) { value, range, _ in
                let font = (value as? NSFont) ?? style.bodyFont
                content.addAttribute(
                    .font,
                    value: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold),
                    range: range
                )
            }
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.textBlocks = outerStack + [block]
        paragraph.alignment = Self.textAlignment(alignment)
        paragraph.paragraphSpacingBefore = spacingBefore
        paragraph.paragraphSpacing = spacingAfter
        content.append(NSAttributedString(string: "\n"))
        content.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: 0, length: content.length)
        )
        return content
    }

    private func renderEmptyCell(
        table: NSTextTable,
        row: Int,
        column: Int,
        isHeader: Bool,
        spacingBefore: CGFloat,
        spacingAfter: CGFloat
    ) -> NSAttributedString {
        let block = cellBlock(table: table, row: row, column: column, span: 1, isHeader: isHeader)
        let paragraph = NSMutableParagraphStyle()
        paragraph.textBlocks = blockStack + [block]
        paragraph.paragraphSpacingBefore = spacingBefore
        paragraph.paragraphSpacing = spacingAfter
        return NSAttributedString(
            string: "\n",
            attributes: [.font: style.bodyFont, .paragraphStyle: paragraph]
        )
    }

    private func cellBlock(
        table: NSTextTable,
        row: Int,
        column: Int,
        span: Int,
        isHeader: Bool
    ) -> NSTextTableBlock {
        let block = NSTextTableBlock(
            table: table,
            startingRow: row,
            rowSpan: 1,
            startingColumn: column,
            columnSpan: span
        )
        block.setWidth(1, type: .absoluteValueType, for: .border)
        block.setBorderColor(style.tableBorder)
        block.setWidth(7, type: .absoluteValueType, for: .padding)
        if isHeader {
            block.backgroundColor = style.tableHeaderBackground
        }
        return block
    }

    private static func textAlignment(
        _ alignment: Markdown.Table.ColumnAlignment?
    ) -> NSTextAlignment {
        switch alignment {
        case .left: .left
        case .right: .right
        case .center: .center
        case nil: .natural
        }
    }

    // MARK: - Inline

    mutating func visitText(_ text: Markdown.Text) -> NSAttributedString {
        NSAttributedString(string: text.string, attributes: baseAttributes)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> NSAttributedString {
        Self.applying(.italic, to: defaultVisit(emphasis))
    }

    mutating func visitStrong(_ strong: Strong) -> NSAttributedString {
        Self.applying(.bold, to: defaultVisit(strong))
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> NSAttributedString {
        let content = NSMutableAttributedString(attributedString: defaultVisit(strikethrough))
        content.addAttribute(
            .strikethroughStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: NSRange(location: 0, length: content.length)
        )
        return content
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> NSAttributedString {
        NSAttributedString(
            string: inlineCode.code,
            attributes: [
                .font: style.codeFont,
                .foregroundColor: style.text,
                .backgroundColor: style.codeBackground,
            ]
        )
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> NSAttributedString {
        NSAttributedString(
            string: inlineHTML.rawHTML,
            attributes: [.font: style.codeFont, .foregroundColor: style.secondary]
        )
    }

    mutating func visitLink(_ link: Markdown.Link) -> NSAttributedString {
        let content = NSMutableAttributedString(attributedString: defaultVisit(link))
        let range = NSRange(location: 0, length: content.length)
        content.addAttribute(.foregroundColor, value: style.link, range: range)
        content.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        content.addAttribute(.underlineColor, value: style.link.withAlphaComponent(0.4), range: range)
        if let destination = link.destination, let url = resolve(destination) {
            content.addAttribute(.link, value: url, range: range)
        }
        return content
    }

    mutating func visitImage(_ image: Markdown.Image) -> NSAttributedString {
        let alternate = image.plainText.isEmpty ? "image" : image.plainText
        guard let source = image.source, let url = resolve(source) else {
            return placeholder(for: alternate)
        }
        guard let loaded = images.image(for: url) else {
            return placeholder(for: alternate)
        }

        let attachment = NSTextAttachment()
        attachment.image = loaded
        // Never upscale past the image's own size, and never overflow the text
        // column — a full-width screenshot in a narrow pane would otherwise
        // stretch the table view's content width and enable horizontal scroll.
        let available = max(contentWidth - listIndent, 32)
        let scale = min(1, available / max(loaded.size.width, 1))
        attachment.bounds = CGRect(
            origin: .zero,
            size: CGSize(width: loaded.size.width * scale, height: loaded.size.height * scale)
        )
        return NSAttributedString(attachment: attachment)
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> NSAttributedString {
        NSAttributedString(string: " ", attributes: baseAttributes)
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> NSAttributedString {
        NSAttributedString(string: "\u{2028}", attributes: baseAttributes)
    }

    // MARK: - Helpers

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: style.bodyFont, .foregroundColor: style.text]
    }

    /// An unresolved or not-yet-loaded image renders as its alt text, so the
    /// document still reads while a remote fetch is in flight or has failed.
    private func placeholder(for alternate: String) -> NSAttributedString {
        NSAttributedString(
            string: "🖼 \(alternate)",
            attributes: [.font: style.bodyFont, .foregroundColor: style.secondary]
        )
    }

    /// Resolves a link or image destination against the document's directory,
    /// so `./docs/x.png` points where it does on disk.
    private func resolve(_ destination: String) -> URL? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        // `[Usage](#usage)` points inside this document. The preview has no
        // anchor navigation, so it stays styled but inert — turning it into a
        // file path would open something named "#usage" that does not exist.
        guard !trimmed.hasPrefix("#") else { return nil }
        // A fragment on a path (`README.md#usage`) is not part of the filename.
        let path = trimmed.split(separator: "#", maxSplits: 1).first.map(String.init) ?? trimmed
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, relativeTo: baseURL).standardizedFileURL
    }

    /// Wraps block content in a paragraph style carrying the current block
    /// stack and list indent, and terminates the paragraph.
    private func block(
        _ content: NSAttributedString,
        spacingBefore: CGFloat = 0,
        spacingAfter: CGFloat = 0
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.textBlocks = blockStack
        paragraph.headIndent = listIndent
        paragraph.firstLineHeadIndent = listIndent
        paragraph.paragraphSpacingBefore = spacingBefore
        paragraph.paragraphSpacing = spacingAfter
        paragraph.lineHeightMultiple = 1.3
        paragraph.lineBreakMode = .byWordWrapping

        let result = NSMutableAttributedString(attributedString: content)
        result.append(NSAttributedString(string: "\n", attributes: baseAttributes))
        result.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    /// Adds a symbolic trait to every font in a run, so nesting composes —
    /// `**bold _and italic_**` ends up both rather than only the inner one.
    private static func applying(
        _ traits: NSFontDescriptor.SymbolicTraits,
        to string: NSAttributedString
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: string)
        result.enumerateAttribute(
            .font,
            in: NSRange(location: 0, length: result.length)
        ) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let descriptor = font.fontDescriptor.withSymbolicTraits(
                font.fontDescriptor.symbolicTraits.union(traits)
            )
            result.addAttribute(
                .font,
                value: NSFont(descriptor: descriptor, size: font.pointSize) ?? font,
                range: range
            )
        }
        return result
    }
}
