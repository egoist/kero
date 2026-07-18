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

    override init() {
        shellPath = Self.loginShell()
        title = (shellPath as NSString).lastPathComponent
        terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()

        terminalView.processDelegate = self
        applyTheme()
        start()
    }

    /// Applies the light/dark terminal theme; called again whenever the
    /// system appearance changes, since SwiftTerm needs concrete colors.
    func applyTheme() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let theme = Theme.terminal(dark: isDark)
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
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
        terminalView.startProcess(
            executable: shellPath,
            args: [],
            environment: env,
            execName: execName,
            currentDirectory: NSHomeDirectory()
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
