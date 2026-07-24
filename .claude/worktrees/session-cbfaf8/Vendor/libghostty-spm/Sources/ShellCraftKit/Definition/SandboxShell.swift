import Foundation
import GhosttyTerminal

public let defaultSandboxShell = ShellDefinition(
    prompt: SandboxShellStyle.prompt,
    welcomeMessage: SandboxShellStyle.welcomeMessage,
    fallback: { command in
        "\(SandboxShellStyle.error)\(command)\(SandboxShellStyle.reset): command not found"
    }
) {
    ShellCommand("echo", summary: "Echo text back") { context in
        .output(context.arguments + "\r\n")
    }
    ShellCommand("date", summary: "Show current date/time") { _ in
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM dd HH:mm:ss zzz yyyy"
        return .output(formatter.string(from: Date()) + "\r\n")
    }
    ShellCommand("uname", summary: "Show system information") { _ in
        .output("Darwin ghostty-sandbox host-managed\r\n")
    }
    ShellCommand("whoami", summary: "Show current user") { context in
        .output(context.username + "\r\n")
    }
    ShellCommand("env", summary: "Show environment variables") { context in
        .output("""
        TERM=xterm-ghostty\r
        SHELL=/bin/zsh\r
        USER=\(context.username)\r
        HOME=/Users/\(context.username)\r
        LANG=en_US.UTF-8\r
        TERM_PROGRAM=GhosttyKit\r\n
        """)
    }
    ShellCommand("size", summary: "Show terminal size") { context in
        let size = context.terminalSize
        return .output(
            "columns: \(size.columns), rows: \(size.rows), " +
                "pixels: \(size.widthPixels)x\(size.heightPixels)\r\n"
        )
    }
    ShellCommand("clear", summary: "Clear the screen") { _ in
        .clear
    }
    ShellCommand("exit", summary: "Exit the terminal") { _ in
        .exit
    }
    ShellCommand("logout", summary: "Exit the terminal") { _ in
        .exit
    }
}

public let sandboxShell = defaultSandboxShell

private enum SandboxShellStyle {
    static let reset = "\u{1B}[0m"
    static let accent = "\u{1B}[38;5;110m"
    static let highlight = "\u{1B}[38;5;221m"
    static let error = "\u{1B}[38;5;203m"
    static let emphasis = "\u{1B}[1m"

    static let prompt = "\(accent)sandbox\(reset)@\(highlight)ghostty\(reset) % "

    static let welcomeMessage = """
    \r\n  \(emphasis)\(accent)GhosttyKit Sandbox Demo\(reset)\r
    \r\n  This terminal runs inside App Sandbox.\r
      \(accent)No subprocesses are spawned.\(reset)\r
      Type '\(highlight)help\(reset)' for available commands.\r\n\r\n
    """
}
