# CLAUDE.md

Kero is a native macOS terminal workspace: SwiftUI around libghostty surfaces, with projects,
panes, a file tree, a git panel, an editor, and a diff viewer. AppKit used over SwiftUI where performance matters.

- [PRODUCT.md](PRODUCT.md) — who Kero is for; product and design calls follow from it.
- [CONTRIBUTING.md](CONTRIBUTING.md) — build, verify, and what a PR must say. Read before opening one.
- [RELEASING.md](RELEASING.md) — maintainer-only. Never bump the version in a PR.

## Verify

Build, run the app, exercise the change;

## Conventions

- Match the file you're in. Comments explain *why* — keep them, add them.
- User-visible changes get a bullet under `## [unrelease]` in
  [CHANGELOG.md](CHANGELOG.md), in the voice of the in-app release notes.
