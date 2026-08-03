# Kero for iOS

Kero for iOS is a separate native Xcode project and app target. It is an SSH client for
iPhone and iPad; it does not build against or share runtime code with the macOS app.

## Version 0.0.1

- Saved SSH hosts
- Password and generated Ed25519 key authentication
- Device-only Keychain storage with optional Face ID or passcode protection
- Trust-on-first-use host-key verification and changed-key warnings
- Ghostty terminal with touch scrolling, Unicode input, links, selection, and hardware keyboards
- Optional `tmux new-session -A -s kero` startup for resumable remote work

Kero is deliberately an interactive SSH terminal. File transfer, Mosh transport,
agent-specific UI, and background session persistence are outside the 1.0 scope.
When iOS backgrounds the app, reconnect and use the optional tmux integration to
resume remote work.

## Build

Open `KeroMobile.xcodeproj`, select the `KeroMobile` scheme, then run on an iOS 18 or newer
device or simulator. Package dependencies resolve through Swift Package Manager.

Use Xcode's normal signed Run or Test action for runnable builds. An artifact built with
`CODE_SIGNING_ALLOWED=NO` can compile, but must not be installed: it lacks the simulated
application identifier that the iOS Keychain requires.

The `KeroMobileTests` target includes persistence, Keychain, host-key, key-generation,
and loopback SSH transport coverage. `KeroMobileUITests` exercises the primary
iPhone workflow.

## Release

Release metadata, the publishable privacy policy, and the external submission
checklist live in [`KeroMobileRelease`](../KeroMobileRelease/).
