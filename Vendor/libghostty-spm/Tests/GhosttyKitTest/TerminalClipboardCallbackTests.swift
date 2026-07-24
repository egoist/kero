import GhosttyKit
@testable import GhosttyTerminal
import Testing

/// Regression coverage for the clipboard callback security contract:
/// a request that Ghostty escalates for user confirmation must never
/// complete with real clipboard data unless a host confirmation
/// delegate explicitly approves it. Serialized because the tests swap
/// the injectable `TerminalClipboardIO` hooks.
@Suite(.serialized)
@MainActor
struct TerminalClipboardCallbackTests {
    @Test
    func `escalated OSC 52 read without a delegate is denied with an empty confirmed reply`() {
        let original = TerminalClipboardIO.complete
        defer { TerminalClipboardIO.complete = original }
        var recorded: (string: String, confirmed: Bool)?
        TerminalClipboardIO.complete = { _, string, _, confirmed in
            recorded = (String(cString: string), confirmed)
        }

        let bridge = makeBridge()
        withTestState { state in
            invokeConfirmCallback(
                bridge: bridge,
                contents: "secret from the pasteboard",
                request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ,
                state: state
            )
        }

        #expect(recorded?.string == "")
        #expect(recorded?.confirmed == true)
    }

    @Test
    func `escalated unsafe paste without a delegate is denied with an empty confirmed reply`() {
        let original = TerminalClipboardIO.complete
        defer { TerminalClipboardIO.complete = original }
        var recorded: (string: String, confirmed: Bool)?
        TerminalClipboardIO.complete = { _, string, _, confirmed in
            recorded = (String(cString: string), confirmed)
        }

        let bridge = makeBridge()
        withTestState { state in
            invokeConfirmCallback(
                bridge: bridge,
                contents: "rm -rf /\n",
                request: GHOSTTY_CLIPBOARD_REQUEST_PASTE,
                state: state
            )
        }

        #expect(recorded?.string == "")
        #expect(recorded?.confirmed == true)
    }

    @Test
    func `escalated OSC 52 write is dropped without completing`() {
        let original = TerminalClipboardIO.complete
        defer { TerminalClipboardIO.complete = original }
        var completed = false
        TerminalClipboardIO.complete = { _, _, _, _ in
            completed = true
        }

        let bridge = makeBridge()
        withTestState { state in
            invokeConfirmCallback(
                bridge: bridge,
                contents: "attacker text",
                request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE,
                state: state
            )
        }

        #expect(!completed)
    }

    @Test
    func `escalated request routes to the confirmation delegate`() {
        let original = TerminalClipboardIO.complete
        defer { TerminalClipboardIO.complete = original }
        var completed = false
        TerminalClipboardIO.complete = { _, _, _, _ in
            completed = true
        }

        let recorder = ClipboardConfirmationRecorder()
        let bridge = makeBridge(delegate: recorder)
        withTestState { state in
            invokeConfirmCallback(
                bridge: bridge,
                contents: "clipboard text",
                request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ,
                state: state
            )

            #expect(recorder.requests.count == 1)
            #expect(recorder.requests.first?.kind == .osc52Read)
            #expect(recorder.requests.first?.contents == "clipboard text")
            // Nothing completes until the delegate decides.
            #expect(!completed)
            recorder.requests.first?.deny()
        }

        #expect(completed)
    }

    @Test
    func `escalated paste maps to the unsafe paste kind`() {
        let original = TerminalClipboardIO.complete
        defer { TerminalClipboardIO.complete = original }
        TerminalClipboardIO.complete = { _, _, _, _ in }

        let recorder = ClipboardConfirmationRecorder()
        let bridge = makeBridge(delegate: recorder)
        withTestState { state in
            invokeConfirmCallback(
                bridge: bridge,
                contents: "multi\nline",
                request: GHOSTTY_CLIPBOARD_REQUEST_PASTE,
                state: state
            )
            #expect(recorder.requests.first?.kind == .unsafePaste)
            recorder.requests.first?.deny()
        }
    }

    @Test
    func `approving completes with the original contents`() {
        let original = TerminalClipboardIO.complete
        defer { TerminalClipboardIO.complete = original }
        var recorded: (string: String, confirmed: Bool)?
        TerminalClipboardIO.complete = { _, string, _, confirmed in
            recorded = (String(cString: string), confirmed)
        }

        let recorder = ClipboardConfirmationRecorder()
        let bridge = makeBridge(delegate: recorder)
        withTestState { state in
            invokeConfirmCallback(
                bridge: bridge,
                contents: "approved text",
                request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ,
                state: state
            )
            recorder.requests.first?.approve()
        }

        #expect(recorded?.string == "approved text")
        #expect(recorded?.confirmed == true)
    }

    @Test
    func `denying completes with an empty confirmed reply`() {
        let original = TerminalClipboardIO.complete
        defer { TerminalClipboardIO.complete = original }
        var recorded: (string: String, confirmed: Bool)?
        TerminalClipboardIO.complete = { _, string, _, confirmed in
            recorded = (String(cString: string), confirmed)
        }

        let recorder = ClipboardConfirmationRecorder()
        let bridge = makeBridge(delegate: recorder)
        withTestState { state in
            invokeConfirmCallback(
                bridge: bridge,
                contents: "never delivered",
                request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ,
                state: state
            )
            recorder.requests.first?.deny()
        }

        #expect(recorded?.string == "")
        #expect(recorded?.confirmed == true)
    }

    @Test
    func `a request resolves at most once`() {
        let original = TerminalClipboardIO.complete
        defer { TerminalClipboardIO.complete = original }
        var completions = 0
        TerminalClipboardIO.complete = { _, _, _, _ in
            completions += 1
        }

        let recorder = ClipboardConfirmationRecorder()
        let bridge = makeBridge(delegate: recorder)
        withTestState { state in
            invokeConfirmCallback(
                bridge: bridge,
                contents: "text",
                request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ,
                state: state
            )
            recorder.requests.first?.approve()
            recorder.requests.first?.deny()
            recorder.requests.first?.approve()
        }

        #expect(completions == 1)
    }

    @Test
    func `a decision after surface teardown is dropped`() {
        let original = TerminalClipboardIO.complete
        defer { TerminalClipboardIO.complete = original }
        var completed = false
        TerminalClipboardIO.complete = { _, _, _, _ in
            completed = true
        }

        let recorder = ClipboardConfirmationRecorder()
        let bridge = makeBridge(delegate: recorder)
        withTestState { state in
            invokeConfirmCallback(
                bridge: bridge,
                contents: "text",
                request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ,
                state: state
            )
            bridge.rawSurface = nil
            recorder.requests.first?.approve()
        }

        #expect(!completed)
    }

    @Test
    func `write requiring confirmation never reaches the pasteboard`() {
        let original = TerminalClipboardIO.writeString
        defer { TerminalClipboardIO.writeString = original }
        var written: String?
        TerminalClipboardIO.writeString = { written = $0 }

        invokeWriteCallback("attacker text", confirm: true)

        #expect(written == nil)
    }

    @Test
    func `unconfirmed write reaches the pasteboard`() {
        let original = TerminalClipboardIO.writeString
        defer { TerminalClipboardIO.writeString = original }
        var written: String?
        TerminalClipboardIO.writeString = { written = $0 }

        invokeWriteCallback("copied text", confirm: false)

        #expect(written == "copied text")
    }

    @Test
    func `paste read completes unconfirmed so core keeps paste authority`() {
        let originalRead = TerminalClipboardIO.readString
        let originalComplete = TerminalClipboardIO.complete
        defer {
            TerminalClipboardIO.readString = originalRead
            TerminalClipboardIO.complete = originalComplete
        }
        TerminalClipboardIO.readString = { "line one\nline two" }
        var recorded: (string: String, confirmed: Bool)?
        TerminalClipboardIO.complete = { _, string, _, confirmed in
            recorded = (String(cString: string), confirmed)
        }

        let bridge = makeBridge()
        var state = 0
        let handled = withUnsafeMutablePointer(to: &state) { statePtr in
            terminalControllerReadClipboardCallback(
                userdata: Unmanaged.passUnretained(bridge).toOpaque(),
                clipboard: GHOSTTY_CLIPBOARD_STANDARD,
                opaquePtr: UnsafeMutableRawPointer(statePtr)
            )
        }

        #expect(handled)
        #expect(recorded?.string == "line one\nline two")
        #expect(recorded?.confirmed == false)
    }

    // MARK: - Helpers

    /// Bridge with a dummy surface pointer; the injected hooks
    /// intercept every path that would dereference it.
    private func makeBridge(
        delegate: (any TerminalSurfaceViewDelegate)? = nil
    ) -> TerminalCallbackBridge {
        let bridge = TerminalCallbackBridge(delegate: delegate)
        bridge.rawSurface = UnsafeMutableRawPointer(bitPattern: 0x1)
        return bridge
    }

    /// Heap-allocated stand-in for the request state Ghostty passes to
    /// the confirm callback, valid for the whole decision lifetime.
    private func withTestState(_ body: (UnsafeMutableRawPointer) -> Void) {
        let state = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer { state.deallocate() }
        body(state)
    }

    private func invokeConfirmCallback(
        bridge: TerminalCallbackBridge,
        contents: String,
        request: ghostty_clipboard_request_e,
        state: UnsafeMutableRawPointer
    ) {
        contents.withCString { cString in
            terminalControllerConfirmReadClipboardCallback(
                userdata: Unmanaged.passUnretained(bridge).toOpaque(),
                string: cString,
                opaquePtr: state,
                request: request
            )
        }
    }

    private func invokeWriteCallback(_ text: String, confirm: Bool) {
        text.withCString { data in
            "text/plain".withCString { mime in
                let content = ghostty_clipboard_content_s(mime: mime, data: data)
                withUnsafePointer(to: content) { contentsPtr in
                    terminalControllerWriteClipboardCallback(
                        userdata: nil,
                        clipboard: GHOSTTY_CLIPBOARD_STANDARD,
                        contents: contentsPtr,
                        contentsLen: 1,
                        confirm: confirm
                    )
                }
            }
        }
    }
}

@MainActor
private final class ClipboardConfirmationRecorder:
    TerminalSurfaceClipboardConfirmationDelegate {
    private(set) var requests: [TerminalClipboardConfirmationRequest] = []

    func terminalDidRequestClipboardConfirmation(
        _ request: TerminalClipboardConfirmationRequest
    ) {
        requests.append(request)
    }
}
