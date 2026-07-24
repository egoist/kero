//
//  TerminalSurfaceContext.swift
//  libghostty-spm
//

import GhosttyKit

public enum TerminalSurfaceContext: Sendable, Equatable {
    case window
    case split

    var ghosttyValue: ghostty_surface_context_e {
        switch self {
        case .window: GHOSTTY_SURFACE_CONTEXT_WINDOW
        case .split: GHOSTTY_SURFACE_CONTEXT_SPLIT
        }
    }
}
