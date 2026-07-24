//  Created by Marcin Krzyzanowski
//  https://github.com/krzyzanowskim/STTextView/blob/main/LICENSE.md

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
    import AppKit
#endif
#if canImport(UIKit)
    import UIKit
#endif

import STTextKitPlus

open class STTextLayoutManager: NSTextLayoutManager {

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        /// Posted when the selected range of characters changes.
        public static let didChangeSelectionNotification = NSTextView.didChangeSelectionNotification
    #else
        /// Posted when the selected range of characters changes.
        public static let didChangeSelectionNotification = NSNotification.Name("STTextView.didChangeSelectionNotification")
    #endif

    override public var textSelections: [NSTextSelection] {
        didSet {
            let notification = Notification(name: Self.didChangeSelectionNotification, object: self, userInfo: nil)
            NotificationCenter.default.post(notification)
        }
    }

    // kero patch: guard rendering attributes against empty ranges.
    //
    // Applying a rendering (temporary) attribute over an empty NSTextRange
    // crashes deep inside TextKit on macOS 15/26 — `_NSTextRunStorage` builds an
    // NSArray from a nil element and raises NSInvalidArgumentException
    // ("attempt to insert nil object from objects[0]"). Tree-sitter grammars
    // emit zero-length highlight tokens (markdown's `punctuation.special` for
    // block continuations and thematic breaks, among others), so the Neon
    // syntax-highlighting plugin hits this on the first markdown file. An empty
    // range has nothing to render, so skipping the call is a no-op. This Swift
    // name maps to `-[NSTextLayoutManager addTemporaryAttribute:value:forTextRange:]`.
    override open func addRenderingAttribute(_ attribute: NSAttributedString.Key, value: Any?, for textRange: NSTextRange) {
        guard !textRange.isEmpty else { return }
        super.addRenderingAttribute(attribute, value: value, for: textRange)
    }
}
