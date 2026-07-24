import AppKit

final class STTextFinderBarContainer: NSObject, NSTextFinderBarContainer {

    // Forward NSTextFinderBarContainer to enclosing NSScrollView (for now at least)
    weak var client: STTextView?

    var findBarView: NSView? {
        get {
            client?.scrollView?.findBarView
        }

        set {
            client?.scrollView?.findBarView = newValue

            // Re-seat the gutter so it keeps clearing the find bar. It has to
            // go back through `addFloatingSubview` rather than a plain
            // `addSubview`: that is what re-registers it with the scroll view's
            // floating-subview machinery, which is the only thing that keeps a
            // document-height gutter scrolling with the text and positioned
            // against the content area. Re-parenting it directly onto the
            // scroll view — as this used to do, purely to get the find bar
            // drawn on top — silently drops that registration, freezing the
            // line numbers where they stood when the bar appeared.
            Task { @MainActor in
                if let scrollView = client?.scrollView, let gutterView = client?.gutterView {
                    gutterView.removeFromSuperviewWithoutNeedingDisplay()
                    scrollView.addFloatingSubview(gutterView, for: .horizontal)
                    // Re-inserting the gutter moves it to the front of the
                    // scroll view's subviews, so pin the find bar back above
                    // it. AppKit happens to order these two correctly on its
                    // own today; this makes the requirement explicit instead
                    // of leaving the bar's visibility to chance.
                    if let findBarView = scrollView.findBarView {
                        scrollView.addSubview(findBarView, positioned: .above, relativeTo: nil)
                    }
                }
            }
        }
    }

    var isFindBarVisible: Bool {
        get {
            client?.scrollView?.isFindBarVisible ?? false
        }

        set {
            client?.scrollView?.isFindBarVisible = newValue
            // The gutter offsets itself by the find bar's height, so it has to
            // re-lay out whenever the bar comes or goes; nothing else marks it
            // dirty, and a hidden bar would otherwise leave the line numbers
            // displaced until the next scroll.
            client?.gutterView?.needsLayout = true
        }
    }

    func contentView() -> NSView? {
        client?.contentView
    }

    func findBarViewDidChangeHeight() {
        client?.scrollView?.findBarViewDidChangeHeight()
    }
}
