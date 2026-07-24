//
//  TerminalMouseShape.swift
//  libghostty-spm
//

import GhosttyKit

/// Pointer shape ghostty wants over the surface, mirroring
/// `ghostty_action_mouse_shape_e`. The terminal grid is `.text`; hovered
/// links, mouse-reporting programs, and OSC 22 requests ask for the rest.
public enum TerminalMouseShape: Sendable {
    case `default`
    case contextMenu
    case help
    case pointer
    case progress
    case wait
    case cell
    case crosshair
    case text
    case verticalText
    case alias
    case copy
    case move
    case noDrop
    case notAllowed
    case grab
    case grabbing
    case allScroll
    case colResize
    case rowResize
    case nResize
    case eResize
    case sResize
    case wResize
    case neResize
    case nwResize
    case seResize
    case swResize
    case ewResize
    case nsResize
    case neswResize
    case nwseResize
    case zoomIn
    case zoomOut

    init(_ raw: ghostty_action_mouse_shape_e) {
        switch raw {
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: self = .contextMenu
        case GHOSTTY_MOUSE_SHAPE_HELP: self = .help
        case GHOSTTY_MOUSE_SHAPE_POINTER: self = .pointer
        case GHOSTTY_MOUSE_SHAPE_PROGRESS: self = .progress
        case GHOSTTY_MOUSE_SHAPE_WAIT: self = .wait
        case GHOSTTY_MOUSE_SHAPE_CELL: self = .cell
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: self = .crosshair
        case GHOSTTY_MOUSE_SHAPE_TEXT: self = .text
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: self = .verticalText
        case GHOSTTY_MOUSE_SHAPE_ALIAS: self = .alias
        case GHOSTTY_MOUSE_SHAPE_COPY: self = .copy
        case GHOSTTY_MOUSE_SHAPE_MOVE: self = .move
        case GHOSTTY_MOUSE_SHAPE_NO_DROP: self = .noDrop
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: self = .notAllowed
        case GHOSTTY_MOUSE_SHAPE_GRAB: self = .grab
        case GHOSTTY_MOUSE_SHAPE_GRABBING: self = .grabbing
        case GHOSTTY_MOUSE_SHAPE_ALL_SCROLL: self = .allScroll
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE: self = .colResize
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE: self = .rowResize
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE: self = .nResize
        case GHOSTTY_MOUSE_SHAPE_E_RESIZE: self = .eResize
        case GHOSTTY_MOUSE_SHAPE_S_RESIZE: self = .sResize
        case GHOSTTY_MOUSE_SHAPE_W_RESIZE: self = .wResize
        case GHOSTTY_MOUSE_SHAPE_NE_RESIZE: self = .neResize
        case GHOSTTY_MOUSE_SHAPE_NW_RESIZE: self = .nwResize
        case GHOSTTY_MOUSE_SHAPE_SE_RESIZE: self = .seResize
        case GHOSTTY_MOUSE_SHAPE_SW_RESIZE: self = .swResize
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE: self = .ewResize
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE: self = .nsResize
        case GHOSTTY_MOUSE_SHAPE_NESW_RESIZE: self = .neswResize
        case GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE: self = .nwseResize
        case GHOSTTY_MOUSE_SHAPE_ZOOM_IN: self = .zoomIn
        case GHOSTTY_MOUSE_SHAPE_ZOOM_OUT: self = .zoomOut
        default: self = .default
        }
    }
}
