//
//  MarkdownCodeHighlighter.swift
//  kero
//

import AppKit
import STPluginNeon
import SwiftTreeSitter

/// Colors a fenced code block in the markdown preview with the same grammars
/// and palette the source editor uses, so ` ```swift ` in a rendered README
/// looks like the same code open in a tab beside it.
///
/// The editor's highlighter (`SyntaxHighlightCoordinator`) can't be reused
/// here: it drives Neon incrementally against a live STTextView's TextKit 2
/// content manager. A preview fence is a short, immutable string, so it takes
/// the same path the editor uses for *injected* regions — parse once, run the
/// highlights query, color the ranges — with no incremental machinery at all.
@MainActor
final class MarkdownCodeHighlighter {
    static let shared = MarkdownCodeHighlighter()

    /// Posted when a grammar's query finishes compiling off the main thread, so
    /// every mounted preview can render again with the fence now colored. A
    /// notification rather than a callback because the highlighter is shared
    /// and several markdown panes can be open at once.
    static let grammarReadyNotification = Notification.Name("kero.markdownGrammarReady")

    private var pendingCompiles: Set<SyntaxLanguage> = []

    /// `code` styled with `font`/`color`, plus syntax colors when the fence's
    /// info string names a grammar kero bundles. Unknown or absent languages
    /// come back as plain text.
    func attributedCode(
        _ code: String,
        language: String?,
        font: NSFont,
        color: NSColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: code,
            attributes: [.font: font, .foregroundColor: color]
        )
        guard let language,
              let syntaxLanguage = SyntaxHighlighting.language(forInjectionName: language),
              let query = highlightsQuery(for: syntaxLanguage)
        else {
            return result
        }

        let parser = Parser()
        do {
            try parser.setLanguage(syntaxLanguage.parser)
        } catch {
            return result
        }
        guard let tree = parser.parse(code), let root = tree.rootNode else {
            return result
        }

        let context = SwiftTreeSitter.Predicate.Context(string: code)
        let limit = result.length
        for named in query.execute(node: root, in: tree).resolve(with: context).highlights() {
            // Clamped rather than trusted: a query range that ran past the end
            // of the string would trap on `addAttribute`.
            guard named.range.length > 0,
                  named.range.location >= 0,
                  named.range.upperBound <= limit,
                  !SyntaxHighlightCoordinator.ignoredCaptures.contains(named.name),
                  let tokenColor = SyntaxHighlightCoordinator.themeColor(
                      for: named.name,
                      theme: SyntaxHighlighting.theme
                  )
            else {
                continue
            }
            result.addAttribute(.foregroundColor, value: tokenColor, range: named.range)
        }
        return result
    }

    /// The compiled highlights query for a grammar, reusing the editor's shared
    /// cache. On a miss the compile — up to a couple hundred milliseconds for a
    /// big grammar — runs off the main thread and the ready notification
    /// re-renders when it lands; the fence stays plain until then. Mirrors the
    /// editor's `injectedHighlightsQuery`.
    private func highlightsQuery(for language: SyntaxLanguage) -> SwiftTreeSitter.Query? {
        if let query = HighlightQueryCache.cached(language) {
            return query
        }
        guard !pendingCompiles.contains(language) else { return nil }
        pendingCompiles.insert(language)

        let data = SyntaxHighlighting.highlightsData(for: language)
        let parser = language.parser
        DispatchQueue.global(qos: .userInitiated).async {
            let query = try? SwiftTreeSitter.Query(language: Language(language: parser), data: data)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingCompiles.remove(language)
                if let query {
                    HighlightQueryCache.store(query, for: language)
                }
                NotificationCenter.default.post(name: Self.grammarReadyNotification, object: nil)
            }
        }
        return nil
    }
}
