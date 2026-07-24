//
//  TerminalSessionBackend.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

public enum TerminalSessionBackend: Sendable {
    case exec
    case inMemory(InMemoryTerminalSession)

    func isEquivalent(to other: TerminalSessionBackend) -> Bool {
        switch (self, other) {
        case (.exec, .exec):
            true
        case let (.inMemory(lhs), .inMemory(rhs)):
            lhs === rhs
        default:
            false
        }
    }
}
