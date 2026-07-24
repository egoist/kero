import Foundation
import GhosttyTerminal

public enum CommandResult: Sendable {
    case output(String)
    case clear
    case exit
}

public struct CommandContext: Sendable {
    public let command: String
    public let arguments: String
    public let username: String
    public let terminalSize: InMemoryTerminalViewport
}

public struct ShellCommand: Sendable {
    public let name: String
    public let summary: String
    let handler: @Sendable (CommandContext) -> CommandResult

    public init(
        _ name: String,
        summary: String = "",
        handler: @escaping @Sendable (CommandContext) -> CommandResult
    ) {
        self.name = name
        self.summary = summary
        self.handler = handler
    }

    func execute(_ context: CommandContext) -> CommandResult {
        handler(context)
    }
}
