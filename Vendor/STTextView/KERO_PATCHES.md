# Why kero vendors STTextView

This directory is a **verbatim copy of upstream [STTextView](https://github.com/krzyzanowskim/STTextView) tag `2.3.11`**, with exactly **three** local source patches. It is wired into the app as a local Swift package (`XCLocalSwiftPackageReference "Vendor/STTextView"` in `kero.xcodeproj`), not as a remote SPM dependency.

We vendor it for one reason: **to carry source-level fixes that aren't in any upstream release.** SPM has no patch/overlay mechanism for a remote package — the only way to ship changes to a dependency's own source is to check that source into the repo and point the project at the local copy. Once the patches below land upstream, we can delete this directory and go back to a pinned remote dependency (see [Exit path](#exit-path)).

`Package.swift` is byte-identical to upstream 2.3.11; the fixes below are the source delta.

## The patches

### Gutter numbering after an attribute change

**`Sources/STTextViewAppKit/STTextView+Gutter.swift`** — gutter line numbers go off-by-one after a font or text-color change.

```diff
         } else if let viewportRange = textLayoutManager.textViewportLayoutController.viewportRange {
             // Get visible fragment views from the map and sort by document order
+            // kero patch: after an attribute change (font/color) invalidates layout,
+            // fragmentViewMap briefly holds both the old and new NSTextLayoutFragment
+            // for the same range (the old one is kept alive by its detached fragment
+            // view until the weak map purges). Numbering those stale entries shifts
+            // every line number. Detached views are never visible, so drop them.
             let visibleFragmentViews = STGutterCalculations.visibleFragmentViewsInViewport(
                 fragmentViewMap: fragmentViewMap,
                 viewportRange: viewportRange
-            )
+            ).filter { $0.1.superview != nil }
```

**Root cause.** When the font or text color is set after text has already been laid out, the attribute change invalidates layout and TextKit 2 rebuilds the affected `NSTextLayoutFragment`s. STTextView's `fragmentViewMap` is weak-key/weak-value, so for a brief window it holds **both** the old and new fragment for the same character range — the stale old fragment stays alive because its (now detached) fragment view hasn't been released yet. The gutter assigns a line number to *every* entry in that map, so the duplicated range pushes all subsequent line numbers down by one.

**Symptom.** Line numbers drift out of alignment with the text and stay wrong — it does **not** self-heal on relayout, resize, or scroll — so the fix has to happen at the numbering source rather than being papered over in the wrapper.

**Why the fix is safe.** A detached fragment view (`superview == nil`) is by definition not on screen, so it can never be a *visible* fragment. Filtering those out removes only the stale duplicates and leaves the real viewport fragments untouched. Worth upstreaming.

### Horizontal document sizing

**`Sources/STTextViewAppKit/STTextView.swift`** — no-wrap documents cannot scroll horizontally when their last line is shorter than an earlier line.

Both `sizeToFit()` and `updateContentSizeIfNeeded()` ask TextKit for the layout fragment immediately before the end of the document, then use that single fragment's width as the document width. That is the final line's width, not the widest line's width. Kero takes the maximum of that value and `usageBoundsForTextContainer.width`, which tracks the widest laid-out line. The scroll-view estimate also adds one `lineFragmentPadding` because TextKit's usage width stops that far short of the final glyph's trailing typographic edge, plus a 16 px readable gap after the final glyph.

**Symptom.** The editor renders long lines past the viewport but its document view can remain only as wide as the short final line, leaving `NSScrollView` with no horizontal scroll range. Even when a range exists, omitting the trailing padding leaves the last few pixels clipped at the rightmost position.

**Why the fix is safe.** It only increases the estimated width when TextKit has already measured wider content. Wrapped editors still replace the estimate with the viewport width in the existing `!isHorizontallyResizable` branch.

### Rendering attributes over empty ranges

**`Sources/STTextViewCommon/STTextLayoutManager.swift`** — applying a rendering (temporary) attribute over an **empty** `NSTextRange` crashes deep inside TextKit.

```swift
override open func addRenderingAttribute(_ attribute: NSAttributedString.Key, value: Any?, for textRange: NSTextRange) {
    guard !textRange.isEmpty else { return }
    super.addRenderingAttribute(attribute, value: value, for: textRange)
}
```

**Root cause.** `NSTextLayoutManager.addRenderingAttribute(_:value:for:)` is the Swift name for `-[NSTextLayoutManager addTemporaryAttribute:value:forTextRange:]`. On macOS 15/26, calling it with a zero-length range walks into `-[_NSTextRunStorage enumerateObjectsFromLocation:options:usingBlock:]`, which builds an `NSArray` from a nil element and raises `NSInvalidArgumentException` (`attempt to insert nil object from objects[0]`).

**Symptom.** The [STTextView-Plugin-Neon](https://github.com/krzyzanowskim/STTextView-Plugin-Neon) syntax highlighter sets a `.foregroundColor` rendering attribute per tree-sitter token. Several grammars emit **zero-length** highlight tokens — markdown's `punctuation.special` for block continuations and thematic breaks is the reliable repro — so opening the first markdown file crashes the app. `STTextViewSystemInterface.applyStyle(to:)` in the plugin doesn't guard the range, and it's a remote package we can't patch, so the guard goes here on STTextView's own layout-manager subclass (`textView.textLayoutManager` is always an `STTextLayoutManager`, so the override intercepts the plugin's call).

**Why the fix is safe.** An empty range has nothing to render, so skipping the call is a no-op — it only suppresses the crash. Worth upstreaming.

## Identifying the vendored version

Don't trust `CHANGELOG.md` in this directory — upstream's own changelog stops at `2.3.8` even on the `2.3.11` tag, so it is not a version marker. To confirm the base, diff `Sources/` against upstream tags and pick the one that differs only by the patches above:

```sh
git clone https://github.com/krzyzanowskim/STTextView.git /tmp/sttv && cd /tmp/sttv
git checkout 2.3.11 -- Sources
diff -ru Sources /path/to/kero/Vendor/STTextView/Sources
# expect: only the three documented source files and hunks differ
```

## Re-vendoring / bumping the version

1. Check out the new upstream tag's tree over this directory (keep the `.md` docs like this one).
2. Re-apply all three patches above; grep for `kero patch` to find them, and check whether upstream has since fixed any root cause — if so, drop the corresponding patch.
3. Verify the delta is limited to the documented source files, using the diff recipe above.
4. Build with the project's usual command and confirm gutter numbers stay aligned after changing font/size (settings → editor) with a file open.

## What is NOT a patch here

Don't re-add these to the package — they live on the app side, in [`kero/SourceTextEditor.swift`](../../kero/SourceTextEditor.swift), and are configuration of a stock STTextView, not modifications to it:

- `scrollView.clipsToBounds = true` — the gutter is a document-height floating subview; since macOS 14 NSViews don't clip subviews, so scrolled-away numbers would otherwise draw over the header.
- `automaticallyAdjustsContentInsets = false` — the full-size-content-view window would otherwise add a titlebar-height top inset that misaligns the gutter by one line.
- Setting font/colors **before** `textView.text` — avoids the restyle-after-layout path that provokes the gutter bug in the first place (belt-and-suspenders alongside the patch).

## Exit path

These three fixes are the only things keeping this vendored. Upstream them, and once all ship in a release, delete `Vendor/STTextView`, remove the `XCLocalSwiftPackageReference` from `kero.xcodeproj`, and add STTextView back as a normal remote package dependency pinned to that release. (The empty-range guard could alternatively move upstream into the Neon plugin's `applyStyle`; either home retires the patch.)
