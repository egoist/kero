//
//  TerminalClipboardConfirmationRequest.swift
//  libghostty-spm
//

import Foundation
import GhosttyKit

/// A clipboard request that Ghostty escalated for a user decision:
/// an OSC 52 read under `clipboard-read = ask`, or a paste that paste
/// protection flagged as unsafe. The host presents a visible prompt
/// and calls ``approve()`` or ``deny()`` exactly once; later calls are
/// ignored.
@MainActor
public final class TerminalClipboardConfirmationRequest {
    public enum Kind: Sendable {
        /// Paste protection flagged the pending paste as unsafe.
        case unsafePaste
        /// A terminal program wants the clipboard via OSC 52 with
        /// `clipboard-read = ask`.
        case osc52Read
    }

    public let kind: Kind

    /// The text under decision: what would be pasted for
    /// ``Kind/unsafePaste``, or what the program would receive for
    /// ``Kind/osc52Read``.
    public let contents: String

    private weak var bridge: TerminalCallbackBridge?
    private let state: UnsafeMutableRawPointer
    private var resolved = false

    init(
        bridge: TerminalCallbackBridge,
        kind: Kind,
        contents: String,
        state: UnsafeMutableRawPointer
    ) {
        self.bridge = bridge
        self.kind = kind
        self.contents = contents
        self.state = state
    }

    /// Completes with the requested contents: the paste proceeds, or
    /// the OSC 52 reply carries the clipboard.
    public func approve() {
        resolve(text: contents, outcome: "approved")
    }

    /// Completes with no data, mirroring upstream Ghostty's cancel
    /// action: the paste becomes a no-op and an OSC 52 read replies
    /// empty.
    public func deny() {
        resolve(text: "", outcome: "denied")
    }

    private func resolve(text: String, outcome: String) {
        guard !resolved else { return }
        resolved = true

        // Completing hands `state` back to the surface, which frees it.
        // Teardown nils `rawSurface` before freeing the surface, so a
        // decision arriving after the surface died is dropped instead
        // of touching freed memory.
        guard let surface = bridge?.rawSurface else {
            TerminalDebugLog.log(
                .input,
                "clipboard confirm \(outcome) after surface teardown; dropped"
            )
            return
        }
        TerminalDebugLog.log(
            .input,
            "clipboard confirm \(outcome) kind=\(kind) bytes=\(text.utf8.count)"
        )
        text.withCString { cString in
            TerminalClipboardIO.complete(surface, cString, state, true)
        }
    }
}
