//
//  TerminalBackend.swift
//  kero
//

import AppKit

/// Which terminal emulator draws and drives Kero's panes.
///
/// Both backends implement Kero's own surface vocabulary, keeping emulator
/// details out of sessions, panes, history, and find UI.
enum TerminalBackend: String, CaseIterable, Identifiable, Sendable {
    /// Ghostty's Metal-backed surface, embedded via `Vendor/libghostty-spm`.
    case libghostty

    /// Alacritty's emulator core, the `alacritty_terminal` crate, reached
    /// through the Rust bridge in `Vendor/alacritty-bridge`. The crate ships
    /// no renderer — Alacritty's own is OpenGL welded to winit — so the grid
    /// is drawn by `AlacrittyTerminalView` with Metal and a CoreText glyph
    /// atlas.
    case alacritty

    /// The backend Kero uses when the config names none, or names one this
    /// build cannot create.
    static let fallback = TerminalBackend.libghostty

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .libghostty: "Ghostty"
        case .alacritty: "Alacritty"
        }
    }

    var settingsIconName: String {
        switch self {
        case .libghostty: "TerminalBackendGhostty"
        case .alacritty: "TerminalBackendAlacritty"
        }
    }

    /// Whether ``makeSurface(launch:)`` returns a surface. Settings offers only
    /// available backends and ``init(persisted:)`` refuses the rest, so a
    /// hand-edited config can never leave a window full of dead panes.
    var isAvailable: Bool {
        switch self {
        case .libghostty, .alacritty: true
        }
    }

    /// The backends there is actually a choice between. Settings shows its
    /// Backend row only once this holds more than one — a picker offering a
    /// selection that cannot take effect would misreport what Kero will do.
    static var selectable: [TerminalBackend] {
        allCases.filter(\.isAvailable)
    }

    /// Scannable strengths and limitations shown below the backend name.
    var settingsHighlights: [TerminalBackendHighlight] {
        switch self {
        case .libghostty:
            [
                .init(title: String(localized: "Excellent performance"), isPositive: true),
                .init(title: String(localized: "GPU-accelerated"), isPositive: true),
                .init(title: String(localized: "Higher memory footprint"), isPositive: false),
                .init(title: String(localized: "Image rendering"), isPositive: true),
            ]
        case .alacritty:
            [
                .init(title: String(localized: "Excellent performance"), isPositive: true),
                .init(title: String(localized: "GPU-accelerated"), isPositive: true),
                .init(title: String(localized: "Lower memory footprint"), isPositive: true),
                .init(title: String(localized: "Image rendering"), isPositive: true),
            ]
        }
    }

    /// What the shell reports as `TERM_PROGRAM`, and the version beside it.
    /// Tools treat this as a capability identity: Ghostty reports its embedded
    /// version, while the Alacritty backend advertises WezTerm so tools select
    /// the OSC 9 notification path that Kero implements.
    var termProgram: (name: String, version: String) {
        switch self {
        case .libghostty: ("ghostty", "1.3.2-dev")
        case .alacritty: ("WezTerm", "")
        }
    }

    /// Reads a persisted name, falling back for anything unknown or for a
    /// backend this build cannot create.
    init(persisted name: String?) {
        guard let name,
              let backend = TerminalBackend(rawValue: name),
              backend.isAvailable
        else {
            self = .fallback
            return
        }
        self = backend
    }

    /// Builds this backend's surface, or nil when this build has none for it.
    @MainActor
    func makeSurface(launch: TerminalLaunch) -> (any TerminalBackendSurface)? {
        switch self {
        case .libghostty:
            return KeroTerminalView(launch: launch)
        case .alacritty:
            return AlacrittyTerminalView(launch: launch)
        }
    }
}

struct TerminalBackendHighlight: Identifiable, Sendable {
    let title: String
    let isPositive: Bool

    var id: String { title }
}

/// Everything a backend needs to start one pane's shell. Kero resolves the
/// login shell, the PID/replay shim, and the environment once, up front; how a
/// backend spawns a PTY from there is its own business.
struct TerminalLaunch {
    /// Program to exec, and the arguments after argv[0] — for backends that
    /// spawn the PTY themselves.
    let program: String
    let arguments: [String]
    /// The same launch as one command line, for backends configured with a
    /// shell string rather than an argv.
    let commandLine: String
    let workingDirectory: String
    let environment: [String: String]
}

/// What Kero needs from a terminal surface, in Kero's vocabulary rather than
/// any one emulator's.
///
/// A surface is an `NSView` because panes reparent the same instance as splits
/// and tabs change (see `TerminalHostView`) — that is what keeps PTY state,
/// selection, and scrollback alive across layout changes. Everything the
/// terminal reports back travels the other way, through
/// ``TerminalBackendEvents``.
@MainActor
protocol TerminalBackendSurface: NSView {
    /// The session listening to this surface. Implementations hold it weakly:
    /// the session owns the surface, not the reverse.
    var events: (any TerminalBackendEvents)? { get set }

    /// Fired whenever direct interaction makes this pane the active one.
    var onBecomeFirstResponder: (() -> Void)? { get set }

    /// Target for the pane-split items in the surface's context menu.
    var splitTarget: SplitMenuTarget { get }

    /// True only while Kero is active, its window is key, and this exact
    /// surface owns the first responder.
    var hasEffectiveTerminalFocus: Bool { get }

    /// PID of the surface's foreground process group leader, when known.
    var foregroundPid: pid_t? { get }

    /// Whether anything is selected in the grid.
    var hasSelection: Bool { get }

    /// Whether this pane draws. Parked panes stay attached so PTY events keep
    /// draining, but should release renderer memory while nothing composites
    /// them.
    func setSurfaceVisible(_ visible: Bool)

    /// Re-reads `AppSettings` and `Theme`. Called whenever a live pane needs
    /// to pick up a new font, color theme, or input setting in place.
    func applyAppearance()

    /// Releases the emulator and its child process bookkeeping. The view
    /// itself outlives this call so teardown never pulls a pane out from
    /// under the layout mid-frame.
    func detach()

    func sendText(_ text: String)

    /// Clears the screen and scrollback, then repaints the shell's prompt at
    /// the top.
    func clearScreen()

    /// Scrolls the viewport to `fraction` of the way through the scrollback,
    /// 0 at the oldest row and 1 at the live prompt. This is the whole of what
    /// the overlay scrollbar's drag needs, so row arithmetic stays with the
    /// backend that knows its own buffer.
    func scroll(toFraction fraction: Double)

    /// Starts or replaces the find for `needle`. The backend highlights the
    /// matches itself and counts them back through ``TerminalBackendEvents``.
    ///
    /// Named for Kero's UI (⌘F, `TerminalFind`) rather than for any backend's
    /// own spelling of "search".
    func beginFind(_ needle: String)

    /// Ends the active find and clears its highlights.
    func endFind()

    /// Moves the selection to the next or previous match.
    func stepFind(forward: Bool)

    /// Starts a find for whatever is selected in the grid, resolving the
    /// needle backend-side so Kero never has to read it out and re-escape it.
    func findSelection()

    /// Writes the screen and scrollback to a temporary file as a VT stream and
    /// returns its path, for `TerminalHistorySerializer`.
    ///
    /// The file must be the only entry in a fresh subdirectory of the process
    /// temporary directory: Kero validates that before reading, and deletes
    /// both the file and its directory afterwards.
    func exportScreenFile() -> String?

    /// Same contract as ``exportScreenFile()``, for the scrollback above the
    /// viewport alone. Nil when there is none — which is also how Kero tells a
    /// scrolled shell from a full-screen TUI.
    func exportScrollbackFile() -> String?
}

/// What a terminal surface reports back to the session that owns it. Each
/// backend translates its own callbacks into these, so `TerminalSession` never
/// names an emulator's types.
@MainActor
protocol TerminalBackendEvents: AnyObject {
    func terminalDidChangeTitle(_ title: String)
    func terminalDidChangeWorkingDirectory(_ path: String)
    func terminalDidRingBell()
    func terminalDidReportShellIntegration(_ event: TerminalShellIntegrationEvent)

    /// The child process is gone, or is about to be. `processAlive` is false
    /// when the backend has already reaped it.
    func terminalDidClose(processAlive: Bool)

    func terminalDidRequestDesktopNotification(title: String, body: String)
    func terminalDidRequestOpenURL(_ url: String)
    func terminalDidScroll(_ position: TerminalScrollPosition)
    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardRequest)

    /// The backend started a find of its own accord — Kero's ⌘E path resolves
    /// the needle from the grid selection, so the bar learns it from here.
    func terminalDidBeginFind(needle: String)
    func terminalDidEndFind()
    func terminalDidUpdateFindTotal(_ total: Int?)
    func terminalDidUpdateFindSelected(_ selected: Int?)
}

/// Backend-neutral OSC 133 command lifecycle reports. Alacritty extracts all
/// four semantic markers at the PTY boundary; libghostty currently exposes
/// the completed command with its measured duration.
enum TerminalShellIntegrationEvent: Equatable, Sendable {
    case promptStart
    case commandStart
    case commandExecuting
    case commandFinished(exitCode: Int?, durationNanos: UInt64?)
}

/// Semantic state retained per terminal session for command navigation,
/// completion notifications, duration display, and other future features.
struct TerminalCommandLifecycle: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case prompt
        case input
        case executing
    }

    var phase: Phase = .idle
    var lastExitCode: Int?
    var lastDurationNanos: UInt64?
    /// Monotonic signal for consumers that need to react to every completed
    /// command, including consecutive commands with identical result metadata.
    var completionSequence: UInt64 = 0
}

/// Where the viewport sits within a surface's total content. Kept as raw row
/// counts rather than a fraction so the overlay scrollbar can both draw itself
/// and map a drag back onto a row.
struct TerminalScrollPosition: Equatable, Sendable {
    /// Rows of content, viewport plus scrollback.
    let totalRows: UInt64
    /// Rows visible in the viewport.
    let viewportRows: UInt64
    /// The content row currently at the top of the viewport.
    let topRow: UInt64

    /// False when everything fits, so there is nothing to scroll.
    var isScrollable: Bool {
        totalRows > viewportRows && viewportRows > 0
    }

    /// Visible fraction of the content, 0…1 — the scrollbar knob's length.
    var proportion: Double {
        totalRows > 0 ? Double(viewportRows) / Double(totalRows) : 1
    }

    /// The knob's travel, 0 at the top of the scrollback and 1 at the live
    /// prompt. Pinned to the bottom when there is nothing to scroll.
    var position: Double {
        guard isScrollable else { return 1 }
        return Double(topRow) / Double(totalRows - viewportRows)
    }

    /// The top row a scrollbar drag to `fraction` of its travel lands on.
    func row(atDragFraction fraction: Double) -> UInt64 {
        let available = totalRows > viewportRows ? totalRows - viewportRows : 0
        return UInt64((Double(available) * fraction).rounded())
    }
}

/// A backend asking Kero to confirm clipboard access before it proceeds.
/// Exactly one of ``approve()`` and ``deny()`` must be called.
@MainActor
final class TerminalClipboardRequest {
    enum Kind: Sendable {
        /// Paste protection flagged the pending paste as unsafe.
        case unsafePaste
        /// A terminal program asked to read the clipboard (OSC 52). Never
        /// resolve this one without asking: any program whose output reaches
        /// the terminal, including a remote SSH host, would otherwise be able
        /// to exfiltrate the macOS clipboard through the PTY.
        case programRead
    }

    let kind: Kind
    /// The text under decision: what would be pasted for ``Kind/unsafePaste``,
    /// or what the program would receive for ``Kind/programRead``.
    let contents: String

    private let resolve: @MainActor (Bool) -> Void

    init(kind: Kind, contents: String, resolve: @escaping @MainActor (Bool) -> Void) {
        self.kind = kind
        self.contents = contents
        self.resolve = resolve
    }

    func approve() { resolve(true) }
    func deny() { resolve(false) }
}
