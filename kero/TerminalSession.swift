//
//  TerminalSession.swift
//  kero
//

import AppKit
import Combine
import Darwin
import Foundation
import GhosttyTerminal
import GhosttyTheme

/// One login shell rendered by one long-lived libghostty surface. SwiftUI only
/// reparents the same `KeroTerminalView`, so PTY state, selection, and
/// scrollback survive tab and split-layout changes.
@MainActor
final class TerminalSession: NSObject, nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id = UUID()

    @Published var title: String
    @Published var workingDirectory: String?
    @Published var hasExited = false

    let terminalView: KeroTerminalView
    let overlayScrollbar = OverlayScrollbarView()
    /// Find-in-terminal state for this session's pane (⌘F).
    let find: TerminalFind
    var onExited: ((TerminalSession) -> Void)?

    private static let persistedHistoryLineLimit = 500
    private static let embeddedGhosttyVersion = "1.3.2-dev"

    private let shellPath: String
    private let launchWorkingDirectory: String
    private let controller: TerminalController
    private let launchCommand: String
    private let launchDirectoryURL: URL?
    private let shellPidFileURL: URL?
    private var cachedShellPid: pid_t?
    private var lastScrollbar: TerminalScrollbar?
    private var lastHistorySnapshot: String?
    private var isTerminating = false

    init(initialDirectory: String? = nil, restoredHistory: String? = nil) {
        let shellPath = Self.loginShell()
        let directory = Self.validWorkingDirectory(initialDirectory)
        let artifacts = Self.makeLaunchArtifacts(restoredHistory: restoredHistory)
        let launchCommand = Self.makeLaunchCommand(
            shellPath: shellPath,
            pidFileURL: artifacts.pidFileURL,
            replayFileURL: artifacts.replayFileURL
        )

        self.shellPath = shellPath
        launchWorkingDirectory = directory
        self.launchCommand = launchCommand
        launchDirectoryURL = artifacts.directoryURL
        shellPidFileURL = artifacts.pidFileURL
        title = (shellPath as NSString).lastPathComponent

        controller = TerminalController(
            configSource: .none,
            theme: Self.ghosttyTheme(),
            terminalConfiguration: Self.terminalConfiguration(command: launchCommand)
        )
        let terminalView = KeroTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        self.terminalView = terminalView
        find = TerminalFind(terminal: terminalView)
        lastHistorySnapshot = restoredHistory
        super.init()

        terminalView.delegate = self
        terminalView.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: directory,
            envVars: Self.surfaceEnvironment()
        )
        terminalView.controller = controller
        installOverlayScrollbar()
        applyTheme()
    }

    deinit {
        if let launchDirectoryURL {
            try? FileManager.default.removeItem(at: launchDirectoryURL)
        }
    }

    private func installOverlayScrollbar() {
        overlayScrollbar.alphaValue = 0
        overlayScrollbar.onScroll = { [weak self] position in
            guard let self, let scrollbar = self.lastScrollbar else { return }
            let available = scrollbar.total > scrollbar.len
                ? scrollbar.total - scrollbar.len : 0
            let row = UInt((Double(available) * position).rounded())
            _ = self.terminalView.scrollToRow(row)
        }
    }

    /// Reconfigures libghostty in place when either appearance or terminal
    /// font settings change. Ghostty also uses these values for OSC 10/11
    /// queries, so reported defaults always match the visible theme.
    func applyTheme() {
        _ = controller.setTerminalConfiguration(
            Self.terminalConfiguration(command: launchCommand)
        )
        _ = controller.setTheme(Self.ghosttyTheme())
        let isDark = NSApp.effectiveAppearance.bestMatch(
            from: [.darkAqua, .aqua]
        ) == .darkAqua
        controller.setColorScheme(isDark ? .dark : .light)
    }

    /// Stops the whole PTY job before releasing the surface. libghostty's
    /// surface teardown owns the final reap; sending HUP first gives shells the
    /// same close signal they received before the backend migration.
    func terminate() {
        guard !hasExited, !isTerminating else { return }
        isTerminating = true
        beginTeardown(processAlive: true, notifyExit: false)
    }

    /// Keeps the session and surface alive until the child has either exited
    /// or been force-stopped. Releasing AppTerminalView first can make
    /// libghostty wait synchronously for a process that ignored SIGHUP.
    private func beginTeardown(processAlive: Bool, notifyExit: Bool) {
        if processAlive {
            _ = shellPid // Cache it before `hasExited` changes.
            signalTerminalJob(SIGHUP)
        }

        Task { @MainActor [self] in
            if processAlive {
                // Give well-behaved shells a moment to unwind, then guarantee
                // surface teardown cannot wait indefinitely.
                try? await Task.sleep(for: .milliseconds(120))
                signalTerminalJob(SIGKILL)
            } else {
                // Avoid freeing the surface reentrantly from libghostty's
                // process-close callback.
                await Task.yield()
            }
            terminalView.controller = nil
            hasExited = true
            removeLaunchArtifacts()
            if notifyExit { onExited?(self) }
        }
    }

    private func signalTerminalJob(_ signal: Int32) {
        var pids = Set<pid_t>()
        if let shellPid { pids.insert(shellPid) }
        if let foreground = terminalView.foregroundPid, foreground > 0 {
            pids.insert(foreground)
        }
        for pid in pids where pid > 1 {
            // Interactive shells and their foreground jobs normally lead
            // distinct process groups. Signal the group, then the leader as a
            // fallback for an unusual launch configuration.
            _ = Darwin.kill(-pid, signal)
            _ = Darwin.kill(pid, signal)
        }
    }

    private func removeLaunchArtifacts() {
        guard let launchDirectoryURL else { return }
        try? FileManager.default.removeItem(at: launchDirectoryURL)
    }

    /// Short label for the sidebar: the tail of the current directory, if known.
    var directoryLabel: String? {
        guard let dir = workingDirectory else { return nil }
        let path = URL(string: dir)?.path ?? dir
        let tail = (path as NSString).lastPathComponent
        return tail.isEmpty ? nil : tail
    }

    /// Best-effort live shell directory: OSC 7 first, kernel process metadata
    /// second, then the directory used to launch this session.
    var currentDirectoryPath: String {
        if let dir = workingDirectory {
            if let url = URL(string: dir), url.isFileURL { return url.path }
            if dir.hasPrefix("/") { return dir }
        }
        if let shellPid, let path = Self.processWorkingDirectory(pid: shellPid) {
            return path
        }
        return launchWorkingDirectory
    }

    func sendCommand(_ text: String) {
        terminalView.sendText(text)
    }

    /// Clears the emulator's visible screen and scrollback, then asks the
    /// foreground shell to repaint its prompt at the top.
    func clear() {
        _ = terminalView.performBindingAction("clear_screen")
        _ = terminalView.performBindingAction("text:\\x0c")
    }

    /// Styled VT snapshot used by the existing sidecar history store. A
    /// scrollback/PID heuristic keeps a full-screen alternate buffer from
    /// replacing the last saved shell scrollback in normal shell/TUI use.
    func serializedHistory(captureLive: Bool) -> String? {
        guard AppSettings.shared.restoreTerminalHistory else { return nil }
        guard captureLive else { return lastHistorySnapshot }

        let rootShellIsForeground = shellPid != nil
            && terminalView.foregroundPid == shellPid
        if !rootShellIsForeground,
           !TerminalHistorySerializer.hasPrimaryScrollback(terminalView) {
            // A primary screen with no rows above the viewport and an
            // alternate screen both have no scrollback export. The root shell
            // is foreground only in the former case; a TUI owns its own
            // foreground process group in the latter.
            return lastHistorySnapshot
        }
        switch TerminalHistorySerializer.capture(
            from: terminalView, maxLines: Self.persistedHistoryLineLimit
        ) {
        case .captured(let snapshot):
            lastHistorySnapshot = snapshot
            return snapshot
        case .failed:
            return lastHistorySnapshot
        }
    }

    var shellName: String {
        (shellPath as NSString).lastPathComponent
    }

    /// PID of the root login shell. The launch shim records its own PID before
    /// `exec`, so this remains stable while Ghostty's foreground PID moves to
    /// child jobs and back.
    var shellPid: pid_t? {
        if let cachedShellPid, cachedShellPid > 0 { return cachedShellPid }
        guard !hasExited, let shellPidFileURL,
              let text = try? String(contentsOf: shellPidFileURL, encoding: .utf8),
              let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0
        else { return nil }
        cachedShellPid = value
        return value
    }

    // MARK: - Ghostty configuration

    private static func terminalConfiguration(command: String) -> TerminalConfiguration {
        let settings = AppSettings.shared
        let family = settings.fontFamily.isEmpty
            ? TerminalFont.bundledFamily : settings.fontFamily
        return TerminalConfiguration { builder in
            builder.withFontFamily(family)
            // Keep Kero's bundled icon font as a fallback after the selected
            // primary face. Repeated font-family entries form Ghostty's list.
            builder.withCustom("font-family", "Symbols Nerd Font Mono")
            builder.withFontSize(Float(settings.fontSize))
            // While translucent, the surface renders a fully clear background:
            // the window chrome applies the theme tint once across the whole
            // window (see ContentView.windowBackground), and a second tint
            // here would compound into a visibly darker cell grid.
            let surfaceOpacity =
                settings.backgroundOpacity < AppSettings.defaultBackgroundOpacity ? 0 : 1.0
            builder.withCustom("background-opacity", TOML.number(surfaceOpacity))
            // Always set explicitly: the wrapper's ConfigSource.none base
            // config injects the package default `font-thicken = true`, and
            // only a later entry in the rendered config overrides it.
            builder.withFontThicken(settings.fontThicken)
            builder.withCursorStyle(.block)
            builder.withCursorStyleBlink(true)
            // Kero's insets around the grid live inside ghostty as
            // window-padding so that window-padding-color=extend can flood
            // them with the nearest cell's background — full-screen TUIs
            // fill the surface while text keeps its breathing room (the
            // host adds a 2pt pane-background frame around the surface, so
            // the fill stops just short of the pane edges; these values plus
            // that frame put the text at least 12pt from the sides and 10pt
            // from the top/bottom). balance re-centers the grid, splitting
            // the sub-cell remainder evenly per axis instead of stranding
            // the prompt a full row above the pane's bottom edge; it also
            // makes each side's padding equal to the value here plus half
            // the remainder, so per-side asymmetry is not expressible.
            builder.withWindowPaddingX(10)
            builder.withWindowPaddingY(8)
            builder.withCustom("window-padding-balance", "true")
            builder.withCustom("window-padding-color", "extend")
            // Kero owns the app-level command map. Leaving Ghostty's defaults
            // installed makes its performKeyEquivalent intercept shortcuts
            // such as Cmd-T, Cmd-N, Cmd-D, Cmd-K, and project/tab navigation
            // before SwiftUI's command menu can handle them.
            builder.withCustom("keybind", "clear")
            // Reinstall only terminal-local editing and scrolling bindings.
            // These preserve the native macOS shell experience without
            // reclaiming any shortcut owned by Kero's command menus.
            for keybind in [
                "alt+left=esc:b",
                "alt+right=esc:f",
                "super+left=text:\\x01",
                "super+right=text:\\x05",
                "super+backspace=text:\\x15",
                "super+home=scroll_to_top",
                "super+end=scroll_to_bottom",
                "super+page_up=scroll_page_up",
                "super+page_down=scroll_page_down",
            ] {
                builder.withCustom("keybind", keybind)
            }
            builder.withCustom("command", "shell:\(command)")
            builder.withCustom("term", "xterm-256color")
            builder.withCustom("shell-integration", "none")
            // The previous backend retained 500 rows. Ghostty budgets bytes
            // instead, so use a small per-surface cap with enough room for at
            // least that many normally sized rows while keeping synchronous
            // history exports bounded.
            builder.withCustom("scrollback-limit", "4194304")
            builder.withCustom("macos-option-as-alt", "true")
            builder.withCustom("scrollbar", "never")
            // Terminal-program clipboard access via OSC 52, matching the
            // Ghostty app defaults: reads prompt the user per request
            // (TerminalSession presents the confirmation sheet), writes
            // are allowed so OSC 52 copy from remote tmux/vim works, and
            // paste protection warns before pastes that look like they
            // could execute commands. Never `allow` reads without a
            // prompt — that lets any program whose output reaches the
            // terminal, including a remote SSH host, silently exfiltrate
            // the macOS clipboard through the PTY. Set explicitly so the
            // wrapper's base config can never drift them. Cmd-C/Cmd-V are
            // host-initiated and stay prompt-free (unless an unsafe paste
            // trips protection).
            builder.withCustom("clipboard-read", "ask")
            builder.withCustom("clipboard-write", "allow")
            builder.withCustom("clipboard-paste-protection", "true")
        }
    }

    private static func ghosttyTheme() -> GhosttyTerminal.TerminalTheme {
        GhosttyTerminal.TerminalTheme(
            light: Theme.terminal(dark: false).toTerminalConfiguration(),
            dark: Theme.terminal(dark: true).toTerminalConfiguration()
        )
    }

    private static func surfaceEnvironment() -> [String: String] {
        var environment = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
        ]
        if ProcessInfo.processInfo.environment["LANG"] == nil {
            environment["LANG"] = "en_US.UTF-8"
        }
        return environment
    }

    private struct LaunchArtifacts {
        let directoryURL: URL?
        let pidFileURL: URL?
        let replayFileURL: URL?
    }

    private static func makeLaunchArtifacts(restoredHistory: String?) -> LaunchArtifacts {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("kero-terminal-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let pidFile = directory.appendingPathComponent("shell.pid")
            var replayFile: URL?
            if AppSettings.shared.restoreTerminalHistory,
               let restoredHistory,
               !restoredHistory.isEmpty {
                let file = directory.appendingPathComponent("history.vt")
                let separator = restoredHistory.hasSuffix("\n") ? "" : "\r\n"
                let contents = restoredHistory + separator
                    + TerminalHistorySerializer.restoredBanner() + "\r\n"
                try Data(contents.utf8).write(to: file, options: .atomic)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: file.path
                )
                replayFile = file
            }
            return LaunchArtifacts(
                directoryURL: directory,
                pidFileURL: pidFile,
                replayFileURL: replayFile
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            NSLog("kero: failed to prepare terminal launch files: \(error)")
            return LaunchArtifacts(directoryURL: nil, pidFileURL: nil, replayFileURL: nil)
        }
    }

    private static func makeLaunchCommand(
        shellPath: String,
        pidFileURL: URL?,
        replayFileURL: URL?
    ) -> String {
        var commands = ["umask 077"]
        if let pidFileURL {
            commands.append("printf '%s\\n' \"$$\" > \(shellQuote(pidFileURL.path))")
        }
        if let replayFileURL {
            let path = shellQuote(replayFileURL.path)
            commands.append("if [ -r \(path) ]; then /bin/cat \(path); /bin/rm -f \(path); fi")
        }
        // Many terminal tools use TERM_PROGRAM as a capability hint. Since
        // Kero's terminal is libghostty-backed, advertise Ghostty so tools
        // such as terminal-image-cli select the Kitty graphics protocol.
        commands.append("export TERM_PROGRAM=ghostty")
        commands.append(
            "export TERM_PROGRAM_VERSION=\(shellQuote(embeddedGhosttyVersion))"
        )
        commands.append("exec \(shellQuote(shellPath)) -l")
        // Ghostty's macOS launcher prepends `exec -l` to a shell command.
        // Make the compound setup one executable command so `exec -l` does
        // not stop after the first shell builtin (`umask`).
        let script = commands.joined(separator: "; ")
        return "/bin/sh -c \(shellQuote(script))"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func validWorkingDirectory(_ requested: String?) -> String {
        var isDirectory: ObjCBool = false
        if let requested,
           FileManager.default.fileExists(atPath: requested, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return requested
        }
        return NSHomeDirectory()
    }

    private static func processWorkingDirectory(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
            return nil
        }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    private static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
}

// MARK: - libghostty surface callbacks

extension TerminalSession: TerminalSurfaceTitleDelegate {
    func terminalDidChangeTitle(_ title: String) {
        guard !title.isEmpty else { return }
        self.title = title
    }
}

extension TerminalSession: TerminalSurfaceGridResizeDelegate {
    func terminalDidResize(_ size: TerminalGridMetrics) {}
}

extension TerminalSession: TerminalSurfaceFocusDelegate {
    func terminalDidChangeFocus(_ focused: Bool) {}
}

extension TerminalSession: TerminalSurfaceBellDelegate {
    func terminalDidRingBell() {
        NSSound.beep()
        guard !terminalView.hasEffectiveTerminalFocus else { return }
        TerminalNotificationService.shared.post(message: "Terminal bell")
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }
}

extension TerminalSession: TerminalSurfaceCloseDelegate {
    func terminalDidClose(processAlive: Bool) {
        guard !isTerminating else { return }
        isTerminating = true
        beginTeardown(processAlive: processAlive, notifyExit: true)
    }
}

extension TerminalSession: TerminalSurfaceDesktopNotificationDelegate {
    func terminalDidRequestDesktopNotification(title: String, body: String) {
        let message = body.isEmpty ? title : body
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        TerminalNotificationService.shared.post(message: message)
    }
}

extension TerminalSession: TerminalSurfaceProgressReportDelegate {
    func terminalDidReportProgress(state: TerminalProgressState, percent: Int?) {
        terminalView.applyProgressReport(state: state, percent: percent)
    }
}

extension TerminalSession: TerminalSurfaceOpenURLDelegate {
    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        if terminalView.consumeHistoryExportURL(url, kind: kind) { return }
        guard let target = URL(string: url) else { return }
        NSWorkspace.shared.open(target)
    }
}

extension TerminalSession: TerminalSurfacePwdDelegate {
    func terminalDidChangeWorkingDirectory(_ path: String) {
        guard !path.isEmpty else { return }
        workingDirectory = path.hasPrefix("/")
            ? URL(fileURLWithPath: path).absoluteString : path
    }
}

extension TerminalSession: TerminalSurfaceSearchDelegate {
    func terminalDidStartSearch(needle: String) {
        find.started(needle: needle)
    }

    func terminalDidEndSearch() {
        find.ended()
    }

    func terminalDidUpdateSearchTotal(_ total: Int?) {
        find.update(total: total)
    }

    func terminalDidUpdateSearchSelected(_ selected: Int?) {
        find.update(selected: selected)
    }
}

extension TerminalSession: TerminalSurfaceClipboardConfirmationDelegate {
    func terminalDidRequestClipboardConfirmation(
        _ request: TerminalClipboardConfirmationRequest
    ) {
        guard let window = terminalView.window else {
            request.deny()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        switch request.kind {
        case .unsafePaste:
            alert.messageText = "Warning: Potentially Unsafe Paste"
            alert.informativeText =
                "Pasting this text to the terminal may be dangerous as it looks like some commands may be executed."
        case .osc52Read:
            alert.messageText = "Authorize Clipboard Access"
            alert.informativeText =
                "A program is attempting to read from the clipboard. The current clipboard contents are shown below."
        }
        alert.accessoryView = Self.clipboardPreview(request.contents)
        alert.addButton(withTitle: request.kind == .unsafePaste ? "Paste" : "Allow")
        let cancel = alert.addButton(
            withTitle: request.kind == .unsafePaste ? "Cancel" : "Deny"
        )
        cancel.keyEquivalent = "\u{1b}"

        Task { @MainActor in
            let response = await alert.beginSheetModal(for: window)
            if response == .alertFirstButtonReturn {
                request.approve()
            } else {
                request.deny()
            }
        }
    }

    /// Bounded, read-only preview of the text under decision, mirroring
    /// the preview area in Ghostty's own confirmation dialog.
    private static func clipboardPreview(_ contents: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        // A pathological clipboard can be arbitrarily large; the decision
        // only needs a glimpse.
        text.string = String(contents.prefix(4096))
        text.autoresizingMask = [.width]
        scroll.documentView = text
        return scroll
    }
}

extension TerminalSession: TerminalSurfaceScrollbarDelegate {
    func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) {
        lastScrollbar = scrollbar
        let active = scrollbar.total > scrollbar.len && scrollbar.len > 0
        let position: Double
        if active {
            position = Double(scrollbar.offset) / Double(scrollbar.total - scrollbar.len)
        } else {
            position = 1
        }
        let proportion = scrollbar.total > 0
            ? Double(scrollbar.len) / Double(scrollbar.total) : 1
        overlayScrollbar.update(
            position: position,
            proportion: proportion,
            active: active
        )
    }
}
