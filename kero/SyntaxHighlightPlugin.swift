//
//  SyntaxHighlightPlugin.swift
//  kero
//
//  kero's own STTextView highlighting plugin. It reuses STTextView-Plugin-Neon's
//  tree-sitter grammars and query files (via TreeSitterResource) and Neon's
//  incremental Highlighter, but owns the glue so it can do one thing the stock
//  plugin can't: **merge a language's inherited base query**. tree-sitter
//  highlight queries use nvim-treesitter's `; inherits:` convention — e.g.
//  TypeScript inherits ecma/JavaScript, C++ inherits C — and SwiftTreeSitter
//  doesn't resolve that, so the stock plugin (which loads a single query file)
//  leaves comments, strings and base keywords unhighlighted. See
//  SyntaxHighlighting.highlightsData(for:).
//
//  Adapted from STTextView-Plugin-Neon's Coordinator / STTextViewSystemInterface.
//

import AppKit
import Neon
import Rearrange
import STPluginNeon
import STTextKitPlus
import STTextView
import SwiftTreeSitter
import TreeSitterClient
import TreeSitterResource

/// STTextView plugin that drives Neon's tree-sitter highlighter.
struct SyntaxHighlightPlugin: STPlugin {
    let theme: STPluginNeonAppKit.Theme
    let language: TreeSitterLanguage
    /// The combined highlights query (`inherited base + language-specific`),
    /// already concatenated by `SyntaxHighlighting.highlightsData(for:)`.
    let highlightsData: Data

    func setUp(context: any Context) {
        context.events.onWillChangeText { affectedRange, _ in
            let range = NSRange(affectedRange, in: context.textView.textContentManager)
            context.coordinator.willChangeContent(in: range)
        }

        context.events.onDidChangeText { affectedRange, replacementString in
            guard let replacementString else { return }
            let range = NSRange(affectedRange, in: context.textView.textContentManager)
            context.coordinator.didChangeContent(
                context.textView.textContentManager,
                in: range,
                delta: replacementString.utf16.count - range.length,
                limit: context.textView.textContentManager.length
            )
        }

        context.events.onDidLayoutViewport { viewportRange in
            context.coordinator.updateViewportRange(viewportRange)
        }
    }

    func makeCoordinator(context: CoordinatorContext) -> SyntaxHighlightCoordinator {
        SyntaxHighlightCoordinator(
            textView: context.textView,
            theme: theme,
            language: language,
            highlightsData: highlightsData
        )
    }
}

/// Compiled highlight queries, cached per language.
///
/// Compiling a tree-sitter query (`ts_query_new`) costs O(grammar complexity),
/// not O(query size): it resolves every pattern against the grammar's symbol
/// table. For the Swift grammar (a 12 MB parser) that is ~190 ms, versus ~30 ms
/// for TypeScript — and it runs synchronously while the editor opens a file. The
/// query is identical for every file of a language and is immutable and
/// thread-safe once built, so it's compiled once and shared across editors;
/// only the first file of each language pays the cost.
@MainActor
enum HighlightQueryCache {
    private static var cache: [TreeSitterLanguage: SwiftTreeSitter.Query] = [:]

    static func query(
        for language: TreeSitterLanguage,
        tsLanguage: SwiftTreeSitter.Language,
        data: Data
    ) -> SwiftTreeSitter.Query? {
        if let cached = cache[language] {
            return cached
        }
        guard let query = try? SwiftTreeSitter.Query(language: tsLanguage, data: data) else {
            return nil
        }
        cache[language] = query
        return query
    }
}

@MainActor
final class SyntaxHighlightCoordinator {
    private var highlighter: Neon.Highlighter?
    private let language: TreeSitterLanguage
    private let tsLanguage: SwiftTreeSitter.Language
    private let tsClient: TreeSitterClient
    private let highlightsData: Data
    private var prevViewportRange: NSTextRange?

    init(
        textView: STTextView,
        theme: STPluginNeonAppKit.Theme,
        language: TreeSitterLanguage,
        highlightsData: Data
    ) {
        self.language = language
        self.highlightsData = highlightsData
        tsLanguage = Language(language: language.parser)

        tsClient = try! TreeSitterClient(language: tsLanguage) { codePointIndex in
            guard let location = textView.textContentManager.location(at: codePointIndex),
                  let position = textView.textContentManager.position(location)
            else {
                return .zero
            }
            return Point(row: position.row, column: position.column)
        }

        tsClient.invalidationHandler = { [weak self] indexSet in
            self?.highlighter?.invalidate(.set(indexSet))
        }

        // Empty fonts table (see SyntaxHighlighting.theme) → this keeps kero's
        // own editor font instead of resetting to the theme's.
        textView.font = theme.font(forToken: "plain") ?? textView.font

        let textInterface = SyntaxHighlightTextInterface(textView: textView) { neonToken in
            // Metadata captures aren't colors — skip them so they don't repaint
            // a real capture on the same range. Swift captures comments as
            // `@comment @spell`; letting `spell` through (it resolves to the
            // plain fallback, applied after `comment`) turned comments black.
            if Self.ignoredCaptures.contains(neonToken.name) {
                return nil
            }
            var attributes: [NSAttributedString.Key: Any] = [:]
            attributes[.font] = textView.font
            if let color = Self.themeColor(for: neonToken.name, theme: theme) {
                attributes[.foregroundColor] = color
            }
            if let font = theme.font(forToken: TokenName(neonToken.name)) {
                attributes[.font] = font
            }
            return attributes.isEmpty ? nil : attributes
        }

        highlighter = Neon.Highlighter(
            textInterface: textInterface,
            tokenProvider: tokenProvider(textContentManager: textView.textContentManager)
        )

        // Parse the whole document once up front.
        let documentRange = NSRange(textView.textContentManager.documentRange, in: textView.textContentManager)
        tsClient.willChangeContent(in: documentRange)
        tsClient.didChangeContent(
            in: documentRange,
            delta: textView.textContentManager.length,
            limit: textView.textContentManager.length,
            readHandler: Parser.readFunction(for: textView.textContentManager.attributedString(in: nil)?.string ?? ""),
            completionHandler: {}
        )
    }

    /// tree-sitter capture names that carry no color — spell-check hints,
    /// concealment, and the explicit "no highlight" marker. Grammars attach
    /// these alongside real captures (e.g. Swift's `@comment @spell`), so they
    /// must be dropped rather than resolved to a color.
    private static let ignoredCaptures: Set<String> = ["spell", "nospell", "conceal", "none"]

    /// The theme color for a tree-sitter capture name, trying the most specific
    /// name first and shortening on each dot (`variable.parameter` → `variable`),
    /// then the theme's `plain` default. The merged queries carry finer-grained
    /// capture names than the theme enumerates, so exact-match alone would leave
    /// many tokens uncolored.
    private static func themeColor(for name: String, theme: STPluginNeonAppKit.Theme) -> NSColor? {
        var key = name
        while true {
            if let color = theme.color(forToken: TokenName(key)) {
                return color
            }
            guard let dot = key.lastIndex(of: ".") else { break }
            key = String(key[..<dot])
        }
        return theme.color(forToken: "plain")
    }

    private func tokenProvider(textContentManager: NSTextContentManager) -> Neon.TokenProvider? {
        guard let query = HighlightQueryCache.query(for: language, tsLanguage: tsLanguage, data: highlightsData) else {
            return nil
        }
        return tsClient.tokenProvider(with: query) { range, _ in
            guard !range.isEmpty else { return nil }
            return textContentManager.attributedString(in: NSTextRange(range, provider: textContentManager))?.string
        }
    }

    func updateViewportRange(_ range: NSTextRange?) {
        if range != prevViewportRange {
            highlighter?.visibleContentDidChange()
        }
        prevViewportRange = range
    }

    func willChangeContent(in range: NSRange) {
        tsClient.willChangeContent(in: range)
    }

    func didChangeContent(_ textContentManager: NSTextContentManager, in range: NSRange, delta: Int, limit: Int) {
        guard let string = textContentManager.attributedString(in: nil)?.string else { return }
        tsClient.didChangeContent(
            in: range,
            delta: delta,
            limit: limit,
            readHandler: Parser.readFunction(for: string),
            completionHandler: {}
        )
    }
}

/// Bridges Neon's token styling onto an STTextView. Colors are applied as
/// rendering (temporary) attributes so they layer over the base text color;
/// any other attributes (currently none, since the theme carries no per-token
/// fonts) go into the text storage.
private final class SyntaxHighlightTextInterface: TextSystemInterface {
    typealias AttributeProvider = (Neon.Token) -> [NSAttributedString.Key: Any]?

    private let textView: STTextView
    private let attributeProvider: AttributeProvider

    init(textView: STTextView, attributeProvider: @escaping AttributeProvider) {
        self.textView = textView
        self.attributeProvider = attributeProvider
    }

    func clearStyle(in range: NSRange) {
        guard let textRange = NSTextRange(range, in: textView.textContentManager) else { return }
        textView.textLayoutManager.removeRenderingAttribute(.foregroundColor, for: textRange)
        textView.addAttributes([.font: textView.font], range: range)
    }

    func applyStyle(to token: Neon.Token) {
        // Zero-length tokens (markdown emits them) would crash TextKit when
        // used as a rendering-attribute range; STTextLayoutManager also guards
        // this, but skipping here avoids the wasted work.
        guard token.range.length > 0,
              let attributes = attributeProvider(token),
              let textRange = NSTextRange(token.range, in: textView.textContentManager)
        else {
            return
        }

        for attribute in attributes {
            if attribute.key == .foregroundColor {
                textView.textLayoutManager.addRenderingAttribute(.foregroundColor, value: attribute.value, for: textRange)
            } else {
                textView.addAttributes([attribute.key: attribute.value], range: token.range)
            }
        }
    }

    var length: Int {
        textView.textContentManager.length
    }

    var visibleRange: NSRange {
        guard let viewportRange = textView.textLayoutManager.textViewportLayoutController.viewportRange else {
            return .zero
        }
        return NSRange(viewportRange, provider: textView.textContentManager)
    }
}
