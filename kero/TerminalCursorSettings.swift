//
//  TerminalCursorSettings.swift
//  kero
//

import Foundation
import GhosttyTerminal

enum TerminalCursorShape: String, CaseIterable, Sendable {
    case block
    case bar
    case underline

    var title: String {
        switch self {
        case .block: String(localized: "Block")
        case .bar:
            String(
                localized: "Bar",
                comment: "Thin vertical terminal cursor shape."
            )
        case .underline: String(localized: "Underline")
        }
    }

    var ghosttyValue: TerminalCursorStyle {
        switch self {
        case .block: .block
        case .bar: .bar
        case .underline: .underline
        }
    }

    var alacrittyValue: UInt8 {
        switch self {
        case .block: 0
        case .underline: 1
        case .bar: 2
        }
    }
}
