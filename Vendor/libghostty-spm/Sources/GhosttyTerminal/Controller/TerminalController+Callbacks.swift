//
//  TerminalController+Callbacks.swift
//  libghostty-spm
//

import Foundation
import GhosttyKit

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// System pasteboard access and libghostty request completion used by
/// the clipboard callbacks. Injectable so tests can verify the security
/// contract — escalated requests must never complete with clipboard
/// data — without a live surface.
enum TerminalClipboardIO {
    nonisolated(unsafe) static var readString: () -> String? = {
        #if canImport(UIKit)
            UIPasteboard.general.string
        #elseif canImport(AppKit)
            TerminalPasteboard.string(from: .general)
        #endif
    }

    nonisolated(unsafe) static var writeString: (String) -> Void = { string in
        #if canImport(UIKit)
            UIPasteboard.general.string = string
        #elseif canImport(AppKit)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(string, forType: .string)
        #endif
    }

    nonisolated(unsafe) static var complete: (
        _ surface: ghostty_surface_t,
        _ string: UnsafePointer<CChar>,
        _ state: UnsafeMutableRawPointer,
        _ confirmed: Bool
    ) -> Void = { surface, string, state, confirmed in
        ghostty_surface_complete_clipboard_request(surface, string, state, confirmed)
    }
}

private enum TerminalCallbacks {
    static func wakeup(userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        let controller = Unmanaged<TerminalController>.fromOpaque(userdata)
            .takeUnretainedValue()
        terminalRunOnMain {
            controller.handleWakeup()
        }
    }

    static func action(
        appPtr: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        guard let appPtr else { return false }
        guard ghostty_app_userdata(appPtr) != nil else { return false }
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
        guard let surfacePtr = target.target.surface else { return false }
        guard let bridgePtr = ghostty_surface_userdata(surfacePtr) else { return false }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(bridgePtr)
            .takeUnretainedValue()
        return terminalRunOnMainSync {
            bridge.handleAction(action)
        }
    }

    static func closeSurface(
        userdata: UnsafeMutableRawPointer?,
        processAlive: Bool
    ) {
        guard let userdata else { return }
        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        terminalRunOnMain {
            bridge.handleClose(processAlive: processAlive)
        }
    }

    static func writeClipboard(
        userdata _: UnsafeMutableRawPointer?,
        clipboard _: ghostty_clipboard_e,
        contents: UnsafePointer<ghostty_clipboard_content_s>?,
        contentsLen: Int,
        confirm: Bool
    ) {
        // `confirm` is set when configuration (`clipboard-write = ask`)
        // requires a user decision before the pasteboard changes. This
        // bridge has no confirmation UI, so deny the write rather than
        // silently performing it.
        guard !confirm else {
            TerminalDebugLog.log(
                .input,
                "clipboard write denied: confirmation required but no UI exists"
            )
            return
        }
        guard contentsLen > 0 else { return }
        guard let content = contents?.pointee else { return }
        guard let data = content.data else { return }

        TerminalClipboardIO.writeString(String(cString: data))
    }

    static func readClipboard(
        userdata: UnsafeMutableRawPointer?,
        clipboard _: ghostty_clipboard_e,
        opaquePtr: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let userdata, let opaquePtr else { return false }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        guard let surface = bridge.rawSurface else { return false }

        guard let string = TerminalClipboardIO.readString() else {
            TerminalDebugLog.log(.input, "clipboard paste read empty")
            return false
        }
        TerminalDebugLog.log(
            .input,
            "clipboard paste read bytes=\(string.utf8.count) lines=\(TerminalInputText.lineCount(in: string))"
        )
        // Complete unconfirmed: Ghostty re-checks configuration and
        // escalates to confirmReadClipboard when a user decision is
        // required (unsafe paste, `clipboard-read = ask`).
        string.withCString { cString in
            TerminalClipboardIO.complete(surface, cString, opaquePtr, false)
        }
        TerminalDebugLog.log(.input, "clipboard paste complete")
        return true
    }

    /// Ghostty escalates a clipboard request here when configuration
    /// demands a user decision: `clipboard-read = ask` for an OSC 52
    /// read, or paste protection for an unsafe paste. The request is
    /// routed to the surface delegate, which presents a prompt and
    /// resolves it; without a confirmation delegate it is denied (see
    /// ``TerminalCallbackBridge/handleClipboardConfirmation``).
    static func confirmReadClipboard(
        userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        opaquePtr: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let userdata, let string, let opaquePtr else { return }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()

        // OSC 52 writes never escalate through this callback (the write
        // callback's `confirm` flag covers them), and completing one
        // would push text onto the system pasteboard.
        guard request != GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE else { return }

        let kind: TerminalClipboardConfirmationRequest.Kind =
            request == GHOSTTY_CLIPBOARD_REQUEST_PASTE ? .unsafePaste : .osc52Read
        // Copy out of the C buffer before hopping threads: the string
        // pointer is only valid for the duration of this callback,
        // while the decision may arrive much later. The request state
        // pointer stays valid until the request is completed.
        let contents = String(cString: string)
        let stateBits = UInt(bitPattern: opaquePtr)
        terminalRunOnMain {
            guard let state = UnsafeMutableRawPointer(bitPattern: stateBits) else {
                return
            }
            bridge.handleClipboardConfirmation(
                contents: contents,
                kind: kind,
                state: state
            )
        }
    }
}

func terminalControllerWakeupCallback(userdata: UnsafeMutableRawPointer?) {
    TerminalCallbacks.wakeup(userdata: userdata)
}

func terminalControllerActionCallback(
    appPtr: ghostty_app_t?,
    target: ghostty_target_s,
    action: ghostty_action_s
) -> Bool {
    TerminalCallbacks.action(appPtr: appPtr, target: target, action: action)
}

func terminalControllerCloseSurfaceCallback(
    userdata: UnsafeMutableRawPointer?,
    processAlive: Bool
) {
    TerminalCallbacks.closeSurface(userdata: userdata, processAlive: processAlive)
}

func terminalControllerWriteClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    clipboard: ghostty_clipboard_e,
    contents: UnsafePointer<ghostty_clipboard_content_s>?,
    contentsLen: Int,
    confirm: Bool
) {
    TerminalCallbacks.writeClipboard(
        userdata: userdata,
        clipboard: clipboard,
        contents: contents,
        contentsLen: contentsLen,
        confirm: confirm
    )
}

func terminalControllerReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    clipboard: ghostty_clipboard_e,
    opaquePtr: UnsafeMutableRawPointer?
) -> Bool {
    TerminalCallbacks.readClipboard(
        userdata: userdata,
        clipboard: clipboard,
        opaquePtr: opaquePtr
    )
}

func terminalControllerConfirmReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    string: UnsafePointer<CChar>?,
    opaquePtr: UnsafeMutableRawPointer?,
    request: ghostty_clipboard_request_e
) {
    TerminalCallbacks.confirmReadClipboard(
        userdata: userdata,
        string: string,
        opaquePtr: opaquePtr,
        request: request
    )
}
