//
//  TerminalSurface.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit

/// Thread-safe wrapper around `ghostty_surface_t`.
///
/// All access must happen on the main actor. The surface should be freed
/// explicitly via ``free()`` before the wrapper is deallocated; `deinit`
/// includes a safety net but relying on it is discouraged.
@MainActor
public final class TerminalSurface {
    private var surface: ghostty_surface_t?
    private var hasBeenFreed = false

    init(_ surface: ghostty_surface_t) {
        self.surface = surface
    }

    var rawValue: ghostty_surface_t? {
        surface
    }

    // MARK: - Input

    @discardableResult
    func sendKeyEvent(_ event: ghostty_input_key_s) -> Bool {
        guard let s = surface else {
            TerminalDebugLog.log(.input, "surface key ignored: missing surface")
            return false
        }
        let result = ghostty_surface_key(s, event)
        TerminalDebugLog.log(
            .input,
            "surface key action=\(TerminalDebugLog.describe(event.action)) keycode=\(event.keycode) mods=0x\(String(event.mods.rawValue, radix: 16)) consumed=0x\(String(event.consumed_mods.rawValue, radix: 16)) text=\(terminalKeyText(event)) composing=\(event.composing) result=\(result)"
        )
        return result
    }

    @discardableResult
    public func sendText(_ text: String) -> Bool {
        guard let s = surface else {
            TerminalDebugLog.log(.input, "surface text ignored: missing surface")
            return false
        }
        TerminalDebugLog.log(
            .input,
            "surface text=\(TerminalDebugLog.describe(text))"
        )
        text.withCString { cStr in
            ghostty_surface_text(s, cStr, UInt(text.utf8.count))
        }
        return true
    }

    @discardableResult
    func sendMouseButton(
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        mods: ghostty_input_mods_e
    ) -> Bool {
        guard let s = surface else {
            TerminalDebugLog.log(.input, "surface mouse button ignored: missing surface")
            return false
        }
        let result = ghostty_surface_mouse_button(s, state, button, mods)
        TerminalDebugLog.log(
            .input,
            "surface mouseButton state=\(TerminalDebugLog.describe(state)) button=\(button.rawValue) mods=0x\(String(mods.rawValue, radix: 16)) result=\(result)"
        )
        return result
    }

    func sendMousePos(x: Double, y: Double, mods: ghostty_input_mods_e) {
        guard let s = surface else {
            TerminalDebugLog.log(.input, "surface mouse position ignored: missing surface")
            return
        }
        TerminalDebugLog.log(
            .input,
            "surface mousePos x=\(String(format: "%.2f", x)) y=\(String(format: "%.2f", y)) mods=0x\(String(mods.rawValue, radix: 16))"
        )
        ghostty_surface_mouse_pos(s, x, y, mods)
    }

    func sendMouseScroll(x: Double, y: Double, mods: ghostty_input_scroll_mods_t) {
        guard let s = surface else {
            TerminalDebugLog.log(.input, "surface scroll ignored: missing surface")
            return
        }
        TerminalDebugLog.log(
            .input,
            "surface scroll x=\(String(format: "%.2f", x)) y=\(String(format: "%.2f", y)) mods=0x\(String(mods, radix: 16))"
        )
        ghostty_surface_mouse_scroll(s, x, y, mods)
    }

    func preedit(_ text: String) {
        guard let s = surface else {
            TerminalDebugLog.log(.ime, "surface preedit ignored: missing surface")
            return
        }
        TerminalDebugLog.log(.ime, "surface preedit=\(TerminalDebugLog.describe(text))")
        text.withCString { cStr in
            ghostty_surface_preedit(s, cStr, UInt(text.utf8.count))
        }
    }

    // MARK: - Actions

    /// Invoke a named Ghostty binding action.
    ///
    /// Action names use the same syntax as Ghostty's `keybind` configuration,
    /// such as `copy_to_clipboard` or `scroll_page_lines:-3`.
    @discardableResult
    public func performBindingAction(_ action: String) -> Bool {
        guard let s = surface else {
            TerminalDebugLog.log(.actions, "binding action ignored: missing surface")
            return false
        }
        let result = action.withCString { cStr in
            ghostty_surface_binding_action(s, cStr, UInt(action.utf8.count))
        }
        TerminalDebugLog.log(
            .actions,
            "binding action=\(TerminalDebugLog.describe(action)) result=\(result)"
        )
        return result
    }

    /// Jump the viewport by a number of shell prompts.
    ///
    /// Negative offsets move toward older prompts and positive offsets move
    /// toward newer prompts. This requires prompt markers from Ghostty shell
    /// integration, or equivalent OSC 133 markers from a host-managed backend.
    @discardableResult
    public func jumpToPrompt(by offset: Int16) -> Bool {
        performBindingAction("jump_to_prompt:\(offset)")
    }

    /// Reveal an absolute scrollback row, where zero is the first row.
    @discardableResult
    public func scrollToRow(_ row: UInt) -> Bool {
        performBindingAction("scroll_to_row:\(row)")
    }

    // MARK: - Rendering

    func draw() {
        guard let s = surface else { return }
        TerminalDebugLog.log(.render, "surface draw")
        ghostty_surface_draw(s)
    }

    func refresh() {
        guard let s = surface else { return }
        TerminalDebugLog.log(.render, "surface refresh")
        ghostty_surface_refresh(s)
    }

    func setSize(width: UInt32, height: UInt32) {
        guard let s = surface else {
            TerminalDebugLog.log(.metrics, "surface setSize ignored: missing surface")
            return
        }
        TerminalDebugLog.log(.metrics, "surface setSize \(width)x\(height)")
        ghostty_surface_set_size(s, width, height)
    }

    func setContentScale(x: Double, y: Double) {
        guard let s = surface else {
            TerminalDebugLog.log(.metrics, "surface contentScale ignored: missing surface")
            return
        }
        TerminalDebugLog.log(
            .metrics,
            "surface contentScale x=\(String(format: "%.2f", x)) y=\(String(format: "%.2f", y))"
        )
        ghostty_surface_set_content_scale(s, x, y)
    }

    // MARK: - State

    func setFocus(_ focused: Bool) {
        guard let s = surface else { return }
        TerminalDebugLog.log(.lifecycle, "surface focus=\(focused)")
        ghostty_surface_set_focus(s, focused)
    }

    func setColorScheme(_ scheme: ghostty_color_scheme_e) {
        guard let s = surface else { return }
        TerminalDebugLog.log(.lifecycle, "surface colorScheme=\(scheme.rawValue)")
        ghostty_surface_set_color_scheme(s, scheme)
    }

    func setOcclusion(_ visible: Bool) {
        guard let s = surface else { return }
        TerminalDebugLog.log(.lifecycle, "surface occlusion visible=\(visible)")
        ghostty_surface_set_occlusion(s, visible)
    }

    // MARK: - Size Query

    func size() -> TerminalGridMetrics? {
        guard let s = surface else {
            TerminalDebugLog.log(.metrics, "surface size query ignored: missing surface")
            return nil
        }
        let metrics = TerminalGridMetrics(ghostty_surface_size(s))
        TerminalDebugLog.log(.metrics, "surface size \(metrics.debugSummary)")
        return metrics
    }

    // MARK: - Selection

    struct SelectionResult {
        let text: String
        let offsetStart: UInt32
        let offsetLength: UInt32
    }

    func hasSelection() -> Bool {
        guard let s = surface else {
            TerminalDebugLog.log(.input, "surface selection query ignored: missing surface")
            return false
        }
        let result = ghostty_surface_has_selection(s)
        TerminalDebugLog.log(.input, "surface hasSelection=\(result)")
        return result
    }

    func readSelection() -> String? {
        readSelectionResult()?.text
    }

    func readSelectionResult() -> SelectionResult? {
        guard let s = surface else {
            TerminalDebugLog.log(.input, "surface readSelection ignored: missing surface")
            return nil
        }
        var out = ghostty_text_s()
        guard ghostty_surface_read_selection(s, &out) else {
            TerminalDebugLog.log(.input, "surface readSelection returned false")
            return nil
        }
        defer { ghostty_surface_free_text(s, &out) }

        guard let textPtr = out.text, out.text_len > 0 else {
            TerminalDebugLog.log(.input, "surface readSelection empty")
            return SelectionResult(
                text: "",
                offsetStart: out.offset_start,
                offsetLength: out.offset_len
            )
        }

        let bytes = UnsafeBufferPointer(start: textPtr, count: Int(out.text_len))
            .map { UInt8(bitPattern: $0) }
        let text = String(decoding: bytes, as: UTF8.self)
        TerminalDebugLog.log(
            .input,
            "surface readSelection bytes=\(text.utf8.count) lines=\(TerminalInputText.lineCount(in: text)) offset=\(out.offset_start)+\(out.offset_len)"
        )
        return SelectionResult(
            text: text,
            offsetStart: out.offset_start,
            offsetLength: out.offset_len
        )
    }

    // MARK: - IME

    func imePoint() -> (x: Double, y: Double, width: Double, height: Double) {
        var x: Double = 0
        var y: Double = 0
        var w: Double = 0
        var h: Double = 0
        if let s = surface {
            ghostty_surface_ime_point(s, &x, &y, &w, &h)
        }
        TerminalDebugLog.log(
            .ime,
            "surface imePoint x=\(String(format: "%.2f", x)) y=\(String(format: "%.2f", y)) width=\(String(format: "%.2f", w)) height=\(String(format: "%.2f", h))"
        )
        return (x, y, w, h)
    }

    // MARK: - Mouse Capture

    var isMouseCaptured: Bool {
        guard let s = surface else { return false }
        return ghostty_surface_mouse_captured(s)
    }

    // MARK: - Quicklook Word (Apple-only)

    #if canImport(UIKit) || canImport(AppKit)
        struct QuicklookWordResult {
            let word: String
            let offsetStart: UInt32
            let offsetLength: UInt32
            // tl_px_x / tl_px_y are reported in host points (view coordinates),
            // not surface pixels. Ghostty's embedded API receives mouse_pos in
            // points and stores the cursor position * contentScale internally,
            // then divides by contentScale when reporting selection coordinates
            // back. Callers must convert cell pixel dimensions to points before
            // dividing.
            let pointX: Double
            let pointY: Double
        }

        func quicklookWord() -> QuicklookWordResult? {
            guard let s = surface else {
                TerminalDebugLog.log(.input, "surface quicklookWord ignored: missing surface")
                return nil
            }
            var out = ghostty_text_s()
            guard ghostty_surface_quicklook_word(s, &out) else {
                TerminalDebugLog.log(.input, "surface quicklookWord returned false")
                return nil
            }
            defer { ghostty_surface_free_text(s, &out) }

            let word: String
            if let textPtr = out.text, out.text_len > 0 {
                let bytes = UnsafeBufferPointer(start: textPtr, count: Int(out.text_len))
                    .map { UInt8(bitPattern: $0) }
                word = String(decoding: bytes, as: UTF8.self)
            } else {
                word = ""
            }
            TerminalDebugLog.log(
                .input,
                "surface quicklookWord word=\(TerminalDebugLog.describe(word)) offset=\(out.offset_start)+\(out.offset_len) pointX=\(String(format: "%.2f", out.tl_px_x)) pointY=\(String(format: "%.2f", out.tl_px_y))"
            )
            return QuicklookWordResult(
                word: word,
                offsetStart: out.offset_start,
                offsetLength: out.offset_len,
                pointX: out.tl_px_x,
                pointY: out.tl_px_y
            )
        }

        func selectionContainsQuicklookWord() -> Bool {
            guard let selected = readSelectionResult(),
                  let word = quicklookWord(),
                  !word.word.isEmpty,
                  word.offsetLength > 0
            else { return false }

            let selectionStart = UInt64(selected.offsetStart)
            let selectionEnd = selectionStart + UInt64(selected.offsetLength)
            let wordStart = UInt64(word.offsetStart)
            let wordEnd = wordStart + UInt64(word.offsetLength)
            let contains = wordStart >= selectionStart && wordEnd <= selectionEnd
            TerminalDebugLog.log(
                .input,
                "surface selectionContainsQuicklookWord=\(contains) selection=\(selected.offsetStart)+\(selected.offsetLength) word=\(word.offsetStart)+\(word.offsetLength)"
            )
            return contains
        }
    #endif

    // MARK: - Process

    /// PID of the pty's foreground process group (`tcgetpgrp(pty)`). When the
    /// user runs a program in the pty this is that program's pid, so hosts can
    /// correlate a surface with an external process list. Ghostty returns 0
    /// when the surface has no process yet — surfaced here as nil.
    var foregroundPid: pid_t? {
        guard let s = surface else { return nil }
        let pid = ghostty_surface_foreground_pid(s)
        return pid == 0 ? nil : pid_t(pid)
    }

    /// Name of the pty's controlling tty (e.g. `/dev/ttys004`), or nil when the
    /// surface has no process yet. Useful as a cross-check for ``foregroundPid``.
    var ttyName: String? {
        guard let s = surface else { return nil }
        let str = ghostty_surface_tty_name(s)
        defer { ghostty_string_free(str) }
        guard let ptr = str.ptr, str.len > 0 else { return nil }
        return String(
            decoding: UnsafeRawBufferPointer(start: ptr, count: Int(str.len)),
            as: UTF8.self
        )
    }

    // MARK: - Lifecycle

    func free() {
        guard !hasBeenFreed, let s = surface else { return }
        TerminalDebugLog.log(.lifecycle, "surface free")
        hasBeenFreed = true
        surface = nil
        ghostty_surface_free(s)
    }

    deinit {
        // Surface should be freed explicitly via free() before deinit.
        // The deinit safety net is intentionally removed because
        // Swift 6 strict concurrency prevents accessing @MainActor
        // state from nonisolated deinit.
    }
}

private func terminalKeyText(_ event: ghostty_input_key_s) -> String {
    guard let text = event.text else { return "nil" }
    return TerminalDebugLog.describe(String(cString: text))
}
