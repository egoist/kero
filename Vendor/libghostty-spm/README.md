# GhosttyKit

Swift Package wrapping [Ghostty](https://ghostty.org)'s terminal emulator library for Apple platforms.

> Pre-built `libghostty` static library distributed as an XCFramework binary target.

## Platforms

- macOS 13+
- iOS 15+
- Mac Catalyst 15+

## Products

| Library           | Description                                                                     |
| ----------------- | ------------------------------------------------------------------------------- |
| `GhosttyKit`      | Re-exports the libghostty C API (`ghostty.h`)                                   |
| `GhosttyTerminal` | Swift wrapper — native views, SwiftUI integration, input handling, display link |
| `GhosttyTheme`    | 485 terminal color themes from [iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes) (MIT License) |
| `ShellCraftKit`   | Sandboxed shell emulation framework (depends on GhosttyTerminal)                |

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.2.0"),
]
```

Then add the product you need:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "GhosttyTerminal", package: "libghostty-spm"),
    ]
)
```

## Usage

The example apps are the best starting point for real integration:

- `Example/GhosttyTerminalApp/` — macOS AppKit demo with delegate callbacks
- `Example/MobileGhosttyApp/` — iOS UIKit demo with keyboard, safe area, themes, and text selection

### SwiftUI (iOS 15+ / macOS 13+ / Mac Catalyst 15+)

```swift
import SwiftUI
import GhosttyTerminal

struct ContentView: View {
    @StateObject private var terminal = TerminalViewState()
    private let session = InMemoryTerminalSession(
        write: { data in
            // Handle bytes produced by the terminal.
        },
        resize: { viewport in
            // Keep your host backend in sync with the terminal grid.
        }
    )

    var body: some View {
        TerminalSurfaceView(context: terminal)
            .navigationTitle(terminal.title)
            .onAppear {
                terminal.configuration = TerminalSurfaceOptions(
                    backend: .inMemory(session)
                )
            }
    }
}
```

### UIKit / AppKit

```swift
import GhosttyTerminal

let terminalView = TerminalView(frame: .zero)
terminalView.delegate = self
terminalView.controller = TerminalController(configFilePath: path)
terminalView.configuration = TerminalSurfaceOptions(
    backend: .inMemory(session)
)
```

`TerminalView` is a type alias that resolves to `UITerminalView` (iOS/Catalyst) or `AppTerminalView` (macOS).

### Prompt and scrollback navigation

`TerminalViewState`, `TerminalView`, and `TerminalSurface` expose the same
programmatic navigation APIs:

```swift
terminal.jumpToPrompt(by: -1) // Previous prompt.
terminal.jumpToPrompt(by: 1)  // Next prompt.
terminal.scrollToRow(0)        // First absolute scrollback row.
```

Prompt navigation requires [Ghostty shell integration](https://ghostty.org/docs/features/shell-integration),
which records prompt boundaries. A host-managed backend must preserve or emit
equivalent OSC 133 prompt markers. Arbitrary Ghostty actions remain available
through `performBindingAction(_:)`.

## Notes

- `TerminalViewState` is the SwiftUI state container.
- `TerminalView` is the UIKit/AppKit view typealias.
- `TerminalController` owns app lifecycle, config resolution, themes, and surface creation.
- `InMemoryTerminalSession` provides the host-managed backend used by the sandboxed example apps.
- `GhosttyThemeCatalog` exposes bundled iTerm2 color schemes.

## Building from Source

The package includes a pre-built XCFramework. To rebuild libghostty from the Ghostty source:

```bash
# Requires: zig compiler
./Script/build.sh
```

This applies patches from `Patches/ghostty/`, builds for all target architectures, and assembles the XCFramework.

## Release Versioning

Bare semantic-version tags such as `1.3.1` are GhosttyKit Swift package
versions. They are independent from Ghostty's upstream tags. The matching
`storage.1.3.1` release stores the XCFramework consumed by that package tag.

Release builds use the immutable upstream Ghostty commit recorded in
`Ghostty.ref`. Updating Ghostty requires a reviewed change to that file, so a
package release cannot silently switch to a different upstream tag or commit.
Manual releases require an explicit package version; scheduled releases only
increment the package patch version when `main` is newer than the latest
package tag.

## Trimmed Build

The bundled `libghostty` is a trimmed build optimized for sandboxed, embedded use on Apple platforms.

| Component                        | Upstream Ghostty | libghostty-spm   | Reason                                                                                                                                                |
| -------------------------------- | ---------------- | ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| Terminal emulation core          | Yes              | Yes              | Full VT parser, state machine, grid — retained                                                                                                        |
| Metal renderer                   | Yes              | Yes              | GPU rendering via CAMetalLayer / IOSurface — retained                                                                                                 |
| Font rasterization & shaping     | Yes              | Yes              | CoreText font backend — retained                                                                                                                      |
| Configuration system             | Yes              | Yes              | All terminal config options — retained                                                                                                                |
| Input handling (key, mouse, IME) | Yes              | Yes              | Full keyboard/mouse/touch/IME pipeline — retained                                                                                                     |
| Text selection & clipboard       | Yes              | Yes              | Selection, copy/paste APIs — retained                                                                                                                 |
| Custom shaders (GLSL)            | Yes              | **No**           | `glslang` and `spirv-cross` removed (`-Dcustom-shaders=false`). Shadertoy/post-processing shaders are a desktop feature unnecessary for embedded use. |
| Terminal inspector (ImGui)       | Yes              | **No**           | `dcimgui` removed (`-Dinspector=false`). Debug inspector UI replaced with no-op stubs.                                                                |
| Sentry crash reporting           | Yes              | **No**           | Disabled (`-Dsentry=false`).                                                                                                                          |
| Native app runtime               | Yes              | **No**           | Cocoa/GTK/Wayland app shell disabled (`-Dapp-runtime=none`). The host app provides its own runtime.                                                   |
| Standalone executable            | Yes              | **No**           | No terminal `.app` or CLI binary emitted (`-Demit-exe=false`).                                                                                        |
| Documentation generation         | Yes              | **No**           | Skipped (`-Demit-docs=false`).                                                                                                                        |
| Frame data generator             | Build-time tool  | **Pre-compiled** | `framedata.compressed` shipped pre-built; framegen C tool dependency removed.                                                                         |
| Host-managed I/O backend         | No               | **Added**        | New `GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED` for non-PTY, sandbox-safe terminal I/O.                                                                 |
| iOS Metal rendering fixes        | No               | **Added**        | IOSurface +1px tolerance, synchronous present, 64-byte row alignment for iOS.                                                                         |
| iOS platform fixes               | No               | **Added**        | Deployment target lowered, private API removed, kqueue fix for simulator.                                                                             |

## License

MIT License. See [LICENSE](LICENSE) for details.

The bundled `libghostty` binary is built from [Ghostty](https://ghostty.org), which has its own license terms.

## Sponsor

- [LookInside](https://lookinside-app.com/) helps you inspect a running iOS or macOS app UI from your Mac.
- This project/repository is sponsored by AFK AI, INC.
