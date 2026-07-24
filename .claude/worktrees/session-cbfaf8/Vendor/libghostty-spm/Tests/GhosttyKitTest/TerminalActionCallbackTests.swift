import GhosttyKit
@testable import GhosttyTerminal
import Testing

@MainActor
struct TerminalActionCallbackTests {
    @Test
    func `open URL is handled when a delegate receives it`() {
        let delegate = OpenURLRecorder()
        let bridge = TerminalCallbackBridge(delegate: delegate)
        let url = "file:///tmp/history.vt"

        let handled = withOpenURLAction(url, kind: GHOSTTY_ACTION_OPEN_URL_KIND_TEXT) {
            bridge.handleAction($0)
        }

        #expect(handled)
        #expect(delegate.url == url)
        #expect(delegate.receivedTextKind)
    }

    @Test
    func `open URL is unhandled without an open URL delegate`() {
        let bridge = TerminalCallbackBridge(delegate: BasicDelegate())

        let handled = withOpenURLAction(
            "file:///tmp/history.vt",
            kind: GHOSTTY_ACTION_OPEN_URL_KIND_TEXT
        ) {
            bridge.handleAction($0)
        }

        #expect(!handled)
    }

    @Test
    func `other actions preserve unhandled fallback behavior`() {
        let bridge = TerminalCallbackBridge(delegate: BasicDelegate())
        let action = ghostty_action_s(
            tag: GHOSTTY_ACTION_RING_BELL,
            action: ghostty_action_u()
        )

        #expect(!bridge.handleAction(action))
    }

    private func withOpenURLAction<Result>(
        _ url: String,
        kind: ghostty_action_open_url_kind_e,
        operation: (ghostty_action_s) -> Result
    ) -> Result {
        url.withCString { pointer in
            var payload = ghostty_action_u()
            payload.open_url = ghostty_action_open_url_s(
                kind: kind,
                url: pointer,
                len: UInt(url.utf8.count)
            )
            return operation(
                ghostty_action_s(tag: GHOSTTY_ACTION_OPEN_URL, action: payload)
            )
        }
    }
}

@MainActor
private final class BasicDelegate: TerminalSurfaceViewDelegate {}

@MainActor
private final class OpenURLRecorder: TerminalSurfaceOpenURLDelegate {
    private(set) var url: String?
    private(set) var receivedTextKind = false

    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        self.url = url
        if case .text = kind {
            receivedTextKind = true
        }
    }
}
