import Foundation
import GhosttyTerminal

@resultBuilder
public enum ShellCommandBuilder {
    public static func buildBlock(_ components: [ShellCommand]...) -> [ShellCommand] {
        components.flatMap(\.self)
    }

    public static func buildExpression(_ expression: ShellCommand) -> [ShellCommand] {
        [expression]
    }

    public static func buildOptional(_ component: [ShellCommand]?) -> [ShellCommand] {
        component ?? []
    }

    public static func buildEither(first component: [ShellCommand]) -> [ShellCommand] {
        component
    }

    public static func buildEither(second component: [ShellCommand]) -> [ShellCommand] {
        component
    }

    public static func buildArray(_ components: [[ShellCommand]]) -> [ShellCommand] {
        components.flatMap(\.self)
    }
}

public struct ShellDefinition: Sendable {
    public let prompt: String
    public let welcomeMessage: String
    public let fallbackMessage: @Sendable (String) -> String
    let promptDisplayWidth: Int
    private let commands: [String: ShellCommand]
    private let commandOrder: [String]

    public init(
        prompt: String = "$ ",
        welcomeMessage: String? = nil,
        fallback: (@Sendable (String) -> String)? = nil,
        @ShellCommandBuilder _ build: () -> [ShellCommand]
    ) {
        self.prompt = prompt
        self.welcomeMessage = welcomeMessage ?? Self.defaultWelcomeMessage
        fallbackMessage = fallback ?? { cmd in "\(cmd): command not found" }
        promptDisplayWidth = prompt.terminalDisplayWidth

        let userCommands = build()
        var ordered: [String] = []
        var map: [String: ShellCommand] = [:]
        for cmd in userCommands {
            let key = cmd.name.lowercased()
            if map[key] == nil {
                ordered.append(key)
            }
            map[key] = cmd
        }
        commandOrder = ordered
        commands = map
    }

    func processCommand(
        _ input: String,
        username: String,
        terminalSize: InMemoryTerminalViewport
    ) -> CommandResult {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .output("")
        }

        let parts = trimmed.split(separator: " ", maxSplits: 1)
        let cmd = String(parts[0]).lowercased()
        let args = parts.count > 1 ? String(parts[1]) : ""

        if cmd == "help" {
            return .output(generateHelp())
        }

        let context = CommandContext(
            command: cmd,
            arguments: args,
            username: username,
            terminalSize: terminalSize
        )

        guard let command = commands[cmd] else {
            return .output(fallbackMessage(trimmed) + "\r\n")
        }

        return command.execute(context)
    }

    private func generateHelp() -> String {
        var lines = ["Available commands:\r"]

        let maxNameLen = max(
            commandOrder.map(\.count).max() ?? 0,
            4 // "help"
        )

        lines.append("  \("help".padding(toLength: maxNameLen + 2, withPad: " ", startingAt: 0))- Show this help message\r")

        for name in commandOrder {
            guard let cmd = commands[name] else { continue }
            let summary = cmd.summary.isEmpty ? cmd.name : cmd.summary
            lines.append("  \(name.padding(toLength: maxNameLen + 2, withPad: " ", startingAt: 0))- \(summary)\r")
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static let defaultWelcomeMessage = """
    \r\n  ShellCraftKit Sandbox Demo\r
    \r\n  This terminal runs inside App Sandbox.\r
      No subprocesses are spawned.\r
      Type 'help' for available commands.\r\n\r\n
    """
}

extension String {
    var terminalDisplayWidth: Int {
        var width = 0
        var scalars = unicodeScalars.makeIterator()

        while let scalar = scalars.next() {
            guard scalar == "\u{1B}" else {
                width += scalar.terminalCellWidth
                continue
            }

            guard let next = scalars.next() else {
                break
            }

            guard next == "[" else {
                continue
            }

            while let parameter = scalars.next() {
                if (0x40 ... 0x7E).contains(parameter.value) {
                    break
                }
            }
        }

        return width
    }
}

private extension UnicodeScalar {
    var terminalCellWidth: Int {
        // Terminal width needs a tailored policy instead of raw wcwidth():
        // - UAX #11 says East_Asian_Width is useful, but "not intended for use by
        //   modern terminal emulators without appropriate tailoring on a
        //   case-by-case basis", and ambiguous characters should default to narrow
        //   when context is unknown.
        // - EastAsianWidth.txt provides the normative W/F defaults and wide
        //   defaults for the ideographic planes we mirror below.
        // - POSIX / Apple wcwidth() is locale-dependent, which made test and
        //   runtime behavior diverge in this project.
        //
        // References:
        // https://www.unicode.org/reports/tr11/
        // https://www.unicode.org/Public/UCD/latest/ucd/EastAsianWidth.txt
        // https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/wcwidth.3.html
        if properties.generalCategory == .control ||
            properties.generalCategory == .format ||
            properties.generalCategory == .nonspacingMark ||
            properties.generalCategory == .enclosingMark
        {
            return 0
        }

        switch value {
        case 0x1100 ... 0x115F,
             0x231A ... 0x231B,
             0x2329 ... 0x232A,
             0x23E9 ... 0x23EC,
             0x23F0,
             0x23F3,
             0x25FD ... 0x25FE,
             0x2614 ... 0x2615,
             0x2648 ... 0x2653,
             0x267F,
             0x2693,
             0x26A1,
             0x26AA ... 0x26AB,
             0x26BD ... 0x26BE,
             0x26C4 ... 0x26C5,
             0x26CE,
             0x26D4,
             0x26EA,
             0x26F2 ... 0x26F3,
             0x26F5,
             0x26FA,
             0x26FD,
             0x2705,
             0x270A ... 0x270B,
             0x2728,
             0x274C,
             0x274E,
             0x2753 ... 0x2755,
             0x2757,
             0x2795 ... 0x2797,
             0x27B0,
             0x27BF,
             0x2B1B ... 0x2B1C,
             0x2B50,
             0x2B55,
             0x2E80 ... 0x2FFB,
             0x3000 ... 0x303E,
             0x3041 ... 0x33FF,
             0x3400 ... 0x4DBF,
             0x4E00 ... 0xA4C6,
             0xA960 ... 0xA97C,
             0xAC00 ... 0xD7A3,
             0xF900 ... 0xFAFF,
             0xFE10 ... 0xFE19,
             0xFE30 ... 0xFE6B,
             0xFF01 ... 0xFF60,
             0xFFE0 ... 0xFFE6,
             0x1F300 ... 0x1F64F,
             0x1F900 ... 0x1F9FF,
             0x20000 ... 0x2FFFD,
             0x30000 ... 0x3FFFD:
            return 2

        default:
            return 1
        }
    }
}
