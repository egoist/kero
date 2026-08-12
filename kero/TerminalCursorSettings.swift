//
//  TerminalCursorSettings.swift
//  kero
//

import Foundation
import GhosttyTerminal

enum TerminalCursorShape: String, CaseIterable, Identifiable, Sendable {
    case block
    case bar
    case underline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .block: String(localized: "Block")
        case .bar: String(localized: "Bar")
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
