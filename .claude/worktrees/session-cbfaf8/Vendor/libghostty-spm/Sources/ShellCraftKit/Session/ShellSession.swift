import Foundation
import GhosttyTerminal

public final class ShellSession {
    public let terminalSession: InMemoryTerminalSession
    private let engine: Engine

    public init(shell: ShellDefinition) {
        let sessionBridge = SessionBridge()
        let engine = Engine(shell: shell, sessionBridge: sessionBridge)
        let terminalSession = InMemoryTerminalSession(
            write: { data in
                Task {
                    await engine.handleOutbound(data)
                }
            },
            resize: { size in
                Task {
                    await engine.updateSize(size)
                }
            }
        )
        sessionBridge.session = terminalSession

        self.terminalSession = terminalSession
        self.engine = engine
    }

    public func start() {
        let engine = engine
        Task {
            await engine.start()
        }
    }
}
