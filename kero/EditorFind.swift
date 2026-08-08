//
//  EditorFind.swift
//  kero
//

import AppKit
import STTextView

/// Find and replace inside a file tab's editor.
///
/// STTextView already carries the AppKit find interface — an `NSTextFinder`
/// over the document, with the search-and-replace bar hosted by the editor's
/// enclosing scroll view — so all that is left is translating kero's Find menu
/// into finder actions and aiming them at the text view this file is currently
/// mounted in.
extension FileTab {
    /// The mounted editor's text view, or nil while this file has no pane on
    /// screen: `editorView` is weak and lives only as long as the editor does.
    var textView: STTextView? {
        (editorView as? NSScrollView)?.documentView as? STTextView
    }

    /// The mounted markdown preview's text view, when this file is showing its
    /// rendered form instead of the editor.
    private var previewTextView: NSTextView? {
        (editorView as? MarkdownPreviewView)?.findTarget
    }

    /// Whether this file is currently on screen as rendered markdown, which is
    /// read-only — so Find works but Replace has nothing to act on.
    var showsRenderedMarkdown: Bool {
        editorView is MarkdownPreviewView
    }

    func performFindAction(_ action: FindAction) {
        let finderAction: NSTextFinder.Action =
            switch action {
            case .show: .showFindInterface
            case .replace: .showReplaceInterface
            case .hide: .hideFindInterface
            case .next: .nextMatch
            case .previous: .previousMatch
            case .useSelection: .setSearchString
            }
        if let textView {
            // Asking for the next match before anything has been searched for,
            // or for the selection with none, does nothing rather than beeping.
            guard textView.textFinder.validateAction(finderAction) else { return }
            textView.textFinder.performAction(finderAction)
        } else if let previewTextView {
            // NSTextView keeps its own finder private and reads the action off
            // the sender's tag, so a rendered document is searched this way.
            let sender = NSMenuItem()
            sender.tag = finderAction.rawValue
            previewTextView.performTextFinderAction(sender)
        }
    }
}
