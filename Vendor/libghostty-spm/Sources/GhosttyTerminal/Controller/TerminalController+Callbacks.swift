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
        confirm _: Bool
    ) {
        guard contentsLen > 0 else { return }
        guard let content = contents?.pointee else { return }
        guard let data = content.data else { return }
        let string = String(cString: data)

        #if canImport(UIKit)
            UIPasteboard.general.string = string
        #elseif canImport(AppKit)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(string, forType: .string)
        #endif
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

        #if canImport(UIKit)
            let string = UIPasteboard.general.string
        #elseif canImport(AppKit)
            let string = NSPasteboard.general.string(forType: .string)
        #endif

        guard let string else {
            TerminalDebugLog.log(.input, "clipboard paste read empty")
            return false
        }
        TerminalDebugLog.log(
            .input,
            "clipboard paste read bytes=\(string.utf8.count) lines=\(TerminalInputText.lineCount(in: string))"
        )
        string.withCString { cString in
            ghostty_surface_complete_clipboard_request(surface, cString, opaquePtr, false)
        }
        TerminalDebugLog.log(.input, "clipboard paste complete")
        return true
    }

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
        guard let surface = bridge.rawSurface else { return }

        let text = String(cString: string)
        TerminalDebugLog.log(
            .input,
            "clipboard paste confirm request=\(request.rawValue) bytes=\(text.utf8.count) lines=\(TerminalInputText.lineCount(in: text))"
        )
        text.withCString { cString in
            ghostty_surface_complete_clipboard_request(surface, cString, opaquePtr, true)
        }
        TerminalDebugLog.log(.input, "clipboard paste confirmed")
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
