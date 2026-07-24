import GhosttyKit
@testable import GhosttyTerminal
import Testing

@MainActor
struct TerminalSearchCallbackTests {
    @Test
    func `start search delivers the resolved needle`() {
        let delegate = SearchRecorder()
        let bridge = TerminalCallbackBridge(delegate: delegate)
        let needle = "alpha"

        let handled = needle.withCString { pointer in
            var payload = ghostty_action_u()
            payload.start_search = ghostty_action_start_search_s(needle: pointer)
            return bridge.handleAction(
                ghostty_action_s(tag: GHOSTTY_ACTION_START_SEARCH, action: payload)
            )
        }

        #expect(handled)
        #expect(delegate.startedNeedle == needle)
    }

    /// `start_search` carries a null needle when it opens search without terms.
    @Test
    func `start search without a needle reports an empty string`() {
        let delegate = SearchRecorder()
        let bridge = TerminalCallbackBridge(delegate: delegate)
        var payload = ghostty_action_u()
        payload.start_search = ghostty_action_start_search_s(needle: nil)

        let handled = bridge.handleAction(
            ghostty_action_s(tag: GHOSTTY_ACTION_START_SEARCH, action: payload)
        )

        #expect(handled)
        #expect(delegate.startedNeedle == "")
    }

    @Test
    func `end search is delivered`() {
        let delegate = SearchRecorder()
        let bridge = TerminalCallbackBridge(delegate: delegate)

        let handled = bridge.handleAction(
            ghostty_action_s(tag: GHOSTTY_ACTION_END_SEARCH, action: ghostty_action_u())
        )

        #expect(handled)
        #expect(delegate.ended)
    }

    @Test
    func `counts are delivered as reported`() {
        let delegate = SearchRecorder()
        let bridge = TerminalCallbackBridge(delegate: delegate)

        var totalPayload = ghostty_action_u()
        totalPayload.search_total = ghostty_action_search_total_s(total: 6)
        var selectedPayload = ghostty_action_u()
        selectedPayload.search_selected = ghostty_action_search_selected_s(selected: 0)

        #expect(bridge.handleAction(
            ghostty_action_s(tag: GHOSTTY_ACTION_SEARCH_TOTAL, action: totalPayload)
        ))
        #expect(bridge.handleAction(
            ghostty_action_s(tag: GHOSTTY_ACTION_SEARCH_SELECTED, action: selectedPayload)
        ))

        #expect(delegate.total == 6)
        #expect(delegate.selected == 0)
    }

    /// Ghostty reports a negative total while a count is not yet known and a
    /// negative index while nothing is selected. Both surface as nil so hosts
    /// never render `-1` as a match count.
    @Test
    func `negative counts surface as unknown`() {
        let delegate = SearchRecorder()
        let bridge = TerminalCallbackBridge(delegate: delegate)

        var totalPayload = ghostty_action_u()
        totalPayload.search_total = ghostty_action_search_total_s(total: -1)
        var selectedPayload = ghostty_action_u()
        selectedPayload.search_selected = ghostty_action_search_selected_s(selected: -1)

        _ = bridge.handleAction(
            ghostty_action_s(tag: GHOSTTY_ACTION_SEARCH_TOTAL, action: totalPayload)
        )
        _ = bridge.handleAction(
            ghostty_action_s(tag: GHOSTTY_ACTION_SEARCH_SELECTED, action: selectedPayload)
        )

        #expect(delegate.receivedTotal)
        #expect(delegate.total == nil)
        #expect(delegate.receivedSelected)
        #expect(delegate.selected == nil)
    }

    @Test
    func `search actions are unhandled without a search delegate`() {
        let bridge = TerminalCallbackBridge(delegate: PlainDelegate())

        #expect(!bridge.handleAction(
            ghostty_action_s(tag: GHOSTTY_ACTION_END_SEARCH, action: ghostty_action_u())
        ))
        #expect(!bridge.handleAction(
            ghostty_action_s(tag: GHOSTTY_ACTION_SEARCH_TOTAL, action: ghostty_action_u())
        ))
    }
}

@MainActor
private final class PlainDelegate: TerminalSurfaceViewDelegate {}

@MainActor
private final class SearchRecorder: TerminalSurfaceSearchDelegate {
    private(set) var startedNeedle: String?
    private(set) var ended = false
    private(set) var total: Int?
    private(set) var receivedTotal = false
    private(set) var selected: Int?
    private(set) var receivedSelected = false

    func terminalDidStartSearch(needle: String) {
        startedNeedle = needle
    }

    func terminalDidEndSearch() {
        ended = true
    }

    func terminalDidUpdateSearchTotal(_ total: Int?) {
        receivedTotal = true
        self.total = total
    }

    func terminalDidUpdateSearchSelected(_ selected: Int?) {
        receivedSelected = true
        self.selected = selected
    }
}
