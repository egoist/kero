//
//  TerminalCallbackBridge.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit

/// Dispatches C runtime callbacks to a ``TerminalSurfaceViewDelegate``.
///
/// An instance of this class is passed as the `userdata` pointer in the
/// surface config so that Ghostty callbacks can route actions back to
/// the owning view.
@MainActor
final class TerminalCallbackBridge {
    weak var delegate: (any TerminalSurfaceViewDelegate)?
    /// Raw surface pointer for use in C callbacks (e.g. clipboard).
    nonisolated(unsafe) var rawSurface: ghostty_surface_t?
    var onCellSizeChange: ((UInt32, UInt32) -> Void)?
    var onRenderRequest: (() -> Void)?
    var onMouseShapeChange: ((TerminalMouseShape) -> Void)?

    init(delegate: (any TerminalSurfaceViewDelegate)? = nil) {
        self.delegate = delegate
    }

    /// Dispatches an action and reports whether the host handled it. Ghostty
    /// uses the return value to decide whether to run its platform fallback.
    func handleAction(_ action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            if let cStr = action.action.set_title.title {
                let title = String(cString: cStr)
                TerminalDebugLog.log(
                    .actions,
                    "callback action=set_title title=\(TerminalDebugLog.describe(title))"
                )
                (delegate as? any TerminalSurfaceTitleDelegate)?
                    .terminalDidChangeTitle(title)
            }

        case GHOSTTY_ACTION_CELL_SIZE:
            let cellSize = action.action.cell_size
            TerminalDebugLog.log(
                .actions,
                "callback action=cell_size width=\(cellSize.width) height=\(cellSize.height)"
            )
            onCellSizeChange?(cellSize.width, cellSize.height)

        case GHOSTTY_ACTION_RING_BELL:
            TerminalDebugLog.log(.actions, "callback action=ring_bell")
            (delegate as? any TerminalSurfaceBellDelegate)?
                .terminalDidRingBell()

        case GHOSTTY_ACTION_RENDER:
            TerminalDebugLog.log(.render, "callback action=render")
            onRenderRequest?()

        case GHOSTTY_ACTION_CONFIG_CHANGE:
            // Colors/theme may have changed (e.g. on system appearance
            // toggle). Ghostty applies the new config internally but won't
            // repaint until the next frame — request one so the refreshed
            // theme is visible without waiting for input or layout.
            TerminalDebugLog.log(.actions, "callback action=config_change")
            onRenderRequest?()

        case GHOSTTY_ACTION_PROGRESS_REPORT:
            let report = action.action.progress_report
            let state = TerminalProgressState(report.state) ?? .set
            // int8_t -1 signals "no progress provided" — surface as nil.
            let percent: Int? = report.progress < 0 ? nil : Int(report.progress)
            TerminalDebugLog.log(
                .actions,
                "callback action=progress_report state=\(state) percent=\(percent.map { "\($0)" } ?? "nil")"
            )
            (delegate as? any TerminalSurfaceProgressReportDelegate)?
                .terminalDidReportProgress(state: state, percent: percent)

        case GHOSTTY_ACTION_COMMAND_FINISHED:
            let finished = action.action.command_finished
            // int16_t -1 signals unknown exit code.
            let exit: Int? = finished.exit_code < 0 ? nil : Int(finished.exit_code)
            TerminalDebugLog.log(
                .actions,
                "callback action=command_finished exit=\(exit.map { "\($0)" } ?? "nil") duration_ns=\(finished.duration)"
            )
            (delegate as? any TerminalSurfaceCommandFinishedDelegate)?
                .terminalDidFinishCommand(
                    exitCode: exit,
                    durationNanos: finished.duration
                )

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let payload = action.action.desktop_notification
            let title = payload.title.map { String(cString: $0) } ?? ""
            let body = payload.body.map { String(cString: $0) } ?? ""
            TerminalDebugLog.log(
                .actions,
                "callback action=desktop_notification title=\(TerminalDebugLog.describe(title)) body=\(TerminalDebugLog.describe(body))"
            )
            (delegate as? any TerminalSurfaceDesktopNotificationDelegate)?
                .terminalDidRequestDesktopNotification(title: title, body: body)

        case GHOSTTY_ACTION_OPEN_URL:
            guard let delegate = delegate as? any TerminalSurfaceOpenURLDelegate else {
                return false
            }
            let payload = action.action.open_url
            let kind = TerminalOpenURLKind(payload.kind)
            let url: String = payload.url.map { ptr in
                // Ghostty provides a length-prefixed string; respect the
                // documented length rather than trusting a NUL terminator.
                let buf = UnsafeBufferPointer(start: ptr, count: Int(payload.len))
                return String(decoding: buf.map(UInt8.init), as: UTF8.self)
            } ?? ""
            TerminalDebugLog.log(
                .actions,
                "callback action=open_url kind=\(kind) url=\(TerminalDebugLog.describe(url))"
            )
            delegate.terminalDidRequestOpenURL(url, kind: kind)
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            let shape = TerminalMouseShape(action.action.mouse_shape)
            TerminalDebugLog.log(
                .actions,
                "callback action=mouse_shape shape=\(shape)"
            )
            onMouseShapeChange?(shape)
            return true

        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            let payload = action.action.mouse_over_link
            let url: String? = {
                guard let ptr = payload.url, payload.len > 0 else { return nil }
                let buf = UnsafeBufferPointer(start: ptr, count: Int(payload.len))
                return String(decoding: buf.map(UInt8.init), as: UTF8.self)
            }()
            TerminalDebugLog.log(
                .actions,
                "callback action=mouse_over_link url=\(url.map { TerminalDebugLog.describe($0) } ?? "nil")"
            )
            (delegate as? any TerminalSurfaceHoverLinkDelegate)?
                .terminalDidUpdateHoverLink(url)

        case GHOSTTY_ACTION_PWD:
            let payload = action.action.pwd
            if let cStr = payload.pwd {
                let pwd = String(cString: cStr)
                TerminalDebugLog.log(
                    .actions,
                    "callback action=pwd pwd=\(TerminalDebugLog.describe(pwd))"
                )
                (delegate as? any TerminalSurfacePwdDelegate)?
                    .terminalDidChangeWorkingDirectory(pwd)
            }

        case GHOSTTY_ACTION_SCROLLBAR:
            let payload = action.action.scrollbar
            TerminalDebugLog.log(
                .actions,
                "callback action=scrollbar total=\(payload.total) offset=\(payload.offset) len=\(payload.len)"
            )
            (delegate as? any TerminalSurfaceScrollbarDelegate)?
                .terminalDidUpdateScrollbar(
                    TerminalScrollbar(
                        total: payload.total,
                        offset: payload.offset,
                        len: payload.len
                    )
                )

        case GHOSTTY_ACTION_START_SEARCH:
            guard let delegate = delegate as? any TerminalSurfaceSearchDelegate else {
                return false
            }
            // Empty for a bare `start_search`; a resolved needle when the
            // action carried terms of its own (e.g. `search_selection`).
            let needle = action.action.start_search.needle
                .map { String(cString: $0) } ?? ""
            TerminalDebugLog.log(
                .actions,
                "callback action=start_search needle=\(TerminalDebugLog.describe(needle))"
            )
            delegate.terminalDidStartSearch(needle: needle)
            return true

        case GHOSTTY_ACTION_END_SEARCH:
            guard let delegate = delegate as? any TerminalSurfaceSearchDelegate else {
                return false
            }
            TerminalDebugLog.log(.actions, "callback action=end_search")
            delegate.terminalDidEndSearch()
            return true

        case GHOSTTY_ACTION_SEARCH_TOTAL:
            guard let delegate = delegate as? any TerminalSurfaceSearchDelegate else {
                return false
            }
            // ssize_t: negative means the count isn't known yet.
            let total = action.action.search_total.total
            TerminalDebugLog.log(.actions, "callback action=search_total total=\(total)")
            delegate.terminalDidUpdateSearchTotal(total < 0 ? nil : Int(total))
            return true

        case GHOSTTY_ACTION_SEARCH_SELECTED:
            guard let delegate = delegate as? any TerminalSurfaceSearchDelegate else {
                return false
            }
            // ssize_t: negative means no match is selected.
            let selected = action.action.search_selected.selected
            TerminalDebugLog.log(
                .actions,
                "callback action=search_selected selected=\(selected)"
            )
            delegate.terminalDidUpdateSearchSelected(selected < 0 ? nil : Int(selected))
            return true

        default:
            TerminalDebugLog.log(
                .actions,
                "callback action=\(TerminalDebugLog.describe(action.tag))"
            )
        }
        return false
    }

    /// Routes a clipboard request that Ghostty escalated for a user
    /// decision to the delegate's prompt. Without a delegate that
    /// adopts ``TerminalSurfaceClipboardConfirmationDelegate`` the only
    /// safe answer is no: auto-confirming would hand the system
    /// clipboard to any program that can write terminal output.
    func handleClipboardConfirmation(
        contents: String,
        kind: TerminalClipboardConfirmationRequest.Kind,
        state: UnsafeMutableRawPointer
    ) {
        let request = TerminalClipboardConfirmationRequest(
            bridge: self,
            kind: kind,
            contents: contents,
            state: state
        )
        guard
            let delegate = delegate
                as? any TerminalSurfaceClipboardConfirmationDelegate
        else {
            TerminalDebugLog.log(
                .input,
                "clipboard confirm denied: no confirmation delegate"
            )
            request.deny()
            return
        }
        TerminalDebugLog.log(
            .input,
            "clipboard confirm escalated kind=\(kind) bytes=\(contents.utf8.count)"
        )
        delegate.terminalDidRequestClipboardConfirmation(request)
    }

    func handleClose(processAlive: Bool) {
        TerminalDebugLog.log(
            .lifecycle,
            "callback close processAlive=\(processAlive)"
        )
        (delegate as? any TerminalSurfaceCloseDelegate)?
            .terminalDidClose(processAlive: processAlive)
    }
}
