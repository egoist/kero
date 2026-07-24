# TreeSitterTSX

The tree-sitter **TSX** grammar — TypeScript *with* JSX — exposed as a local
SwiftPM package so kero can link `tree_sitter_tsx()`.

## Why this is vendored

tree-sitter-typescript ships **two separate grammars**: `typescript` and `tsx`.
They aren't dialects of one parser — `typescript` has no JSX node types at all
(`jsx_opening_element` appears 0 times in its `parser.c`, 508 times in the TSX
one), because JSX's `<tag>` is ambiguous with TypeScript's `<T>x` type
assertion and the grammar has to pick one. So parsing a `.tsx` file with the
`typescript` grammar turns every element into a parse error and the whole JSX
body of the file renders miscolored.

kero's grammars otherwise come from `STTextView-Plugin-Neon`, which *does*
carry a `TreeSitterTSX` target — but it's unreachable: the package's only
product is `STTextView-Plugin-Neon`, `TreeSitterResource` doesn't depend on the
TSX target, and `TreeSitterLanguage` has no `.tsx` case. Nothing in the graph
references it, so SwiftPM never builds it and Xcode can't link a bare target
that isn't part of a product. Short of forking the plugin, vendoring the
grammar is the way to get the symbol.

Only the parser is vendored, not the queries: TSX's `highlights.scm` is
byte-identical to TypeScript's, which kero already reaches through
`TreeSitterTypeScriptQueries`. The JSX captures come from JavaScript's
`highlights-jsx.scm`; `SyntaxHighlighting.highlightsData(for:)` merges the
three.

## Provenance

Copied verbatim from `STTextView-Plugin-Neon` 0.8.1 (commit `5a30db4`),
`Sources/TreeSitterTSX/` — the same revision kero pins in
`kero.xcodeproj/project.pbxproj`, so the grammar matches the queries and the
tree-sitter runtime the rest of the highlighting stack uses (grammar ABI
`LANGUAGE_VERSION 13`). `Package.swift` mirrors that package's target
declaration (`cSettings: [.headerSearchPath("src")]`) and adds the library
product that upstream is missing.

To update, re-copy `include/` and `src/` from the plugin checkout at the
revision kero pins:

```sh
cp -R "$CHECKOUTS/STTextView-Plugin-Neon/Sources/TreeSitterTSX/"{include,src} \
  Vendor/TreeSitterTSX/Sources/TreeSitterTSX/
```
