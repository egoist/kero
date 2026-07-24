import Foundation
import GhosttyTerminal

final class SessionBridge: @unchecked Sendable {
    nonisolated(unsafe) var session: InMemoryTerminalSession?
}
