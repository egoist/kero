//
//  TerminalSession.swift
//  mitty
//

import AppKit
import Combine
import Darwin
import Foundation
import SwiftTerm

/// One shell running in one terminal view. The session owns its
/// `LocalProcessTerminalView` so scrollback and process state survive
/// tab switches — SwiftUI only ever re-parents the same NSView.
@MainActor
final class TerminalSession: NSObject, nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id = UUID()

    @Published var title: String
    @Published var workingDirectory: String?
    @Published var hasExited = false

    let terminalView: LocalProcessTerminalView
    var onExited: ((TerminalSession) -> Void)?

    private let shellPath: String
    private let initialDirectory: String?
    let overlayScrollbar = OverlayScrollbarView()
    private var scrollerObservations: [NSKeyValueObservation] = []

    init(initialDirectory: String? = nil) {
        self.initialDirectory = initialDirectory
        shellPath = Self.loginShell()
        title = (shellPath as NSString).lastPathComponent
        terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()

        terminalView.processDelegate = self
        applyTheme()
        installOverlayScrollbar()
        start()
    }

    /// SwiftTerm's built-in scroller is a bare NSScroller that can't render
    /// like a native overlay scrollbar (its .overlay style never draws a
    /// knob outside an NSScrollView). Keep it permanently hidden — SwiftTerm
    /// still pushes scroll state into it, and hiding it also frees its
    /// reserved width — and mirror its values into our own overlay thumb.
    /// `TerminalHostView` places the thumb; this only wires up the sync.
    private func installOverlayScrollbar() {
        guard let scroller = terminalView.subviews.compactMap({ $0 as? NSScroller }).first else {
            return
        }
        scroller.isHidden = true

        overlayScrollbar.alphaValue = 0
        overlayScrollbar.onScroll = { [weak self] position in
            self?.terminalView.scroll(toPosition: position)
        }

        let sync = { [weak self, weak scroller] in
            guard let self, let scroller else { return }
            self.overlayScrollbar.update(
                position: scroller.doubleValue,
                proportion: scroller.knobProportion,
                active: scroller.isEnabled
            )
        }
        // SwiftTerm updates the scroller from the main thread, so deliver
        // synchronously when possible — the thumb then moves in the same
        // frame as the content.
        let deliver = {
            if Thread.isMainThread {
                sync()
            } else {
                DispatchQueue.main.async(execute: sync)
            }
        }
        sync()
        scrollerObservations = [
            scroller.observe(\.doubleValue) { _, _ in deliver() },
            scroller.observe(\.knobProportion) { _, _ in deliver() },
            scroller.observe(\.isEnabled) { _, _ in deliver() },
        ]
    }

    /// Applies the light/dark terminal theme; called again whenever the
    /// system appearance changes, since SwiftTerm needs concrete colors.
    func applyTheme() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let theme = Theme.terminal(dark: isDark)
        terminalView.font = TerminalFont.current()
        terminalView.nativeBackgroundColor = theme.background
        terminalView.nativeForegroundColor = theme.foreground
        terminalView.caretColor = theme.cursor
        terminalView.installColors(theme.ansi)
        terminalView.optionAsMetaKey = true

        // Also push fg/bg into the terminal engine: OSC 10/11 queries are
        // answered from there, and shells (fish 4+) use them to pick
        // light-vs-dark syntax colors. The view's native colors alone
        // would leave queries reporting the default dark palette.
        let engine = terminalView.getTerminal()
        engine.foregroundColor = Self.engineColor(theme.foreground)
        engine.backgroundColor = Self.engineColor(theme.background)
    }

    private static func engineColor(_ color: NSColor) -> SwiftTerm.Color {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        return SwiftTerm.Color(
            red: UInt16(srgb.redComponent * 65535),
            green: UInt16(srgb.greenComponent * 65535),
            blue: UInt16(srgb.blueComponent * 65535)
        )
    }

    private func start() {
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        if !env.contains(where: { $0.hasPrefix("LANG=") }) {
            env.append("LANG=en_US.UTF-8")
        }
        let execName = "-" + (shellPath as NSString).lastPathComponent
        var directory = NSHomeDirectory()
        // A restored directory may have been deleted since the last run.
        var isDir: ObjCBool = false
        if let initialDirectory,
           FileManager.default.fileExists(atPath: initialDirectory, isDirectory: &isDir),
           isDir.boolValue {
            directory = initialDirectory
        }
        terminalView.startProcess(
            executable: shellPath,
            args: [],
            environment: env,
            execName: execName,
            currentDirectory: directory
        )
    }

    func terminate() {
        guard !hasExited else { return }
        terminalView.terminate()
    }

    /// Short label for the sidebar: the tail of the current directory, if known.
    var directoryLabel: String? {
        guard let dir = workingDirectory else { return nil }
        let path = URL(string: dir)?.path ?? dir
        let tail = (path as NSString).lastPathComponent
        return tail.isEmpty ? nil : tail
    }

    /// Best-effort live working directory of the shell: prefers the
    /// OSC 7 report, falls back to asking the kernel about the shell PID
    /// (fish/zsh only emit OSC 7 for terminals they recognize).
    var currentDirectoryPath: String {
        if let dir = workingDirectory, let url = URL(string: dir), url.isFileURL {
            return url.path
        }
        if let process = terminalView.process, process.shellPid > 0,
           let path = Self.processWorkingDirectory(pid: process.shellPid) {
            return path
        }
        return NSHomeDirectory()
    }

    /// Types text into the shell as if the user had entered it.
    func sendCommand(_ text: String) {
        terminalView.send(txt: text)
    }

    /// Executable name of the shell, e.g. "fish".
    var shellName: String {
        (shellPath as NSString).lastPathComponent
    }

    /// PID of the running shell, or nil before launch / after exit.
    var shellPid: pid_t? {
        guard !hasExited, let process = terminalView.process, process.shellPid > 0 else {
            return nil
        }
        return process.shellPid
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

extension TerminalSession: nonisolated LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !title.isEmpty else { return }
            self.title = title
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.workingDirectory = directory
        }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasExited = true
            self.onExited?(self)
        }
    }
}
