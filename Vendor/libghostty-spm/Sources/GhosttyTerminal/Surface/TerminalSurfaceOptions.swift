//
//  TerminalSurfaceOptions.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import GhosttyKit

public struct TerminalSurfaceOptions: Sendable {
    public var backend: TerminalSessionBackend
    public var fontSize: Float?
    public var workingDirectory: String?
    /// Extra environment variables set in the child process spawned for this
    /// surface (exec backend). Passed through `ghostty_surface_config_s.env_vars`;
    /// every process launched from the surface's shell inherits them, which lets
    /// embedding hosts tag a surface (e.g. `MYAPP_PANE=<uuid>`) and correlate
    /// externally observed processes back to it.
    public var envVars: [String: String]
    public var context: TerminalSurfaceContext

    public init(
        backend: TerminalSessionBackend = .exec,
        fontSize: Float? = nil,
        workingDirectory: String? = nil,
        envVars: [String: String] = [:],
        context: TerminalSurfaceContext = .window
    ) {
        self.backend = backend
        self.fontSize = fontSize
        self.workingDirectory = workingDirectory
        self.envVars = envVars
        self.context = context
    }

    func isEquivalent(to other: TerminalSurfaceOptions) -> Bool {
        fontSize == other.fontSize
            && workingDirectory == other.workingDirectory
            && envVars == other.envVars
            && context == other.context
            && backend.isEquivalent(to: other.backend)
    }

    var inMemorySession: InMemoryTerminalSession? {
        guard case let .inMemory(session) = backend else { return nil }
        return session
    }
}
