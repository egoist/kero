# Plan: a Screen tab in the right sidebar

Status: proposed, nothing implemented. Written 2026-10-31, after the right
sidebar gained its Changes and Files tabs.

## Goal

Show the screen of the host the selected session runs on, in a third tab of
the right sidebar beside Changes and Files, and let the user work on it:
point, click, scroll and type into the host's desktop. The host is the one
the Files tab already follows (`hostOf(pane)`).

## What the user sees

**The tab.** Screen sits after Changes and Files. It shows a live preview
of the host's screen, fitted to the sidebar with its aspect ratio kept. Its
header row holds:

- the host's name chip in its color, so it's clear which machine is shown;
- a display picker, shown only when the host has more than one display;
- an "Open in viewer" button.

**The viewer card.** A click on the preview opens it in the viewer card
beside the panes, as Files opens a file there (`viewerCard`, side.go). The
card is resizable, so that's where the user works on the host's screen.
The sidebar is mostly a glanceable monitor.

**Shortcut.** `screen.toggle`, bound to `CmdOrCtrl+Alt+S` (free; Changes is
`+G`, Files `+E`), `Remote: true`.

**States**, each shown with `sideMessage`:

| Situation | Shows |
| --- | --- |
| A local session | Your own screen: hide the tab's body, or offer the host picker (see Decisions) |
| A host without a display (a headless Linux box, Windows in session 0) | "devbox has no display" |
| A host without Screen Recording permission | Which setting to turn on, on that machine, and **Ask on devbox**, which shows the system's prompt there |
| A host on an older Kero | The existing **Update** flow |
| A dropped link | The last frame, faded, as the sidebar's sessions fade; it picks up again on reconnect |

**Interaction.**

- View only by default. A **Control** toggle in the header arms input for
  that host, kept per session, not globally.
- With control armed, a click on the image gives it the keyboard: pointer,
  scroll and keys go to the host. ⌘-shortcuts go too while it has the
  keyboard, except one release chord (such as ⌃⌥⌘ or ⇧⌘Esc). A click outside
  releases it too. A "Controlling devbox" bar shows while it holds the
  keyboard.
- Coordinates go over the wire normalized, 0 to 1 per display, so the size
  the image shows at doesn't matter.

## Architecture

**kerod captures the screen itself.** Not a tunnel to VNC or Screen Sharing,
which would mean:

- asking for a password, or Apple's ARD authentication;
- a third-party server on Windows and Linux;
- no way for the host to scale frames down to the sidebar's size.

kerod already owns the one multiplexed, authenticated, compressed connection
to each host (see [remote-servers.md](remote-servers.md)), and the screen
rides on it.

**Discovery**, over the control connection:

- `screen.displays` returns the displays (`ID, Name, W, H, Scale, Main`) and
  an `Access`: `granted | denied | undetermined | no-display | off`.
- `screen.ask` shows the permission prompt on the host.
- An older kerod answers both with "unknown method", which the app shows as
  "update the host". These are new methods, so `proto.Version` stays as it
  is, and no capability flag is needed.

**The stream** is a new Hello kind, `screen`, a yamux stream as `attach` is
(daemon.go). The app opens one only after `screen.displays` succeeds, so an
older kerod never sees the kind.

- Host to app:
  - `ScreenSize`: the display's size, and the scale being sent;
  - `ScreenTiles`: the 64×64 tiles that changed, as JPEG while they change,
    then as lossless PNG once they've been still for about 500 ms (as
    Tight VNC does);
  - `ScreenCursor`: its position and shape, apart from the frames, so the
    pointer moves smoothly at low frame rates.
- App to host:
  - `ScreenConfig`: the display, the largest size in pixels (the sidebar's
    or the card's backing size) and the frame rate's cap;
  - `ScreenCredit`: flow control;
  - `ScreenPointer`, `ScreenScroll`, `ScreenKey` (the physical keycode, and
    the text it types).

**Flow control** decides how it feels. The app grants credit for N frames.
The host captures continuously, but sends its latest frame only while it has
credit, so the newest frame always wins and a slow SSH link drops frames
rather than queueing them. The sidebar asks for about 2–5 fps at its size;
the viewer card, with control armed, for up to 30.

**Capture runs only while someone is watching**: the tab or the card shows,
and the window isn't hidden behind others. Otherwise the stream closes, and
capture with it, which matters given the GPU memory each pane already pins.

**Drawing.** `ui.Bitmap.Update(*image.RGBA)` keeps the bitmap's GPU texture
and uploads the new pixels into it, as for video (mygo/ui/bitmap.go). The
tiles are decoded off the main thread into one `image.RGBA` per display,
then `Update` runs through `Window.Update`: one texture, nothing allocated a
frame.

**Bandwidth.** The mux already compresses everything with DEFLATE, which
compresses the JPEG tiles a second time for nothing. Fine for a start; if it
shows in profiles, hardware H.264 (VideoToolbox, Media Foundation) replaces
the tiles in a later phase.

## Platforms and permissions

| Host | Capture | Input | Catch |
| --- | --- | --- | --- |
| macOS | ScreenCaptureKit, through purego, which kerod already uses | `CGEventPost` | TCC, below |
| Windows | DXGI Desktop Duplication | `SendInput` | A kerod started over SSH while no one is logged on runs in session 0, which has no desktop; the Task Scheduler one runs in the user's session and works |
| Linux, X11 | XShm, through purego | XTest | None |
| Linux, Wayland | xdg-desktop-portal ScreenCast and PipeWire | the RemoteDesktop portal | Someone at the host approves a dialog: later |

**macOS TCC.** Screen Recording, and Accessibility for input, are granted to
the *responsible process*:

- a kerod the app spawned (`__kerod`, internal/client/client.go) counts as
  Kero.app, so the prompt names Kero, which works;
- the server build under launchd is granted under its own binary's path;
- a kerod that `kero __bridge` started over SSH counts as sshd, which can't
  show a prompt.

For the last, kerod runs capture in a helper launched through LaunchServices
or its launchd agent, so that it has a stable identity. The docs then say:
grant Kero Screen Recording on the host, once.

## Safety

- A connection can already run anything as its account, so watching and
  driving the desktop needs no new privilege. It is more visible, though, so
  the host has the say.
- **The host's configuration:** `screen = control | view | off` in the
  host's `~/.config/kero/config`, which kerod reads and follows live, as it
  does `listen`. The default is a decision below.
- **Seen on the host:** macOS shows its own recording indicator. The host's
  app, while it runs, shows "Viewed from laptop" in its tray. `kero clients`
  lists `screen` connections with their peer.
- **Control is announced:** as control starts, the host gets a notification
  naming the client.

## Code map

- `side.go`: a `sideScreen` constant, accepted by `sideTab()`; a third
  `tabButton`; a branch of `viewerCard`.
- `screen.go` (new, the app): `screenState` (streams by host and display,
  their bitmaps, the credit, control armed per session), `screenSide`,
  `screenViewer`, input mapping, taking and releasing the keyboard.
- `internal/actions`, `actions.go`: `screen.toggle` and `screen.control`;
  their strings in en, ja and zh.
- `internal/proto/screen.go`: `KindScreen`, `ScreenHello`, the frame kinds,
  `ScreenDisplay`, the methods' params.
- `internal/screen/`: `capture_{darwin,windows,linux}.go`, `input_*.go`,
  the tile differ and encoder. Add it to `kerodSource`'s embed list in
  kerod_build.go, or `TestKerodSource` fails.
- `internal/daemon`: `serveScreen`, the `screen.*` methods, the `screen`
  configuration key, and a `ClientInfo` kind.
- `docs/remote.md`, and ja and zh: a "Screen" section.
- Later, for agents: `kero -H devbox screenshot [-o file.png]`, so an agent
  can check a remote GUI: `screen.displays` and one frame.

## Phases

1. **macOS hosts, view only.** The tab and the viewer card,
   `screen.displays`, the stream with credit, JPEG tiles, the permission
   states. This tests the whole pipeline end to end.
2. **Control on macOS.** Pointer, scroll, keys, the release chord, the
   host's notification, the `screen` configuration key.
3. **Windows and X11 hosts**, the lossless refinement, cursor shapes.
4. **Extras.** `kero screenshot` for agents, clipboard sync while
   controlling, Wayland through the portal, hardware video encoding.

## Decisions

1. **The default of `screen`:** `view`, with control turned on at the host,
   or `control`, as it's the same account anyway. Leaning `view`: safe, and
   one line of configuration turns control on.
2. **Local sessions:** hide the tab, or let it show any host's screen
   through a host picker, so a Mac mini's screen can be watched while the
   user works locally. Leaning the picker: it makes the tab useful with no
   remote session selected.
3. **Input in the sidebar's preview,** or only in the viewer card. Leaning
   the card only: the sidebar is too small to aim at, and it avoids stray
   clicks.
