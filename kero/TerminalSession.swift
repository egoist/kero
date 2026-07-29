//
//  TerminalSession.swift
//  kero
//

import AppKit
import Combine
import Darwin
import Foundation

/// One long-lived terminal process rendered by one terminal surface. Normally
/// that process is the user's login shell; a CLI-created project can instead
/// exec an explicit argv directly. SwiftUI only reparents the same surface, so
/// PTY state, selection, and scrollback survive tab and split-layout changes.
///
/// Which emulator draws that surface is `TerminalBackend`'s business: this
/// type talks to ``TerminalBackendSurface`` and hears back through
/// ``TerminalBackendEvents``, and names no emulator's types itself.
@MainActor
final class TerminalSession: NSObject, nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id = UUID()

    @Published var title: String
    @Published var workingDirectory: String?
    @Published var hasExited = false
    @Published private(set) var commandLifecycle = TerminalCommandLifecycle()

    /// The emulator driving this session. Fixed for the session's lifetime —
    /// changing the setting only affects terminals opened afterwards.
    let backend: TerminalBackend
    /// Daemon-owned PTY this pane attaches to. Nil for the traditional
    /// renderer-owned process lifecycle.
    let muxSessionID: UUID?
    let surface: any TerminalBackendSurface
    let overlayScrollbar = OverlayScrollbarView()
    /// Find-in-terminal state for this session's pane (⌘F).
    let find: TerminalFind
    var onExited: ((TerminalSession) -> Void)?

    private static let persistedHistoryLineLimit = 500

    private let shellPath: String
    private let launchWorkingDirectory: String
    private let launchDirectoryURL: URL?
    private let shellPidFileURL: URL?
    private var cachedShellPid: pid_t?
    private var lastHistorySnapshot: String?
    private var isTerminating = false
    private var commandExecutionStartedAtNanos: UInt64?

    init(
        initialDirectory: String? = nil,
        restoredHistory: String? = nil,
        commandArguments: [String]? = nil,
        environmentPath: String? = nil,
        restoredMuxSessionID: UUID? = nil,
        restoredBackend: TerminalBackend? = nil
    ) {
        let directCommand = commandArguments.flatMap { $0.isEmpty ? nil : $0 }
        let shellPath = directCommand?.first ?? Self.loginShell()
        let directory = Self.validWorkingDirectory(initialDirectory)
        let artifacts = Self.makeLaunchArtifacts(restoredHistory: restoredHistory)
        let restoredMuxInfo = restoredMuxSessionID.flatMap {
            KeroMuxControl.info($0)
        }
        // The daemon's renderer is authoritative for a live session. The
        // snapshot copy remains useful if the daemon disappeared and this pane
        // falls back to starting a replacement terminal.
        let backend = restoredMuxInfo.map {
            TerminalBackend(persisted: $0.backend)
        } ?? restoredBackend ?? AppSettings.shared.terminalBackend
        let script = Self.makeLaunchScript(
            backend: backend,
            shellPath: shellPath,
            commandArguments: directCommand,
            pidFileURL: artifacts.pidFileURL,
            replayFileURL: artifacts.replayFileURL
        )
        let launch = TerminalLaunch(
            program: "/bin/sh",
            arguments: ["-c", script],
            commandLine: "/bin/sh -c \(Self.shellQuote(script))",
            workingDirectory: directory,
            environment: Self.surfaceEnvironment(pathOverride: environmentPath)
        )

        var muxInfo = restoredMuxInfo
        if muxInfo == nil, AppSettings.shared.durableTerminalSessions {
            do {
                muxInfo = try KeroMuxControl.create(
                    launch: launch,
                    backend: backend,
                    shellName: (shellPath as NSString).lastPathComponent
                )
            } catch {
                NSLog("kero: durable session unavailable, using a local PTY: \(error)")
            }
        }
        let muxSessionID = muxInfo?.id
        let surfaceLaunch: TerminalLaunch
        if let muxSessionID {
            surfaceLaunch = KeroMuxControl.attachmentLaunch(
                sessionID: muxSessionID,
                workingDirectory: directory,
                environment: launch.environment
            )
        } else {
            surfaceLaunch = launch
        }

        self.shellPath = shellPath
        self.backend = backend
        self.muxSessionID = muxSessionID
        launchWorkingDirectory = directory
        launchDirectoryURL = artifacts.directoryURL
        shellPidFileURL = artifacts.pidFileURL
        title = muxInfo?.title ?? (shellPath as NSString).lastPathComponent
        workingDirectory = muxInfo?.workingDirectory

        let surface = Self.makeSurface(backend: backend, launch: surfaceLaunch)
        self.surface = surface
        find = TerminalFind(surface: surface)
        lastHistorySnapshot = restoredHistory
        super.init()

        surface.events = self
        installOverlayScrollbar()
        applyTheme()
    }

    deinit {
        if let launchDirectoryURL {
            try? FileManager.default.removeItem(at: launchDirectoryURL)
        }
    }

    /// `makeSurface` returns nil only for a backend this build has no surface
    /// for, and `AppSettings` refuses to store one — so this is belt and
    /// braces, preferring a working terminal over an empty pane.
    private static func makeSurface(
        backend: TerminalBackend, launch: TerminalLaunch
    ) -> any TerminalBackendSurface {
        if let surface = backend.makeSurface(launch: launch) { return surface }
        NSLog("kero: no surface for terminal backend \(backend.rawValue)")
        return KeroTerminalView(launch: launch)
    }

    private func installOverlayScrollbar() {
        overlayScrollbar.alphaValue = 0
        overlayScrollbar.onScroll = { [weak self] position in
            self?.surface.scroll(toFraction: position)
        }
    }

    /// Reconfigures the surface in place when either appearance or terminal
    /// font settings change.
    func applyTheme() {
        surface.applyAppearance()
    }

    /// Stops the whole PTY job before releasing the surface. The backend's
    /// teardown owns the final reap; sending HUP first gives shells the same
    /// close signal they received before the backend migration.
    func terminate() {
        guard !hasExited, !isTerminating else { return }
        isTerminating = true
        if let muxSessionID {
            KeroMuxControl.terminate(muxSessionID)
            beginTeardown(processAlive: false, notifyExit: false)
            return
        }
        beginTeardown(processAlive: true, notifyExit: false)
    }

    /// A window close or app quit is a detach for daemon-owned terminals and
    /// the traditional close for renderer-owned terminals. Capturing before
    /// releasing the renderer gives reconnect a compact, exact VT baseline.
    func closeForAppLifecycle() {
        guard !hasExited, !isTerminating else { return }
        guard let muxSessionID else {
            terminate()
            return
        }
        isTerminating = true
        if let checkpoint = TerminalHistorySerializer.captureRaw(from: surface) {
            KeroMuxControl.checkpoint(checkpoint, sessionID: muxSessionID)
        }
        surface.setSurfaceVisible(false)
        surface.onBecomeFirstResponder = nil
        surface.splitTarget.onSplit = nil
        surface.splitTarget.onNewBrowserTab = nil
        surface.splitTarget.onNewBrowserPane = nil
        surface.detach()
        hasExited = true
        removeLaunchArtifacts()
    }

    /// Keeps the session and surface alive until the child has either exited
    /// or been force-stopped. Detaching first can make a backend wait
    /// synchronously for a process that ignored SIGHUP.
    private func beginTeardown(processAlive: Bool, notifyExit: Bool) {
        // TerminalHostView normally clears these while dismantling, but close
        // teardown must not depend on a later SwiftUI reconciliation pass.
        // Both callbacks originate on PaneView and capture this session.
        surface.setSurfaceVisible(false)
        surface.onBecomeFirstResponder = nil
        surface.splitTarget.onSplit = nil
        surface.splitTarget.onNewBrowserTab = nil
        surface.splitTarget.onNewBrowserPane = nil

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
                // Avoid freeing the surface reentrantly from the backend's
                // process-close callback.
                await Task.yield()
            }
            surface.detach()
            hasExited = true
            removeLaunchArtifacts()
            if notifyExit { onExited?(self) }
        }
    }

    private func signalTerminalJob(_ signal: Int32) {
        var pids = Set<pid_t>()
        if let shellPid { pids.insert(shellPid) }
        if let foreground = surface.foregroundPid, foreground > 0 {
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
        if let shellPid, let path = processWorkingDirectory(pid: shellPid) {
            return path
        }
        return launchWorkingDirectory
    }

    /// Working directory of the terminal's foreground job, when that job is
    /// something other than the shell itself. Coding agents change their own
    /// process directory when they move to another checkout — Claude Code's
    /// worktree switch is a `chdir` inside the running `claude` process — and
    /// the shell never moves, so no OSC 7 arrives and `currentDirectoryPath`
    /// keeps describing the old tree. This is deliberately a separate fact:
    /// `currentDirectoryPath` must stay true to the shell.
    var foregroundDirectoryPath: String? {
        let foreground = muxSessionID.flatMap { KeroMuxControl.info($0)?.foregroundPID }
            ?? surface.foregroundPid
        guard let foreground, foreground > 0,
              foreground != shellPid
        else { return nil }
        return processWorkingDirectory(pid: foreground)
    }

    func sendCommand(_ text: String) {
        surface.sendText(text)
    }

    /// Clears the emulator's visible screen and scrollback, then asks the
    /// foreground shell to repaint its prompt at the top.
    func clear() {
        surface.clearScreen()
    }

    /// Styled VT snapshot used by the existing sidecar history store. A
    /// scrollback/PID heuristic keeps a full-screen alternate buffer from
    /// replacing the last saved shell scrollback in normal shell/TUI use.
    func serializedHistory(captureLive: Bool) -> String? {
        guard AppSettings.shared.restoreTerminalHistory else { return nil }
        guard captureLive else { return lastHistorySnapshot }

        let foregroundPID = muxSessionID.flatMap {
            KeroMuxControl.info($0)?.foregroundPID
        } ?? surface.foregroundPid
        let rootShellIsForeground = shellPid != nil
            && foregroundPID == shellPid
        if !rootShellIsForeground,
           !TerminalHistorySerializer.hasPrimaryScrollback(surface) {
            // A primary screen with no rows above the viewport and an
            // alternate screen both have no scrollback export. The root shell
            // is foreground only in the former case; a TUI owns its own
            // foreground process group in the latter.
            return lastHistorySnapshot
        }
        switch TerminalHistorySerializer.capture(
            from: surface, maxLines: Self.persistedHistoryLineLimit
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

    /// PID of the root terminal process. The launch shim records its own PID
    /// before `exec`, so this remains stable while a shell's foreground PID
    /// moves to child jobs and back.
    var shellPid: pid_t? {
        if let muxSessionID {
            return KeroMuxControl.info(muxSessionID)?.shellPID
        }
        if let cachedShellPid, cachedShellPid > 0 { return cachedShellPid }
        guard !hasExited, let shellPidFileURL,
              let text = try? String(contentsOf: shellPidFileURL, encoding: .utf8),
              let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0
        else { return nil }
        cachedShellPid = value
        return value
    }

    // MARK: - Launch

    private static func surfaceEnvironment(pathOverride: String?) -> [String: String] {
        var environment = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
        ]
        environment.merge(
            KeroCLIService.shared.terminalEnvironment,
            uniquingKeysWith: { _, cliValue in cliValue }
        )
        if let pathOverride, !pathOverride.isEmpty {
            environment["PATH"] = pathOverride
        }
        // Locale belongs to the user's shell environment. Kero's app language
        // must never synthesize or override LANG/LC_* for terminal processes.
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

    /// The `sh` script every pane starts with: record the process PID, replay
    /// any restored scrollback, advertise the emulator, then become either the
    /// requested argv or the user's login shell.
    private static func makeLaunchScript(
        backend: TerminalBackend,
        shellPath: String,
        commandArguments: [String]?,
        pidFileURL: URL?,
        replayFileURL: URL?
    ) -> String {
        var commands: [String] = []
        if let pidFileURL {
            // The PID file is the only thing this script creates, so the
            // tightened mask stays inside a subshell: `umask` outlives the
            // `exec` below, and a terminal that leaves the user's shell at 077
            // silently makes every file they create private. `$$` keeps
            // expanding to this shell's PID inside the subshell — the same PID
            // `exec` hands to the shell itself.
            commands.append(
                "(umask 077; printf '%s\\n' \"$$\" > \(shellQuote(pidFileURL.path)))"
            )
        }
        if let replayFileURL {
            let path = shellQuote(replayFileURL.path)
            commands.append("if [ -r \(path) ]; then /bin/cat \(path); /bin/rm -f \(path); fi")
        }
        // Many terminal tools use TERM_PROGRAM as a capability hint. Each
        // backend advertises a compatible identity so tools select protocols
        // that Kero can actually render.
        let termProgram = backend.termProgram
        commands.append("export TERM_PROGRAM=\(shellQuote(termProgram.name))")
        if !termProgram.version.isEmpty {
            commands.append(
                "export TERM_PROGRAM_VERSION=\(shellQuote(termProgram.version))"
            )
        } else {
            commands.append("unset TERM_PROGRAM_VERSION")
        }
        if let commandArguments {
            let argv = commandArguments.map(shellQuote).joined(separator: " ")
            // `env` resolves argv[0] against the caller's PATH. Every argument
            // is quoted independently, so no command text is reparsed or
            // expanded by the launch shim.
            commands.append("exec /usr/bin/env -- \(argv)")
        } else {
            commands.append("exec \(shellQuote(shellPath)) -l")
        }
        // Ghostty's macOS launcher prepends `exec -l` to a shell command.
        // Keeping the setup as one compound command means `exec -l` does not
        // stop after the first shell builtin.
        return commands.joined(separator: "; ")
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

    private static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
}

// MARK: - Terminal surface callbacks

extension TerminalSession: TerminalBackendEvents {
    func terminalDidChangeTitle(_ title: String) {
        guard !title.isEmpty else { return }
        self.title = title
        if let muxSessionID {
            KeroMuxControl.updateMetadata(sessionID: muxSessionID, title: title)
        }
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        guard !path.isEmpty else { return }
        workingDirectory = path.hasPrefix("/")
            ? URL(fileURLWithPath: path).absoluteString : path
        if let muxSessionID {
            KeroMuxControl.updateMetadata(
                sessionID: muxSessionID,
                workingDirectory: path
            )
        }
    }

    func terminalDidRingBell() {
        NSSound.beep()
        guard !surface.hasEffectiveTerminalFocus else { return }
        TerminalNotificationService.shared.post(message: String(localized: "Terminal bell"))
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    func terminalDidReportShellIntegration(_ event: TerminalShellIntegrationEvent) {
        var lifecycle = commandLifecycle
        switch event {
        case .promptStart:
            lifecycle.phase = .prompt
        case .commandStart:
            lifecycle.phase = .input
        case .commandExecuting:
            lifecycle.phase = .executing
            commandExecutionStartedAtNanos = DispatchTime.now().uptimeNanoseconds
        case let .commandFinished(exitCode, reportedDuration):
            let measuredDuration = commandExecutionStartedAtNanos.flatMap { started in
                let now = DispatchTime.now().uptimeNanoseconds
                return now >= started ? now - started : nil
            }
            lifecycle.phase = .idle
            lifecycle.lastExitCode = exitCode
            lifecycle.lastDurationNanos = reportedDuration ?? measuredDuration
            lifecycle.completionSequence &+= 1
            commandExecutionStartedAtNanos = nil
        }
        commandLifecycle = lifecycle
    }

    func terminalDidClose(processAlive: Bool) {
        guard !isTerminating else { return }
        isTerminating = true
        beginTeardown(processAlive: processAlive, notifyExit: true)
    }

    func terminalDidRequestDesktopNotification(title: String, body: String) {
        let message = body.isEmpty ? title : body
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        TerminalNotificationService.shared.post(message: message)
    }

    func terminalDidRequestOpenURL(_ url: String) {
        guard let target = URL(string: url) else { return }
        NSWorkspace.shared.open(target)
    }

    func terminalDidScroll(_ position: TerminalScrollPosition) {
        overlayScrollbar.update(
            position: position.position,
            proportion: position.proportion,
            active: position.isScrollable
        )
    }

    func terminalDidBeginFind(needle: String) {
        find.started(needle: needle)
    }

    func terminalDidEndFind() {
        find.ended()
    }

    func terminalDidUpdateFindTotal(_ total: Int?) {
        find.update(total: total)
    }

    func terminalDidUpdateFindSelected(_ selected: Int?) {
        find.update(selected: selected)
    }

    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardRequest) {
        guard let window = surface.window else {
            request.deny()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        switch request.kind {
        case .unsafePaste:
            alert.messageText = String(localized: "Warning: Potentially Unsafe Paste")
            alert.informativeText =
                String(localized: "Pasting this text to the terminal may be dangerous because it looks like one or more commands may execute.")
        case .programRead:
            alert.messageText = String(localized: "Authorize Clipboard Access")
            alert.informativeText =
                String(localized: "A program is attempting to read from the clipboard. The current clipboard contents are shown below.")
        }
        alert.accessoryView = Self.clipboardPreview(request.contents)
        alert.addButton(withTitle: request.kind == .unsafePaste
            ? String(localized: "Paste")
            : String(localized: "Allow"))
        let cancel = alert.addButton(
            withTitle: request.kind == .unsafePaste
                ? String(localized: "Cancel")
                : String(localized: "Deny")
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
