# Why mitty vendors STTextView

This directory is a **verbatim copy of upstream [STTextView](https://github.com/krzyzanowskim/STTextView) tag `2.3.11`**, with exactly **one** local source patch. It is wired into the app as a local Swift package (`XCLocalSwiftPackageReference "Vendor/STTextView"` in `mitty.xcodeproj`), not as a remote SPM dependency.

We vendor it for one reason: **to carry a source-level fix that isn't in any upstream release.** SPM has no patch/overlay mechanism for a remote package — the only way to ship a change to a dependency's own source is to check that source into the repo and point the project at the local copy. If the patch below lands upstream, we can delete this directory and go back to a pinned remote dependency (see [Exit path](#exit-path)).

`Package.swift` is byte-identical to upstream 2.3.11; the fix is the whole delta.

## The patch

**`Sources/STTextViewAppKit/STTextView+Gutter.swift`** — gutter line numbers go off-by-one after a font or text-color change.

```diff
         } else if let viewportRange = textLayoutManager.textViewportLayoutController.viewportRange {
             // Get visible fragment views from the map and sort by document order
+            // mitty patch: after an attribute change (font/color) invalidates layout,
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

## Identifying the vendored version

Don't trust `CHANGELOG.md` in this directory — upstream's own changelog stops at `2.3.8` even on the `2.3.11` tag, so it is not a version marker. To confirm the base, diff `Sources/` against upstream tags and pick the one that differs only by the patch above:

```sh
git clone https://github.com/krzyzanowskim/STTextView.git /tmp/sttv && cd /tmp/sttv
git checkout 2.3.11 -- Sources
diff -ru Sources /path/to/mitty/Vendor/STTextView/Sources
# expect: only STTextView+Gutter.swift differs, only the hunk above
```

## Re-vendoring / bumping the version

1. Check out the new upstream tag's tree over this directory (keep the `.md` docs like this one).
2. Re-apply the gutter patch above. It's a one-line change (`.filter { $0.1.superview != nil }`); grep for `mitty patch` to find where it went, and check whether upstream has since fixed the duplicate-fragment numbering — if so, drop the patch.
3. Verify the delta is *only* the gutter file, using the diff recipe above.
4. Build with the project's usual command and confirm gutter numbers stay aligned after changing font/size (settings → editor) with a file open.

## What is NOT a patch here

Don't re-add these to the package — they live on the app side, in [`mitty/SourceTextEditor.swift`](../../mitty/SourceTextEditor.swift), and are configuration of a stock STTextView, not modifications to it:

- `scrollView.clipsToBounds = true` — the gutter is a document-height floating subview; since macOS 14 NSViews don't clip subviews, so scrolled-away numbers would otherwise draw over the header.
- `automaticallyAdjustsContentInsets = false` — the full-size-content-view window would otherwise add a titlebar-height top inset that misaligns the gutter by one line.
- Setting font/colors **before** `textView.text` — avoids the restyle-after-layout path that provokes the gutter bug in the first place (belt-and-suspenders alongside the patch).

## Exit path

The gutter fix is the only thing keeping this vendored. Upstream it (PR the `superview != nil` filter), and once it ships in a release, delete `Vendor/STTextView`, remove the `XCLocalSwiftPackageReference` from `mitty.xcodeproj`, and add STTextView back as a normal remote package dependency pinned to that release.
