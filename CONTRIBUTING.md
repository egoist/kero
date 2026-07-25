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

Open `kero.xcodeproj` and run the `kero` scheme, or:

```bash
xcodebuild -project kero.xcodeproj -scheme kero -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Add `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` for if you only have XCode beta.