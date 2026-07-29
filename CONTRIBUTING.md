# Contributing to Kero

For anything larger than a fix, open an issue first —
Kero says no to features that fit some other tool better, and it's kinder to find
that out before the work.

## Setup and build

```bash
git clone --recurse-submodules https://github.com/egoist/kero.git
```

Already cloned? `git submodule update --init --recursive`. Bun is also needed for
`web/` and `scripts/`.

A Rust toolchain ([rustup](https://rustup.rs)) is required: the Alacritty
backend's bridge in `Vendor/alacritty-bridge` is a Rust static library, built
from an Xcode build phase. Building for a second architecture needs its target
installed too — `rustup target add x86_64-apple-darwin`.

Open `kero.xcodeproj` and run the `kero` scheme, or:

```bash
xcodebuild -project kero.xcodeproj -scheme kero -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Add `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` if you only have Xcode beta.

## Localization

Kero’s development language is English, with Simplified Chinese and Japanese
translations maintained in Xcode String Catalogs. See
[LOCALIZATION.md](LOCALIZATION.md) for translating existing text, adding a
language, testing a localization, and writing localizable Swift.

Translation-only pull requests are welcome. Xcode’s catalog editor and XLIFF
export/import workflow both work; contributors do not need to edit Swift.
